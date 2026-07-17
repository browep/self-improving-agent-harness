(in-package #:self-improving-agent-harness)

(defun harness-asd-path ()
  "Locate the project ASD file from the loaded system or the working directory."
  (or (let ((system (asdf:find-system :self-improving-agent-harness nil)))
        (when system
          (asdf:system-source-file system)))
      (probe-file (merge-pathnames "self-improving-agent-harness.asd"
                                   (uiop:getcwd)))
      (error "Could not locate self-improving-agent-harness.asd")))

(defun harness-source-files (system)
  "Return absolute pathnames of CL source files in SYSTEM in serial order."
  (let ((files '()))
    (labels ((walk (component)
               (typecase component
                 (asdf:cl-source-file
                  (push (asdf:component-pathname component) files))
                 (asdf:module
                  (mapc #'walk (asdf:component-children component))))))
      (walk system))
    (nreverse files)))

(defun reload-harness-source-files ()
  "Reload every Lisp source file in the harness ASDF system from source.

The Docker runtime mounts /workspace read-only, so COMPILE-FILE cannot safely
write FASLs beside sources. Loading the source files directly redefines the
running image without mutating the checkout or relying on ASDF's outer
operation state."
  (let* ((system (asdf:find-system :self-improving-agent-harness t))
         (files (harness-source-files system)))
    (dolist (file files)
      (load file :verbose nil :print nil))
    files))

(defun reload-harness-tool (arguments)
  "Reload harness sources into the current Lisp image.

ARGUMENTS is the decoded tool-argument object (hash-table or NIL) and is
ignored: reload always reloads the full ASDF system sources. This runs
in-process, so redefined functions and parameters (including chat CLI prompt
bindings in src/chat-cli.lisp) are visible to later turns of the same chat.
Existing CHAT-SESSION slot values (history, max-rounds, captured handler list)
are not reset; use interactive /max-rounds to change the live session limit."
  (declare (ignore arguments))
  (log-interaction :info "tool-call" :tool "reload_harness")
  (format *error-output* "TOOL_CALL name=reload_harness~%")
  (let ((asd (harness-asd-path)))
    (asdf:load-asd asd)
    ;; Refresh system definition so newly added components (e.g. chat-cli) appear.
    (asdf:find-system :self-improving-agent-harness t)
    (reload-harness-source-files)
    (let ((message
            (format nil
                    "Reloaded self-improving-agent-harness from ~A. Function definitions now match disk. Existing chat-session history, max-rounds, and handler list were not reset."
                    asd)))
      (log-interaction :info "tool-completed" :tool "reload_harness"
                       :asd (namestring asd))
      message)))
