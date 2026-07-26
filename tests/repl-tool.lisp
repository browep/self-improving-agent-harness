(in-package #:self-improving-agent-harness/tests)

(defun make-eval-lisp-arguments (&key code timeout)
  (let ((arguments (make-hash-table :test #'equal)))
    (when code
      (setf (gethash "code" arguments) code))
    (when timeout
      (setf (gethash "timeout" arguments) timeout))
    arguments))

(defun run-eval-lisp-tests ()
  ;; Basic arithmetic: return value is printed after "=> ".
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "(+ 1 2)"))))
    (ensure-true (search "=> 3" output)
                 "eval_lisp returns the printed value of a simple form"))
  ;; Multiple forms: only the last form's value is the printed result.
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "(defparameter *eval-lisp-test-var* 41) (1+ *eval-lisp-test-var*)"))))
    (ensure-true (search "=> 42" output)
                 "eval_lisp evaluates every form and returns the last form's value"))
  ;; Captured standard output is included ahead of the printed value.
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "(format t \"hello-from-eval-lisp\")"))))
    (ensure-true (search "hello-from-eval-lisp" output)
                 "eval_lisp captures *standard-output* text produced during eval")
    (ensure-true (search "=>" output)
                 "eval_lisp still reports a printed return value after captured output"))
  ;; Forms run in the harness package: bare harness symbols resolve.
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments
            :code "(stringp (backend-name (make-openrouter-backend :api-key \"test-key\")))"))))
    (ensure-true (search "=> T" output)
                 "eval_lisp evaluates forms in the self-improving-agent-harness package"))
  ;; Definitions persist across separate tool calls in the same image.
  (self-improving-agent-harness::eval-lisp-tool
   (make-eval-lisp-arguments :code "(defun eval-lisp-test-fn () :eval-lisp-test-marker)"))
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "(eval-lisp-test-fn)"))))
    (ensure-true (search "EVAL-LISP-TEST-MARKER" output)
                 "eval_lisp definitions persist in the running image across calls"))
  ;; Reader/eval errors are returned as a string, never signaled.
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "(this-symbol-is-not-fbound-anywhere)"))))
    (ensure-true (search "eval_lisp failed" output)
                 "eval_lisp reports an evaluation error as a string result"))
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "(unbalanced-paren"))))
    (ensure-true (search "eval_lisp failed" output)
                 "eval_lisp reports a reader (syntax) error as a string result"))
  ;; A hanging form is interrupted by the timeout, not left to hang forever.
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "(loop)" :timeout 1))))
    (ensure-true (search "timed out after 1 seconds" output)
                 "eval_lisp reports a helpful timeout message for a hanging form"))
  ;; #. reader macros do not execute at read time (READ-EVAL is bound NIL).
  (let ((output
          (self-improving-agent-harness::eval-lisp-tool
           (make-eval-lisp-arguments :code "#.(quote (+ 1 1))"))))
    (ensure-true (or (search "eval_lisp failed" output)
                     (search "*READ-EVAL*" output))
                 "eval_lisp disables #. read-time evaluation for submitted code"))
  ;; eval_lisp requires a non-empty code string.
  (handler-case
      (progn
        (self-improving-agent-harness::eval-lisp-tool (make-eval-lisp-arguments))
        (error "Test failed: eval_lisp must reject a missing code argument"))
    (error (condition)
      (ensure-true (search "non-empty code" (princ-to-string condition))
                   "eval_lisp rejects a missing code argument")))
  ;; eval_lisp is registered in the live chat tool schema and handler alist.
  (let* ((definitions (self-improving-agent-harness:chat-tool-definitions))
         (names (mapcar (lambda (definition)
                           (getf (getf definition :function) :name))
                         definitions)))
    (ensure-true (member "eval_lisp" names :test #'string=)
                 "eval_lisp is advertised in chat-tool-definitions"))
  (let* ((handlers (self-improving-agent-harness:chat-handlers))
         (entry (assoc "eval_lisp" handlers :test #'string=)))
    (ensure-true (and entry (eq (cdr entry) 'self-improving-agent-harness::eval-lisp-tool))
                 "chat-handlers dispatches eval_lisp to eval-lisp-tool"))
  ;; A subagent also gets eval_lisp (in addition to run_shell), never
  ;; reload_harness or run_subagent (no-recursion structural enforcement).
  (let* ((definitions (self-improving-agent-harness::subagent-tool-definitions))
         (names (mapcar (lambda (definition)
                           (getf (getf definition :function) :name))
                         definitions)))
    (ensure-true (member "run_shell" names :test #'string=)
                 "subagent tool set still includes run_shell")
    (ensure-true (member "eval_lisp" names :test #'string=)
                 "subagent tool set includes eval_lisp")
    (ensure-true (not (member "reload_harness" names :test #'string=))
                 "subagent tool set excludes reload_harness")
    (ensure-true (not (member "run_subagent" names :test #'string=))
                 "subagent tool set excludes run_subagent (no recursion)"))
  (let* ((handlers (self-improving-agent-harness::subagent-tool-handlers)))
    (ensure-true (assoc "eval_lisp" handlers :test #'string=)
                 "subagent tool handlers include eval_lisp"))
  t)
