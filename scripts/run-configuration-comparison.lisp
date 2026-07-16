(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

(in-package #:self-improving-agent-harness)

(defclass offline-comparison-backend (backend)
  ((responses :initarg :responses :accessor offline-comparison-responses)))

(defmethod complete ((backend offline-comparison-backend) request)
  (declare (ignore request))
  (or (pop (offline-comparison-responses backend))
      (error "Offline comparison backend exhausted its scripted responses.")))

(defun offline-comparison-backend-for (candidate)
  (let ((model-id (getf (candidate-configuration candidate) :model-id)))
    (make-instance
     'offline-comparison-backend :name "offline-configuration-comparison"
     :responses
     (list
      (make-completion-response
       :model model-id :usage '(:total-tokens 8 :cost-usd 0.004)
       :tool-calls
       `((:id "submit-offline-comparison" :type "function" :name "submit_candidate"
          :arguments ,(format nil "{\"answer\":\"~A\"}"
                              (if (string= model-id "offline/regression") "wrong" "baseline-ok")))))
      (make-completion-response :model model-id :text "submitted"
                                :usage '(:total-tokens 2 :cost-usd 0.001))))))

(let* ((experiment
         (make-experiment
          :id "configuration-comparison-v1"
          :task-fixture '(:kind :inline :input "Submit baseline-ok.")
          :acceptance-criteria '((:kind :deterministic-command))
          :agent-configuration
          '(:model-id "offline/baseline" :prompt-template-version "v1"
            :max-rounds 2 :tool-workflow-strategy "submit-once")
          :evaluator '(:kind :deterministic-command :id "offline-evaluator-v1")
          :budget '(:max-wall-seconds 5 :max-provider-calls 2
                    :max-total-tokens 32 :max-cost-usd 1)))
       (baseline (materialize-candidate
                  experiment :id "configuration-comparison-v1/baseline"
                  :configuration (experiment-agent-configuration experiment)))
       (candidates
         (generate-configuration-candidates
          (make-instance 'deterministic-configuration-generator)
          experiment baseline
          '(:model-id ("offline/improvement" "offline/regression")
            :prompt-template-version ("v1") :max-rounds (2)
            :tool-workflow-strategy ("submit-once"))))
       (record
         (run-configuration-comparison
          experiment
          '(:version "1" :id "configuration-comparison-fixture"
            :input "Submit baseline-ok."
            :acceptance-commands ((:name "answer-is-baseline-ok"
                                   :command "test \"$HARNESS_CANDIDATE_ANSWER\" = baseline-ok")))
          baseline candidates #'offline-comparison-backend-for))
       (artifacts (write-configuration-comparison-report
                   record "reports/configuration-comparison-v1/")))
  (format t "JSON report: ~A~%HTML report: ~A~%" (getf artifacts :json-path) (getf artifacts :html-path))
  (unless (and (probe-file (getf artifacts :json-path)) (probe-file (getf artifacts :html-path)))
    (uiop:quit 1)))
