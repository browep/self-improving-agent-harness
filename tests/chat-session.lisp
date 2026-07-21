(in-package #:self-improving-agent-harness/tests)

(defun message-role (message)
  (getf message :role))

(defun run-chat-session-tests ()
  (let ((system-prompt +chat-system-prompt+))
    (dolist (required-text
             '("evidence-driven improvement"
               "allow-all"
               "Do not treat your own final response as acceptance evidence."
               "Do not weaken, replace, or silently redefine"
               "Docker-only"
               "reload_harness"
               "external supervisor owns isolation, budgets, independent evidence, and promotion decisions"
               "Never expose credentials"
               "native tools/tool_calls"
               "Never put tool invocations in assistant text"
               "chunked commands"))
      (ensure-true (search required-text system-prompt)
                   (format nil "system prompt preserves worker contract: ~A" required-text))))
  (let* ((first-response (make-completion-response :text "first answer" :model "test/model"))
         (second-response (make-completion-response :text "second answer" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list first-response second-response)))
         (session (make-chat-session :backend backend :model "test/model"
                                     :options '(:max-tokens 512) :handlers '())))
    (ensure-true (null (chat-session-turn session "") )
                 "empty interactive input is ignored")
    (ensure-equal 0 (length (scripted-backend-received-requests backend))
                  "empty interactive input makes no backend request")
    (chat-session-turn session "first question")
    (chat-session-turn session "second question")
    (let* ((requests (reverse (scripted-backend-received-requests backend)))
           (second-request (second requests))
           (second-messages (completion-request-messages second-request)))
      (ensure-equal 4 (length second-messages)
                    "second turn carries the prior completed exchange")
      (ensure-equal "system" (message-role (first second-messages))
                    "history begins with the system prompt")
      (ensure-equal "first question" (getf (second second-messages) :content)
                    "second request retains the first user turn")
      (ensure-equal "first answer" (getf (third second-messages) :content)
                    "second request retains the first assistant response")
      (ensure-equal "second question" (getf (fourth second-messages) :content)
                    "second request ends with the current user turn")))
  (let* ((tool-response
           (make-completion-response
            :text ""
            :model "test/model"
            :provider-request-id "provider-tool-1"
            :raw '(:provider-body "provider secret" :tool-output "tool input")
            :usage '(:prompt-tokens 2 :completion-tokens 1 :total-tokens 3 :cost-usd 0.001)
            :tool-calls '((:id "call-session" :type "function" :name "echo"
                           :arguments "{\"message\":\"tool input\"}"))))
         (final-response (make-completion-response :text "tool answer" :model "test/model"
                                                   :provider-request-id "provider-tool-2"
                                                   :usage '(:prompt-tokens 3 :completion-tokens 1
                                                            :total-tokens 4 :cost-usd 0.002)))
         (backend (make-instance 'scripted-backend :name "scripted"
                                 :responses (list tool-response final-response)))
         (session (make-chat-session
                   :backend backend :model "test/model"
                   :handlers `(("echo" . ,(lambda (arguments)
                                            (format nil "echo: ~A"
                                                    (gethash "message" arguments))))))))
    (chat-session-turn session "use the tool")
    (let ((history (chat-session-history session)))
      (ensure-equal '("system" "user" "assistant" "tool" "assistant")
                    (mapcar #'message-role history)
                    "interactive history preserves tool-loop message order")
      (ensure-equal "call-session" (getf (fourth history) :tool-call-id)
                    "interactive tool result stays linked to its tool call")
      (ensure-equal "tool answer" (getf (fifth history) :content)
                    "interactive history retains the final tool-turn response")
      (ensure-equal 2 (length (chat-session-last-provider-responses session))
                    "a successful tool turn retains every provider response in order")
      (let ((accounting (chat-session-last-accounting session)))
        (ensure-equal 2 (getf accounting :provider-call-count)
                      "accounting includes every tool-loop provider call")
        (ensure-equal 7 (getf (getf accounting :aggregate) :total-tokens)
                      "accounting sums authoritative token totals across tool-loop calls")
        (ensure-equal 0.003 (getf (getf accounting :aggregate) :cost-usd)
                      "accounting sums cost only when each tool-loop call supplied it")
        (ensure-true (not (search "tool input" (prin1-to-string accounting)))
                     "sanitized accounting does not expose tool arguments or output"))))
  (let* ((backend (make-instance 'scripted-backend :name "scripted" :responses '()))
         (partial (self-improving-agent-harness::provider-accounting-summary
                   backend
                   (list (make-completion-response :model "test/model"
                                                   :usage '(:total-tokens 2 :cost-usd 0.001))
                         (make-completion-response :model "test/model"
                                                   :usage '(:total-tokens 3))))))
    (ensure-equal :unavailable (getf (getf partial :aggregate) :cost-usd)
                  "a missing tool-loop cost makes aggregate cost unavailable rather than partial")
    (ensure-equal "one-or-more-invocations-missing-authoritative-cost"
                  (getf (getf partial :aggregate) :cost-usd-reason)
                  "unavailable aggregate cost carries a deterministic reason"))
  (let* ((backend (make-instance 'scripted-backend :name "scripted" :responses '()))
         (session (make-chat-session :backend backend :model "test/model" :handlers '())))
    (note-chat-session-failure session)
    (ensure-true (chat-session-failed-turn-p session)
                 "a failed interactive turn is recorded without exposing error detail"))
  (let ((options (self-improving-agent-harness:chat-options)))
    (ensure-equal 0.2 (getf options :temperature)
                  "chat-options keeps a low default temperature")
    (ensure-true (integerp (getf options :max-tokens))
                 "chat-options supplies max-tokens")
    (ensure-true (>= (getf options :max-tokens) 8192)
                 "chat-options default max-tokens is at least 8192")
    (ensure-equal "auto" (getf options :tool-choice)
                  "chat-options sets tool_choice auto explicitly")
    (ensure-true (search "native tools/tool_calls"
                         (getf (getf (first (getf options :tools)) :function) :description))
                 "run_shell tool description requires native tool_calls"))
  (format t "Chat-session tests passed.~%")
  t)
