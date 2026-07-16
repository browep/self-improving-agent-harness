(in-package #:self-improving-agent-harness/tests)

(defun comparison-scripted-backend (candidate)
  (let ((answer (if (string= (getf (candidate-configuration candidate) :model-id)
                              "offline/regression")
                    "wrong"
                    "baseline-ok")))
    (make-instance
     'scripted-backend :name "comparison-scripted"
     :responses
     (list (make-completion-response
            :model (getf (candidate-configuration candidate) :model-id)
            :usage '(:total-tokens 8 :cost-usd 0.004)
            :tool-calls `((:id "submit-comparison" :type "function"
                           :name "submit_candidate"
                           :arguments ,(format nil "{\"answer\":\"~A\"}" answer))))
           (make-completion-response
            :model (getf (candidate-configuration candidate) :model-id)
            :text "submitted" :usage '(:total-tokens 2 :cost-usd 0.001))))))

(defun run-configuration-comparison-tests ()
  (let* ((experiment
           (make-experiment
            :id "offline-configuration-comparison"
            :task-fixture '(:kind :inline :input "Submit baseline-ok.")
            :acceptance-criteria '((:kind :deterministic-command))
            :agent-configuration
            '(:model-id "offline/baseline" :prompt-template-version "v1"
              :max-rounds 2 :tool-workflow-strategy "submit-once")
            :evaluator '(:kind :deterministic-command :id "offline-evaluator-v1")
            :budget '(:max-wall-seconds 5 :max-provider-calls 2
                      :max-total-tokens 32 :max-cost-usd 1)))
         (baseline (materialize-candidate
                    experiment :id "offline-configuration-comparison/baseline"
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
            '(:version "1" :id "comparison-fixture" :input "Submit baseline-ok."
              :acceptance-commands ((:name "answer-is-baseline-ok"
                                     :command "test \"$HARNESS_CANDIDATE_ANSWER\" = baseline-ok")))
            baseline candidates #'comparison-scripted-backend))
         (entries (getf record :comparisons))
         (regression (find "offline/regression" entries :test #'search
                           :key (lambda (entry) (getf (getf entry :candidate) :model-id)))))
    (ensure-true (equal (getf record :budget) (experiment-budget experiment))
                 "baseline and every configuration candidate receive the same explicit budget caps")
    (ensure-true (= 2 (length entries))
                 "the comparison retains a record for every generated candidate")
    (dolist (entry entries)
      (let ((accounting (getf entry :accounting)))
        (ensure-true (and (= 2 (getf accounting :provider-calls))
                          (= 10 (getf accounting :total-tokens))
                          (< (abs (- 0.005 (getf accounting :cost-usd))) 0.000001))
                     "comparison preserves actual provider-call, token, and cost accounting"))
      (ensure-true (getf entry :evaluation)
                   "comparison persists evaluator-owned results for retention replay"))
    (ensure-true (eq :reject (getf (getf regression :decision) :action))
                 "the retention policy rejects a deterministic regression")
    (ensure-true (search "regression" (getf (getf regression :decision) :rationale))
                 "rejected regressions retain an auditable rationale")
    (ensure-true (equal (getf (getf regression :decision) :action)
                        (getf (retention-decision-from-evaluations
                               (getf record :baseline-evaluation)
                               (getf regression :evaluation))
                              :action))
                 "retention is reproducible from persisted evaluator results rather than self-assessment")
    (let* ((directory (merge-pathnames
                       (format nil "self-improving-agent-harness-comparison-~D/"
                               (get-universal-time))
                       (uiop:temporary-directory)))
           (artifacts (write-configuration-comparison-report record directory))
           (json (uiop:read-file-string (getf artifacts :json-path)))
           (html (uiop:read-file-string (getf artifacts :html-path))))
      (unwind-protect
           (progn
             (ensure-true (and (plusp (length json)) (plusp (length html)))
                          "comparison writes nonempty paired JSON and HTML artifacts")
             (ensure-true (search "baseline_evaluation" json)
                          "comparison JSON includes baseline evaluator evidence")
             (ensure-true (search "provider_calls" json)
                          "comparison JSON includes actual provider-call accounting")
             (dolist (json-budget-cap '("max_wall_seconds" "max_provider_calls" "max_total_tokens" "max_cost_usd"))
               (ensure-true (search json-budget-cap json)
                            "comparison JSON retains each explicit non-sensitive budget cap"))
             (dolist (html-budget-cap '(":MAX-WALL-SECONDS" ":MAX-PROVIDER-CALLS" ":MAX-TOTAL-TOKENS" ":MAX-COST-USD"))
               (ensure-true (search html-budget-cap html)
                            "comparison HTML retains each explicit non-sensitive budget cap"))
             (ensure-true (search "Baseline vs candidate comparison" html)
                          "comparison HTML renders the baseline-versus-candidate evidence")
             (ensure-true (search "offline/regression" html)
                          "comparison HTML includes candidate configuration identity"))
        (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore)))))
