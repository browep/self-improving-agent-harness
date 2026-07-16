(in-package #:self-improving-agent-harness/tests)

(defun run-experiment-model-tests ()
  (let ((experiment
          (self-improving-agent-harness::make-experiment
           :id "offline-summary"
           :task-fixture '(:kind :inline :input "Summarize this fixture.")
           :acceptance-criteria '((:kind :contains :value "summary"))
           :agent-configuration '(:backend :scripted :model "offline")
           :evaluator '(:kind :deterministic)
           :budget '(:max-runs 1 :max-provider-calls 0))))
    (self-improving-agent-harness::register-experiment experiment)
    (ensure-true
     (eq experiment
         (self-improving-agent-harness::find-experiment "offline-summary"))
     "a complete experiment registers under its stable identifier"))
  (eval
   '(self-improving-agent-harness:defexperiment dsl-offline-example
      :id "dsl-offline-example"
      :task-fixture '(:kind :inline :input "Summarize this fixture.")
      :acceptance-criteria '((:kind :contains :value "summary"))
      :agent-configuration '(:backend :scripted :model "offline")
      :evaluator '(:kind :deterministic)
      :budget '(:max-runs 1 :max-provider-calls 0)))
  (ensure-true
   (self-improving-agent-harness::find-experiment "dsl-offline-example")
   "defexperiment validates and registers a complete declaration")
  (handler-case
      (progn
        (eval
         '(self-improving-agent-harness:defexperiment incomplete-example
            :id "incomplete-example"
            :task-fixture '(:kind :inline :input "missing fields")))
        (error "Test failed: incomplete DSL declarations must fail before execution"))
    (error ()
      (ensure-true
       (null (self-improving-agent-harness::find-experiment "incomplete-example"))
       "invalid DSL declarations do not register or execute")))
  (let* ((experiment (self-improving-agent-harness::find-experiment "offline-summary"))
         (root (self-improving-agent-harness::materialize-candidate
                experiment :id "offline-summary/root" :configuration '(:strategy :baseline)))
         (child (self-improving-agent-harness::materialize-candidate
                 experiment :id "offline-summary/rewrite-1"
                 :parent-candidate root :configuration '(:strategy :rewrite)))
         (record (self-improving-agent-harness::make-run-record
                  :id "run-1" :candidate-id "offline-summary/rewrite-1"
                  :outcome :passed))
         (evaluation (self-improving-agent-harness::make-evaluation
                      :candidate-id "offline-summary/rewrite-1"
                      :verdict :pass :evidence '(:checks 1)))
         (decision (self-improving-agent-harness::make-decision
                    :candidate-id "offline-summary/rewrite-1"
                    :action :retain :rationale "deterministic evaluator passed"))
         (serialized (self-improving-agent-harness::serialize-domain-object child)))
    (ensure-true (string= "offline-summary/rewrite-1"
                          (self-improving-agent-harness::candidate-id child))
                 "candidate materialization preserves its stable identifier")
    (ensure-true (string= "offline-summary/root"
                          (self-improving-agent-harness::candidate-parent-id child))
                 "candidate materialization retains parent lineage")
    (ensure-true (and (typep record 'self-improving-agent-harness::run-record)
                      (typep evaluation 'self-improving-agent-harness::evaluation)
                      (typep decision 'self-improving-agent-harness::decision))
                 "run records, evaluations, and decisions are first-class domain types")
    (ensure-true (equal "1" (getf serialized :schema-version))
                 "domain serialization carries a stable schema version")
    (ensure-true (equal "candidate" (getf serialized :type))
                 "candidate serialization identifies its domain type"))
  (load "examples/offline-summary.lisp")
  (ensure-true
   (self-improving-agent-harness::find-experiment "offline-summary-example")
   "the checked-in DSL example loads as a complete registered experiment")
  (dolist (name '("RUN-RECORD-ID" "RUN-RECORD-CANDIDATE-ID"
                  "EVALUATION-CANDIDATE-ID" "EVALUATION-VERDICT"
                  "DECISION-CANDIDATE-ID" "DECISION-ACTION"))
    (multiple-value-bind (symbol status)
        (find-symbol name :self-improving-agent-harness)
      (ensure-true (and symbol (eq status :external))
                   "domain readers are public extension points"))))
