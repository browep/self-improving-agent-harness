(in-package #:self-improving-agent-harness)

(defun select-chat-backend (&key backend)
  "Return BACKEND, or construct one from HARNESS_BACKEND / env keys.

HARNESS_BACKEND selects the provider adapter:
  - unset / \"openrouter\" (default) -> make-openrouter-backend via OPENROUTER_API_KEY
  - \"codex\" -> make-codex-app-server-backend (ChatGPT/Codex *subscription* via
    local codex app-server; no API key)

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
          ((string= name "codex")
           (make-codex-app-server-backend))
          ((string= name "openai")
           (error "HARNESS_BACKEND=openai is not supported. OpenAI Platform API-key billing is out of scope; use HARNESS_BACKEND=codex for ChatGPT/Codex subscription usage (no OPENAI_API_KEY), or openrouter for OPENROUTER_API_KEY."))
          (t
           (error "HARNESS_BACKEND must be openrouter or codex, got ~S. OpenAI Platform API-key billing is not available." raw))))))

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
