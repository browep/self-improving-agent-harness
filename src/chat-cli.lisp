(in-package #:self-improving-agent-harness)

;;; Interactive / one-shot chat CLI helpers.
;;; Loaded via ASDF so reload_harness redefines these in a running chat image.
;;; scripts/chat.lisp only bootstraps env + calls RUN-CHAT-CLI.

(defparameter +chat-input-prompt+
  " >>> "
  "Prompt printed before each interactive user line (stderr).")

(defparameter +chat-prompt-separator+
  (make-string 80 :initial-element #\-)
  "Horizontal rule printed around the interactive prompt (stderr).")

(defparameter *pending-chat-prompt-close* nil
  "When true, the next interactive input should reprint +CHAT-PROMPT-SEPARATOR+.")

(defun required-environment (name)
  (let ((value (uiop:getenv name)))
    (unless (and value (plusp (length value)))
      (error "~A must be supplied by bin/chat." name))
    value))

(defun shell-tool (arguments)
  (run-shell-tool arguments))

(defun reload-tool (arguments)
  (reload-harness-tool arguments))

(defun chat-tool-definitions ()
  '((:type "function"
     :function (:name "run_shell"
                :description "Run a shell command in the harness container and return combined output."
                :parameters (:type "object"
                             :properties (:command (:type "string"))
                             :required ("command"))))
    (:type "function"
     :function (:name "reload_harness"
                :description "Reload self-improving-agent-harness sources into this same Lisp image after editing project Lisp files. Does not reset chat history or max-rounds."
                :parameters (:type "object")))))

(defun chat-options ()
  (list :temperature 0.2
        :max-tokens 512
        :tools (chat-tool-definitions)))

(defun chat-handlers ()
  `(("run_shell" . ,#'shell-tool)
    ("reload_harness" . ,#'reload-tool)))

(defun make-chat-backend ()
  (make-openrouter-backend :api-key (uiop:getenv "OPENROUTER_API_KEY")))

(defun make-cli-chat-session (backend model max-rounds)
  (make-chat-session
   :backend backend
   :model model
   :options (chat-options)
   :handlers (chat-handlers)
   :max-rounds max-rounds))

(defun parse-positive-integer (text)
  (let* ((trimmed (string-trim '(#\Space #\Tab) text))
         (value (ignore-errors (parse-integer trimmed :junk-allowed nil))))
    (unless (and (integerp value) (plusp value))
      (error "Value must be a positive integer, got ~S." text))
    value))

(defun write-chat-prompt-closing ()
  "Print the same separator line used above the interactive prompt."
  (format *error-output* "~A~%" +chat-prompt-separator+)
  (finish-output *error-output*))

(defun maybe-write-chat-prompt-closing ()
  "If WRITE-CHAT-PROMPT armed a close, print it once and clear the flag.

This lets an already-running interactive loop pick up the post-submit rule after
reload_harness, because WRITE-CHAT-PROMPT / HANDLE-INTERACTIVE-COMMAND /
CHAT-SESSION-TURN resolve through the global function cell each call."
  (when *pending-chat-prompt-close*
    (setf *pending-chat-prompt-close* nil)
    (write-chat-prompt-closing)
    t))

(defun handle-interactive-command (session input)
  "Handle slash commands that must run in-process. Return T when INPUT was consumed."
  (maybe-write-chat-prompt-closing)
  (cond
    ((or (string= input "/reload") (string= input "/reload-harness"))
     (format *error-output* "COMMAND /reload~%")
     (let ((message (reload-harness-tool nil)))
       (log-interaction :info "command-completed" :command "/reload" :message message)
       (format t "~A~%" message)
       (format *error-output* "OUTCOME command=/reload~%"))
     t)
    ((string= input "/max-rounds")
     (format t "max-rounds=~D~%" (chat-session-max-rounds session))
     (format *error-output* "OUTCOME command=/max-rounds~%")
     t)
    ((let ((prefix "/max-rounds "))
       (when (and (>= (length input) (length prefix))
                  (string= input prefix :end1 (length prefix)))
         (let* ((raw (subseq input (length prefix)))
                (value (parse-positive-integer raw)))
           (setf (chat-session-max-rounds session) value)
           (log-interaction :info "command-completed" :command "/max-rounds"
                            :max-rounds value)
           (format t "max-rounds set to ~D for this session. Later tool loops use the new limit.~%"
                   value)
           (format *error-output* "OUTCOME command=/max-rounds value=~D~%" value)
           t))))
    (t nil)))

(defun run-one-shot (backend model max-rounds prompt)
  (let* ((session (make-cli-chat-session backend model max-rounds))
         (response (chat-session-turn session prompt)))
    (format t "~A~%" (completion-response-text response))
    (format *error-output* "OUTCOME final-response model=~A~%"
            (completion-response-model response))))

(defun write-chat-prompt ()
  "Print the interactive input prompt to stderr using +CHAT-INPUT-PROMPT+.

Also arms *PENDING-CHAT-PROMPT-CLOSE* so the matching separator is printed once
the submitted line is handled (works even if RUN-INTERACTIVE itself was not
re-entered after reload_harness)."
  (format *error-output*
          "~%~A~%~A"
          +chat-prompt-separator+
          +chat-input-prompt+)
  (finish-output *error-output*)
  (setf *pending-chat-prompt-close* t)
  (values))

(defun read-chat-input-line ()
  "Read one interactive line, then print the closing separator when armed."
  (let ((input (read-line *standard-input* nil :eof)))
    (maybe-write-chat-prompt-closing)
    input))

(defun run-interactive (backend model max-rounds)
  (let ((session (make-cli-chat-session backend model max-rounds)))
    (format *error-output*
            "Interactive OpenRouter chat (model=~A, max-rounds=~D).~%~
Commands: /exit, /quit, /reload, /max-rounds [N]. Ctrl-C also leaves.~%"
            model max-rounds)
    (handler-bind
        ((sb-sys:interactive-interrupt
           (lambda (condition)
             (declare (ignore condition))
             (format *error-output* "~%Interrupted; leaving interactive chat.~%")
             (finish-output *error-output*)
             (return-from run-interactive nil))))
      (loop
        (write-chat-prompt)
        (let ((input (read-chat-input-line)))
          (cond
            ((eq input :eof) (return))
            ((or (string= input "/exit") (string= input "/quit")) (return))
            ((zerop (length input))
             (format *error-output* "Empty input ignored.~%"))
            ((handle-interactive-command session input)
             nil)
            (t
             (handler-case
                 (let ((response (chat-session-turn session input)))
                   (format t "~%~A~%" (completion-response-text response))
                   (format *error-output* "~%OUTCOME final-response model=~A~%"
                           (completion-response-model response)))
               (error (condition)
                 (note-chat-session-failure session)
                 (format *error-output*
                         "~%TURN_FAILED: ~A; session continues and prior history is retained.~%"
                         condition)))))))
      (when (chat-session-failed-turn-p session)
        (uiop:quit 1)))))

(defun run-chat-cli ()
  "Entry point for bin/chat after the system is loaded. Reads HARNESS_* env vars."
  (let* ((mode (required-environment "HARNESS_CHAT_MODE"))
         (model (required-environment "HARNESS_CHAT_MODEL"))
         (max-rounds (parse-integer (required-environment "HARNESS_CHAT_MAX_ROUNDS")))
         (log-directory (or (uiop:getenv "HARNESS_LOG_DIR") "/logs"))
         (backend (make-chat-backend)))
    (configure-interaction-logging log-directory)
    (log-interaction :info "session-start" :mode mode :model model :max-rounds max-rounds)
    (handler-case
        (cond
          ((string= mode "one-shot")
           (run-one-shot backend model max-rounds
                         (required-environment "HARNESS_CHAT_PROMPT")))
          ((string= mode "interactive")
           (run-interactive backend model max-rounds))
          (t (error "HARNESS_CHAT_MODE must be one-shot or interactive.")))
      (error (condition)
        (log-interaction :error "session-failed" :message (princ-to-string condition))
        (error condition)))
    (log-interaction :info "session-ended" :mode mode)
    (uiop:quit 0)))
