;;;; Opt-in, billable Codex ChatGPT subscription verification (issue #18).
;;;;
;;;; Runs AFTER a human completes Codex-managed ChatGPT login. Starts the
;;;; official local `codex app-server`, requires authMode == chatgpt, and runs
;;;; one bounded, tool-free turn. Exits 0 only when BOTH succeed; otherwise a
;;;; non-zero exit with a redacted, actionable reason. Never run from make test.
;;;;
;;;; Emits and persists ONLY sanitized evidence (Codex version, timestamp, auth
;;;; mode, non-secret plan/model, turn outcome). No OAuth material.

(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

(defpackage #:codex-verify-script (:use #:cl))
(in-package #:codex-verify-script)

(defun getenv (name) (uiop:getenv name))

(defun opted-in-p ()
  (let ((v (getenv "HARNESS_LIVE_CODEX_SMOKE")))
    (and (stringp v) (string= v "1"))))

(defun codex-version-string ()
  "Best-effort, non-secret Codex version label; unavailable on any failure."
  (handler-case
      (string-trim '(#\Space #\Newline #\Return)
                   (uiop:run-program '("codex" "--version")
                                     :output :string :ignore-error-status t))
    (error () "unavailable")))

(defun iso-timestamp ()
  (multiple-value-bind (s min h d mon y) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mon d h min s)))

(defun evidence-artifact-path ()
  (let ((dir (or (getenv "HARNESS_CODEX_EVIDENCE_DIR")
                 (getenv "HARNESS_LOG_DIR")
                 "agent-logs")))
    (ensure-directories-exist (merge-pathnames "" (uiop:ensure-directory-pathname dir)))
    (merge-pathnames (format nil "codex-verify-~A.txt"
                             (substitute #\_ #\: (iso-timestamp)))
                     (uiop:ensure-directory-pathname dir))))

(defun main ()
  (unless (opted-in-p)
    (format *error-output*
            "SKIP: set HARNESS_LIVE_CODEX_SMOKE=1 to run the billable Codex verification.~%")
    (uiop:quit 77))
  (let ((codex-version (codex-version-string))
        (timestamp (iso-timestamp)))
    (multiple-value-bind (evidence success)
        (self-improving-agent-harness:verify-codex-chatgpt-auth
         :codex-version codex-version)
      ;; Add the verification timestamp; everything is already sanitized.
      (setf evidence (list* :timestamp timestamp evidence))
      ;; Print to stdout.
      (self-improving-agent-harness:format-codex-verification-evidence evidence *standard-output*)
      ;; Persist a sanitized artifact.
      (handler-case
          (let ((path (evidence-artifact-path)))
            (with-open-file (out path :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
              (self-improving-agent-harness:format-codex-verification-evidence evidence out))
            (format *error-output* "CODEX_VERIFY evidence written to ~A~%" (namestring path)))
        (error (condition)
          (format *error-output* "CODEX_VERIFY warning: could not write evidence artifact (~A)~%"
                  (type-of condition))))
      (uiop:quit (if success 0 1)))))

(main)
