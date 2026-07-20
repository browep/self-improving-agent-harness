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

(defparameter *codex-turn-method* "turn/start"
  "JSON-RPC method used to start one Codex turn, per the pinned app-server
protocol schema (@openai/codex 0.144.6). A turn is thread/start + turn/start,
with assistant text streamed via item/agentMessage/delta and finalized by a
turn/completed notification (see codex-run-turn). Overridable at runtime.")

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

(defun codex-request-text (request)
  "Flatten REQUEST messages into a single prompt string for a text turn.

The Codex turn/start input is a list of text UserInput items; this adapter sends
one text item built from the request's message contents in order."
  (with-output-to-string (out)
    (loop for message in (completion-request-messages request)
          for content = (getf message :content)
          when (and (stringp content) (plusp (length content)))
            do (write-string content out)
               (write-char #\Newline out))))

(defmethod complete ((backend codex-app-server-backend) request)
  "Run one bounded, read-only, tool-free turn through an authenticated Codex session.

Opens a connection via the backend's factory, performs the initialize handshake,
reads account state, REQUIRES chatgpt auth (hard-failing on apiKey / missing /
other with no OPENAI_API_KEY fallback), runs a single read-only turn
(thread/start + turn/start, tools/approvals disabled), and returns a
COMPLETION-RESPONSE. The connection is always closed. Only redacted, non-secret
metadata is logged; no OAuth token is read or surfaced. Accounting stays
unavailable: a subscription turn does not report authoritative token/cost here."
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
             (multiple-value-bind (text completed-params)
                 (codex-run-turn connection (codex-request-text request)
                                 :turn-method (codex-backend-turn-method backend))
               (let ((model (or (completion-request-model request)
                                *codex-default-model*)))
                 (log-interaction :info "codex-turn-completed"
                                  :provider (backend-name backend)
                                  :model model
                                  :output-length (length text)
                                  :usage-state "unavailable")
                 (make-completion-response
                  :text text
                  :model model
                  ;; RAW is the redacted turn/completed params; never unredacted.
                  :raw completed-params
                  :tool-calls '()
                  :finish-reason "stop"
                  :provider-request-id nil
                  ;; No authoritative usage from a subscription turn -> unavailable.
                  :usage nil)))))
      (close-codex-connection connection))))

;;; ---------------------------------------------------------------------------
;;; Post-OAuth verification entry point (issue #18, Phase 5).
;;;
;;; VERIFY-CODEX-CHATGPT-AUTH is the acceptance-proof routine invoked by
;;; bin/verify-codex-chatgpt-auth AFTER a human completes Codex-managed ChatGPT
;;; login. It is explicitly opt-in and is never called from make test. It emits
;;; and returns ONLY sanitized evidence; OAuth credentials, device codes,
;;; prompts, raw provider events, and tool output are never surfaced.
;;; ---------------------------------------------------------------------------

(defparameter *codex-verify-prompt*
  "Reply with the single word: verified."
  "Bounded, tool-free prompt for the minimal live proof turn. Its content is
never emitted or persisted; only the turn outcome/model is recorded.")

(defun codex-verification-evidence (&key status auth-mode model plan outcome reason
                                      codex-version)
  "Assemble a sanitized evidence plist. Every value here is non-secret."
  (list :status status
        :codex-version (or codex-version "unavailable")
        :auth-mode (or auth-mode "unavailable")
        :plan (or plan "unavailable")
        :model (or model "unavailable")
        :turn-outcome (or outcome "unavailable")
        ;; Cost/token stay unavailable unless Codex reports them authoritatively;
        ;; the verify turn does not attempt to aggregate them.
        :input-tokens "unavailable"
        :output-tokens "unavailable"
        :cost-usd "unavailable"
        :reason (and reason (scrub-interaction-log-text (princ-to-string reason)))))

(defun verify-codex-chatgpt-auth (&key (connection-factory #'spawn-codex-app-server)
                                    (turn-method *codex-turn-method*)
                                    codex-version)
  "Prove the ChatGPT/Codex subscription session is usable, returning evidence.

Returns two values: a sanitized evidence plist and a boolean success flag.
Success requires BOTH (a) account/read reporting authMode == chatgpt and (b) one
bounded, tool-free turn completing. apiKey/missing/other auth, or a failed turn,
is a failure with a redacted, actionable reason. There is no OPENAI_API_KEY
fallback. Never emits or persists OAuth material."
  (let ((connection (funcall connection-factory)))
    (unwind-protect
         (handler-case
             (progn
               (codex-initialize connection)
               (multiple-value-bind (safe-state) (codex-read-account connection)
                 (let ((auth-mode (codex-require-chatgpt-auth safe-state))
                       (plan (or (gethash "planType" safe-state)
                                 (gethash "plan" safe-state))))
                   ;; A completed login notification alone is insufficient; run a
                   ;; real turn to prove the session is usable.
                   (multiple-value-bind (text completed-params)
                       (codex-run-turn connection *codex-verify-prompt*
                                       :turn-method turn-method)
                     (declare (ignore completed-params))
                     (values
                      (codex-verification-evidence
                       :status "ok" :auth-mode auth-mode :model *codex-default-model*
                       :plan plan
                       :codex-version codex-version
                       :outcome (if (plusp (length text)) "completed" "empty"))
                      t)))))
           (codex-app-server-error (condition)
             (values
              (codex-verification-evidence
               :status "failed" :codex-version codex-version
               :reason (codex-app-server-error-reason condition))
              nil))
           (error (condition)
             (values
              (codex-verification-evidence
               :status "failed" :codex-version codex-version
               :reason (format nil "runtime/protocol failure: ~A" (type-of condition)))
              nil)))
      (close-codex-connection connection))))

(defun format-codex-verification-evidence (evidence stream)
  "Print sanitized EVIDENCE as stable key=value lines to STREAM."
  (loop for (key value) on evidence by #'cddr
        do (format stream "CODEX_VERIFY ~A=~A~%"
                   (string-downcase (symbol-name key))
                   (if value value "unavailable")))
  (finish-output stream))
