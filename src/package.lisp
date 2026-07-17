(defpackage #:self-improving-agent-harness
  (:use #:cl)
  (:export
   #:backend
   #:backend-name
   #:complete
   #:run-tool-loop
   #:configure-interaction-logging
   #:log-interaction
   #:emit-chat-event
   #:run-shell-tool
   #:reload-harness-tool
   #:chat-session
   #:make-chat-session
   #:chat-session-history
   #:chat-session-max-rounds
   ;; Session accounting remains a compatibility surface for the supervisor
   ;; evidence path while the reloadable CLI owns interaction orchestration.
   #:chat-session-last-provider-responses
   #:chat-session-last-accounting
   #:chat-session-turn
   #:chat-session-failed-turn-p
   #:note-chat-session-failure
   #:completion-request
   #:make-completion-request
   #:completion-request-model
   #:completion-request-messages
   #:completion-request-options
   #:completion-response
   #:make-completion-response
   #:completion-response-text
   #:completion-response-model
   #:completion-response-raw
   #:completion-response-tool-calls
   #:completion-response-finish-reason
   #:completion-response-provider-request-id
   #:completion-response-usage
   #:openrouter-backend
   #:make-openrouter-backend
   #:openrouter-backend-base-url
   #:openrouter-backend-api-key
   #:run-harness
   ;; chat CLI (reloadable via reload_harness)
   #:+chat-input-prompt+
   #:write-chat-prompt
   #:run-interactive
   #:run-one-shot
   #:run-chat-cli
   #:handle-interactive-command))
