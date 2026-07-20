(in-package #:self-improving-agent-harness/tests)

;;;; Deterministic, network-free, process-free tests for the Codex app-server
;;;; supervisor + JSON-RPC client (issue #18, Phase 2).
;;;;
;;;; The connection transport is injectable: we drive the client over an INPUT
;;;; string stream pre-seeded with the fake server's framed responses (in the
;;;; order the strictly-sequential client will consume them) and capture the
;;;; client's writes in an OUTPUT string stream. No child process, no network.

(defun cas-sym (name)
  (find-symbol (string name) '#:self-improving-agent-harness))

(defun cas-frame (object)
  "Frame a yason-ready OBJECT the way the server would."
  (funcall (cas-sym '#:codex-encode-jsonrpc-message) object))

(defun cas-obj (&rest kv)
  "Build a JSON-object hash table from alternating key/value args."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun cas-response (id result)
  (cas-obj "jsonrpc" "2.0" "id" id "result" result))

(defun cas-error-response (id code message)
  (cas-obj "jsonrpc" "2.0" "id" id "error" (cas-obj "code" code "message" message)))

(defun cas-notification (method params)
  (cas-obj "jsonrpc" "2.0" "method" method "params" params))

(defun cas-connection (server-frames)
  "Return a CODEX-CONNECTION whose input is SERVER-FRAMES (a list of framed
strings, concatenated) and whose output is a capturing string stream. Returns
two values: the connection and the output stream."
  (let* ((input (make-string-input-stream (apply #'concatenate 'string server-frames)))
         (output (make-string-output-stream))
         (conn (self-improving-agent-harness:make-codex-connection-from-streams
                input output)))
    (values conn output)))

(defun cas-sent-messages (output-stream)
  "Decode every framed message the client wrote to OUTPUT-STREAM."
  (let ((text (get-output-stream-string output-stream))
        (messages '()))
    (with-input-from-string (in text)
      (loop for msg = (self-improving-agent-harness:codex-read-jsonrpc-message in)
            until (eq msg :eof)
            do (push msg messages)))
    (nreverse messages)))

(defun run-codex-request-and-error-tests ()
  ;; A single request/response round-trip. Client's first id is 1.
  (multiple-value-bind (conn out)
      (cas-connection (list (cas-frame (cas-response 1 (cas-obj "ok" t)))))
    (let ((result (self-improving-agent-harness:codex-request conn "initialize")))
      (ensure-true (hash-table-p result) "codex-request returns the result object")
      (ensure-true (eq t (gethash "ok" result)) "result payload is delivered"))
    (let ((sent (cas-sent-messages out)))
      (ensure-true (= 1 (length sent)) "exactly one request was sent")
      (ensure-true (equal "initialize"
                          (self-improving-agent-harness:codex-jsonrpc-field
                           (first sent) "method"))
                   "the sent request carries the requested method")
      (ensure-true (eql 1 (self-improving-agent-harness:codex-jsonrpc-field
                           (first sent) "id"))
                   "the sent request id starts at 1")))
  ;; Interleaved notifications before the matching response are tolerated and
  ;; returned as the secondary value.
  (multiple-value-bind (conn out)
      (cas-connection (list (cas-frame (cas-notification "server/progress" (cas-obj "n" 1)))
                            (cas-frame (cas-response 1 (cas-obj "ok" t)))))
    (declare (ignore out))
    (multiple-value-bind (result notes)
        (self-improving-agent-harness:codex-request conn "initialize")
      (ensure-true (eq t (gethash "ok" result)) "response after a notification still resolves")
      (ensure-true (= 1 (length notes)) "the interleaved notification is collected")))
  ;; A JSON-RPC error object becomes a redacted codex-app-server-error.
  (multiple-value-bind (conn out)
      (cas-connection (list (cas-frame (cas-error-response 1 -32001 "boom"))))
    (declare (ignore out))
    (handler-case
        (progn (self-improving-agent-harness:codex-request conn "initialize")
               (error "Test failed: a JSON-RPC error must signal"))
      (self-improving-agent-harness:codex-app-server-error (condition)
        (let ((reason (self-improving-agent-harness:codex-app-server-error-reason condition)))
          (ensure-true (search "initialize" reason) "error names the failing method")
          (ensure-true (search "boom" reason) "error surfaces the redacted message")))))
  ;; Premature end of stream signals rather than hangs.
  (multiple-value-bind (conn out) (cas-connection '())
    (declare (ignore out))
    (handler-case
        (progn (self-improving-agent-harness:codex-request conn "initialize")
               (error "Test failed: EOF before a response must signal"))
      (self-improving-agent-harness:codex-app-server-error () t))))

(defun run-codex-account-and-auth-tests ()
  ;; account/read: safe state keeps allow-listed keys and drops/redacts secrets.
  (let ((account (cas-obj "authMode" "chatgpt"
                          "planType" "plus"
                          "access_token" "sk-secret-should-not-survive"
                          "internalDebug" "drop-me")))
    (multiple-value-bind (conn out)
        (cas-connection (list (cas-frame (cas-response 1 account))))
      (declare (ignore out))
      (multiple-value-bind (safe raw)
          (self-improving-agent-harness:codex-read-account conn)
        (ensure-true (equal "chatgpt" (gethash "authMode" safe))
                     "safe account state keeps authMode")
        (ensure-true (equal "plus" (gethash "planType" safe))
                     "safe account state keeps planType")
        (ensure-true (not (nth-value 1 (gethash "access_token" safe)))
                     "safe account state drops the token key entirely")
        (ensure-true (not (nth-value 1 (gethash "internalDebug" safe)))
                     "safe account state drops non-allow-listed keys")
        ;; raw is returned for internal use but must not be surfaced unredacted.
        (ensure-true (hash-table-p raw) "raw account object is returned for internal use")
        (let ((flat (with-output-to-string (s) (yason:encode safe s))))
          (ensure-true (not (search "should-not-survive" flat))
                       "serialized safe state contains no token value")))))
  ;; require-chatgpt-auth: accepts chatgpt, rejects apiKey and missing.
  (let ((chatgpt (self-improving-agent-harness:codex-account-safe-state
                  (cas-obj "authMode" "chatgpt"))))
    (ensure-true (equal "chatgpt"
                        (self-improving-agent-harness:codex-require-chatgpt-auth chatgpt))
                 "chatgpt auth mode is accepted"))
  (let ((apikey (self-improving-agent-harness:codex-account-safe-state
                 (cas-obj "authMode" "apiKey"))))
    (handler-case
        (progn (self-improving-agent-harness:codex-require-chatgpt-auth apikey)
               (error "Test failed: apiKey auth must be rejected"))
      (self-improving-agent-harness:codex-app-server-error (condition)
        (let ((reason (self-improving-agent-harness:codex-app-server-error-reason condition)))
          (ensure-true (search "OPENAI_API_KEY" reason)
                       "apiKey rejection explicitly forbids the OPENAI_API_KEY fallback")))))
  (let ((none (self-improving-agent-harness:codex-account-safe-state (cas-obj))))
    (handler-case
        (progn (self-improving-agent-harness:codex-require-chatgpt-auth none)
               (error "Test failed: missing auth must be rejected"))
      (self-improving-agent-harness:codex-app-server-error () t))))

(defun run-codex-login-tests ()
  ;; login/start: returns Codex-provided verification info, redacts secrets.
  (let ((start-result (cas-obj "verificationUri" "https://example/device"
                               "userCode" "ABCD-1234"
                               "deviceCode" "secretdevicecode-should-not-survive")))
    (multiple-value-bind (conn out)
        (cas-connection (list (cas-frame (cas-response 1 start-result))))
      (declare (ignore out))
      (let ((info (self-improving-agent-harness:codex-login-start conn "chatgptDeviceCode")))
        (ensure-true (equal "https://example/device" (gethash "verificationUri" info))
                     "login start surfaces the verification URI")
        (ensure-true (equal "ABCD-1234" (gethash "userCode" info))
                     "login start surfaces the user code")
        (let ((flat (with-output-to-string (s) (yason:encode info s))))
          (ensure-true (not (search "should-not-survive" flat))
                       "login start redacts the device-code secret")))))
  ;; unsupported login type is rejected.
  (multiple-value-bind (conn out) (cas-connection '())
    (declare (ignore out))
    (handler-case
        (progn (self-improving-agent-harness:codex-login-start conn "magic-link")
               (error "Test failed: unsupported login type must be rejected"))
      (self-improving-agent-harness:codex-app-server-error () t)))
  ;; wait-for-login consumes notifications until completed, redacting params.
  (multiple-value-bind (conn out)
      (cas-connection (list (cas-frame (cas-notification "account/login/progress" (cas-obj "step" 1)))
                            (cas-frame (cas-notification "account/login/completed"
                                                         (cas-obj "authMode" "chatgpt"
                                                                  "refresh_token" "leak-me")))))
    (declare (ignore out))
    (let ((params (self-improving-agent-harness:codex-wait-for-login conn)))
      (ensure-true (equal "chatgpt" (gethash "authMode" params))
                   "completed params keep non-secret authMode")
      (let ((flat (with-output-to-string (s) (yason:encode params s))))
        (ensure-true (not (search "leak-me" flat))
                     "completed params redact any token field")))))

(defun run-codex-app-server-tests ()
  (run-codex-request-and-error-tests)
  (run-codex-account-and-auth-tests)
  (run-codex-login-tests)
  (format t "Codex app-server supervisor tests passed.~%")
  t)
