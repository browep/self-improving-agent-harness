(in-package #:self-improving-agent-harness)

(defparameter *reload-diagnostic-limit* 20
  "Maximum number of non-benign reload diagnostics included in the tool result.")

(defparameter *pending-synthetic-followups* nil
  "FIFO list of synthetic user-turn strings to run without human input.

Successful RELOAD-HARNESS-TOOL pushes a follow-up so the model can use
newly registered tools on a fresh provider request without a human message.
Consumed by MAYBE-RUN-SYNTHETIC-FOLLOWUP-TURNS after the primary turn or
slash-command finishes.")

(defparameter *suppress-synthetic-followup-scheduling* nil
  "When true, SCHEDULE-SYNTHETIC-FOLLOWUP is a no-op.

Bound true while a synthetic follow-up turn is running so a nested
reload_harness cannot queue an unbounded chain in the same auto-run.")

(defun schedule-synthetic-followup (content &key (source "reload_harness"))
  "Append CONTENT as a pending synthetic user turn.

No-op when *SUPPRESS-SYNTHETIC-FOLLOWUP-SCHEDULING* is true, or when CONTENT
is empty. SOURCE is logged for operators and tests."
  (let ((text (and (stringp content) (string-trim '(#\Space #\Tab #\Newline) content))))
    (cond
      (*suppress-synthetic-followup-scheduling*
       nil)
      ((not (and text (plusp (length text))))
       nil)
      (t
       (setf *pending-synthetic-followups*
             (append *pending-synthetic-followups* (list text)))
       (log-interaction :info "synthetic-followup-scheduled"
                        :initiator "harness"
                        :source source
                        :content text
                        :queue-length (length *pending-synthetic-followups*))
       (format *error-output* "~%")
       (format *error-output* "----------------------------------------------------------------~%")
       (format *error-output*
               "SYNTHETIC_FOLLOWUP scheduled initiator=harness source=~A queue_length=~D~%"
               source (length *pending-synthetic-followups*))
       (format *error-output* "SYNTHETIC_FOLLOWUP preview=~S~%"
               (if (> (length text) 200)
                   (concatenate 'string (subseq text 0 200) "...")
                   text))
       (format *error-output* "----------------------------------------------------------------~%")
       (finish-output *error-output*)
       text))))

(defun take-next-synthetic-followup ()
  "Pop and return the next pending synthetic user turn, or NIL."
  (let ((next (first *pending-synthetic-followups*)))
    (setf *pending-synthetic-followups* (rest *pending-synthetic-followups*))
    next))

(defun clear-synthetic-followups ()
  "Drop all pending synthetic follow-ups. Returns the discarded list."
  (prog1 *pending-synthetic-followups*
    (setf *pending-synthetic-followups* nil)))

(defun default-reload-synthetic-followup-content (status)
  "User-turn text injected after a successful in-process reload."
  (format nil
          "[harness] reload_harness finished with status=~A. ~
This is an automatic follow-up turn (no human message). ~
Tool schemas and handlers have been re-resolved for this turn. ~
If you created or changed tools, call them now as needed, then return a final response."
          status))

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

(defun reload-condition-source-path (condition)
  "Best-effort source path for a compiler note/warning, or NIL."
  (declare (ignore condition))
  (or (ignore-errors *compile-file-pathname*)
      (ignore-errors *load-pathname*)))

(defun reload-condition-kind (condition)
  "Return a compact diagnostic kind keyword for CONDITION."
  (cond
    ((typep condition 'error) :error)
    ((and (find-symbol "COMPILER-NOTE" :sb-ext)
          (typep condition (find-symbol "COMPILER-NOTE" :sb-ext)))
     :note)
    ((typep condition 'style-warning) :style-warning)
    ((typep condition 'warning) :warning)
    (t :diagnostic)))

(defun benign-reload-condition-p (condition)
  "True for expected noise from in-process redefinition and foreign ASDFs.

Reload intentionally LOADs every harness source file into a live image, so
SBCL redefinition warnings are normal success signals rather than problems to
surface to the tool caller."
  (or (typep condition 'sb-kernel:redefinition-with-defun)
      (typep condition 'sb-kernel:redefinition-with-defmacro)
      (typep condition 'sb-kernel:redefinition-with-defgeneric)
      (typep condition 'sb-kernel:redefinition-with-defmethod)
      (let ((text (ignore-errors (princ-to-string condition))))
        (and (stringp text)
             (or (search "redefining" text :test #'char-equal)
                 (search "BAD-SYSTEM-NAME" text :test #'char-equal)
                 (search "contains definition for system" text :test #'char-equal))))))

(defun sanitize-reload-diagnostic-text (text)
  "Return a single-line, length-capped diagnostic string safe for tool results."
  (let* ((flattened (if (stringp text)
                        (substitute #\Space #\Newline
                                    (substitute #\Space #\Return text))
                        (prin1-to-string text)))
         (trimmed (string-trim '(#\Space #\Tab) flattened))
         (limit 240))
    (if (<= (length trimmed) limit)
        trimmed
        (concatenate 'string (subseq trimmed 0 (- limit 3)) "..."))))

(defun format-reload-diagnostic (kind condition &optional source-path)
  "Format one collected diagnostic for inclusion in the tool result."
  (let* ((path-string
           (when source-path
             (namestring source-path)))
         (relative
           (when path-string
             (let* ((marker "/workspace/")
                    (pos (search marker path-string)))
               (if pos
                   (subseq path-string (+ pos (length marker)))
                   path-string))))
         (text (sanitize-reload-diagnostic-text
                (ignore-errors (princ-to-string condition)))))
    (if relative
        (format nil "~(~A~): ~A: ~A" kind relative text)
        (format nil "~(~A~): ~A" kind text))))

(defun collect-reload-diagnostics (thunk)
  "Run THUNK while collecting non-benign warnings/notes.

Returns five values: primary value of THUNK, warning messages, note messages,
benign-count, and error message or NIL. Soft warnings/notes are muffled after
collection so reload can continue; serious errors are captured and abort THUNK."
  (let ((warnings '())
        (notes '())
        (benign 0)
        (error-message nil)
        (primary nil))
    (handler-bind
        ((warning
          (lambda (condition)
            (if (benign-reload-condition-p condition)
                (incf benign)
                (push (format-reload-diagnostic (reload-condition-kind condition)
                                                condition
                                                (reload-condition-source-path condition))
                      warnings))
            (muffle-warning condition)))
         #+#.(cl:if (cl:find-symbol "COMPILER-NOTE" :sb-ext) '(and) '(or))
         (sb-ext:compiler-note
          (lambda (condition)
            (if (benign-reload-condition-p condition)
                (incf benign)
                (push (format-reload-diagnostic :note condition
                                                (reload-condition-source-path condition))
                      notes)))))
      (handler-case
          (setf primary (funcall thunk))
        (error (condition)
          (setf error-message
                (format-reload-diagnostic :error condition
                                         (reload-condition-source-path condition))
                primary nil))))
    (values primary
            (nreverse warnings)
            (nreverse notes)
            benign
            error-message)))

(defun reload-status-for-counts (error-message warning-count note-count)
  "Map collected diagnostic counts to a compact status token."
  (cond
    (error-message "error")
    ((plusp warning-count) "warning")
    ((plusp note-count) "note")
    (t "ok")))

(defun format-reload-tool-result (&key status asd file-count warning-count note-count
                                    benign-count diagnostics error-message)
  "Build the structured reload_harness tool result string."
  (with-output-to-string (stream)
    (format stream
            "status=~A files=~D warnings=~D notes=~D benign_redefinitions=~D asd=~A"
            status file-count warning-count note-count benign-count (namestring asd))
    (format stream
            "~%Reloaded self-improving-agent-harness from ~A. Function definitions now match disk. Existing chat-session history, max-rounds, and handler list were not reset."
            asd)
    (when error-message
      (format stream "~%error: ~A" error-message))
    (let ((limit *reload-diagnostic-limit*)
          (emitted 0))
      (dolist (item diagnostics)
        (when (< emitted limit)
          (format stream "~%~A" item)
          (incf emitted)))
      (let ((remaining (- (length diagnostics) emitted)))
        (when (plusp remaining)
          (format stream "~%... ~D more diagnostic(s) omitted" remaining))))))

(defun relative-workspace-path-string (path)
  "Return PATH relative to /workspace when possible, else namestring."
  (let* ((names (namestring path))
         (marker "/workspace/")
         (pos (search marker names)))
    (if pos
        (subseq names (+ pos (length marker)))
        names)))

(defun reload-harness-source-files (&key (progress-callback nil))
  "Reload every Lisp source file in the harness ASDF system from source.

The Docker runtime mounts /workspace read-only, so COMPILE-FILE cannot safely
write FASLs beside sources. Loading the source files directly redefines the
running image without mutating the checkout or relying on ASDF's outer
operation state.

PROGRESS-CALLBACK, when non-NIL, is called as
  (funcall callback :index i :total n :file path)
before each file load so operators can see hang progress in JSONL.

Returns the list of loaded pathnames."
  (let* ((system (asdf:find-system :self-improving-agent-harness t))
         (files (harness-source-files system))
         (total (length files))
         (index 0))
    (dolist (file files)
      (incf index)
      (when progress-callback
        (funcall progress-callback :index index :total total :file file))
      (load file :verbose nil :print nil))
    files))

(defun reload-harness-tool (arguments)
  "Reload harness sources into the current Lisp image.

ARGUMENTS is the decoded tool-argument object (hash-table or NIL) and is
ignored: reload always reloads the full ASDF system sources. This runs
in-process, so redefined functions and parameters (including chat CLI prompt
bindings in src/chat-cli.lisp) are visible to later turns of the same chat.
Existing CHAT-SESSION slot values (history, max-rounds, captured handler list)
are not reset; use interactive /max-rounds to change the live session limit.

The tool result is a structured status summary:

  status=ok|note|warning|error files=N warnings=N notes=N benign_redefinitions=N asd=...

followed by a human sentence and any non-benign diagnostics. Expected SBCL
redefinition warnings from LOAD are counted as benign and omitted. Soft
warnings/notes do not abort the reload; load/read errors set status=error and
still return a tool result string so the model can see the failure detail.

Hang diagnosis: always logs reload-started, per-file reload-progress, and a
terminal reload-completed/reload-failed plus tool-completed/tool-failed with
duration-seconds, even when a load error is captured into status=error."
  (declare (ignore arguments))
  (let ((start (get-internal-real-time))
        (asd nil)
        (status "error")
        (warning-count 0)
        (note-count 0)
        (file-count 0)
        (message nil))
    (log-interaction :info "tool-call" :tool "reload_harness")
    (unwind-protect
         (handler-case
             (progn
               (setf asd (harness-asd-path))
               (log-interaction :info "reload-started"
                                :tool "reload_harness"
                                :file (namestring asd))
               (format *error-output* "RELOAD_PROGRESS phase=start asd=~A~%"
                       (namestring asd))
               (finish-output *error-output*)
               (multiple-value-bind (files warnings notes benign error-message)
                   (collect-reload-diagnostics
                    (lambda ()
                      (asdf:load-asd asd)
                      ;; Refresh system definition so newly added components appear.
                      (asdf:find-system :self-improving-agent-harness t)
                      (reload-harness-source-files
                       :progress-callback
                       (lambda (&key index total file)
                         (let ((relative (relative-workspace-path-string file)))
                           (log-interaction :info "reload-progress"
                                            :tool "reload_harness"
                                            :loaded-file-count index
                                            :total-file-count total
                                            :file relative)
                           (format *error-output*
                                   "RELOAD_PROGRESS phase=load file=~A index=~D total=~D~%"
                                   relative index total)
                           (finish-output *error-output*))))))
                 (setf file-count (if (listp files) (length files) 0)
                       warning-count (length warnings)
                       note-count (length notes)
                       status (reload-status-for-counts error-message
                                                       warning-count
                                                       note-count)
                       message
                       (format-reload-tool-result
                        :status status
                        :asd asd
                        :file-count file-count
                        :warning-count warning-count
                        :note-count note-count
                        :benign-count benign
                        :diagnostics (append warnings notes)
                        :error-message error-message))))
           (error (condition)
             (setf status "error"
                   message
                   (format nil
                           "status=error files=0 warnings=0 notes=0 benign_redefinitions=0 asd=~A~%error: ~A"
                           (if asd (namestring asd) "unknown")
                           (princ-to-string condition)))
             message))
      (let ((duration (elapsed-seconds-since start)))
        (if (string= status "error")
            (progn
              (log-interaction :error "reload-failed"
                               :tool "reload_harness"
                               :status status
                               :duration-seconds duration
                               :file-count file-count
                               :message (or message "reload failed"))
              (log-interaction :error "tool-failed"
                               :tool "reload_harness"
                               :duration-seconds duration
                               :status status))
            (progn
              (log-interaction :info "reload-completed"
                               :tool "reload_harness"
                               :status status
                               :duration-seconds duration
                               :file-count file-count)
              (log-interaction :info "tool-completed"
                               :tool "reload_harness"
                               :duration-seconds duration
                               :status status
                               :file-count file-count)))
        (format *error-output*
                "RELOAD_SUMMARY status=~A warnings=~D notes=~D duration_seconds=~,3F~%"
                status warning-count note-count duration)
        (finish-output *error-output*)))
    ;; Queue a synthetic follow-up so newly registered tools can be advertised
    ;; on a fresh provider request without waiting for another human message.
    ;; Multiple reloads in one primary turn collapse to a single follow-up.
    (unless (string= status "error")
      (setf *pending-synthetic-followups*
            (remove-if (lambda (content)
                         (and (stringp content)
                              (search "[harness] reload_harness finished" content)))
                       *pending-synthetic-followups*))
      (schedule-synthetic-followup
       (default-reload-synthetic-followup-content status)
       :source "reload_harness"))
    (or message
        (format nil "status=error files=0 warnings=0 notes=0 benign_redefinitions=0 asd=unknown~%error: reload_harness produced no result"))))
