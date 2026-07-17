(in-package #:self-improving-agent-harness)

;;; Interactive / one-shot chat CLI helpers.
;;; Loaded via ASDF so reload_harness redefines these in a running chat image.
;;; scripts/chat.lisp only bootstraps env + calls RUN-CHAT-CLI.
;;;
;;; Hot-reload contract for interactive sessions:
;;; - RUN-INTERACTIVE stays a thin long-lived frame and only calls helpers by name.
;;; - Per-turn outcome formatting lives in src/chat-turn-report.lisp.
;;; - Sessions store OPTIONS/HANDLERS as function designators (symbols), not
;;;   captured function objects or frozen plists, so tool schemas and handlers
;;;   re-resolve after reload_harness without rebuilding the session.

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
                :description "Reload self-improving-agent-harness sources into this same Lisp image after editing project Lisp files. Returns a structured status line (status=ok|note|warning|error files=N warnings=N notes=N ...) plus any non-benign compiler diagnostics. Does not reset chat history or max-rounds."
                :parameters (:type "object")))))

(defun chat-options ()
  (list :temperature 0.2
        :max-tokens 512
        :tools (chat-tool-definitions)))

(defun chat-handlers ()
  "Return the live tool-handler alist using symbol designators.

Symbols are intentional: OPENROUTER-TOOL-HANDLER / FUNCALL re-resolve them on
each tool call, so redefining SHELL-TOOL or RELOAD-TOOL via reload_harness is
visible to the already-running interactive session."
  '(("run_shell" . shell-tool)
    ("reload_harness" . reload-tool)))

(defun make-chat-backend ()
  (make-openrouter-backend :api-key (uiop:getenv "OPENROUTER_API_KEY")))

(defun make-cli-chat-session (backend model max-rounds)
  "Build a CLI chat session that re-resolves options/handlers after reload.

CHAT-OPTIONS and CHAT-HANDLERS are stored as symbols, not as the values they
currently return. CHAT-SESSION-TURN funcalls those symbols each turn."
  (make-chat-session
   :backend backend
   :model model
   :options 'chat-options
   :handlers 'chat-handlers
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
  "Run a single prompt and print the answer plus structured OUTCOME on stderr."
  (let* ((session (make-cli-chat-session backend model max-rounds))
         (start (get-internal-real-time))
         (response (chat-session-turn session prompt)))
    (report-completed-chat-turn session start response :leading-newline nil)))

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

(defun write-interactive-session-banner (model max-rounds)
  "Print the interactive startup banner to stderr.

Kept as its own function so banner text can hot-reload if RUN-INTERACTIVE is
re-entered; an already-running process keeps the banner it already printed."
  (format *error-output*
          "Interactive OpenRouter chat (model=~A, max-rounds=~D).~%~
Commands: /exit, /quit, /reload, /max-rounds [N]. Ctrl-C also leaves.~%"
          model max-rounds)
  (finish-output *error-output*))

(defun interactive-exit-command-p (input)
  "True when INPUT is an interactive session-exit slash command."
  (or (string= input "/exit") (string= input "/quit")))

(defun handle-interactive-interrupt (condition)
  "Default Ctrl-C policy for interactive chat: leave the session cleanly."
  (declare (ignore condition))
  (format *error-output* "~%Interrupted; leaving interactive chat.~%")
  (finish-output *error-output*)
  :exit)

(defun process-interactive-input (session input)
  "Dispatch one interactive input line.

Returns :EXIT when the session should end, otherwise NIL. All work is done via
named global functions so reload_harness can replace command/turn/prompt policy
between lines without restarting the process."
  (cond
    ((eq input :eof) :exit)
    ((interactive-exit-command-p input) :exit)
    ((zerop (length input))
     (format *error-output* "Empty input ignored.~%")
     (finish-output *error-output*)
     nil)
    ((handle-interactive-command session input)
     nil)
    (t
     (process-interactive-user-turn session input)
     nil)))

(defun run-interactive-loop (session)
  "Read/dispatch interactive lines until exit.

This is the long-lived loop frame. Keep it thin: only call helpers by name."
  (loop
    (write-chat-prompt)
    (let ((input (read-chat-input-line)))
      (when (eq (process-interactive-input session input) :exit)
        (return))))
  session)

(defun run-interactive (backend model max-rounds)
  "Persistent interactive chat loop.

The loop body intentionally stays thin and calls PROCESS-INTERACTIVE-INPUT,
WRITE-CHAT-PROMPT, and READ-CHAT-INPUT-LINE by name each iteration. Those
global function cells are what reload_harness updates; this stack frame is not
rewritten in place. After one process start on this thin loop, outcome/prompt/
command/tool-handler changes hot-reload without restarting chat.

Still requires process restart: changes to this function's own control flow
while it is already running, Docker/bin bootstrap, and incompatible
struct/class layout changes."
  (let ((session (make-cli-chat-session backend model max-rounds)))
    (write-interactive-session-banner model max-rounds)
    (handler-bind
        ((sb-sys:interactive-interrupt
           (lambda (condition)
             (handle-interactive-interrupt condition)
             (return-from run-interactive nil))))
      (run-interactive-loop session)
      (when (chat-session-failed-turn-p session)
        (uiop:quit 1)))))

(defun run-chat-cli ()
  "Entry point for bin/chat after the system is loaded. Reads HARNESS_* env vars."
  (let* ((mode (required-environment "HARNESS_CHAT_MODE"))
         (model (required-environment "HARNESS_CHAT_MODEL"))
         (max-rounds (parse-integer (required-environment "HARNESS_CHAT_MAX_ROUNDS")))
         (log-directory (or (uiop:getenv "HARNESS_LOG_DIR")
                               "/workspace/agent-logs"))
         (preferred-session-id (uiop:getenv "HARNESS_CHAT_SESSION_ID"))
         (backend (make-chat-backend)))
    ;; One session JSONL file per process: agent-logs/$ISO-TIMESTAMP.jsonl under
    ;; the workspace bind-mount so hosts can inspect logs without the Docker
    ;; named volume. Non-timestamp supervisor correlation IDs still work for
    ;; stderr events, but the durable log basename is always an ISO-8601 UTC
    ;; timestamp.
    (configure-interaction-logging log-directory :session-id preferred-session-id)
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
