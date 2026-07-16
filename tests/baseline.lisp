(in-package #:self-improving-agent-harness/tests)

(defun run-baseline-tests ()
  (let ((evaluation
          (self-improving-agent-harness:normalize-command-check
           '(:name "acceptance" :command "true" :exit-code 0 :output "ok"))))
    (ensure-true (eq :pass (getf evaluation :verdict))
                 "a zero-exit acceptance command normalizes to pass")
    (ensure-true (equal '(:name "acceptance" :status :pass :exit-code 0)
                        (getf evaluation :evidence))
                 "normalized evidence omits raw command output"))
  (let ((evaluation
          (self-improving-agent-harness:normalize-command-check
           '(:name "acceptance" :command "false" :exit-code 1
             :output "sensitive failure output"))))
    (ensure-true (eq :fail (getf evaluation :verdict))
                 "a nonzero acceptance command normalizes to fail")
    (ensure-true (equal '(:name "acceptance" :status :fail :exit-code 1)
                        (getf evaluation :evidence))
                 "failed normalized evidence omits raw command output"))
  (let* ((backend
           (make-instance 'scripted-backend :name "scripted"
                            :responses
                            (list (make-completion-response
                                   :model "offline/baseline"
                                   :tool-calls '((:id "submit-1" :type "function"
                                                  :name "submit_candidate"
                                                  :arguments "{\"answer\":\"baseline-ok\"}")))
                                  (make-completion-response :text "submitted"
                                                            :model "offline/baseline"))))
         (result
           (self-improving-agent-harness:run-baseline-fixture
            '(:version "1" :id "baseline-fixture" :input "Return baseline-ok."
              :acceptance-commands ((:name "answer-is-baseline-ok"
                                     :command "test \"$HARNESS_CANDIDATE_ANSWER\" = baseline-ok")))
            backend
            '(:max-wall-seconds 5 :max-provider-calls 2
              :max-total-tokens 20 :max-cost-usd 0))))
    (ensure-true (eq :success (getf result :outcome))
                 "a scripted baseline completes through the tool-loop seam")
    (ensure-true (equal '((:name "answer-is-baseline-ok" :status :pass :exit-code 0))
                        (getf result :evidence))
                 "baseline success returns normalized deterministic evidence")
    (ensure-true (= 2 (length (scripted-backend-received-requests backend)))
                 "baseline submits its task through the existing backend loop"))
  (let ((result
          (self-improving-agent-harness:run-baseline-fixture
           '(:version "1" :id "token-budget-fixture" :input "Submit an answer."
             :acceptance-commands ((:name "answer-is-baseline-ok"
                                    :command "test \"$HARNESS_CANDIDATE_ANSWER\" = baseline-ok")))
           (make-instance 'scripted-backend :name "scripted"
                          :responses
                          (list (make-completion-response
                                 :model "offline/baseline"
                                 :usage '(:total-tokens 21)
                                 :tool-calls '((:id "submit-budget" :type "function"
                                                :name "submit_candidate"
                                                :arguments "{\"answer\":\"baseline-ok\"}")))
                                (make-completion-response :model "offline/baseline"
                                                          :text "submitted"
                                                          :usage '(:total-tokens 0))))
           '(:max-wall-seconds 5 :max-provider-calls 2
             :max-total-tokens 20 :max-cost-usd 0))))
    (ensure-true (eq :execution-failure (getf result :outcome))
                 "token budgets include every provider response in the tool loop"))
  (let ((result
          (self-improving-agent-harness:run-baseline-fixture
           '(:version "1" :id "cost-budget-fixture" :input "Submit an answer."
             :acceptance-commands ((:name "answer-is-baseline-ok"
                                    :command "test \"$HARNESS_CANDIDATE_ANSWER\" = baseline-ok")))
           (make-instance 'scripted-backend :name "scripted"
                          :responses
                          (list (make-completion-response
                                 :model "offline/baseline"
                                 :usage '(:total-tokens 1 :cost-usd 0.01)
                                 :tool-calls '((:id "submit-cost" :type "function"
                                                :name "submit_candidate"
                                                :arguments "{\"answer\":\"baseline-ok\"}")))
                                (make-completion-response :model "offline/baseline"
                                                          :text "submitted"
                                                          :usage '(:total-tokens 1 :cost-usd 0))))
           '(:max-wall-seconds 5 :max-provider-calls 2
             :max-total-tokens 20 :max-cost-usd 0))))
    (ensure-true (eq :execution-failure (getf result :outcome))
                 "cost budgets include every provider response in the tool loop"))
  (let ((result (self-improving-agent-harness:run-fixed-baseline)))
    (ensure-true (eq :success (getf result :outcome))
                 "the checked-in fixed baseline is runnable without credentials")
    (ensure-true (equal '((:name "answer-is-baseline-ok" :status :pass :exit-code 0))
                        (getf result :evidence))
                 "the fixed baseline reports sanitized acceptance evidence"))
  (let ((failure
          (self-improving-agent-harness:run-baseline-fixture
           '(:version "1" :id "failure-fixture" :input "Submit an answer."
             :acceptance-commands ((:name "always-fails" :command "false")))
           (make-instance 'scripted-backend :name "scripted"
                          :responses (list (make-completion-response
                                            :tool-calls '((:id "submit-2" :type "function"
                                                           :name "submit_candidate"
                                                           :arguments "{\"answer\":\"wrong\"}")))
                                           (make-completion-response :text "submitted")))
           '(:max-wall-seconds 5 :max-provider-calls 2
             :max-total-tokens 20 :max-cost-usd 0))))
    (ensure-true (eq :acceptance-failure (getf failure :outcome))
                 "a completed candidate with a failing command is an acceptance failure")
    (ensure-true (equal '((:name "always-fails" :status :fail :exit-code 1))
                        (getf failure :evidence))
                 "acceptance failure evidence remains normalized"))
  (let ((failure
          (self-improving-agent-harness:run-baseline-fixture
           '(:version "1" :id "execution-fixture" :input "Submit an answer."
             :acceptance-commands ((:name "unreached" :command "true")))
           (make-instance 'scripted-backend :name "scripted" :responses '())
           '(:max-wall-seconds 5 :max-provider-calls 2
             :max-total-tokens 20 :max-cost-usd 0))))
    (ensure-true (eq :execution-failure (getf failure :outcome))
                 "backend failures are distinct from acceptance failures")))
