(in-package #:self-improving-agent-harness)

(defexperiment offline-summary-example
  :id "offline-summary-example"
  :task-fixture '(:kind :inline :input "Summarize this fixture in one sentence.")
  :acceptance-criteria '((:kind :contains :value "summary")
                          (:kind :max-words :value 30))
  :agent-configuration '(:backend :scripted :model "offline/example")
  :evaluator '(:kind :deterministic :id "offline-summary-check")
  :budget '(:max-runs 1 :max-provider-calls 0 :max-cost-usd 0))
