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
                :description "Run a shell command in the harness container and return combined stdout/stderr. Optional timeout is wall-clock seconds (default 60); timed-out commands are terminated and reported."
                :parameters (:type "object"
                             :properties (:command (:type "string"
                                                    :description "Shell command to run via /bin/sh -lc.")
                                          :timeout (:type "number"
                                                    :description "Optional wall-clock timeout in seconds. Defaults to 60. On expiry the command is terminated and a timeout message is returned."))
                             :required ("command"))))
    (:type "function"
     :function (:name "reload_harness"
                :description "Reload self-improving-agent-harness sources into this same Lisp image after editing project Lisp files. Returns a structured status line (status=ok|note|warning|error files=N warnings=N notes=N ...) plus any non-benign compiler diagnostics. Does not reset chat history or max-rounds."
                :parameters (:type "object")))))

(defun chat-options ()
  (list :temperature 0.2
        :max-tokens 4096
        :tools (chat-tool-definitions)))

(defun chat-handlers ()
  "Return the live tool-handler alist using symbol designators.

Symbols are intentional: OPENROUTER-TOOL-HANDLER / FUNCALL re-resolve them on
each tool call, so redefining SHELL-TOOL or RELOAD-TOOL via reload_harness is
visible to the already-running interactive session."
  '(("run_shell" . shell-tool)
    ("reload_harness" . reload-tool)))

(defun make-chat-backend ()
  "Construct the chat provider backend from HARNESS_BACKEND (default openrouter).

Delegates to SELECT-CHAT-BACKEND. Supported values: openrouter (OPENROUTER_API_KEY)
or codex (ChatGPT/Codex subscription via local app-server). OpenAI Platform
API-key billing (OPENAI_API_KEY / api.openai.com) is not offered and is rejected."
  (select-chat-backend))

(defun make-cli-chat-session (backend model max-rounds &key history)
  "Build a CLI chat session that re-resolves options/handlers after reload.

CHAT-OPTIONS and CHAT-HANDLERS are stored as symbols, not as the values they
currently return. CHAT-SESSION-TURN funcalls those symbols each turn.

When HISTORY is a non-empty message list (from a resumed session snapshot), it
replaces the fresh single-system-message history so the model sees the full
prior conversation, including tool calls and tool results. The leading system
message is realigned to the current +CHAT-SYSTEM-PROMPT+ via
ENSURE-CHAT-SESSION-SYSTEM-PROMPT."
  (let ((session (make-chat-session
                  :backend backend
                  :model model
                  :options 'chat-options
                  :handlers 'chat-handlers
                  :max-rounds max-rounds)))
    (when (and history (listp history))
      (setf (chat-session-history session) history)
      (ensure-chat-session-system-prompt session))
    session))

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

(defun run-one-shot (backend model max-rounds prompt &key history)
  "Run a single prompt and print the answer plus structured OUTCOME on stderr.

If the prompt's tool loop schedules a synthetic follow-up (e.g. after
reload_harness), run that automatic turn before returning. HISTORY, when
supplied, seeds the session from a resumed snapshot."
  (let* ((session (make-cli-chat-session backend model max-rounds :history history))
         (start (get-internal-real-time))
         (response (chat-session-turn session prompt)))
    (report-completed-chat-turn session start response :leading-newline nil)
    (maybe-run-synthetic-followup-turns session)
    response))

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
between lines without restarting the process.

Slash commands such as /reload may schedule a synthetic follow-up; those run
here so the model can continue without another human line."
  (cond
    ((eq input :eof) :exit)
    ((interactive-exit-command-p input) :exit)
    ((zerop (length input))
     (format *error-output* "Empty input ignored.~%")
     (finish-output *error-output*)
     nil)
    ((handle-interactive-command session input)
     (maybe-run-synthetic-followup-turns session)
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

(defun run-interactive (backend model max-rounds &key history)
  "Persistent interactive chat loop.

The loop body intentionally stays thin and calls PROCESS-INTERACTIVE-INPUT,
WRITE-CHAT-PROMPT, and READ-CHAT-INPUT-LINE by name each iteration. Those
global function cells are what reload_harness updates; this stack frame is not
rewritten in place. After one process start on this thin loop, outcome/prompt/
command/tool-handler changes hot-reload without restarting chat.

Still requires process restart: changes to this function's own control flow
while it is already running, Docker/bin bootstrap, and incompatible
struct/class layout changes."
  (let ((session (make-cli-chat-session backend model max-rounds :history history)))
    (write-interactive-session-banner model max-rounds)
    (handler-bind
        ((sb-sys:interactive-interrupt
           (lambda (condition)
             (handle-interactive-interrupt condition)
             (return-from run-interactive nil))))
      (run-interactive-loop session)
      (when (chat-session-failed-turn-p session)
        (uiop:quit 1)))))

(defparameter +chat-fatal-exit-code+ 70
  "Process exit code used when an unhandled condition aborts the chat process.")

(defun chat-fatal-debugger-hook (condition previous-hook)
  "Print CONDITION plus a short backtrace and exit instead of entering the debugger.

bin/chat runs SBCL with an attached stdin (interactive or supervisor pipe) and,
unlike every other wrapper, cannot pass --non-interactive. Without this hook an
unhandled condition -- notably SB-KERNEL::HEAP-EXHAUSTED-ERROR -- drops into the
interactive debugger, which then blocks reading stdin and looks like a hang.
Each step is wrapped in IGNORE-ERRORS because a heap-exhausted image may fail to
allocate while reporting; the process must still exit."
  (declare (ignore previous-hook))
  (ignore-errors
    (format *error-output* "~&FATAL name=chat condition=~A message=~A~%"
            (type-of condition) condition)
    (finish-output *error-output*))
  (ignore-errors
    (log-interaction :error "session-failed"
                     :message (princ-to-string condition)))
  (ignore-errors
    (sb-debug:print-backtrace :stream *error-output* :count 20)
    (finish-output *error-output*))
  (uiop:quit +chat-fatal-exit-code+))

(defun install-chat-fatal-debugger-hook ()
  "Route unhandled conditions to CHAT-FATAL-DEBUGGER-HOOK for this process.

Does not affect normal interactive reads; it only replaces what happens when a
condition would otherwise enter the debugger."
  (setf sb-ext:*invoke-debugger-hook* #'chat-fatal-debugger-hook)
  (values))

(defun snapshot-session-id-from-path (path)
  "Return the ISO-timestamp session id encoded in a .history.json PATH, or NIL.

The basename is $SESSION-ID.history.json; strip the trailing .history.json."
  (let* ((name (file-namestring path))
         (suffix ".history.json"))
    (when (and (>= (length name) (length suffix))
               (string= suffix name :start2 (- (length name) (length suffix))))
      (subseq name 0 (- (length name) (length suffix))))))

(defun resolve-resume-plan (log-directory)
  "Return a resume plan for the most recent snapshot under LOG-DIRECTORY, or NIL.

The plan is a plist (:session-id :history :model :max-rounds :path). Returns NIL
when no snapshot exists or it has no usable messages, so the caller can start a
fresh session instead."
  (let ((snapshot (most-recent-session-snapshot log-directory)))
    (when snapshot
      (let ((history (read-session-history-snapshot snapshot)))
        (when (and history (listp history))
          (multiple-value-bind (session-id model max-rounds)
              (read-session-snapshot-metadata snapshot)
            (list :session-id (or session-id
                                  (snapshot-session-id-from-path snapshot))
                  :history history
                  :model model
                  :max-rounds max-rounds
                  :path snapshot)))))))

(defparameter *workspace-env-file*
  "/workspace/.env"
  "Default path to the workspace env file loaded into the process environment at
chat startup. The file is bind-mounted from the repository root, so hosts edit it
outside Docker. Override with the HARNESS_ENV_FILE environment variable (a
container-visible path; bin/chat forwards HARNESS_ENV_FILE into the container).")

(defun parse-env-file-line (line)
  "Parse a single env-file LINE into (VALUES NAME VALUE), or NIL to skip.

Blank lines and comments (# ...) are skipped. A line is NAME=VALUE, tolerating a
leading `export ` and surrounding single or double quotes around VALUE. Names
must match [A-Za-z_][A-Za-z0-9_]*; malformed lines are skipped."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
    (when (or (zerop (length trimmed))
              (char= (char trimmed 0) #\#))
      (return-from parse-env-file-line nil))
    (when (and (>= (length trimmed) 7)
               (string= (subseq trimmed 0 7) "export "))
      (setf trimmed (string-left-trim '(#\Space #\Tab) (subseq trimmed 7))))
    (let ((eq (position #\= trimmed)))
      (unless (and eq (plusp eq))
        (return-from parse-env-file-line nil))
      (let ((name (string-right-trim '(#\Space #\Tab) (subseq trimmed 0 eq)))
            (value (string-trim '(#\Space #\Tab) (subseq trimmed (1+ eq)))))
        (unless (and (plusp (length name))
                     (or (alpha-char-p (char name 0)) (char= (char name 0) #\_))
                     (every (lambda (c) (or (alphanumericp c) (char= c #\_))) name))
          (return-from parse-env-file-line nil))
        ;; Strip one layer of matching surrounding quotes from the value.
        (when (and (>= (length value) 2)
                   (member (char value 0) '(#\" #\'))
                   (char= (char value 0) (char value (1- (length value)))))
          (setf value (subseq value 1 (1- (length value)))))
        (values name value)))))

(defun load-workspace-env-file (&optional (path (or (uiop:getenv "HARNESS_ENV_FILE")
                                                    *workspace-env-file*)))
  "Read PATH and set each KEY=value into the running process environment.

Runs at chat startup so tools like run_shell (which inherit this process's
environment) see workspace-provided secrets such as GITHUB_TOKEN without passing
them through Docker. Variables already present in the process environment are
left untouched, so an explicitly exported value wins over the file. Logs the file
path and the names it set on *ERROR-OUTPUT* -- never the values. A missing file is
not an error. Returns the list of variable names set."
  (unless (and path (probe-file path))
    (format *error-output* "~&chat: no workspace env file at ~A; using inherited process environment only.~%"
            path)
    (finish-output *error-output*)
    (return-from load-workspace-env-file nil))
  (let ((set-names '()))
    (with-open-file (stream path :direction :input :external-format :utf-8)
      (loop for line = (read-line stream nil :eof)
            until (eq line :eof)
            do (multiple-value-bind (name value) (parse-env-file-line line)
                 (when name
                   (let ((existing (uiop:getenv name)))
                     (if (and existing (plusp (length existing)))
                         nil ; keep an already-set value; do not override
                         (progn
                           (setf (uiop:getenv name) value)
                           (push name set-names))))))))
    (setf set-names (nreverse set-names))
    (format *error-output* "~&chat: loaded workspace env file ~A into process environment; set ~D variable~:P~@[ (~{~A~^, ~})~].~%"
            path (length set-names) set-names)
    (finish-output *error-output*)
    (log-interaction :info "env-file-loaded" :path (namestring path)
                     :count (length set-names) :names set-names)
    set-names))

(defun run-chat-cli ()
  "Entry point for bin/chat after the system is loaded. Reads HARNESS_* env vars."
  (install-chat-fatal-debugger-hook)
  (let* ((mode (required-environment "HARNESS_CHAT_MODE"))
         (model (required-environment "HARNESS_CHAT_MODEL"))
         (max-rounds (parse-integer (required-environment "HARNESS_CHAT_MAX_ROUNDS")))
         (log-directory (or (uiop:getenv "HARNESS_LOG_DIR")
                               "/workspace/agent-logs"))
         (preferred-session-id (uiop:getenv "HARNESS_CHAT_SESSION_ID"))
         (resume-requested (let ((v (uiop:getenv "HARNESS_CHAT_RESUME")))
                             (and v (plusp (length v)))))
         (resume-plan (when resume-requested (resolve-resume-plan log-directory)))
         (resume-history (getf resume-plan :history))
         ;; A resumed session adopts the prior snapshot's session id (so its
         ;; JSONL/text/history files continue), model, and round limit -- those
         ;; describe the conversation being continued. Fresh sessions keep the
         ;; env-supplied values.
         (session-id (or (getf resume-plan :session-id) preferred-session-id))
         (model (or (getf resume-plan :model) model))
         (max-rounds (or (getf resume-plan :max-rounds) max-rounds))
         (backend (make-chat-backend)))
    ;; One session JSONL file per process: agent-logs/$ISO-TIMESTAMP.jsonl under
    ;; the workspace bind-mount so hosts can inspect logs without the Docker
    ;; named volume. Non-timestamp supervisor correlation IDs still work for
    ;; stderr events, but the durable log basename is always an ISO-8601 UTC
    ;; timestamp.
    (configure-interaction-logging log-directory :session-id session-id)
    (load-workspace-env-file)
    (when (and resume-requested (null resume-plan))
      (format *error-output*
              "~&No resumable session snapshot found under ~A; starting fresh.~%"
              log-directory)
      (finish-output *error-output*))
    (when resume-plan
      (format *error-output*
              "~&Resumed session ~A (~D messages) from ~A.~%"
              (getf resume-plan :session-id)
              (length resume-history)
              (file-namestring (getf resume-plan :path)))
      (finish-output *error-output*))
    (log-interaction :info "session-start" :mode mode :model model
                     :max-rounds max-rounds
                     :reason (if resume-plan "resumed" "fresh"))
    (handler-case
        (cond
          ((string= mode "one-shot")
           (run-one-shot backend model max-rounds
                         (required-environment "HARNESS_CHAT_PROMPT")
                         :history resume-history))
          ((string= mode "interactive")
           (run-interactive backend model max-rounds :history resume-history))
          (t (error "HARNESS_CHAT_MODE must be one-shot or interactive.")))
      (error (condition)
        (log-interaction :error "session-failed" :message (princ-to-string condition))
        (error condition)))
    (log-interaction :info "session-ended" :mode mode)
    (uiop:quit 0)))
