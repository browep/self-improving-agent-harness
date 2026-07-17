(in-package #:self-improving-agent-harness)

(defparameter *run-shell-after-hooks*
  (list 'report-run-shell-timing)
  "Functions invoked after each run_shell completes.

Each hook is called with keyword arguments:
  :command, :exit-status, :duration-seconds, :output, :timeout-seconds, :timed-out.
The default list reports wall-clock duration and exit status on *ERROR-OUTPUT*.")

(defparameter *run-shell-default-timeout-seconds* 60
  "Default wall-clock timeout in seconds for run_shell when the tool call omits timeout.")

(defparameter *run-shell-timeout-kill-after-seconds* 5
  "Seconds GNU timeout waits after SIGTERM before sending SIGKILL.")

(defun truncate-for-display (text &optional (max-chars 80))
  "Return TEXT limited to MAX-CHARS characters, appending \"...\" when truncated."
  (if (and (stringp text) (> (length text) max-chars))
      (concatenate 'string (subseq text 0 max-chars) "...")
      (or text "")))

(defun report-run-shell-timing (&key command exit-status duration-seconds output
                                  timeout-seconds timed-out)
  "Default run_shell hook: print command preview, exit status, and elapsed seconds."
  (declare (ignore output timeout-seconds timed-out))
  (format *error-output*
          "TOOL_DONE name=run_shell exit_status=~D duration_seconds=~,3F command=~S~%"
          exit-status duration-seconds (truncate-for-display command 80))
  (finish-output *error-output*))

(defun run-run-shell-after-hooks (&rest args &key command exit-status duration-seconds
                                             output timeout-seconds timed-out)
  "Apply every function in *RUN-SHELL-AFTER-HOOKS* to ARGS.

Hooks should be symbols when possible so reload_harness can redefine them
without rewriting this list. Function objects remain supported but stay frozen."
  (declare (ignore command exit-status duration-seconds output timeout-seconds timed-out))
  (dolist (hook *run-shell-after-hooks*)
    (apply (if (symbolp hook) hook (coerce hook 'function)) args)))

(defun coerce-run-shell-timeout (value)
  "Return a positive real timeout in seconds from tool VALUE or the default.

NIL means use *RUN-SHELL-DEFAULT-TIMEOUT-SECONDS*. A positive number (integer or
float) is accepted. Anything else signals an error."
  (cond
    ((null value)
     *run-shell-default-timeout-seconds*)
    ((and (realp value) (plusp value))
     value)
    (t
     (error "run_shell timeout must be a positive number of seconds, got ~S."
            value))))

(defun format-run-shell-timeout-seconds (timeout-seconds)
  "Render TIMEOUT-SECONDS for human-readable timeout messages."
  (cond
    ((and (integerp timeout-seconds) (plusp timeout-seconds))
     (format nil "~D" timeout-seconds))
    ((and (realp timeout-seconds)
          (plusp timeout-seconds)
          (= timeout-seconds (round timeout-seconds)))
     (format nil "~D" (round timeout-seconds)))
    (t
     (let* ((raw (format nil "~,3F" (float timeout-seconds 1.0d0)))
            (text (string-right-trim
                   '(#\0)
                   (string-right-trim '(#\.) raw))))
       (if (plusp (length text))
           text
           (format nil "~F" timeout-seconds))))))

(defun run-shell-command (command timeout-seconds)
  "Run COMMAND via /bin/sh -lc under a wall-clock TIMEOUT-SECONDS bound.

Uses GNU coreutils `timeout` so hung commands are terminated with SIGTERM and,
after *RUN-SHELL-TIMEOUT-KILL-AFTER-SECONDS*, SIGKILL. Returns three values:
combined UTF-8 output, exit status, and a boolean timed-out flag. Exit status
124 from `timeout` is treated as a wall-clock timeout."
  (multiple-value-bind (output ignored-error-output exit-status)
      (uiop:run-program
       (list "timeout"
             "--signal=TERM"
             (format nil "--kill-after=~A"
                     (format-run-shell-timeout-seconds
                      *run-shell-timeout-kill-after-seconds*))
             (format-run-shell-timeout-seconds timeout-seconds)
             "/bin/sh" "-lc" command)
       :output :string
       :error-output :output
       :external-format :utf-8
       :ignore-error-status t)
    (declare (ignore ignored-error-output))
    (values output exit-status (= exit-status 124))))

(defun run-shell-timeout-message (timeout-seconds output)
  "Return a helpful tool-result string for a timed-out command."
  (format nil
          "Command timed out after ~A seconds and was terminated. Increase the optional timeout argument if the command needs more time.~%~A"
          (format-run-shell-timeout-seconds timeout-seconds)
          output))

(defun run-shell-tool (arguments)
  "Run the non-empty `command` field from decoded tool ARGUMENTS in the container.

Optional `timeout` is a positive number of wall-clock seconds (default
*RUN-SHELL-DEFAULT-TIMEOUT-SECONDS*). Return combined stdout/stderr as UTF-8
text. A command failure remains an error string so the tool loop can report a
safe, redacted failure outcome. On timeout, return a clear timeout message
instead of hanging the chat turn. After the process exits, *RUN-SHELL-AFTER-HOOKS*
run with timing, exit status, and timeout metadata."
  (let ((command (gethash "command" arguments))
        (timeout-seconds (coerce-run-shell-timeout (gethash "timeout" arguments))))
    (unless (and (stringp command) (plusp (length command)))
      (error "run_shell requires a non-empty command."))
    (log-interaction :info "tool-call" :tool "run_shell"
                     :command command
                     :timeout-seconds timeout-seconds)
    (format *error-output*
            "TOOL_CALL name=run_shell timeout_seconds=~A command=~S~%"
            (format-run-shell-timeout-seconds timeout-seconds)
            (truncate-for-display command 80))
    (finish-output *error-output*)
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (output exit-status timed-out)
          (run-shell-command command timeout-seconds)
        (let ((duration-seconds
                (/ (float (- (get-internal-real-time) start) 0d0)
                   internal-time-units-per-second)))
          (run-run-shell-after-hooks :command command
                                     :exit-status exit-status
                                     :duration-seconds duration-seconds
                                     :output output
                                     :timeout-seconds timeout-seconds
                                     :timed-out timed-out)
          (cond
            (timed-out
             (log-interaction :error "tool-failed" :tool "run_shell"
                              :command command
                              :exit-status exit-status
                              :duration-seconds duration-seconds
                              :timeout-seconds timeout-seconds
                              :reason "timeout")
             (run-shell-timeout-message timeout-seconds output))
            ((zerop exit-status)
             (log-interaction :info "tool-completed" :tool "run_shell"
                              :command command
                              :exit-status exit-status
                              :duration-seconds duration-seconds
                              :timeout-seconds timeout-seconds
                              :output-length (length output))
             output)
            (t
             (log-interaction :error "tool-failed" :tool "run_shell"
                              :command command
                              :exit-status exit-status
                              :duration-seconds duration-seconds
                              :timeout-seconds timeout-seconds)
             (format nil "Command failed with exit status ~D.~%~A"
                     exit-status output))))))))
