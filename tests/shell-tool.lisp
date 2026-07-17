(in-package #:self-improving-agent-harness/tests)

(defun make-run-shell-arguments (&key command timeout)
  (let ((arguments (make-hash-table :test #'equal)))
    (when command
      (setf (gethash "command" arguments) command))
    (when timeout
      (setf (gethash "timeout" arguments) timeout))
    arguments))

(defun run-shell-tool-tests ()
  (let* ((em-dash (string (code-char #x2014)))
         (expected (format nil "unicode ~A output" em-dash))
         (output
           (self-improving-agent-harness::run-shell-tool
            (make-run-shell-arguments
             :command "printf 'unicode \\342\\200\\224 output'"))))
    (ensure-equal expected output
                  "shell tool decodes UTF-8 command output"))
  (let ((output
          (self-improving-agent-harness::run-shell-tool
           (make-run-shell-arguments
            :command "printf 'README was not found' >&2; exit 9"))))
    (ensure-true (search "Command failed with exit status 9" output)
                 "shell tool returns a nonzero exit status to the model")
    (ensure-true (search "README was not found" output)
                 "shell tool returns combined failure output to the model"))
  (let* ((seen nil)
         (arguments (make-run-shell-arguments :command "printf ok; exit 3")))
    (let ((self-improving-agent-harness:*run-shell-after-hooks*
            (list (lambda (&key command exit-status duration-seconds output
                             timeout-seconds timed-out)
                    (setf seen (list command exit-status duration-seconds output
                                     timeout-seconds timed-out))))))
      (let ((output (self-improving-agent-harness:run-shell-tool arguments)))
        (ensure-true (search "Command failed with exit status 3" output)
                     "hook test still returns failure content")
        (ensure-true (not (null seen)) "run_shell after-hook was invoked")
        (ensure-equal "printf ok; exit 3" (first seen)
                      "hook receives the command string")
        (ensure-equal 3 (second seen) "hook receives the exit status")
        (ensure-true (and (numberp (third seen)) (>= (third seen) 0))
                     "hook receives a non-negative duration")
        (ensure-true (search "ok" (fourth seen))
                     "hook receives command output")
        (ensure-equal self-improving-agent-harness:*run-shell-default-timeout-seconds*
                      (fifth seen)
                      "hook receives the default timeout when omitted")
        (ensure-equal nil (sixth seen)
                      "hook receives timed-out=nil for ordinary failures"))))
  (let ((output
          (self-improving-agent-harness::run-shell-tool
           (make-run-shell-arguments :command "sleep 5" :timeout 1))))
    (ensure-true (search "timed out after 1 seconds" output)
                 "shell tool reports a helpful timeout message")
    (ensure-true (search "Increase the optional timeout argument" output)
                 "timeout message tells the model how to raise the limit")
    (ensure-true (not (search "Command failed with exit status" output))
                 "timeout path does not look like a generic nonzero exit"))
  (let* ((seen nil)
         (arguments (make-run-shell-arguments :command "sleep 5" :timeout 1)))
    (let ((self-improving-agent-harness:*run-shell-after-hooks*
            (list (lambda (&key timed-out timeout-seconds exit-status
                             &allow-other-keys)
                    (setf seen (list timed-out timeout-seconds exit-status))))))
      (self-improving-agent-harness:run-shell-tool arguments)
      (ensure-equal t (first seen) "timeout after-hook sets timed-out")
      (ensure-equal 1 (second seen) "timeout after-hook keeps configured timeout")
      (ensure-equal 124 (third seen)
                    "timeout after-hook reports GNU timeout exit status 124")))
  (let ((output
          (self-improving-agent-harness::run-shell-tool
           (make-run-shell-arguments :command "printf quick" :timeout 5))))
    (ensure-equal "quick" output
                  "explicit timeout still returns successful command output"))
  (handler-case
      (progn
        (self-improving-agent-harness::run-shell-tool
         (make-run-shell-arguments :command "printf x" :timeout 0))
        (error "Test failed: non-positive timeout must be rejected"))
    (error (condition)
      (ensure-true (search "positive number" (princ-to-string condition))
                   "non-positive timeout signals a clear error")))
  (format t "Shell-tool tests passed.~%")
  t)
