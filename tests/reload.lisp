(in-package #:self-improving-agent-harness/tests)

(defun run-reload-tests ()
  (let ((message (self-improving-agent-harness:reload-harness-tool nil)))
    (ensure-true (search "Reloaded self-improving-agent-harness" message)
                 "reload tool reports a successful in-process reload")
    (ensure-true (search "self-improving-agent-harness.asd" message)
                 "reload tool names the project ASD"))
  (let* ((tool-response
           (make-completion-response
            :text ""
            :model "test/model"
            :tool-calls '((:id "call-reload" :type "function" :name "reload_harness"
                           :arguments "{}"))))
         (final-response
           (make-completion-response :text "reloaded in-process" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list tool-response final-response)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "Reload the harness.")))
            `(("reload_harness" . ,#'self-improving-agent-harness:reload-harness-tool)))))
    (ensure-equal "reloaded in-process" (completion-response-text result)
                  "reload_harness participates in the normal tool loop")
    (let* ((continuation (first (scripted-backend-received-requests backend)))
           (tool-message (third (completion-request-messages continuation))))
      (ensure-equal "tool" (getf tool-message :role)
                    "reload tool result is returned as a tool message")
      (ensure-true (search "Reloaded self-improving-agent-harness"
                           (getf tool-message :content))
                   "reload tool result content reaches the model")))
  (let ((session (make-chat-session :backend nil :model "test/model" :handlers '())))
    (ensure-equal 8 (chat-session-max-rounds session)
                  "session default max-rounds remains 8")
    (setf (chat-session-max-rounds session) 24)
    (ensure-equal 24 (chat-session-max-rounds session)
                  "session max-rounds can be updated in-process"))
  (ensure-true (boundp 'self-improving-agent-harness:+chat-input-prompt+)
               "chat CLI prompt parameter is part of the reloadable system")
  (ensure-true (fboundp 'self-improving-agent-harness:write-chat-prompt)
               "write-chat-prompt is reloadable")
  (ensure-true (fboundp 'self-improving-agent-harness:run-chat-cli)
               "run-chat-cli is reloadable")
  (format t "Reload-hook tests passed.~%")
  t)
