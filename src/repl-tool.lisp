(in-package #:self-improving-agent-harness)

;;; eval_lisp tool — evaluate Lisp forms in the running harness image (issue #96).
;;;
;;; This is an in-process REPL: forms are read and evaluated in the SAME Lisp
;;; image the chat CLI (or subagent) is already running in, at the same trust
;;; level as reload_harness (which already reloads/redefines every harness
;;; source file into this image). eval_lisp does NOT read or write any file: a
;;; form such as (defparameter *chat-max-tokens* 8192) takes effect
;;; immediately in the live image but is never written back to
;;; src/chat-cli.lisp. Persisting a change requires an explicit run_shell edit
;;; to the source file (and reload_harness, or simply relying on this same
;;; in-memory redefinition until the process restarts or reload_harness
;;; reloads the on-disk source and overwrites it again). This distinction is
;;; called out explicitly in the tool description so the model does not
;;; confuse an in-memory eval with a committed source change.

(defparameter *eval-lisp-default-timeout-seconds* 30
  "Default wall-clock timeout in seconds for eval_lisp when the tool call
omits timeout. Lisp forms run in-process (unlike run_shell, which can wrap an
OS subprocess in `timeout`), so the bound here is SB-EXT:WITH-TIMEOUT around
the read+eval loop.")

(defparameter *eval-lisp-package* :self-improving-agent-harness
  "Package *EVAL-LISP-TOOL* binds *PACKAGE* to while reading/evaluating code.

Same trust level as reload_harness: forms are read/evaluated in the harness's
own package so bare symbols (DEFPARAMETER, DEFUN, existing harness functions)
resolve without qualification, exactly as they do when reload_harness LOADs a
harness source file into this image.")

(defun coerce-eval-lisp-timeout (value)
  "Return a positive real timeout in seconds from tool VALUE or the default.

NIL means use *EVAL-LISP-DEFAULT-TIMEOUT-SECONDS*. A positive number (integer
or float) is accepted. Anything else signals an error."
  (cond
    ((null value)
     *eval-lisp-default-timeout-seconds*)
    ((and (realp value) (plusp value))
     value)
    (t
     (error "eval_lisp timeout must be a positive number of seconds, got ~S."
            value))))

(defun read-all-forms-from-string (text)
  "Return a list of every Lisp form read from TEXT, reading until EOF.

Reads with *READ-EVAL* bound NIL so a malicious/accidental #. reader macro in
submitted code cannot execute at read time (only through ordinary EVAL of the
forms themselves, matching how reload_harness LOADs source text). Signals a
READER error (propagated to the caller) on malformed syntax."
  (let ((*read-eval* nil))
    (with-input-from-string (stream text)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            collect form))))

(defun eval-lisp-forms (forms)
  "Evaluate each of FORMS in order. Return the values of the LAST form.

Uses plain EVAL, so DEFUN/DEFPARAMETER/DEFVAR/DEFMETHOD and ordinary
expressions all behave as they would if typed at a real REPL in this image."
  (let ((result nil))
    (dolist (form forms result)
      (setf result (multiple-value-list (eval form))))))

(defun format-eval-lisp-values (values)
  "Render a list of returned Lisp values for the tool result, one per line."
  (cond
    ((null values) "; No value")
    ((null (rest values))
     (with-standard-io-syntax
       (let ((*print-readably* nil) (*print-pretty* t))
         (prin1-to-string (first values)))))
    (t
     (with-standard-io-syntax
       (let ((*print-readably* nil) (*print-pretty* t))
         (format nil "~{~A~^~%~}" (mapcar #'prin1-to-string values)))))))

(defun run-eval-lisp (code timeout-seconds)
  "Read and evaluate every form in CODE inside *EVAL-LISP-PACKAGE*.

Returns three values: a result string (captured *STANDARD-OUTPUT* text plus
the printed return value(s) of the last form, or an error string on failure),
a boolean success flag, and a boolean timed-out flag. Never signals: reader
and evaluation errors are caught and formatted as a tool-facing error string,
matching RUN-SHELL-TOOL's contract of always returning a string."
  (let ((output-stream (make-string-output-stream)))
    (handler-case
        (let* ((*package* (find-package *eval-lisp-package*))
               (*standard-output* output-stream)
               (*error-output* output-stream)
               (values-and-captured
                 (if (and (realp timeout-seconds) (plusp timeout-seconds))
                     (sb-ext:with-timeout timeout-seconds
                       (eval-lisp-forms (read-all-forms-from-string code)))
                     (eval-lisp-forms (read-all-forms-from-string code))))
               (captured (get-output-stream-string output-stream))
               (value-text (format-eval-lisp-values values-and-captured)))
          (values
           (if (plusp (length captured))
               (format nil "~A~%=> ~A" captured value-text)
               (format nil "=> ~A" value-text))
           t nil))
      (sb-ext:timeout ()
        (values
         (format nil
                 "eval_lisp timed out after ~A seconds and was interrupted. Increase the optional timeout argument if the code needs more time.~%~A"
                 (format-run-shell-timeout-seconds timeout-seconds)
                 (get-output-stream-string output-stream))
         nil t))
      (error (condition)
        (values
         (format nil "eval_lisp failed: ~A~%~A"
                 (princ-to-string condition)
                 (get-output-stream-string output-stream))
         nil nil)))))

(defun eval-lisp-tool (arguments)
  "eval_lisp tool handler. Evaluate the `code` field from decoded tool
ARGUMENTS in the running harness Lisp image (the same process as this chat
session), at the same trust level as reload_harness.

Optional `timeout` is a positive number of wall-clock seconds (default
*EVAL-LISP-DEFAULT-TIMEOUT-SECONDS*). Returns captured standard-output text
followed by the printed return value(s) of the last form. A reader/eval error
or timeout is returned as a plain string (never signaled to the caller), same
contract as RUN-SHELL-TOOL.

eval_lisp does not read or write any file. It only mutates the live image
in-memory; use run_shell to edit a source file and reload_harness to load it
from disk if a change should persist."
  (let ((code (gethash "code" arguments))
        (timeout-seconds (coerce-eval-lisp-timeout (gethash "timeout" arguments))))
    (unless (and (stringp code) (plusp (length code)))
      (error "eval_lisp requires a non-empty code string."))
    (log-interaction :info "tool-call" :tool "eval_lisp"
                     :command code
                     :timeout-seconds timeout-seconds)
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (result success timed-out)
          (run-eval-lisp code timeout-seconds)
        (let ((duration-seconds
                (/ (float (- (get-internal-real-time) start) 0d0)
                   internal-time-units-per-second))
              (scrubbed (scrub-interaction-log-text result)))
          (cond
            (timed-out
             (log-interaction :error "tool-failed" :tool "eval_lisp"
                              :command code
                              :duration-seconds duration-seconds
                              :timeout-seconds timeout-seconds
                              :reason "timeout"))
            (success
             (log-interaction :info "tool-completed" :tool "eval_lisp"
                              :command code
                              :duration-seconds duration-seconds
                              :timeout-seconds timeout-seconds
                              :output-length (length scrubbed)))
            (t
             (log-interaction :error "tool-failed" :tool "eval_lisp"
                              :command code
                              :duration-seconds duration-seconds
                              :timeout-seconds timeout-seconds)))
          scrubbed)))))
