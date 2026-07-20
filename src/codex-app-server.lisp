(in-package #:self-improving-agent-harness)

;;;; Narrowly scoped Codex app-server process supervisor + JSON-RPC client
;;;; (issue #18, Phase 2).
;;;;
;;;; Design: the CONNECTION (a bidirectional input/output stream pair plus an
;;;; optional process handle) is injectable. Deterministic tests build a
;;;; connection over in-memory streams and a fake server; production spawns a
;;;; pinned `codex app-server` child via uiop:launch-program. Nothing in the
;;;; JSON-RPC client logic depends on a real process or the network, so the
;;;; protocol paths are exercised with networking disabled.
;;;;
;;;; Scope guardrails (issue #18): this supervisor only performs app-server
;;;; lifecycle, the initialize handshake, account state reads, and managed login
;;;; orchestration. It never enables Codex-native command/filesystem tools and
;;;; never extracts, stores, or logs OAuth tokens.

(defparameter *codex-app-server-command* '("codex" "app-server")
  "Argv used to launch the official local Codex app-server. Overridable at
runtime (reload_harness picks up new values) so a pinned binary path can be
substituted without a rebuild. Never contains credentials.")

(defparameter *codex-request-timeout-seconds* 60
  "Wall-clock seconds to wait for a single framed JSON-RPC message from the
app-server before signalling a CODEX-APP-SERVER-ERROR. Enforced in CODEX-RECEIVE
so a hung or protocol-mismatched app-server never blocks the harness forever
(a real hang seen when the live app-server did not speak the expected framing).
NIL disables the per-read timeout; bound at runtime to tune, reload_harness
picks up new values.")

(define-condition codex-app-server-error (error)
  ((reason :initarg :reason :reader codex-app-server-error-reason))
  (:report (lambda (condition stream)
             (format stream "Codex app-server error: ~A"
                     (codex-app-server-error-reason condition))))
  (:documentation "Signalled for Codex app-server protocol/lifecycle failures.
REASON is a redacted, human-readable string safe for logs and tickets."))

(defun codex-error (format-control &rest args)
  (error 'codex-app-server-error
         :reason (apply #'format nil format-control args)))

;;; ---------------------------------------------------------------------------
;;; Connection: an injectable transport around the app-server's stdio.
;;; ---------------------------------------------------------------------------

(defstruct (codex-connection
            (:constructor %make-codex-connection))
  "A live JSON-RPC transport to a Codex app-server.

INPUT is the stream the harness reads server->client messages from; OUTPUT is
the stream the harness writes client->server messages to. PROCESS, when present,
is the uiop process-info for a spawned child so it can be reaped. NEXT-ID is the
monotonically increasing request id counter."
  input
  output
  process
  (next-id 0 :type integer))

(defun make-codex-connection-from-streams (input output &optional process)
  "Build a CODEX-CONNECTION over explicit INPUT/OUTPUT streams.

This is the seam deterministic tests use: they pass in-memory streams driven by
a fake server. PROCESS is optional and only set for spawned children."
  (%make-codex-connection :input input :output output :process process))

(defun codex-next-request-id (connection)
  "Return the next monotonically increasing request id for CONNECTION."
  (incf (codex-connection-next-id connection)))

(defun codex-send (connection object)
  "Frame and write OBJECT to CONNECTION's output stream, then flush."
  (let ((output (codex-connection-output connection)))
    (write-string (codex-encode-jsonrpc-message object) output)
    (finish-output output)))

(defun call-with-codex-timeout (timeout-seconds thunk)
  "Run THUNK, aborting with a CODEX-APP-SERVER-ERROR after TIMEOUT-SECONDS.

A NIL or non-positive timeout runs THUNK with no bound. The timeout guards the
single blocking point (reading a framed message) so a hung or mismatched
app-server surfaces a diagnosable error instead of hanging the process."
  (cond
    ((and (realp timeout-seconds) (plusp timeout-seconds))
     (handler-case
         (sb-ext:with-timeout timeout-seconds
           (funcall thunk))
       (sb-ext:timeout ()
         (codex-error "timed out after ~A seconds waiting for an app-server message; the app-server may not speak the expected stdio JSON-RPC framing."
                      timeout-seconds))))
    (t (funcall thunk))))

(defun codex-receive (connection)
  "Read one framed JSON-RPC message from CONNECTION, or :EOF at end of stream.

The blocking read is bounded by *CODEX-REQUEST-TIMEOUT-SECONDS* so a
non-responsive or protocol-mismatched app-server cannot hang the harness."
  (call-with-codex-timeout *codex-request-timeout-seconds*
                           (lambda ()
                             (codex-read-jsonrpc-message
                              (codex-connection-input connection)))))

(defun codex-jsonrpc-error-field (message)
  "Return the JSON-RPC error object from a decoded response MESSAGE, or NIL."
  (codex-jsonrpc-field message "error"))

(defun redacted-codex-error-summary (rpc-error)
  "Return a redacted one-line summary of a JSON-RPC error object.

Only the numeric code and message are surfaced, and the message is scrubbed, so
no token-shaped material from a server error can reach logs or tickets."
  (let* ((redacted (codex-redact rpc-error))
         (code (codex-jsonrpc-field redacted "code"))
         (message (codex-jsonrpc-field redacted "message")))
    (format nil "code=~A message=~A"
            (if code code "unknown")
            (if (stringp message) (scrub-interaction-log-text message) "unavailable"))))

(defun codex-request (connection method &optional params)
  "Send a METHOD request with PARAMS and return the matching response result.

Interleaved server notifications received while waiting are collected and
returned as the secondary value so callers (e.g. login flows) can observe them.
Signals CODEX-APP-SERVER-ERROR on a JSON-RPC error object, a protocol mismatch,
or a premature end of stream. All error text is redacted before it is raised."
  (let* ((id (codex-next-request-id connection))
         (request (codex-jsonrpc-request id method params))
         (notifications '()))
    (codex-send connection request)
    (loop
      (let ((message (codex-receive connection)))
        (when (eq message :eof)
          (codex-error "app-server closed the connection while awaiting ~A." method))
        (cond
          ((codex-jsonrpc-notification-p message)
           (push message notifications))
          ((eql (codex-jsonrpc-field message "id") id)
           (let ((rpc-error (codex-jsonrpc-error-field message)))
             (when rpc-error
               (codex-error "~A failed: ~A" method
                            (redacted-codex-error-summary rpc-error)))
             (return (values (codex-jsonrpc-field message "result")
                             (nreverse notifications)))))
          (t
           ;; A response to some other id (should not happen in the strictly
           ;; sequential flows here); ignore rather than deadlock.
           nil))))))


;;; ---------------------------------------------------------------------------
;;; Handshake + account state (no secrets retained).
;;; ---------------------------------------------------------------------------

(defparameter *codex-client-info*
  '(("name" . "self-improving-agent-harness")
    ("version" . "0"))
  "Non-secret client identity sent in the initialize handshake.")

(defun codex-initialize (connection)
  "Perform the app-server initialize handshake. Returns the server result."
  (let ((params (let ((p (make-hash-table :test #'equal)))
                  (setf (gethash "clientInfo" p)
                        (let ((ci (make-hash-table :test #'equal)))
                          (loop for (k . v) in *codex-client-info*
                                do (setf (gethash k ci) v))
                          ci))
                  p)))
    (codex-request connection "initialize" params)))

(defparameter *codex-safe-account-keys*
  '("type" "planType" "plan" "accountId" "requiresOpenaiAuth"
    "rateLimit" "rateLimits" "capabilities" "model" "modelId")
  "Allow-list of non-secret account keys the harness may retain as evidence.
Validated against the pinned Codex app-server protocol schema (v0.144.6): the
account object's auth discriminator is `type` (chatgpt|apiKey|...), not a
top-level authMode. `email` is intentionally excluded (PII). Secret-shaped keys
are additionally redacted by CODEX-REDACT before this filter runs.")

(defun codex-account-safe-state (account)
  "Return an allow-listed, redacted, non-secret view of a decoded account object.

CODEX-REDACT first removes token-shaped fields recursively; then only keys on
*CODEX-SAFE-ACCOUNT-KEYS* are kept. The result is safe to log or persist as
evidence and never contains OAuth material."
  (let ((redacted (codex-redact account))
        (out (make-hash-table :test #'equal)))
    (when (hash-table-p redacted)
      (dolist (key *codex-safe-account-keys*)
        (multiple-value-bind (value present) (gethash key redacted)
          (when present
            (setf (gethash key out) value)))))
    out))

(defun codex-account-auth-mode (account-or-state)
  "Return the auth-mode string from a safe-state object.

Per the pinned protocol schema the account object's discriminator is `type`
(e.g. \"chatgpt\" or \"apiKey\")."
  (when (hash-table-p account-or-state)
    (gethash "type" account-or-state)))

(defun codex-response-account (response)
  "Return the inner `account` object from an account/read RESPONSE.

Per the pinned protocol schema, account/read returns
{ requiresOpenaiAuth, account: {...} }; a signed-out server may return a null
account. Returns an empty object rather than NIL so downstream reads are safe."
  (let ((account (and (hash-table-p response) (codex-jsonrpc-field response "account"))))
    (if (hash-table-p account) account (make-hash-table :test #'equal))))

(defun codex-read-account (connection)
  "Call account/read and return two values: the safe (allow-listed) account
state and the raw decoded account/read response. The raw response is for
internal inspection only and must be redacted before any external surfacing."
  (let* ((response (codex-request connection "account/read"))
         (account (codex-response-account response)))
    (values (codex-account-safe-state account) response)))

(defparameter *codex-authenticated-mode* "chatgpt"
  "The only authMode this workstream accepts. Per issue #18, apiKey or any other
mode is a rejection, never a fallback to OPENAI_API_KEY / OpenAI Platform.")

(defun codex-require-chatgpt-auth (safe-state)
  "Signal unless SAFE-STATE reports authMode == chatgpt.

This is the hard rejection required by issue #18: missing auth, apiKey auth, or
any other mode fails; there is deliberately no OPENAI_API_KEY fallback path."
  (let ((mode (codex-account-auth-mode safe-state)))
    (cond
      ((null mode)
       (codex-error "no Codex ChatGPT session; run the managed login first (authMode is unset)."))
      ((string= mode *codex-authenticated-mode*) mode)
      (t
       (codex-error "unacceptable authMode ~S; issue #18 requires ChatGPT subscription auth and forbids an OPENAI_API_KEY fallback."
                    mode)))))

;;; ---------------------------------------------------------------------------
;;; Managed login (device-code / browser), no token storage.
;;; ---------------------------------------------------------------------------

(defun codex-login-start (connection type)
  "Start a managed login of TYPE (\"chatgpt\" or \"chatgptDeviceCode\").

Returns the redacted, non-secret login-start result (e.g. verification URL and
user code for the device-code flow). Any token-shaped field is stripped by
CODEX-REDACT so the harness only ever surfaces Codex-provided instructions."
  (unless (member type '("chatgpt" "chatgptDeviceCode") :test #'string=)
    (codex-error "unsupported login type ~S." type))
  (let ((params (let ((p (make-hash-table :test #'equal)))
                  (setf (gethash "type" p) type) p)))
    (codex-redact (codex-request connection "account/login/start" params))))

(defparameter *codex-login-wait-seconds* 300
  "Maximum wall-clock seconds to wait for account/login/completed.")

(defun codex-login-completed-p (notification)
  "True when NOTIFICATION is the account/login/completed method notification."
  (and (codex-jsonrpc-notification-p notification)
       (equal "account/login/completed"
              (codex-jsonrpc-field notification "method"))))

(defun codex-wait-for-login (connection)
  "Block reading notifications until account/login/completed arrives.

Returns the redacted completion params. Signals on end of stream. Only
non-secret completion metadata is returned; tokens never leave Codex."
  (loop
    (let ((message (codex-receive connection)))
      (when (eq message :eof)
        (codex-error "app-server closed the connection before login completed."))
      (when (codex-login-completed-p message)
        (return (codex-redact (codex-jsonrpc-field message "params")))))))

(defun codex-thread-start (connection)
  "Start a Codex thread and return its thread id string.

Per the pinned protocol schema, thread/start returns { thread: { id, ... }, ... }."
  (let* ((result (codex-request connection "thread/start"))
         (thread (codex-jsonrpc-field result "thread"))
         (id (and (hash-table-p thread) (codex-jsonrpc-field thread "id"))))
    (unless (stringp id)
      (codex-error "thread/start did not return a thread id."))
    id))

(defun codex-turn-start-params (thread-id text)
  "Build read-only, no-approval turn/start params for a single text message.

Keeps the turn tool-free and read-only: approvalPolicy=never means no approval
round trips, and sandboxPolicy=readOnly forbids writes. This is the initial,
harness-boundary-preserving posture required by issue #18."
  (let ((params (make-hash-table :test #'equal))
        (input (make-array 1))
        (message (make-hash-table :test #'equal))
        (sandbox (make-hash-table :test #'equal)))
    (setf (gethash "type" message) "text"
          (gethash "text" message) text
          (aref input 0) message
          (gethash "type" sandbox) "readOnly"
          (gethash "threadId" params) thread-id
          (gethash "input" params) input
          (gethash "approvalPolicy" params) "never"
          (gethash "sandboxPolicy" params) sandbox)
    params))

(defparameter *codex-turn-notification-limit* 10000
  "Safety bound on notifications consumed while awaiting turn/completed, so a
misbehaving server cannot spin this loop forever.")

(defun codex-collect-turn (connection request-id)
  "After a turn/start request (REQUEST-ID), read notifications until the turn
completes, accumulating assistant text deltas.

Returns two values: the accumulated assistant text and the redacted decoded
turn/completed params. The turn/start response itself is consumed first.
Signals on a failed turn or premature end of stream."
  ;; Consume the turn/start response (its result carries the initial Turn).
  (loop
    (let ((message (codex-receive connection)))
      (when (eq message :eof)
        (codex-error "app-server closed the connection during turn/start."))
      (cond
        ((codex-jsonrpc-notification-p message) nil) ; ignore pre-response notes
        ((eql (codex-jsonrpc-field message "id") request-id)
         (let ((rpc-error (codex-jsonrpc-error-field message)))
           (when rpc-error
             (codex-error "turn/start failed: ~A"
                          (redacted-codex-error-summary rpc-error))))
         (return))
        (t nil))))
  ;; Then read notifications, accumulating deltas until turn/completed.
  (let ((text (make-string-output-stream))
        (count 0))
    (loop
      (when (> (incf count) *codex-turn-notification-limit*)
        (codex-error "turn did not complete within the notification bound."))
      (let ((message (codex-receive connection)))
        (when (eq message :eof)
          (codex-error "app-server closed the connection before turn/completed."))
        (when (codex-jsonrpc-notification-p message)
          (let ((method (codex-jsonrpc-field message "method"))
                (params (codex-jsonrpc-field message "params")))
            (cond
              ((equal method "item/agentMessage/delta")
               (let ((delta (and params (codex-jsonrpc-field params "delta"))))
                 (when (stringp delta) (write-string delta text))))
              ((equal method "turn/completed")
               (let* ((turn (and params (codex-jsonrpc-field params "turn")))
                      (status (and (hash-table-p turn)
                                   (codex-jsonrpc-field turn "status"))))
                 (when (equal status "failed")
                   (codex-error "turn completed with failed status."))
                 (return (values (get-output-stream-string text)
                                 (codex-redact params))))))))))))

(defun codex-run-turn (connection text &key (turn-method "turn/start"))
  "Run one bounded, read-only, tool-free turn for TEXT.

Starts a thread, sends a read-only turn/start, and collects assistant text until
turn/completed. Returns two values: the assistant text and the redacted
turn/completed params. TURN-METHOD is overridable for forward compatibility."
  (let* ((thread-id (codex-thread-start connection))
         (params (codex-turn-start-params thread-id text))
         (request-id (codex-next-request-id connection))
         (request (codex-jsonrpc-request request-id turn-method params)))
    (codex-send connection request)
    (codex-collect-turn connection request-id)))

;;; ---------------------------------------------------------------------------
;;; Process lifecycle (production path; not exercised by deterministic tests).
;;; ---------------------------------------------------------------------------

(defun spawn-codex-app-server (&optional (command *codex-app-server-command*))
  "Launch the official local Codex app-server and return a CODEX-CONNECTION.

Uses uiop:launch-program with piped stdio. The child's stderr is discarded here
(diagnostics are surfaced through redacted protocol errors) to avoid capturing
anything unredacted. This is the production seam; tests use
MAKE-CODEX-CONNECTION-FROM-STREAMS with a fake server instead."
  (let ((process (uiop:launch-program command
                                      :input :stream
                                      :output :stream
                                      :error-output nil)))
    (make-codex-connection-from-streams
     (uiop:process-info-output process)
     (uiop:process-info-input process)
     process)))

(defun close-codex-connection (connection)
  "Close CONNECTION's streams and terminate/reap any spawned child process."
  (ignore-errors (close (codex-connection-output connection)))
  (ignore-errors (close (codex-connection-input connection)))
  (let ((process (codex-connection-process connection)))
    (when process
      (ignore-errors (uiop:terminate-process process))
      (ignore-errors (uiop:wait-process process))))
  (values))

(defmacro with-codex-app-server ((connection &key command) &body body)
  "Spawn a Codex app-server, bind CONNECTION, and guarantee cleanup."
  (let ((cmd (or command '*codex-app-server-command*)))
    `(let ((,connection (spawn-codex-app-server ,cmd)))
       (unwind-protect (progn ,@body)
         (close-codex-connection ,connection)))))
