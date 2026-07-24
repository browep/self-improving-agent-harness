(in-package #:self-improving-agent-harness/tests)

(defun web-event-kind (event)
  (getf event :kind))

(defun run-web-session-tests ()
  (let* ((response (make-completion-response :text "browser answer"
                                             :model "test/model"
                                             :finish-reason "stop"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list response)))
         (session (make-web-session :backend backend
                                    :model "test/model"
                                    :run-session-id "harness-run-24"
                                    :options '(:max-tokens 64)
                                    :handlers '()
                                    :max-rounds 3)))
    (ensure-equal '("session-started")
                  (mapcar #'web-event-kind (web-session-events session))
                  "a web session starts with one observable lifecycle event")
    (ensure-equal "harness-run-24" (getf (first (web-session-events session)) :run-session-id)
                  "a browser session carries its existing harness run correlation ID")
    (web-session-submit session "hello from browser")
    (ensure-equal '("session-started" "user-message" "assistant-pending"
                    "provider-round-started" "provider-round-completed"
                    "assistant-message" "turn-completed")
                  (mapcar #'web-event-kind (web-session-events session))
                  "a browser turn emits the visible provider-to-final-message sequence")
    (ensure-equal "browser answer"
                  (getf (car (last (web-session-events session))) :text)
                  "the completed browser event contains the final assistant text")
    (ensure-equal 3 (length (chat-session-history (web-session-chat-session session)))
                  "a successful browser turn uses the normal persistent chat history")
    (let ((old-id (web-session-id session)))
      (web-session-clear session)
      (ensure-true (not (string= old-id (web-session-id session)))
                   "clear replaces the opaque browser session ID")
      (ensure-equal 1 (length (web-session-events session))
                    "clear discards the prior timeline")
      (ensure-equal "session-cleared" (web-event-kind (first (web-session-events session)))
                    "clear emits only the replacement lifecycle event")
      (ensure-equal 1 (length (chat-session-history (web-session-chat-session session)))
                    "clear keeps only the system message in replacement history")))
  (let* ((tool-response (make-completion-response
                         :model "test/model"
                         :tool-calls '((:id "web-call-1" :type "function" :name "echo"
                                        :arguments "{\"message\":\"from browser\"}"))))
         (final-response (make-completion-response :text "tool complete" :model "test/model"))
         (backend (make-instance 'scripted-backend :name "scripted"
                                 :responses (list tool-response final-response)))
         (session (make-web-session
                   :backend backend :model "test/model"
                   :handlers `(("echo" . ,(lambda (arguments)
                                            (format nil "echo: ~A" (gethash "message" arguments))))))))
    (web-session-submit session "use a tool")
    (ensure-equal '("session-started" "user-message" "assistant-pending"
                    "provider-round-started" "provider-round-completed"
                    "tool-call-started" "tool-call-completed"
                    "provider-round-started" "provider-round-completed"
                    "assistant-message" "turn-completed")
                  (mapcar #'web-event-kind (web-session-events session))
                  "a browser tool turn exposes each provider and matching tool event in order")
    (let ((tool-result (find "tool-call-completed" (web-session-events session)
                             :key #'web-event-kind :test #'string=)))
      (ensure-equal "web-call-1" (getf tool-result :tool-call-id)
                    "browser tool completion remains linked to its source call")
      (ensure-equal "echo: from browser" (getf tool-result :result)
                    "browser tool completion preserves the local trusted result")))
  ;; Claude native events are replayed to the existing browser lifecycle without
  ;; presenting pending tool calls or calling the local handler a second time.
  (let* ((handler-calls 0)
         (response (make-completion-response
                    :text "fixture final" :model "claude/fixture"
                    :native-tool-events
                    (list (list :tool-call-id "toolu_captured_1"
                                :tool-name "run_shell"
                                :arguments "{\"command\":\"pwd\"}"
                                :result (format nil "/workspace~%")
                                :error-p nil))))
         (backend (make-instance 'scripted-backend :name "claude-fixture"
                                 :responses (list response)))
         (session (make-web-session
                   :backend backend :model "claude/fixture"
                   :handlers `(("run_shell" . ,(lambda (arguments)
                                                  (declare (ignore arguments))
                                                  (incf handler-calls)
                                                  "must not run"))))))
    (web-session-submit session "fixture-backed Claude tool turn")
    (ensure-equal '("session-started" "user-message" "assistant-pending"
                    "provider-round-started" "provider-round-completed"
                    "tool-call-started" "tool-call-completed"
                    "assistant-message" "turn-completed")
                  (mapcar #'web-event-kind (web-session-events session))
                  "Claude native events use the same CLOG tool-card lifecycle as Synthetic")
    (ensure-equal 0 handler-calls
                  "replayed native Claude events never dispatch a second local handler call")
    (let ((started (find "tool-call-started" (web-session-events session)
                         :key #'web-event-kind :test #'string=))
          (completed (find "tool-call-completed" (web-session-events session)
                           :key #'web-event-kind :test #'string=)))
      (ensure-equal "run_shell" (getf started :tool-name)
                    "tool card start displays normalized Harness tool name")
      (ensure-equal "toolu_captured_1" (getf completed :tool-call-id)
                    "tool card completion remains correlated by native Claude ID")
      (ensure-equal (format nil "/workspace~%") (getf completed :result)
                    "tool card completion preserves fixture result text")))
  (ensure-true (web-event-visible-in-chat-log-p '(:kind "user-message"))
               "user messages belong in the browser chat log")
  (ensure-true (web-event-visible-in-chat-log-p '(:kind "assistant-message"))
               "assistant messages belong in the browser chat log")
  (ensure-true (web-event-visible-in-chat-log-p '(:kind "tool-call-completed"))
               "tool results are visible in the browser transcript")
  ;; --- web-default-model-for-backend (issue #87 Web UI model bug) ---------
  ;; The Web UI dropdown previously hardcoded Haiku, which 400s on the direct
  ;; claude-sdk backend (adaptive thinking). The helper now defaults claude-sdk
  ;; to sonnet-5, preserves Haiku elsewhere, honors HARNESS_CHAT_MODEL, and is
  ;; defensive about nil/blank/case in the backend name.
  (let ((saved (uiop:getenv "HARNESS_CHAT_MODEL")))
    (unwind-protect
         (progn
           ;; Env override unset: backend-specific defaults.
           (setf (uiop:getenv "HARNESS_CHAT_MODEL") "")
           (ensure-equal "claude-sonnet-5"
                         (self-improving-agent-harness::web-default-model-for-backend "claude-sdk")
                         "claude-sdk Web UI default is claude-sonnet-5, not Haiku")
           (ensure-equal "claude-haiku-4-5-20251001"
                         (self-improving-agent-harness::web-default-model-for-backend "openrouter")
                         "non-claude-sdk backends keep the Haiku default")
           (ensure-equal "claude-haiku-4-5-20251001"
                         (self-improving-agent-harness::web-default-model-for-backend nil)
                         "nil backend falls through to the Haiku default without erroring")
           (ensure-equal "claude-haiku-4-5-20251001"
                         (self-improving-agent-harness::web-default-model-for-backend "")
                         "blank backend falls through to the Haiku default")
           (ensure-equal "claude-sonnet-5"
                         (self-improving-agent-harness::web-default-model-for-backend "  Claude-SDK  ")
                         "backend name is normalized (case + whitespace) before matching")
           ;; Env override non-blank: wins for every backend.
           (setf (uiop:getenv "HARNESS_CHAT_MODEL") "custom/model")
           (ensure-equal "custom/model"
                         (self-improving-agent-harness::web-default-model-for-backend "claude-sdk")
                         "HARNESS_CHAT_MODEL overrides the claude-sdk default")
           (ensure-equal "custom/model"
                         (self-improving-agent-harness::web-default-model-for-backend "openrouter")
                         "HARNESS_CHAT_MODEL overrides non-claude-sdk defaults too")
           ;; Whitespace-only override is ignored; blank-padded override trimmed.
           (setf (uiop:getenv "HARNESS_CHAT_MODEL") "   ")
           (ensure-equal "claude-sonnet-5"
                         (self-improving-agent-harness::web-default-model-for-backend "claude-sdk")
                         "whitespace-only HARNESS_CHAT_MODEL is ignored")
           (setf (uiop:getenv "HARNESS_CHAT_MODEL") "  gpt-4o  ")
           (ensure-equal "gpt-4o"
                         (self-improving-agent-harness::web-default-model-for-backend "openrouter")
                         "HARNESS_CHAT_MODEL override is trimmed"))
      (if saved
          (setf (uiop:getenv "HARNESS_CHAT_MODEL") saved)
          (sb-posix:unsetenv "HARNESS_CHAT_MODEL"))))
  (format t "Web-session tests passed.~%")
  t)
