(in-package #:self-improving-agent-harness)

(defparameter *run-shell-after-hooks*
  (list 'report-run-shell-timing)
  "Functions invoked after each run_shell completes.

Each hook is called with keyword arguments:
  :command, :exit-status, :duration-seconds, :output.
The default list reports wall-clock duration and exit status on *ERROR-OUTPUT*.")

(defun truncate-for-display (text &optional (max-chars 80))
  "Return TEXT limited to MAX-CHARS characters, appending \"...\" when truncated."
  (if (and (stringp text) (> (length text) max-chars))
      (concatenate 'string (subseq text 0 max-chars) "...")
      (or text "")))

(defun report-run-shell-timing (&key command exit-status duration-seconds output)
  "Default run_shell hook: print command preview, exit status, and elapsed seconds."
  (declare (ignore output))
  (format *error-output*
          "TOOL_DONE name=run_shell exit_status=~D duration_seconds=~,3F command=~S~%"
          exit-status duration-seconds (truncate-for-display command 80))
  (finish-output *error-output*))

(defun run-run-shell-after-hooks (&rest args &key command exit-status duration-seconds output)
  "Apply every function in *RUN-SHELL-AFTER-HOOKS* to ARGS."
  (declare (ignore command exit-status duration-seconds output))
  (dolist (hook *run-shell-after-hooks*)
    (apply hook args)))

(defun run-shell-tool (arguments)
  "Run the non-empty `command` field from decoded tool ARGUMENTS in the container.

Return combined stdout/stderr as UTF-8 text.  A command failure remains an
error so the tool loop can report a safe, redacted failure outcome.
After the process exits, *RUN-SHELL-AFTER-HOOKS* run with timing and exit status."
  (let ((command (gethash "command" arguments)))
    (unless (and (stringp command) (plusp (length command)))
      (error "run_shell requires a non-empty command."))
    (log-interaction :info "tool-call" :tool "run_shell" :command command)
    (format *error-output*
            "TOOL_CALL name=run_shell command=~S~%"
            (truncate-for-display command 80))
    (finish-output *error-output*)
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (output ignored-error-output exit-status)
          (uiop:run-program (list "/bin/sh" "-lc" command)
                            :output :string
                            :error-output :output
                            :external-format :utf-8
                            :ignore-error-status t)
        (declare (ignore ignored-error-output))
        (let ((duration-seconds
                (/ (float (- (get-internal-real-time) start) 0d0)
                   internal-time-units-per-second)))
          (run-run-shell-after-hooks :command command
                                     :exit-status exit-status
                                     :duration-seconds duration-seconds
                                     :output output)
          (if (zerop exit-status)
              (progn
                (log-interaction :info "tool-completed" :tool "run_shell"
                                 :command command
                                 :exit-status exit-status
                                 :duration-seconds duration-seconds
                                 :output-length (length output))
                output)
              (progn
                (log-interaction :error "tool-failed" :tool "run_shell"
                                 :command command
                                 :exit-status exit-status
                                 :duration-seconds duration-seconds)
                (format nil "Command failed with exit status ~D.~%~A"
                        exit-status output))))))))
