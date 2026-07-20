(in-package #:self-improving-agent-harness)

;;;; Text-only `codex-app-server` backend adapter (issue #18, Phase 4).
;;;;
;;;; This adapter satisfies the `complete` generic by running ONE bounded,
;;;; read-only, tool-free turn through a Codex app-server session that is
;;;; authenticated with the ChatGPT/Codex subscription (authMode == chatgpt).
;;;;
;;;; Hard constraints (issue #18), enforced here:
;;;;   * Requires authMode == chatgpt. Missing/apiKey/other mode is a hard error;
;;;;     there is NO OPENAI_API_KEY / api.openai.com / OpenAI Platform fallback.
;;;;   * Codex-native command/filesystem tools are NOT enabled, and the harness
;;;;     run_shell tool loop is NOT wired into this session.
;;;;   * No OAuth token is read, stored, logged, or surfaced; only redacted,
;;;;     non-secret metadata is retained.
;;;;   * Accounting stays `unavailable` unless Codex reports authoritative
;;;;     numeric token/cost data (COMPLETION-RESPONSE-USAGE left without numeric
;;;;     values -> PROVIDER-ACCOUNTING-SUMMARY reports unavailable).

(defparameter *codex-turn-method* "thread/runTurn"
  "JSON-RPC method used to run one Codex turn. Doc-derived and MUST be validated
against a pinned real Codex binary before the live path is trusted; overridable
at runtime so a corrected method name needs no rebuild.")

(defparameter *codex-default-model* "gpt-5-codex"
  "Model identifier recorded when neither the request nor Codex names one. This
is a label only; the subscription/session decides the actual served model.")

(defclass codex-app-server-backend (backend)
  ((connection-factory
    :initarg :connection-factory
    :initform #'spawn-codex-app-server
    :reader codex-backend-connection-factory
    :documentation "Thunk returning a fresh CODEX-CONNECTION. Defaults to
spawning the official local app-server; tests inject a fake-server connection.")
   (turn-method
    :initarg :turn-method
    :initform *codex-turn-method*
    :reader codex-backend-turn-method))
  (:documentation "Backend that runs turns through the local Codex app-server
using the ChatGPT/Codex subscription. Opt-in only; the default harness backend
remains OpenRouter."))

(defun make-codex-app-server-backend (&key (connection-factory #'spawn-codex-app-server)
                                        (turn-method *codex-turn-method*))
  "Construct a codex-app-server backend without performing any I/O.

CONNECTION-FACTORY is a zero-argument function returning a CODEX-CONNECTION; the
default spawns the official local app-server. TURN-METHOD overrides the turn RPC
method name. No credentials are captured here."
  (make-instance 'codex-app-server-backend
                 :name "codex-app-server"
                 :connection-factory connection-factory
                 :turn-method turn-method))

(defun codex-turn-params (request)
  "Build the (tool-free, read-only) turn params for REQUEST.

Only the provider-neutral messages and a small allow-list of options are
forwarded. Tools are explicitly empty: this adapter never enables Codex-native
command/filesystem tools nor the harness run_shell loop."
  (let ((params (make-hash-table :test #'equal))
        (messages (make-array 0 :adjustable t :fill-pointer 0)))
    (dolist (message (completion-request-messages request))
      (let ((m (make-hash-table :test #'equal)))
        (setf (gethash "role" m) (or (getf message :role) "user")
              (gethash "content" m) (or (getf message :content) ""))
        (vector-push-extend m messages)))
    (setf (gethash "input" params) messages
          ;; Explicitly disable tools for the initial subscription-auth session.
          (gethash "tools" params) (make-array 0)
          (gethash "toolChoice" params) "none")
    (let ((model (completion-request-model request)))
      (when (and (stringp model) (plusp (length model)))
        (setf (gethash "model" params) model)))
    params))

(defun codex-turn-text (result)
  "Extract assistant text from a decoded turn RESULT, defaulting to empty string.

Tolerant of a few plausible shapes since the exact turn schema is doc-derived:
a top-level \"text\"/\"output\" string, or a message-like object with \"content\"."
  (or (let ((text (codex-jsonrpc-field result "text")))
        (and (stringp text) text))
      (let ((output (codex-jsonrpc-field result "output")))
        (and (stringp output) output))
      (let* ((message (codex-jsonrpc-field result "message"))
             (content (and message (codex-jsonrpc-field message "content"))))
        (and (stringp content) content))
      ""))

(defun codex-turn-usage (result)
  "Return a usage plist ONLY for authoritative numeric fields Codex reports.

If Codex does not supply numeric usage (the expected case for a subscription
session), this returns NIL, so PROVIDER-ACCOUNTING-SUMMARY reports token/cost as
`unavailable` rather than fabricating zeros."
  (let ((usage (codex-jsonrpc-field result "usage")))
    (when (hash-table-p usage)
      (let ((plist '()))
        (flet ((numeric (json-key plist-key)
                 (let ((v (codex-jsonrpc-field usage json-key)))
                   (when (realp v) (setf plist (list* plist-key v plist))))))
          (numeric "inputTokens" :prompt-tokens)
          (numeric "outputTokens" :completion-tokens)
          (numeric "totalTokens" :total-tokens)
          (numeric "costUsd" :cost-usd))
        plist))))

(defmethod complete ((backend codex-app-server-backend) request)
  "Run one bounded, tool-free turn through an authenticated Codex session.

Opens a connection via the backend's factory, performs the initialize handshake,
reads account state, REQUIRES authMode == chatgpt (hard-failing on apiKey /
missing / other with no OPENAI_API_KEY fallback), runs a single tool-free turn,
and returns a COMPLETION-RESPONSE. The connection is always closed. Only
redacted, non-secret metadata is logged; no OAuth token is read or surfaced."
  (let ((connection (funcall (codex-backend-connection-factory backend))))
    (unwind-protect
         (progn
           (codex-initialize connection)
           (multiple-value-bind (safe-state) (codex-read-account connection)
             (let ((auth-mode (codex-require-chatgpt-auth safe-state)))
               (log-interaction :info "codex-turn-started"
                                :provider (backend-name backend)
                                :auth-mode auth-mode
                                :plan (or (gethash "planType" safe-state)
                                          (gethash "plan" safe-state)
                                          "unavailable")))
             (let* ((result (codex-request connection
                                           (codex-backend-turn-method backend)
                                           (codex-turn-params request)))
                    (text (codex-turn-text result))
                    (model (or (codex-jsonrpc-field result "model")
                               (completion-request-model request)
                               *codex-default-model*))
                    (usage (codex-turn-usage result)))
               (log-interaction :info "codex-turn-completed"
                                :provider (backend-name backend)
                                :model model
                                :output-length (length text)
                                :usage-state (if usage "actual" "unavailable"))
               (make-completion-response
                :text text
                :model model
                ;; RAW is a redacted, non-secret view; never the unredacted turn.
                :raw (codex-redact result)
                :tool-calls '()
                :finish-reason (or (codex-jsonrpc-field result "finishReason")
                                   "stop")
                :provider-request-id (codex-jsonrpc-field result "id")
                :usage usage))))
      (close-codex-connection connection))))
