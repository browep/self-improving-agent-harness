(in-package #:self-improving-agent-harness)

(defun normalize-command-check (check)
  "Normalize a completed deterministic command CHECK without retaining its output.

CHECK is a plist containing :NAME and :EXIT-CODE.  Its optional :OUTPUT is
intentionally excluded from returned evidence because command output can contain
sensitive task or tool data."
  (let ((exit-code (getf check :exit-code)))
    (list :verdict (if (zerop exit-code) :pass :fail)
          :evidence (list :name (getf check :name)
                          :status (if (zerop exit-code) :pass :fail)
                          :exit-code exit-code))))

(defun baseline-budget-valid-p (budget)
  (and (numberp (getf budget :max-wall-seconds))
       (plusp (getf budget :max-wall-seconds))
       (integerp (getf budget :max-provider-calls))
       (plusp (getf budget :max-provider-calls))
       (numberp (getf budget :max-total-tokens))
       (not (minusp (getf budget :max-total-tokens)))
       (numberp (getf budget :max-cost-usd))
       (not (minusp (getf budget :max-cost-usd)))))

(defun run-baseline-command (check answer timeout)
  "Run one fixture command and return sanitized normalized evidence."
  (multiple-value-bind (output error-output exit-code)
      (uiop:run-program (list "/bin/sh" "-lc" (getf check :command))
                        :output :string
                        :error-output :string
                        :ignore-error-status t
                        :timeout timeout
                        :env (list (cons :|HARNESS_CANDIDATE_ANSWER| answer)))
    (declare (ignore output error-output))
    (normalize-command-check
     (list :name (getf check :name) :exit-code exit-code))))

(defun baseline-usage-within-budget-p (response budget)
  (let ((total-tokens (getf (completion-response-usage response) :total-tokens)))
    (or (null total-tokens)
        (<= total-tokens (getf budget :max-total-tokens)))))

(defun run-baseline-fixture (fixture backend budget)
  "Execute a versioned FIXTURE through BACKEND's existing tool-loop seam.

The fixture owns its input and deterministic acceptance commands.  The backend
only supplies a candidate answer through the submit_candidate tool, and cannot
alter evaluation commands or budgets.  Returned evidence contains names,
statuses, and exit codes only; it deliberately excludes assistant and command
output."
  (unless (and (stringp (getf fixture :version))
               (stringp (getf fixture :id))
               (stringp (getf fixture :input))
               (listp (getf fixture :acceptance-commands))
               (baseline-budget-valid-p budget))
    (error "Baseline fixture requires version, id, input, commands, and explicit budgets."))
  (let ((answer nil))
    (handler-case
        (let* ((response
                 (run-tool-loop
                  backend
                  (make-completion-request
                   :model "baseline/scripted"
                   :messages (list (list :role "user" :content (getf fixture :input))))
                  `(("submit_candidate" .
                     ,(lambda (arguments)
                        (setf answer (gethash "answer" arguments))
                        "candidate received")))
                  :max-rounds (1- (getf budget :max-provider-calls))))
               (checks (mapcar (lambda (check)
                                 (run-baseline-command check answer
                                                       (getf budget :max-wall-seconds)))
                               (getf fixture :acceptance-commands)))
               (evidence (mapcar (lambda (check) (getf check :evidence)) checks)))
          (cond
            ((not (baseline-usage-within-budget-p response budget))
             (list :outcome :execution-failure
                   :evidence '((:stage :budget :status :exceeded))))
            ((some (lambda (check) (eq :fail (getf check :verdict))) checks)
             (list :outcome :acceptance-failure :evidence evidence))
            (t
             (list :outcome :success :evidence evidence))))
      (error ()
        (list :outcome :execution-failure
              :evidence '((:stage :execution :status :failed)))))))

(defvar *fixed-baseline-fixture*)
(defvar *fixed-baseline-budget*)

(defclass fixed-baseline-backend (backend)
  ((responses :initarg :responses :accessor fixed-baseline-responses)))

(defmethod complete ((backend fixed-baseline-backend) request)
  (declare (ignore request))
  (or (pop (fixed-baseline-responses backend))
      (error "Fixed baseline backend exhausted its scripted responses.")))

(defun run-fixed-baseline ()
  "Run the checked-in versioned scripted baseline without provider credentials."
  (load "fixtures/baseline-answer-v1.lisp")
  (run-baseline-fixture
   *fixed-baseline-fixture*
   (make-instance
    'fixed-baseline-backend :name "fixed-scripted-baseline"
    :responses
    (list
     (make-completion-response
      :model "offline/baseline-v1"
      :tool-calls '((:id "submit-baseline-v1" :type "function"
                     :name "submit_candidate"
                     :arguments "{\"answer\":\"baseline-ok\"}")))
     (make-completion-response :model "offline/baseline-v1" :text "submitted")))
   *fixed-baseline-budget*))
