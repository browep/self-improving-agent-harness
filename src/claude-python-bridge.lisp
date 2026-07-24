(in-package #:self-improving-agent-harness)

;;;; Python Agent SDK bridge contract (issue #81).
;;;;
;;;; Common Lisp owns the request envelope and the sole tool-definition source.
;;;; Python receives only an ephemeral MCP configuration pointing back to the
;;;; existing Lisp bridge; it never receives copied schema/handler definitions.

(defparameter +claude-python-bridge-protocol+ "claude-python/v1"
  "Stable version for the Common Lisp -> Python JSONL bridge request envelope.")

(defun claude-python-bridge-user-prompt (request)
  "Return the newest nonempty user message from REQUEST for the SDK prompt channel."
  (or (loop for message in (reverse (completion-request-messages request))
            when (and (string= "user" (or (getf message :role) ""))
                      (stringp (getf message :content))
                      (plusp (length (getf message :content))))
              do (return (getf message :content)))
      ""))

(defun claude-python-bridge-request-payload (request &key request-id session-id timeout-seconds base-url)
  "Return the credential-free `claude-python/v1` request payload for REQUEST.

The generated MCP config is connection metadata only: its stdio server is the
existing Common Lisp bridge, which supplies live schemas through `tools/list`.
No tool description, schema, handler, OAuth value, or Authorization header is
serialized here."
  (append
   (list :protocol +claude-python-bridge-protocol+
         :request-id request-id
         :model (completion-request-model request)
         :prompt (claude-python-bridge-user-prompt request)
         :mcp-config (claude-mcp-config-json))
   (when (and (stringp session-id) (plusp (length session-id)))
     (list :session-id session-id))
   (when (and (realp timeout-seconds) (plusp timeout-seconds))
     (list :timeout-seconds timeout-seconds))
   (when (and (stringp base-url) (plusp (length base-url)))
     (list :anthropic-base-url base-url))))
