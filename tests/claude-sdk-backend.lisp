(in-package #:self-improving-agent-harness/tests)

;;;; Deterministic, offline tests for the `claude-sdk` direct backend seam
;;;; (issue #67). This backend never spawns a process and never opens a
;;;; network connection: COMPLETE either signals a missing/blank-token error
;;;; or a deliberate not-implemented error, both before any transport attempt.

(defun with-claude-sdk-test-env (token thunk)
  (let ((saved-token (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN"))
        (saved-anthropic (uiop:getenv "ANTHROPIC_API_KEY")))
    (unwind-protect
         (progn
           (if token
               (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") token)
               (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN"))
           (funcall thunk))
      (if saved-token
          (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") saved-token)
          (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN"))
      (if saved-anthropic
          (setf (uiop:getenv "ANTHROPIC_API_KEY") saved-anthropic)
          (sb-posix:unsetenv "ANTHROPIC_API_KEY")))))

(defun claude-sdk-test-request (&optional (content "hello"))
  (make-completion-request :model "claude-sdk-fixture-model"
                           :messages (list (list :role "user" :content content))))

(defun run-claude-sdk-backend-tests ()
  ;; Identity: a distinct class/constructor/name from the CLI `claude` backend.
  (let ((backend (make-claude-sdk-backend)))
    (ensure-equal "claude-sdk" (backend-name backend)
                  "claude-sdk backend has its own stable provider identity")
    (ensure-true (typep backend 'claude-sdk-backend)
                 "make-claude-sdk-backend returns a claude-sdk-backend")
    (ensure-true (not (typep backend 'claude-backend))
                 "claude-sdk-backend is not a claude-backend subtype"))

  ;; Missing token fails at completion time, before any transport attempt, and
  ;; never reads/accepts ANTHROPIC_API_KEY as a fallback credential.
  (with-claude-sdk-test-env
   nil
   (lambda ()
     (setf (uiop:getenv "ANTHROPIC_API_KEY") "anthropic-fixture-not-a-real-key")
     (let ((backend (make-claude-sdk-backend)))
       (handler-case
           (progn
             (complete backend (claude-sdk-test-request))
             (error "Test failed: missing CLAUDE_CODE_OAUTH_TOKEN must signal"))
         (claude-sdk-backend-error (condition)
           (let ((message (claude-sdk-backend-error-reason condition)))
             (ensure-true (search "CLAUDE_CODE_OAUTH_TOKEN" message)
                          "missing-token error names the required environment variable")
             (ensure-true (not (search "anthropic-fixture-not-a-real-key" message))
                          "missing-token error never echoes the ANTHROPIC_API_KEY fixture")))))))

  ;; A blank token is treated as absent.
  (with-claude-sdk-test-env
   "   "
   (lambda ()
     (let ((backend (make-claude-sdk-backend)))
       (handler-case
           (progn
             (complete backend (claude-sdk-test-request))
             (error "Test failed: blank CLAUDE_CODE_OAUTH_TOKEN must signal"))
         (claude-sdk-backend-error (condition)
           (ensure-true (search "CLAUDE_CODE_OAUTH_TOKEN" (claude-sdk-backend-error-reason condition))
                        "blank token is rejected like an absent token"))))))

  ;; With a token present, COMPLETE must never attempt a network call; it
  ;; deliberately signals that no direct transport/captured contract exists yet.
  (with-claude-sdk-test-env
   "claude-sdk-fixture-token"
   (lambda ()
     (let ((backend (make-claude-sdk-backend)))
       (handler-case
           (progn
             (complete backend (claude-sdk-test-request))
             (error "Test failed: claude-sdk COMPLETE must refuse to run a direct transport call"))
         (claude-sdk-backend-error (condition)
           (let ((message (claude-sdk-backend-error-reason condition)))
             (ensure-true (or (search "not implemented" message)
                              (search "not yet implemented" message))
                          "unimplemented-transport error says so plainly")
             (ensure-true (search "captured" message)
                          "unimplemented-transport error points at the missing captured contract")
             (ensure-true (not (search "claude-sdk-fixture-token" message))
                          "the OAuth token fixture never appears in a raised error message")))))))

  ;; A static guarantee stronger than any single runtime scenario above: the
  ;; backend never obtains an Anthropic API key. Documentation may name the
  ;; variable to explain the no-fallback boundary, so assert the credential
  ;; lookup rather than forbidding explanatory prose.
  (let ((source (uiop:read-file-string
                 (asdf:system-relative-pathname
                  :self-improving-agent-harness "src/claude-sdk-backend.lisp"))))
    (ensure-true (not (search "uiop:getenv \"ANTHROPIC_API_KEY\"" source))
                 "claude-sdk backend never reads ANTHROPIC_API_KEY"))

  (format t "Claude-sdk direct backend seam tests passed.~%")
  t)
