(in-package #:self-improving-agent-harness/tests)

;;;; Red/green coverage for issue #81's Lisp-owned Python bridge boundary.

(defun run-claude-python-bridge-tests ()
  ;; The bridge configuration belongs to Lisp and must carry only connection
  ;; metadata—not a copied tool registry or any credential.
  (let* ((request (make-completion-request
                   :model "test/model"
                   :messages (list (list :role "user" :content "use a tool"))))
         (payload (self-improving-agent-harness::claude-python-bridge-request-payload request
                                                                                     :request-id "turn-1"))
         (mcp-config (getf payload :mcp-config)))
    (ensure-equal "claude-python/v1" (getf payload :protocol)
                  "bridge payload has an explicit protocol version")
    (ensure-equal "turn-1" (getf payload :request-id)
                  "bridge payload retains the Lisp correlation id")
    (ensure-equal "test/model" (getf payload :model)
                  "bridge payload retains the exact requested model")
    (ensure-equal (claude-mcp-config-json) mcp-config
                  "bridge receives the generated Lisp MCP configuration")
    (ensure-true (not (search "CLAUDE_CODE_OAUTH_TOKEN" (prin1-to-string payload)))
                 "bridge payload never carries OAuth credentials")
    (ensure-true (not (search "run_shell" (prin1-to-string payload)))
                 "bridge payload never duplicates Lisp tool definitions")))
