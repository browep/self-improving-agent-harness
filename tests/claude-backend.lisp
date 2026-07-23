(in-package #:self-improving-agent-harness/tests)

;;;; Deterministic, process-free, network-free tests for the Claude Code CLI
;;;; backend. The runner is injectable, so no real Claude binary/token is used.

(defun with-claude-test-token (value thunk)
  (let ((saved (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN")))
    (unwind-protect
         (progn
           (if value
               (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") value)
               (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN"))
           (funcall thunk))
      (if saved
          (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") saved)
          (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN")))))

(defun claude-test-request (&optional (content "hello"))
  (make-completion-request :model "sonnet"
                           :messages (list (list :role "user" :content content))))

(defun run-claude-backend-tests ()
  ;; Missing token fails before the runner can spawn any process and supplies
  ;; provisioning guidance without leaking credential material.
  (with-claude-test-token
   nil
   (lambda ()
     (let ((spawned nil))
       (let ((backend (make-claude-backend
                       :runner (lambda (&rest ignored)
                                 (declare (ignore ignored))
                                 (setf spawned t)
                                 (values "" "" 0)))))
         (handler-case
             (progn
               (complete backend (claude-test-request))
               (error "Test failed: missing Claude OAuth token must signal"))
           (claude-backend-error (condition)
             (let ((message (claude-backend-error-reason condition)))
               (ensure-true (search "CLAUDE_CODE_OAUTH_TOKEN" message)
                            "missing-token error names the required environment variable")
               (ensure-true (search "claude setup-token" message)
                            "missing-token error gives setup-token remediation")
               (ensure-true (not (search "test-oauth" message))
                            "missing-token error contains no secret fixture")))))
       (ensure-true (not spawned) "missing token fails before child process spawn"))))

  ;; A successful JSON result parses response fields and captures a session id.
  (with-claude-test-token
   "test-oauth-token"
   (lambda ()
     (let ((seen-argv nil)
           (seen-token nil)
           (calls 0))
       (let* ((backend (make-claude-backend
                        :runner (lambda (argv token timeout)
                                  (declare (ignore timeout))
                                  (incf calls)
                                  (setf seen-argv argv seen-token token)
                                  (if (= calls 1)
                                      (values "{\"result\":\"first response\",\"session_id\":\"claude-session-1\",\"model\":\"sonnet\",\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}" "" 0)
                                      (values "{\"result\":\"resumed response\",\"session_id\":\"claude-session-1\",\"model\":\"sonnet\"}" "" 0)))
                        :timeout 3))
              (first (complete backend (claude-test-request)))
              (second (complete backend (claude-test-request "continue"))))
         (ensure-equal "claude" (backend-name backend)
                       "Claude backend has a stable provider name")
         (ensure-equal "first response" (completion-response-text first)
                       "Claude JSON result maps to response text")
         (ensure-equal "claude-session-1" (completion-response-provider-request-id first)
                       "Claude JSON session_id maps to provider request id")
         (ensure-equal "claude-session-1" (claude-backend-session-id backend)
                       "Claude backend retains returned session id for resume")
         (ensure-equal 6 (getf (completion-response-usage first) :total-tokens)
                       "Claude authoritative input/output usage is totaled")
         (ensure-equal "resumed response" (completion-response-text second)
                       "second Claude turn parses normally")
         (ensure-true (member "--resume" seen-argv :test #'string=)
                      "subsequent Claude turn uses --resume")
         (ensure-true (member "claude-session-1" seen-argv :test #'string=)
                      "subsequent Claude turn resumes the exact returned session")
         (ensure-true (member "--output-format" seen-argv :test #'string=)
                      "Claude invocation requests structured JSON")
         (ensure-true (member "--tools" seen-argv :test #'string=)
                      "Claude invocation disables native tools")
         (ensure-true (not (member "--bare" seen-argv :test #'string=))
                      "OAuth setup-token invocation never uses incompatible bare mode")
         (ensure-true (not (member seen-token seen-argv :test #'string=))
                      "OAuth token is absent from Claude argv")
         (ensure-equal "test-oauth-token" seen-token
                       "OAuth token is passed only to the injectable child runner")))))

  ;; Child failures produce a bounded action-oriented error and never echo a
  ;; token-looking diagnostic supplied by the fake process.
  (with-claude-test-token
   "test-oauth-token"
   (lambda ()
     (let ((backend (make-claude-backend
                     :runner (lambda (&rest ignored)
                               (declare (ignore ignored))
                               (values "{\"result\":\"login needed token=test-oauth-token\"}"
                                       "authentication failed token=test-oauth-token" 17)))))
       (handler-case
           (progn (complete backend (claude-test-request))
                  (error "Test failed: nonzero Claude exit must signal"))
         (claude-backend-error (condition)
           (let ((message (claude-backend-error-reason condition)))
             (ensure-true (search "status 17" message)
                          "nonzero Claude exit reports exit status")
             (ensure-true (search "setup-token" message)
                          "authentication failure advises token replacement")
             (ensure-true (search "login needed" message)
                          "structured Claude error result is surfaced safely")
             (ensure-true (not (search "test-oauth-token" message))
                          "child diagnostic redaction removes OAuth token")))))))
  (format t "Claude CLI backend tests passed.~%")
  t)
