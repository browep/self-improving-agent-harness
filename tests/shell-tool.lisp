(in-package #:self-improving-agent-harness/tests)

(defun run-shell-tool-tests ()
  (let* ((em-dash (string (code-char #x2014)))
         (expected (format nil "unicode ~A output" em-dash))
         (output
           (self-improving-agent-harness::run-shell-tool
            (let ((arguments (make-hash-table :test #'equal)))
              (setf (gethash "command" arguments)
                    "printf 'unicode \\342\\200\\224 output'")
              arguments))))
    (ensure-equal expected output
                  "shell tool decodes UTF-8 command output"))
  (format t "Shell-tool tests passed.~%")
  t)
