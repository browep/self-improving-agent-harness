(in-package #:self-improving-agent-harness/tests)

;;;; Deterministic, network-free tests for Codex app-server JSON-RPC framing and
;;;; recursive auth redaction (issue #18, Phase 1).

(defun codex-jsonrpc-field* (message name)
  (self-improving-agent-harness::codex-jsonrpc-field message name))

(defun run-codex-jsonrpc-framing-tests ()
  ;; Round-trip: encode a request, read it back through the frame reader.
  (let* ((params (let ((p (make-hash-table :test #'equal)))
                   (setf (gethash "type" p) "chatgpt") p))
         (request (self-improving-agent-harness:codex-jsonrpc-request 7 "account/login/start" params))
         (framed (self-improving-agent-harness:codex-encode-jsonrpc-message request)))
    (ensure-true (search "Content-Length: " framed)
                 "framed message carries a Content-Length header")
    (with-input-from-string (in framed)
      (let ((decoded (self-improving-agent-harness:codex-read-jsonrpc-message in)))
        (ensure-true (hash-table-p decoded) "decoded frame is a JSON object")
        (ensure-true (equal "2.0" (codex-jsonrpc-field* decoded "jsonrpc"))
                     "decoded frame preserves the jsonrpc version")
        (ensure-true (eql 7 (codex-jsonrpc-field* decoded "id"))
                     "decoded frame preserves the request id")
        (ensure-true (equal "account/login/start" (codex-jsonrpc-field* decoded "method"))
                     "decoded frame preserves the method")
        ;; Next read on an exhausted stream is a clean EOF.
        (ensure-true (eq :eof (self-improving-agent-harness:codex-read-jsonrpc-message in))
                     "reading past the last frame returns :eof"))))
  ;; Notification detection: a method call without an id.
  (let ((note (make-hash-table :test #'equal)))
    (setf (gethash "jsonrpc" note) "2.0"
          (gethash "method" note) "account/login/completed")
    (ensure-true (self-improving-agent-harness:codex-jsonrpc-notification-p note)
                 "a method message without an id is a notification"))
  (let ((resp (make-hash-table :test #'equal)))
    (setf (gethash "jsonrpc" resp) "2.0"
          (gethash "id" resp) 1)
    (ensure-true (not (self-improving-agent-harness:codex-jsonrpc-notification-p resp))
                 "a message with an id is not a notification"))
  ;; Malformed frame: missing Content-Length signals rather than hangs.
  (with-input-from-string (in (format nil "X-Bogus: 1~C~C~C~C{}" #\Return #\Newline #\Return #\Newline))
    (ensure-true (nth-value 1 (ignore-errors
                                (self-improving-agent-harness:codex-read-jsonrpc-message in)))
                 "a frame with no Content-Length signals an error")))

(defun codex-redact-account-payload ()
  "A decoded-account-shaped hash table mixing secret and non-secret fields."
  (let ((account (make-hash-table :test #'equal))
        (nested (make-hash-table :test #'equal)))
    (setf (gethash "authMode" account) "chatgpt"
          (gethash "planType" account) "plus"
          (gethash "access_token" account) "sk-or-shouldnotappear1234567890"
          (gethash "refresh_token" account) "reallysecretrefresh"
          (gethash "tokens" nested) "nestedsecret"
          (gethash "modelId" nested) "gpt-5-codex"
          (gethash "session" account) nested)
    account))

(defun run-codex-redaction-tests ()
  (let* ((account (codex-redact-account-payload))
         (redacted (self-improving-agent-harness:codex-redact account))
         (marker self-improving-agent-harness:*codex-redaction-marker*)
         (flat (with-output-to-string (s) (yason:encode redacted s))))
    ;; Non-secret metadata survives.
    (ensure-true (equal "chatgpt" (gethash "authMode" redacted))
                 "authMode metadata is preserved through redaction")
    (ensure-true (equal "plus" (gethash "planType" redacted))
                 "planType metadata is preserved through redaction")
    ;; Secret-keyed fields are replaced by the marker.
    (ensure-true (equal marker (gethash "access_token" redacted))
                 "access_token is replaced with the redaction marker")
    (ensure-true (equal marker (gethash "refresh_token" redacted))
                 "refresh_token is replaced with the redaction marker")
    ;; Nested secret keys are redacted recursively; nested safe metadata kept.
    (let ((session (gethash "session" redacted)))
      (ensure-true (equal marker (gethash "tokens" session))
                   "nested token field is redacted recursively")
      (ensure-true (equal "gpt-5-codex" (gethash "modelId" session))
                   "nested non-secret model id survives"))
    ;; The serialized evidence contains no secret values at all.
    (ensure-true (not (search "shouldnotappear" flat))
                 "serialized redacted evidence contains no access-token value")
    (ensure-true (not (search "reallysecretrefresh" flat))
                 "serialized redacted evidence contains no refresh-token value")
    (ensure-true (not (search "nestedsecret" flat))
                 "serialized redacted evidence contains no nested secret value"))
  ;; Alist objects are redacted too (the harness uses both shapes).
  (let* ((alist (list (cons "authMode" "chatgpt")
                      (cons "id_token" "leakme-abc")
                      (cons "meta" (list (cons "refresh" "leakme-def")
                                         (cons "plan" "pro")))))
         (redacted (self-improving-agent-harness:codex-redact alist))
         (marker self-improving-agent-harness:*codex-redaction-marker*))
    (ensure-true (equal marker (cdr (assoc "id_token" redacted :test #'string=)))
                 "alist secret key is redacted")
    (ensure-true (equal marker (cdr (assoc "refresh"
                                           (cdr (assoc "meta" redacted :test #'string=))
                                           :test #'string=)))
                 "nested alist secret key is redacted")
    (ensure-true (equal "pro" (cdr (assoc "plan"
                                          (cdr (assoc "meta" redacted :test #'string=))
                                          :test #'string=)))
                 "nested alist non-secret key survives"))
  ;; String leaves still get scrubbed for token-shaped substrings.
  (ensure-true (not (search "sk-or-abcdef123456"
                            (self-improving-agent-harness:codex-redact
                             "prefix sk-or-abcdef123456 suffix")))
               "string leaf token substring is scrubbed"))

(defun run-codex-jsonrpc-tests ()
  (run-codex-jsonrpc-framing-tests)
  (run-codex-redaction-tests)
  (format t "Codex JSON-RPC framing and redaction tests passed.~%")
  t)
