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
                                      (values "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"first response\",\"session_id\":\"claude-session-1\",\"model\":\"sonnet\",\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}" "" 0)
                                      (values "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"resumed response\",\"session_id\":\"claude-session-1\",\"model\":\"sonnet\"}" "" 0)))
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
         (ensure-true (member "--mcp-config" seen-argv :test #'string=)
                      "Claude invocation receives Lisp-generated MCP config")
         (ensure-true (member "--strict-mcp-config" seen-argv :test #'string=)
                      "Claude invocation ignores ambient MCP configuration")
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
  ;; MCP schemas must be a projection of the live Lisp definitions, never a
  ;; second checked-in registry that can drift.
  (let ((mcp-tools (claude-mcp-tool-specifications))
        (chat-tools (chat-tool-definitions)))
    (ensure-equal (mapcar (lambda (definition) (getf (getf definition :function) :name)) chat-tools)
                  (mapcar (lambda (tool) (gethash "name" tool)) mcp-tools)
                  "MCP tool names are projected from chat-tool-definitions")
    (ensure-equal
     (mapcar (lambda (definition)
               (with-output-to-string (stream)
                 (yason:encode (self-improving-agent-harness::openrouter-json-value (getf (getf definition :function) :parameters)) stream)))
             chat-tools)
     (mapcar (lambda (tool)
               (with-output-to-string (stream)
                 (yason:encode (gethash "inputSchema" tool) stream)))
             mcp-tools)
     "MCP input schemas are projected from chat-tool-definitions")
    (let* ((config (yason:parse (claude-mcp-config-json)))
           (server (gethash "harness" (gethash "mcpServers" config))))
      (ensure-equal "stdio" (gethash "type" server)
                    "generated MCP config declares stdio transport")
      (ensure-true (gethash "alwaysLoad" server)
                   "generated MCP server always loads for a Claude invocation")))

  ;; System content travels through Claude's real system channel and cannot be
  ;; mistaken for an injected `[system]` user-text block.
  (let* ((request (make-completion-request
                   :model "sonnet"
                   :messages (list (list :role "system" :content "SYSTEM-TEST")
                                   (list :role "user" :content "USER-TEST"))))
         (argv (claude-cli-argv request))
         (prompt (claude-request-prompt request)))
    (ensure-true (member "--append-system-prompt" argv :test #'string=)
                 "Claude receives a native system-prompt argument")
    (ensure-true (not (search "SYSTEM-TEST" prompt))
                 "system content is excluded from ordinary prompt text")
    (ensure-true (search "USER-TEST" prompt)
                 "user content remains in ordinary prompt text")
    (ensure-true (search "mcp__harness__run_shell" (claude-system-prompt request))
                 "system prompt derives exact namespaced live MCP tool names")
    (ensure-true (search "actual native MCP tool call" (claude-system-prompt request))
                 "system prompt forbids describing an unexecuted tool call"))

  ;; Native Claude MCP events are display/audit trace, not pending Harness calls.
  (let* ((stream (format nil "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu-1\",\"name\":\"mcp__harness__run_shell\",\"input\":{\"command\":\"pwd\"}}]}}~%{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu-1\",\"content\":\"/workspace\",\"is_error\":false}]}}~%{\"type\":\"result\",\"result\":\"/workspace\",\"session_id\":\"stream-session\"}"))
         (response (claude-parse-stream-response stream (claude-test-request))))
    (ensure-equal '() (completion-response-tool-calls response)
                  "already executed Claude MCP events are never pending tool calls")
    (let ((event (first (completion-response-native-tool-events response))))
      (ensure-equal "run_shell" (getf event :tool-name)
                    "namespaced MCP tool normalizes to Harness display name")
      (ensure-equal "/workspace" (getf event :result)
                    "tool result joins with its tool_use id")))

  (format t "Claude CLI backend tests passed.~%")
  t)
