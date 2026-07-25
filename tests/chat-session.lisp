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
  ;; Error classification (#92, classification half). Deterministic string map;
  ;; unknown falls back rather than guessing.
  (flet ((classifies (input expected)
           (ensure-equal expected
                         (self-improving-agent-harness::classify-chat-turn-error input)
                         (format nil "classify ~S -> ~A" input expected))))
    (classifies "OpenRouter request timed out after 120 seconds." "provider-timeout")
    (classifies "finish_reason=max_tokens with empty content" "empty-max-tokens")
    (classifies "HTTP 429 Too Many Requests: rate limit exceeded" "rate-limit")
    (classifies "401 Unauthorized: invalid api key" "auth-error")
    (classifies "connection reset by peer" "transport-error")
    (classifies "tool execution failed" "tool-error")
    (classifies "some unexpected explosion" "unknown-provider-error"))
  ;; #91 success path: exactly one turn-summary with accurate counts and
  ;; history persistence, emitted to the observer and the durable JSONL.
  (let* ((directory #P"/tmp/self-improving-agent-harness-turn-summary-ok/")
         (session-id "2026-02-02T00:00:00.020Z")
         (events '())
         (response (make-completion-response :text "done" :model "test/model"
                                             :finish-reason "end_turn"))
         (backend (make-instance 'scripted-backend :name "scripted"
                                 :responses (list response)))
         (session (make-chat-session :backend backend :model "test/model" :handlers '())))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (ensure-true
            (self-improving-agent-harness::configure-interaction-logging
             directory :session-id session-id)
            "interaction logging is configured (durable JSONL assertions are meaningful)")
           (chat-session-turn session "hello"
                              :observer (lambda (kind &rest fields)
                                          (push (cons kind fields) events)))
           (let ((summaries (remove "turn-summary" events
                                    :key #'car :test (complement #'string=))))
             (ensure-equal 1 (length summaries)
                           "a completed turn emits exactly one turn-summary to the observer")
             (let ((f (cdr (first summaries))))
               (ensure-equal "completed" (getf f :status)
                             "success summary status is completed")
               (ensure-equal "hello" (getf f :user-prompt)
                             "success summary carries the raw user prompt")
               (ensure-equal 2 (getf f :submitted-message-count)
                             "success summary counts system+user submitted messages")
               (ensure-equal 1 (getf f :history-message-count-before)
                             "success summary records pre-turn history count")
               (ensure-equal 3 (getf f :history-message-count-after)
                             "success summary records post-turn history count")
               (ensure-true (getf f :history-persisted)
                            "success summary reports durable persistence when logging is on")
               (ensure-equal 1 (getf f :provider-request-count)
                             "success summary counts one provider request")
               (ensure-equal 1 (getf f :provider-response-count)
                             "success summary counts one provider response")
               (ensure-equal 0 (getf f :provider-failure-count)
                             "success summary counts zero provider failures")
               (ensure-equal 0 (getf f :tool-call-count)
                             "success summary counts zero tool calls for a text answer")
               (ensure-equal "end_turn" (getf f :last-finish-reason)
                             "success summary carries the provider finish reason")
               (ensure-equal "none" (getf f :terminal-error-class)
                             "success summary has no error class")))
           (let* ((started (find "provider-round-started" events :key #'car :test #'string=))
                  (completed (find "provider-round-completed" events :key #'car :test #'string=))
                  (summary (find "turn-summary" events :key #'car :test #'string=))
                  (attempt-id (getf (cdr started) :attempt-id)))
             (ensure-true (and (stringp attempt-id) (plusp (length attempt-id)))
                          "provider round start has a nonempty harness attempt ID")
             (ensure-equal attempt-id (getf (cdr completed) :attempt-id)
                           "provider round completion joins its start by attempt ID")
             (ensure-equal (list attempt-id) (getf (cdr summary) :provider-attempt-ids)
                           "turn-summary carries the ordered provider attempt IDs"))
           (let ((jc (uiop:read-file-string
                      (logging-test-session-path directory session-id))))
             (ensure-true (search "\"event\":\"turn-summary\"" jc)
                          "turn-summary is durable in JSONL")
             (ensure-true (search "\"status\":\"completed\"" jc)
                          "durable turn-summary records completed status")
             (ensure-true (search "\"userPrompt\":\"hello\"" jc)
                          "durable turn-summary records raw userPrompt")
             (ensure-true (search "\"historyPersisted\":true" jc)
                          "durable turn-summary records historyPersisted (camelCase)")
             (ensure-true (search "\"attemptId\":" jc)
                          "durable provider events carry attemptId")
             (ensure-true (search "\"providerAttemptIds\":[" jc)
                          "durable turn-summary carries providerAttemptIds")
             (ensure-true (search "\"terminalErrorClass\":\"none\"" jc)
                          "durable turn-summary records terminalErrorClass none")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  ;; #91/#92 failure path: a provider timeout still emits one turn-summary with
  ;; a classified error, correct counts, and the preserved failed turn.
  (let* ((directory #P"/tmp/self-improving-agent-harness-turn-summary-fail/")
         (session-id "2026-02-02T00:00:00.021Z")
         (events '())
         (backend (make-instance 'erroring-backend :name "erroring"
                                 :message "OpenRouter request timed out after 120 seconds."))
         (session (make-chat-session :backend backend :model "test/model" :handlers '())))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (ensure-true
            (self-improving-agent-harness::configure-interaction-logging
             directory :session-id session-id)
            "interaction logging is configured for the failure-path test")
           (handler-case
               (chat-session-turn session "Fix the issue"
                                  :observer (lambda (kind &rest fields)
                                              (push (cons kind fields) events)))
             (error () nil))
           ;; The failed turn is still preserved (from the earlier fix).
           (ensure-equal '("system" "user" "assistant")
                         (mapcar #'message-role (chat-session-history session))
                         "failed turn still preserves prompt + marker with summary added")
           (let ((summaries (remove "turn-summary" events
                                    :key #'car :test (complement #'string=))))
             (ensure-equal 1 (length summaries)
                           "a failed turn emits exactly one turn-summary to the observer")
             (let ((f (cdr (first summaries))))
               (ensure-equal "failed" (getf f :status)
                             "failure summary status is failed")
               (ensure-equal "Fix the issue" (getf f :user-prompt)
                             "failure summary carries the raw failed user prompt")
               (ensure-equal "provider-timeout" (getf f :terminal-error-class)
                             "failure summary classifies the provider timeout")
               (ensure-equal 1 (getf f :provider-request-count)
                             "failure summary counts the one attempted request")
               (ensure-equal 0 (getf f :provider-response-count)
                             "failure summary counts zero successful responses")
               (ensure-equal 1 (getf f :provider-failure-count)
                             "failure summary counts one provider failure")
               (ensure-equal 0 (getf f :tool-call-count)
                             "failure summary counts zero tool calls")
               (ensure-equal 1 (getf f :history-message-count-before)
                             "failure summary records pre-turn history count")
               (ensure-equal 3 (getf f :history-message-count-after)
                             "failure summary records preserved post-turn history count")
               (ensure-true (getf f :history-persisted)
                            "failure summary reports the preserved turn was persisted")))
           (let* ((started (find "provider-round-started" events :key #'car :test #'string=))
                  (failed (find "provider-round-failed" events :key #'car :test #'string=))
                  (summary (find "turn-summary" events :key #'car :test #'string=))
                  (attempt-id (getf (cdr started) :attempt-id)))
             (ensure-true (and (stringp attempt-id) (plusp (length attempt-id)))
                          "failed provider round start has a nonempty harness attempt ID")
             (ensure-equal attempt-id (getf (cdr failed) :attempt-id)
                           "provider failure joins its start by attempt ID")
             (ensure-equal (list attempt-id) (getf (cdr summary) :provider-attempt-ids)
                           "failed turn summary carries its provider attempt ID"))
           (let* ((jc (uiop:read-file-string
                       (logging-test-session-path directory session-id)))
                  (summary-line
                    (find-if (lambda (line) (search "\"event\":\"turn-summary\"" line))
                             (uiop:split-string jc :separator '(#\Newline)))))
             (ensure-true (search "\"event\":\"provider-request-failed\"" jc)
                          "provider-request-failed is durable in JSONL")
             (ensure-true (search "\"terminalErrorClass\":\"provider-timeout\"" jc)
                          "provider-request-failed carries the classified error (camelCase)")
             (ensure-true (search "\"attemptId\":" jc)
                          "failed provider event carries attemptId")
             (ensure-true summary-line
                          "failed turn's turn-summary is durable in JSONL")
             (ensure-true (search "\"status\":\"failed\"" summary-line)
                          "durable turn-summary records failed status")
             (ensure-true (search "\"providerAttemptIds\":[" summary-line)
                          "failed turn summary carries providerAttemptIds")
             ;; Raw prompt retention in the terminal summary is explicitly
             ;; authorized for this harness; raw provider error text remains
             ;; excluded in favor of terminalErrorClass.
             (ensure-true (not (search "120 seconds" summary-line))
                          "turn-summary carries the class only, never raw error text")
             (ensure-true (search "\"userPrompt\":\"Fix the issue\"" summary-line)
                          "turn-summary records the raw failed user prompt")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  ;; Regression for the 2026-07-25T16:33:08.866Z "apparent forgetting" session:
  ;; a failed turn must PRESERVE the failed user prompt plus a sanitized
  ;; assistant failure marker in history (and in the durable snapshot), so a
  ;; later turn does not silently resume from the last COMPLETED turn.
  (let* ((tmp (format nil "/tmp/harness-failed-turn-~A.history.json"
                      (random 1000000000)))
         (backend (make-instance 'scripted-backend :name "scripted" :responses '()))
         (session (make-chat-session :backend backend :model "test/model" :handlers '())))
    (unwind-protect
         (let ((self-improving-agent-harness::*session-history-path* (pathname tmp)))
           (ensure-error-containing
            (lambda () (chat-session-turn session "Fix the issue"))
            "scripted responses"
            "a provider failure mid-turn re-signals the condition")
           (let ((history (chat-session-history session)))
             (ensure-equal '("system" "user" "assistant")
                           (mapcar #'message-role history)
                           "failed turn preserves system + failed user prompt + assistant marker")
             (ensure-equal "Fix the issue" (getf (second history) :content)
                           "failed user prompt is retained in history")
             (let ((marker (getf (third history) :content)))
               (ensure-true (search "[harness] Previous turn failed" marker)
                            "failed turn appends a harness failure marker")
               (ensure-true (search "preserved in history" marker)
                            "failure marker explains the turn was preserved")))
           (ensure-true (chat-session-failed-turn-p session)
                        "a preserved failed turn still records the failed-turn flag")
           ;; Durable snapshot must carry the failed turn so a container restart
           ;; or bin/chat -c resume does not lose it.
           (ensure-true (probe-file (pathname tmp))
                        "a failed turn writes a durable history snapshot")
           (let ((restored (self-improving-agent-harness::read-session-history-snapshot
                            (pathname tmp))))
             (ensure-equal '("system" "user" "assistant")
                           (mapcar #'message-role restored)
                           "durable snapshot preserves the failed turn shape")
             (ensure-equal "Fix the issue" (getf (second restored) :content)
                           "durable snapshot preserves the failed user prompt")
             (ensure-true (search "[harness] Previous turn failed"
                                  (getf (third restored) :content))
                          "durable snapshot preserves the failure marker"))
           ;; A subsequent successful turn must SEE the preserved failed turn in
           ;; the request it sends to the backend (proving the model is no longer
           ;; blind to the failed request).
           (setf (scripted-backend-responses backend)
                 (list (make-completion-response :text "resumed" :model "test/model")))
           (chat-session-turn session "Still working?")
           (let* ((requests (reverse (scripted-backend-received-requests backend)))
                  (followup-messages (completion-request-messages (car (last requests)))))
             (ensure-equal '("system" "user" "assistant" "user")
                           (mapcar #'message-role followup-messages)
                           "follow-up request replays the preserved failed turn before the new prompt")
             (ensure-equal "Fix the issue" (getf (second followup-messages) :content)
                           "follow-up request still carries the previously failed user prompt")
             (ensure-equal "Still working?" (getf (fourth followup-messages) :content)
                           "follow-up request ends with the new user prompt")))
      (ignore-errors (delete-file (pathname tmp)))))
  (let ((saved-max-tokens (uiop:getenv "HARNESS_CHAT_MAX_TOKENS")))
    (unwind-protect
         (progn
           ;; HARNESS_CHAT_MAX_TOKENS overrides CHAT-OPTIONS' :max-tokens (see
           ;; CHAT-OPTIONS in src/chat-cli.lisp), and a live chat session's
           ;; container environment may already export it (e.g. to configure
           ;; that session's own interactive turns). Unset it here so this
           ;; block observes the unconfigured *CHAT-MAX-TOKENS* default rather
           ;; than ambient environment state, mirroring the isolation used by
           ;; the explicit-override test immediately below.
           (sb-posix:unsetenv "HARNESS_CHAT_MAX_TOKENS")
           (let ((options (self-improving-agent-harness:chat-options)))
             (ensure-equal 0.2 (getf options :temperature)
                           "chat-options keeps a low default temperature")
             (ensure-true (integerp (getf options :max-tokens))
                          "chat-options supplies max-tokens")
             (ensure-equal 16384 (getf options :max-tokens)
                           "chat-options defaults to 16384 max-tokens for long tool-using turns")
             (ensure-equal "auto" (getf options :tool-choice)
                           "chat-options sets tool_choice auto explicitly")
             (ensure-true (search "native tools/tool_calls"
                                  (getf (getf (first (getf options :tools)) :function) :description))
                          "run_shell tool description requires native tool_calls")))
      (if saved-max-tokens
          (setf (uiop:getenv "HARNESS_CHAT_MAX_TOKENS") saved-max-tokens)
          (sb-posix:unsetenv "HARNESS_CHAT_MAX_TOKENS"))))
  (let ((saved (uiop:getenv "HARNESS_CHAT_MAX_TOKENS")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "HARNESS_CHAT_MAX_TOKENS") "64000")
           (ensure-equal 64000
                         (getf (self-improving-agent-harness:chat-options) :max-tokens)
                         "chat-options honors an explicit positive max-tokens environment override"))
      (if saved
          (setf (uiop:getenv "HARNESS_CHAT_MAX_TOKENS") saved)
          (sb-posix:unsetenv "HARNESS_CHAT_MAX_TOKENS"))))
  (format t "Chat-session tests passed.~%")
  t)
