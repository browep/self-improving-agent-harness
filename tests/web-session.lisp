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
  (ensure-true (web-event-visible-in-chat-log-p '(:kind "user-message"))
               "user messages belong in the browser chat log")
  (ensure-true (web-event-visible-in-chat-log-p '(:kind "assistant-message"))
               "assistant messages belong in the browser chat log")
  (ensure-true (web-event-visible-in-chat-log-p '(:kind "tool-call-completed"))
               "tool results are visible in the browser transcript")
  (format t "Web-session tests passed.~%")
  t)
