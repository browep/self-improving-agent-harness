(in-package #:self-improving-agent-harness)

(defun select-chat-backend (&key backend)
  "Return BACKEND, or construct one from HARNESS_BACKEND / env keys.

HARNESS_BACKEND selects the provider adapter:
 - unset / \"openrouter\" (default) -> make-openrouter-backend via OPENROUTER_API_KEY
 - \"synthetic\" -> make-synthetic-backend via SYNTHETIC_API_KEY
 - \"codex\" -> make-codex-app-server-backend (ChatGPT/Codex *subscription* via
    local codex app-server; no API key)
 - \"claude\" -> make-claude-backend (local Claude Code CLI using a runtime
    CLAUDE_CODE_OAUTH_TOKEN setup-token; no Anthropic HTTP API)
 - \"claude-sdk\" -> make-claude-sdk-backend (narrow direct Claude Agent SDK
    transport seam, distinct from \"claude\"; also CLAUDE_CODE_OAUTH_TOKEN-only
    and never ANTHROPIC_API_KEY, but its direct transport is not implemented
    yet -- COMPLETE always signals a clear not-implemented error)

OpenAI Platform billing is intentionally unsupported:
  - \"openai\" is a hard error
  - there is no OPENAI_API_KEY / api.openai.com adapter or fallback

There is no automatic cross-provider fallback."
  (or backend
      (let* ((raw (or (uiop:getenv "HARNESS_BACKEND") "openrouter"))
             (name (string-downcase (string-trim '(#\Space #\Tab #\Newline #\Return) raw))))
        (cond
          ((or (string= name "") (string= name "openrouter"))
           (make-openrouter-backend :api-key (uiop:getenv "OPENROUTER_API_KEY")))
          ((string= name "synthetic")
           (make-synthetic-backend :api-key (uiop:getenv "SYNTHETIC_API_KEY")))
          ((string= name "codex")
           (make-codex-app-server-backend))
          ((string= name "claude")
           (make-claude-backend))
          ((string= name "claude-sdk")
           (make-claude-sdk-backend))
          ((string= name "openai")
           (error "HARNESS_BACKEND=openai is not supported. OpenAI Platform API-key billing is out of scope; use HARNESS_BACKEND=codex for ChatGPT/Codex subscription usage (no OPENAI_API_KEY), or openrouter for OPENROUTER_API_KEY."))
          (t
           (error "HARNESS_BACKEND must be openrouter, synthetic, codex, claude, or claude-sdk, got ~S. OpenAI Platform API-key billing is not available." raw))))))

(defun backend-api-key-configured-p (backend)
  "True when BACKEND carries a non-empty runtime API key (never the key itself).

Codex subscription backends have no API key; they authenticate via Codex-managed
ChatGPT OAuth outside the harness."
  (cond
    ((typep backend 'openrouter-backend)
     (let ((key (openrouter-backend-api-key backend)))
       (and (stringp key) (plusp (length key)))))
    (t nil)))

(defun run-harness (&key backend)
  "Prepare the harness runtime and return a non-secret readiness summary.

No model request is made here. BACKEND may be supplied directly by callers;
otherwise SELECT-CHAT-BACKEND chooses from HARNESS_BACKEND (default openrouter).
Safe as a container-runtime smoke check."
  (let ((effective-backend (select-chat-backend :backend backend)))
    (list :status :ready
          :backend (backend-name effective-backend)
          :api-key-present
          (backend-api-key-configured-p effective-backend))))
