(in-package #:self-improving-agent-harness)

(defun run-shell-tool (arguments)
  "Run the non-empty `command` field from decoded tool ARGUMENTS in the container.

Return combined stdout/stderr as UTF-8 text.  A command failure remains an
error so the tool loop can report a safe, redacted failure outcome."
  (let ((command (gethash "command" arguments)))
    (unless (and (stringp command) (plusp (length command)))
      (error "run_shell requires a non-empty command."))
    (format *error-output* "TOOL_CALL name=run_shell~%")
    (uiop:run-program (list "/bin/sh" "-lc" command)
                      :output :string
                      :error-output :output
                      :external-format :utf-8)))
