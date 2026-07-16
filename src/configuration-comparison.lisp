(in-package #:self-improving-agent-harness)

(defun evaluation-record-verdict (evaluation-record)
  (if (typep evaluation-record 'evaluation)
      (evaluation-verdict evaluation-record)
      (getf evaluation-record :verdict)))

(defun evaluation-record-candidate-id (evaluation-record)
  (if (typep evaluation-record 'evaluation)
      (evaluation-candidate-id evaluation-record)
      (getf evaluation-record :candidate-id)))

(defun retention-decision-from-evaluations (baseline-evaluation candidate-evaluation)
  "Make a reproducible retention decision from persisted evaluator results only."
  (let* ((baseline-verdict (evaluation-record-verdict baseline-evaluation))
         (candidate-verdict (evaluation-record-verdict candidate-evaluation))
         (candidate-id (evaluation-record-candidate-id candidate-evaluation))
         (retain-p (and (eq baseline-verdict :pass) (eq candidate-verdict :pass)))
         (rationale
           (cond
             (retain-p "candidate evaluator passed under the baseline's equal explicit budget caps")
             ((not (eq baseline-verdict :pass))
              "baseline evaluator did not pass; no candidate can be retained")
             (t "candidate evaluator failed; reject deterministic regression"))))
    (serialize-domain-object
     (make-decision :candidate-id candidate-id
                    :action (if retain-p :retain :reject)
                    :rationale rationale
                    :evaluation-reference candidate-id))))

(defun comparison-candidate-summary (candidate)
  (list :id (candidate-id candidate)
        :parent-id (candidate-parent-id candidate)
        :configuration-hash (candidate-configuration-hash candidate)
        :configuration (candidate-configuration candidate)
        :model-id (getf (candidate-configuration candidate) :model-id)))

(defun evaluation-from-baseline-result (candidate result evaluator-id)
  (make-evaluation :candidate-id (candidate-id candidate)
                   :evaluator-id evaluator-id
                   :verdict (if (eq (getf result :outcome) :success) :pass :fail)
                   :evidence (getf result :evidence)
                   :outcome (getf result :outcome)
                   :accounting (getf result :accounting)))

(defun run-configuration-comparison (experiment fixture baseline candidates backend-factory)
  "Evaluate BASELINE and CANDIDATES under one shared explicit experiment budget.

BACKEND-FACTORY receives a candidate and returns a backend.  Evaluation facts,
not candidate self-assessment, are persisted and are the only inputs to the
retention policy."
  (validate-experiment experiment)
  (unless (baseline-budget-valid-p (experiment-budget experiment))
    (error "Configuration comparison requires #12 explicit evaluator budget caps."))
  (unless (and (string= (candidate-experiment-id baseline) (experiment-id experiment))
               (every (lambda (candidate)
                        (and (string= (candidate-experiment-id candidate) (experiment-id experiment))
                             (string= (candidate-parent-id candidate) (candidate-id baseline))))
                      candidates))
    (error "Comparison candidates must share experiment and baseline lineage."))
  (let* ((budget (experiment-budget experiment))
         (evaluator-id (or (getf (experiment-evaluator experiment) :id)
                           "deterministic-command"))
         (baseline-result (run-baseline-fixture fixture (funcall backend-factory baseline) budget))
         (baseline-evaluation
           (serialize-domain-object
            (evaluation-from-baseline-result baseline baseline-result evaluator-id))))
    (list :schema-version +run-report-schema-version+
          :report-type "configuration-comparison"
          :experiment-id (experiment-id experiment)
          :budget budget
          :baseline (comparison-candidate-summary baseline)
          :baseline-outcome (getf baseline-result :outcome)
          :baseline-accounting (getf baseline-result :accounting)
          :baseline-evaluation baseline-evaluation
          :comparisons
          (loop for candidate in candidates
                for result = (run-baseline-fixture fixture (funcall backend-factory candidate) budget)
                for evaluation = (serialize-domain-object
                                  (evaluation-from-baseline-result candidate result evaluator-id))
                collect (list :candidate (comparison-candidate-summary candidate)
                              :outcome (getf result :outcome)
                              :accounting (getf result :accounting)
                              :evaluation evaluation
                              :decision (retention-decision-from-evaluations
                                         baseline-evaluation evaluation))))))
