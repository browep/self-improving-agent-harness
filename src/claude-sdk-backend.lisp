(in-package #:self-improving-agent-harness)

;;;; Claude Agent SDK direct backend seam (issue #67).
;;;;
;;;; This is a narrow, selectable placeholder for a *direct* Anthropic
;;;; transport, deliberately separate from CLAUDE-BACKEND (which spawns the
;;;; official Claude Code CLI binary in src/claude-backend.lisp). This backend
;;;; never spawns a process and never opens a socket. Its only credential
;;;; boundary is the same runtime-only CLAUDE_CODE_OAUTH_TOKEN used by the CLI
;;;; backend; it never reads or falls back to ANTHROPIC_API_KEY. Until the
;;;; real request/response contract is captured and sanitized (issue #66),
;;;; COMPLETE deliberately refuses to make a live call and signals a clear
;;;; not-implemented error instead of guessing an undocumented wire protocol.

(define-condition claude-sdk-backend-error (error)
  ((reason :initarg :reason :reader claude-sdk-backend-error-reason))
  (:report (lambda (condition stream)
             (format stream "Claude SDK backend error: ~A"
                     (claude-sdk-backend-error-reason condition)))))

(defun claude-sdk-error (format-control &rest args)
  (error 'claude-sdk-backend-error :reason (apply #'format nil format-control args)))

(defun claude-sdk-normalize-token (value)
  "Trim VALUE and remove one matching layer of .env-style surrounding quotes."
  (when (stringp value)
    (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) value)))
      (if (and (>= (length trimmed) 2)
               (member (char trimmed 0) '(#\" #\'))
               (char= (char trimmed 0) (char trimmed (1- (length trimmed)))))
          (subseq trimmed 1 (1- (length trimmed)))
          trimmed))))

(defun require-claude-sdk-oauth-token ()
  "Return the runtime CLAUDE_CODE_OAUTH_TOKEN, or signal a safe missing-token error.

This is the only credential this backend ever consults. It never reads
ANTHROPIC_API_KEY, and never falls back to it when the OAuth token is absent
or blank."
  (let ((token (claude-sdk-normalize-token (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN"))))
    (unless (and token (plusp (length token)))
      (claude-sdk-error
       "authentication is not configured. Generate a long-lived OAuth token with `claude setup-token` on a machine logged in to the intended Claude subscription, then provide it as CLAUDE_CODE_OAUTH_TOKEN and retry."))
    token))

(defclass claude-sdk-backend (backend) ()
  (:documentation "Direct Claude Agent SDK transport seam, distinct from the CLI-spawning CLAUDE-BACKEND.

No direct transport is implemented yet: COMPLETE always signals
CLAUDE-SDK-BACKEND-ERROR once a runtime token is confirmed present."))

(defun make-claude-sdk-backend ()
  "Construct a claude-sdk backend without reading credentials or doing I/O."
  (make-instance 'claude-sdk-backend :name "claude-sdk"))

(defmethod complete ((backend claude-sdk-backend) request)
  "Deliberately refuse to run a live Claude Agent SDK request.

Requires CLAUDE_CODE_OAUTH_TOKEN at this completion-time boundary (never
ANTHROPIC_API_KEY), then stops before any network attempt because no
captured, sanitized Claude Agent SDK request/response contract is available
yet (see issue #66)."
  (declare (ignore backend request))
  (require-claude-sdk-oauth-token)
  (claude-sdk-error
   "the claude-sdk direct transport is not implemented yet. No captured, sanitized Claude Agent SDK request/response contract is available (see issue #66); this call intentionally stops before any network attempt rather than guess an undocumented wire protocol."))
