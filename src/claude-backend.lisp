(in-package #:self-improving-agent-harness)

;;;; Claude Code CLI backend (issues #49, #52-55).
;;;;
;;;; This is intentionally a Claude *binary* adapter.  It never speaks the
;;;; Anthropic HTTP API and never stores the setup-token OAuth credential.  The
;;;; only credential boundary is CLAUDE_CODE_OAUTH_TOKEN in the spawned CLI
;;;; process environment.

(defparameter *claude-command* '("claude")
  "Argv prefix for the installed Claude Code binary. Overridable for tests.")

(defparameter *claude-request-timeout-seconds* 120
  "Wall-clock limit for one non-interactive Claude Code CLI invocation.")

(defparameter *claude-default-model* "sonnet"
  "Fallback Claude model label used when a request omits a model.")

(define-condition claude-backend-error (error)
  ((reason :initarg :reason :reader claude-backend-error-reason))
  (:report (lambda (condition stream)
             (format stream "Claude backend error: ~A"
                     (claude-backend-error-reason condition)))))

(defun claude-error (format-control &rest args)
  (error 'claude-backend-error :reason (apply #'format nil format-control args)))

(defun normalized-claude-oauth-token (value)
  "Trim VALUE and remove one matching layer of .env-style surrounding quotes."
  (when (stringp value)
    (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) value)))
      (if (and (>= (length trimmed) 2)
               (member (char trimmed 0) '(#\" #\'))
               (char= (char trimmed 0) (char trimmed (1- (length trimmed)))))
          (subseq trimmed 1 (1- (length trimmed)))
          trimmed))))

(defun claude-oauth-token-present-p ()
  "True if the runtime-only Claude setup-token environment variable is nonblank."
  (let ((token (normalized-claude-oauth-token (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN"))))
    (and token (plusp (length token)))))

(defun require-claude-oauth-token ()
  "Return the runtime token without logging or retaining it on a backend object."
  (let ((token (normalized-claude-oauth-token (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN"))))
    (unless (and token (plusp (length token)))
      (claude-error
       "authentication is not configured. Generate a long-lived OAuth token with `claude setup-token` on a machine logged in to the intended Claude subscription, then provide it as CLAUDE_CODE_OAUTH_TOKEN and retry."))
    token))

(defun claude-safe-diagnostic (value &optional secret)
  "Return a bounded, credential-safe diagnostic string for child-process errors.

SECRET is the runtime token only while COMPLETE is handling a child result; it is
removed before any formatting, logging, or condition is constructed."
  (let* ((raw (princ-to-string (or value "")))
         (without-token
           (if (and (stringp secret) (plusp (length secret)))
               (let ((result raw))
                 (loop for found = (search secret result)
                       while found
                       do (setf result
                                (concatenate 'string (subseq result 0 found)
                                             "[REDACTED]"
                                             (subseq result (+ found (length secret)))))
                       finally (return result)))
               raw))
         (text (scrub-interaction-log-text without-token)))
    (if (plusp (length text))
        (subseq text 0 (min 500 (length text)))
        "no diagnostic provided")))

(defun claude-cli-error-diagnostic (stdout stderr token)
  "Extract a bounded provider diagnostic from a failed structured Claude result."
  (let ((result (ignore-errors
                  (let ((object (yason:parse stdout)))
                    (and object (claude-json-field object "result"))))))
    (claude-safe-diagnostic (or result stderr "") token)))

(defun claude-json-field (object name)
  "Read NAME from a YASON hash-table/alist object without assuming one shape."
  (etypecase object
    (hash-table (gethash name object))
    (list (cdr (assoc name object :test #'string=)))))

(defun claude-json-number (object name)
  (let ((value (claude-json-field object name)))
    (and (realp value) value)))

(defun claude-request-prompt (request)
  "Flatten harness messages into an explicit role-labelled Claude CLI prompt.

Claude Code owns its own conversation persistence; we still include the harness
history in each first/resumed request so a failed or unavailable resume never
silently loses context."
  (with-output-to-string (out)
    (dolist (message (completion-request-messages request))
      (let ((role (getf message :role))
            (content (getf message :content)))
        (when (and (stringp content) (plusp (length content)))
          (format out "[~A]~%~A~%~%" (or role "user") content))))))

(defun claude-cli-argv (request &key session-id json-schema)
  "Build safe argv for one Claude Code non-interactive invocation.

The OAuth token is deliberately absent from argv. An empty `--tools` list
disables the Claude-native tool set so this adapter cannot bypass the harness
tool loop.

Do not use `--bare`: Claude Code documents bare mode as bypassing OAuth/keychain
credential reads in favor of API-key helpers, which is incompatible with this
setup-token OAuth-only backend. A Claude CLI session id, if known, is resumed
explicitly rather than using `--continue`, which is directory-scoped and
ambiguous for durable sessions."
  (append *claude-command*
          (list "--tools" "" "-p" (claude-request-prompt request)
                "--output-format" "json"
                "--model" (or (completion-request-model request) *claude-default-model*))
          (when (and (stringp session-id) (plusp (length session-id)))
            (list "--resume" session-id))
          (when (and (stringp json-schema) (plusp (length json-schema)))
            (list "--json-schema" json-schema))))

(defun call-with-claude-timeout (timeout thunk)
  (if (and (realp timeout) (plusp timeout))
      (handler-case
          (sb-ext:with-timeout timeout (funcall thunk))
        (sb-ext:timeout ()
          (claude-error "timed out after ~A seconds waiting for the Claude CLI." timeout)))
      (funcall thunk)))

(defun claude-child-environment (token)
  "Return the minimal child environment required by the Claude native CLI.

UIOP replaces rather than merges an environment list on this SBCL build, so PATH
and HOME must accompany the runtime-only OAuth variable.  No value is logged."
  (remove nil
          (list (format nil "CLAUDE_CODE_OAUTH_TOKEN=~A" token)
                (let ((path (uiop:getenv "PATH"))) (and path (format nil "PATH=~A" path)))
                (let ((home (uiop:getenv "HOME"))) (and home (format nil "HOME=~A" home)))
                (let ((xdg (uiop:getenv "XDG_CONFIG_HOME")))
                  (and xdg (format nil "XDG_CONFIG_HOME=~A" xdg))))))

(defun run-claude-cli (argv token timeout)
  "Run ARGV once and return stdout, stderr, and exit status.

TOKEN is supplied only through the child environment. It is intentionally not
logged, stored, returned, or included in errors."
  (handler-case
      (call-with-claude-timeout
       timeout
       (lambda ()
         (multiple-value-bind (stdout stderr status)
             (uiop:run-program argv
                               :output :string
                               :error-output :string
                               :ignore-error-status t
                               :environment (claude-child-environment token))
           (values (or stdout "") (or stderr "") (or status 0)))))
    (claude-backend-error (condition) (error condition))
    (error (condition)
      (claude-error "could not launch the Claude CLI (~A). Ensure the pinned `claude` binary is installed in the runtime image."
                    (type-of condition)))))

(defun claude-parse-response (json-text request)
  "Convert Claude Code `--output-format json` output into a completion response.

Claude's JSON result carries `result`, `session_id`, optional `model`, and
optional authoritative usage/cost metadata.  The harness intentionally leaves
usage absent when values are unavailable rather than fabricating accounting."
  (handler-case
      (let* ((raw (yason:parse json-text))
             (result (claude-json-field raw "result"))
             (session-id (claude-json-field raw "session_id"))
             (model (or (claude-json-field raw "model")
                        (completion-request-model request)
                        *claude-default-model*))
             (usage-object (claude-json-field raw "usage"))
             (input (and usage-object (or (claude-json-number usage-object "input_tokens")
                                           (claude-json-number usage-object "inputTokens"))))
             (output (and usage-object (or (claude-json-number usage-object "output_tokens")
                                            (claude-json-number usage-object "outputTokens"))))
             (total (and input output (+ input output)))
             (cost (claude-json-number raw "total_cost_usd"))
             (usage (append (when input (list :prompt-tokens input))
                            (when output (list :completion-tokens output))
                            (when total (list :total-tokens total))
                            (when cost (list :cost-usd cost)))))
        (unless (stringp result)
          (claude-error "Claude CLI JSON did not contain a string result."))
        (make-completion-response
         :text result :model model :raw raw :tool-calls '() :finish-reason "stop"
         :provider-request-id (and (stringp session-id) session-id) :usage usage))
    (claude-backend-error (condition) (error condition))
    (error (condition)
      (claude-error "could not parse Claude CLI JSON output (~A)."
                    (type-of condition)))))

(defclass claude-backend (backend)
  ((runner :initarg :runner :initform #'run-claude-cli :reader claude-backend-runner)
   (session-id :initarg :session-id :initform nil :accessor claude-backend-session-id)
   (timeout :initarg :timeout :initform *claude-request-timeout-seconds*
            :reader claude-backend-timeout))
  (:documentation "Claude Code CLI-only backend. The token remains environment-only."))

(defun make-claude-backend (&key (runner #'run-claude-cli)
                              (timeout *claude-request-timeout-seconds*) session-id)
  "Construct a Claude CLI backend without reading credentials or doing I/O."
  (make-instance 'claude-backend :name "claude" :runner runner :timeout timeout
                 :session-id session-id))

(defmethod complete ((backend claude-backend) request)
  "Run one safe, tool-free Claude Code CLI turn and retain its returned session id.

Claude-native tools are deliberately disabled via an empty `--tools` list; this
adapter emits no fabricated harness tool calls. A future implementation may
enable structured stream-json mediation only after its event contract is proven
sufficient."
  (let* ((token (require-claude-oauth-token))
         (argv (claude-cli-argv request :session-id (claude-backend-session-id backend)))
         (runner (claude-backend-runner backend)))
    (multiple-value-bind (stdout stderr status)
        (funcall runner argv token (claude-backend-timeout backend))
      (unless (and (integerp status) (zerop status))
        (claude-error "Claude CLI exited with status ~A: ~A. Verify CLAUDE_CODE_OAUTH_TOKEN was generated with `claude setup-token` and replace it if authentication failed."
                      status (claude-cli-error-diagnostic stdout stderr token)))
      (let ((response (claude-parse-response stdout request)))
        (setf (claude-backend-session-id backend)
              (completion-response-provider-request-id response))
        (log-interaction :info "claude-turn-completed"
                         :provider "claude"
                         :model (completion-response-model response)
                         :session-id (or (claude-backend-session-id backend) "unavailable")
                         :output-length (length (completion-response-text response))
                         :usage-state (if (completion-response-usage response) "reported" "unavailable"))
        response))))

(defparameter *claude-verify-prompt* "Reply with the single word: verified."
  "Minimal billable prompt used only by the explicit live Claude verification.")

(defun claude-verification-evidence (&key status claude-version model session-id outcome reason)
  "Return sanitized, non-secret evidence for the opt-in live smoke."
  (list :status status :claude-version (or claude-version "unavailable")
        :model (or model "unavailable") :session-id (or session-id "unavailable")
        :turn-outcome (or outcome "unavailable")
        :input-tokens "unavailable" :output-tokens "unavailable" :cost-usd "unavailable"
        :reason (and reason (claude-safe-diagnostic reason))))

(defun verify-claude-oauth (&key (runner #'run-claude-cli) claude-version)
  "Run two real or injected Claude CLI turns, proving session capture and resume.

This is opt-in at the shell wrapper. It never prints OAuth material."
  (handler-case
      (let* ((backend (make-claude-backend :runner runner))
             (first (complete backend (make-completion-request
                                       :model *claude-default-model*
                                       :messages (list (list :role "user" :content *claude-verify-prompt*)))))
             (session-id (claude-backend-session-id backend))
             (second (complete backend (make-completion-request
                                        :model *claude-default-model*
                                        :messages (list (list :role "user" :content "Reply with the single word: resumed."))))))
        (values (claude-verification-evidence
                 :status "ok" :claude-version claude-version
                 :model (completion-response-model second) :session-id session-id
                 :outcome (if (and (plusp (length (completion-response-text first)))
                                   (plusp (length (completion-response-text second))))
                              "completed-and-resumed" "empty"))
                t))
    (claude-backend-error (condition)
      (values (claude-verification-evidence :status "failed" :claude-version claude-version
                                            :reason (claude-backend-error-reason condition)) nil))
    (error (condition)
      (values (claude-verification-evidence :status "failed" :claude-version claude-version
                                            :reason (type-of condition)) nil))))

(defun format-claude-verification-evidence (evidence stream)
  (loop for (key value) on evidence by #'cddr
        do (format stream "CLAUDE_VERIFY ~A=~A~%" (string-downcase (symbol-name key))
                   (or value "unavailable")))
  (finish-output stream))
