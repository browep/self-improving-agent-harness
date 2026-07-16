(in-package #:self-improving-agent-harness/tests)

(defun run-candidate-generation-tests ()
  (let* ((experiment
           (make-experiment
            :id "configuration-comparison-v1"
            :task-fixture '(:kind :inline :input "Submit baseline-ok.")
            :acceptance-criteria '((:kind :deterministic-command))
            :agent-configuration
            '(:model-id "offline/baseline-v1" :prompt-template-version "v1"
              :max-rounds 2 :tool-workflow-strategy "submit-once")
            :evaluator '(:kind :deterministic-command)
            :budget '(:max-wall-seconds 5 :max-provider-calls 2
                      :max-total-tokens 32 :max-cost-usd 1)))
         (baseline (materialize-candidate
                    experiment :id "configuration-comparison-v1/baseline"
                    :configuration (experiment-agent-configuration experiment)))
         (mutation-space
           '(:model-id ("offline/candidate-a" "offline/candidate-b")
             :prompt-template-version ("v2")
             :max-rounds (2)
             :tool-workflow-strategy ("submit-once")))
         (generator (make-instance 'deterministic-configuration-generator))
         (candidates (generate-configuration-candidates
                      generator experiment baseline mutation-space)))
    (ensure-true (typep generator 'candidate-generator)
                 "the configuration candidate generator implements the generator protocol")
    (ensure-true (= 2 (length candidates))
                 "one explicit mutation space deterministically generates at least two candidates")
    (dolist (candidate candidates)
      (ensure-true (stringp (candidate-configuration-hash candidate))
                   "each generated candidate has a stable configuration hash")
      (ensure-true (plusp (length (candidate-configuration-hash candidate)))
                   "candidate configuration hashes are non-empty")
      (ensure-true (string= (candidate-parent-id candidate) (candidate-id baseline))
                   "each generated candidate retains baseline parent lineage")
      (ensure-true (equal (candidate-configuration candidate)
                          (canonical-configuration (candidate-configuration candidate)))
                   "generated candidate configurations are canonical and explicit"))
    (ensure-true (equal (mapcar #'candidate-id candidates)
                        (mapcar #'candidate-id
                                (generate-configuration-candidates
                                 generator experiment baseline mutation-space)))
                 "candidate generation is stable for the declared mutation space")))
