(in-package #:self-improving-agent-harness)

(defparameter *fixed-baseline-fixture*
  '(:version "1"
    :id "baseline-answer-v1"
    :input "Submit the exact answer baseline-ok through submit_candidate."
    :acceptance-commands
    ((:name "answer-is-baseline-ok"
      :command "test \"$HARNESS_CANDIDATE_ANSWER\" = baseline-ok"))))

(defparameter *fixed-baseline-budget*
  '(:max-wall-seconds 5
    :max-provider-calls 2
    :max-total-tokens 32
    :max-cost-usd 0))
