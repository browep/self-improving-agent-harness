(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

(defun required-environment (name)
  (let ((value (uiop:getenv name)))
    (unless (and value (plusp (length value)))
      (error "~A must be supplied by bin/chat." name))
    value))

(defun shell-tool (arguments)
  (self-improving-agent-harness:run-shell-tool arguments))

(defun chat-options ()
  '(:temperature 0.2
    :max-tokens 512
    :tools ((:type "function"
             :function (:name "run_shell"
                        :description "Run a shell command in the harness container and return combined output."
                        :parameters (:type "object"
                                     :properties (:command (:type "string"))
                                     :required ("command")))))))

(defun make-chat-backend ()
  (self-improving-agent-harness:make-openrouter-backend
   :api-key (uiop:getenv "OPENROUTER_API_KEY")))

(defun run-one-shot (backend model max-rounds prompt)
  (let* ((session (self-improving-agent-harness:make-chat-session
                   :backend backend :model model :options (chat-options)
                   :handlers `(("run_shell" . ,#'shell-tool)) :max-rounds max-rounds))
         (self-improving-agent-harness::*interaction-turn-number* 1)
         (response (self-improving-agent-harness:chat-session-turn session prompt)))
    (format t "~A~%" (self-improving-agent-harness:completion-response-text response))
    (format *error-output* "OUTCOME final-response model=~A~%"
            (self-improving-agent-harness:completion-response-model response))))

(defun run-interactive (backend model max-rounds)
  (let ((session (self-improving-agent-harness:make-chat-session
                  :backend backend :model model :options (chat-options)
                  :handlers `(("run_shell" . ,#'shell-tool)) :max-rounds max-rounds))
        (turn-number 0))
    (format *error-output*
            "Interactive OpenRouter chat (model=~A). Type /exit or /quit, or press Ctrl-C, to leave.~%"
            model)
    (handler-bind
        ((sb-sys:interactive-interrupt
           (lambda (condition)
             (declare (ignore condition))
             (format *error-output* "~%Interrupted; leaving interactive chat.~%")
             (self-improving-agent-harness:emit-chat-event
              "session-exited" :reason "interrupted")
             (self-improving-agent-harness:log-interaction
              :info "session-ended" :reason "interrupted")
             (finish-output *error-output*)
             (return-from run-interactive nil))))
      (let ((reason
              (loop
                (format *error-output* "chat> ")
                (finish-output *error-output*)
                (let ((input (read-line *standard-input* nil :eof)))
                  (cond
                    ((eq input :eof) (return "eof"))
                    ((or (string= input "/exit") (string= input "/quit"))
                     (return "local-exit"))
                    ((zerop (length input))
                     (incf turn-number)
                     (let ((self-improving-agent-harness::*interaction-turn-number*
                             turn-number))
                       (self-improving-agent-harness:emit-chat-event "turn-submitted")
                       (self-improving-agent-harness:emit-chat-event "turn-empty")
                       (self-improving-agent-harness:log-interaction :info "turn-empty"))
                     (format *error-output* "Empty input ignored.~%"))
                    (t
                     (incf turn-number)
                     (let ((self-improving-agent-harness::*interaction-turn-number*
                             turn-number))
                       (self-improving-agent-harness:emit-chat-event "turn-submitted")
                       (handler-case
                           (let ((response (self-improving-agent-harness:chat-session-turn
                                            session input)))
                             (format t "~A~%"
                                     (self-improving-agent-harness:completion-response-text response))
                             (format *error-output* "OUTCOME final-response model=~A~%"
                                     (self-improving-agent-harness:completion-response-model response))
                             (self-improving-agent-harness:emit-chat-event
                              "turn-completed"
                              :model (self-improving-agent-harness:completion-response-model response)))
                         (error (condition)
                           ;; The condition is already redacted by the tool loop where needed.
                           (self-improving-agent-harness:note-chat-session-failure session)
                           (self-improving-agent-harness:emit-chat-event "turn-failed")
                           (format *error-output*
                                   "TURN_FAILED: ~A; session continues and prior history is retained.~%"
                                   condition))))))))))
        (self-improving-agent-harness:emit-chat-event
         "session-exited" :reason reason
         :failed-turn-p (self-improving-agent-harness:chat-session-failed-turn-p session))
        (self-improving-agent-harness:log-interaction
         :info "session-ended" :reason reason
         :failed-turn-p (self-improving-agent-harness:chat-session-failed-turn-p session)))
      (when (self-improving-agent-harness:chat-session-failed-turn-p session)
        (uiop:quit 1)))))

(let* ((mode (required-environment "HARNESS_CHAT_MODE"))
       (model (required-environment "HARNESS_CHAT_MODEL"))
       (max-rounds (parse-integer (required-environment "HARNESS_CHAT_MAX_ROUNDS")))
       (session-id (required-environment "HARNESS_CHAT_SESSION_ID"))
       (log-directory (or (uiop:getenv "HARNESS_LOG_DIR") "/logs"))
       (backend (make-chat-backend)))
  (let ((self-improving-agent-harness::*interaction-session-id* session-id))
    (self-improving-agent-harness:configure-interaction-logging log-directory)
    (self-improving-agent-harness:log-interaction
     :info "session-start" :mode mode :model model :max-rounds max-rounds)
    (when (string= mode "interactive")
      (self-improving-agent-harness:emit-chat-event
       "session-started" :mode mode :model model :max-rounds max-rounds))
    (handler-case
        (cond
          ((string= mode "one-shot")
           (run-one-shot backend model max-rounds (required-environment "HARNESS_CHAT_PROMPT")))
          ((string= mode "interactive")
           (run-interactive backend model max-rounds))
          (t (error "HARNESS_CHAT_MODE must be one-shot or interactive.")))
      (error (condition)
        (self-improving-agent-harness:log-interaction
         :error "session-failed" :message (princ-to-string condition))
        (error condition)))
    (unless (string= mode "interactive")
      (self-improving-agent-harness:log-interaction :info "session-ended" :mode mode))
    (uiop:quit 0)))
