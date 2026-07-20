(in-package #:self-improving-agent-harness)

;;;; Offline JSON-RPC 2.0 framing and recursive auth redaction for the Codex
;;;; app-server backend (issue #18).
;;;;
;;;; Everything in this file is pure / stream-local: no process spawn, no
;;;; network, no environment access. The transport layer (a later file) injects
;;;; the streams so deterministic tests can exercise framing and redaction with
;;;; networking disabled.

;;; ---------------------------------------------------------------------------
;;; JSON-RPC message construction (provider-neutral, keyword-based like the rest
;;; of the harness; converted to JSON by the existing yason helpers).
;;; ---------------------------------------------------------------------------

(defun codex-jsonrpc-request (id method &optional params)
  "Build a JSON-RPC 2.0 request object as a yason-ready hash table.

ID is a request identifier (integer or string). METHOD is the RPC method name.
PARAMS is a hash table or alist/plist already in JSON shape. The Codex
app-server requires a `params` field even for argument-less methods (it rejects
a missing field with -32600 \"missing field `params`\"), so PARAMS defaults to
an empty JSON object rather than being omitted."
  (let ((object (make-hash-table :test #'equal)))
    (setf (gethash "jsonrpc" object) "2.0"
          (gethash "id" object) id
          (gethash "method" object) method
          (gethash "params" object) (or params (make-hash-table :test #'equal)))
    object))

(defun codex-jsonrpc-notification-p (message)
  "True when decoded MESSAGE is a notification (a method call with no id)."
  (and (hash-table-p message)
       (nth-value 1 (gethash "method" message))
       (not (nth-value 1 (gethash "id" message)))))

(defun codex-jsonrpc-field (message name)
  "Read NAME from a decoded JSON-RPC MESSAGE hash table (NIL if absent)."
  (when (hash-table-p message)
    (gethash name message)))

;;; ---------------------------------------------------------------------------
;;; Line-delimited JSON framing.
;;;
;;; The official `codex app-server` speaks newline-delimited JSON over stdio:
;;; one compact JSON object per line, terminated by a newline. (Validated
;;; against @openai/codex 0.144.6, which rejects LSP-style Content-Length
;;; frames with "Failed to deserialize JSONRPCMessage".) Each JSON object must
;;; therefore contain no raw newline; YASON emits compact single-line JSON and
;;; escapes control characters in strings, so this holds.
;;; ---------------------------------------------------------------------------

(defun codex-encode-jsonrpc-message (object)
  "Serialize OBJECT to a single newline-terminated JSON line for the app-server."
  (let ((body (with-output-to-string (stream) (yason:encode object stream))))
    (concatenate 'string body (string #\Newline))))

(defun codex-read-jsonrpc-message (stream)
  "Read one newline-delimited JSON-RPC message from STREAM.

Returns the decoded message (a yason hash table) or :EOF at clean end of stream.
Blank lines are skipped. Signals an error on a non-empty line that is not valid
JSON."
  (loop
    (let ((line (read-line stream nil :eof)))
      (when (eq line :eof)
        (return :eof))
      (setf line (string-right-trim '(#\Return) line))
      (unless (zerop (length (string-trim " " line)))
        (return
          (handler-case
              (yason:parse line)
            (error (condition)
              (error "Codex JSON-RPC line is not valid JSON: ~A" condition))))))))

;;; ---------------------------------------------------------------------------
;;; Recursive auth redaction.
;;;
;;; Any decoded Codex message may be surfaced as evidence. Before that happens we
;;; redact secret-shaped fields recursively. We deny by key name (token-shaped
;;; keys) and keep the structure otherwise; string leaves are additionally run
;;; through the existing SCRUB-INTERACTION-LOG-TEXT.
;;; ---------------------------------------------------------------------------

(defparameter *codex-secret-key-substrings*
  '("token" "secret" "password" "apikey" "api_key" "api-key"
    "authorization" "auth_code" "authcode" "code_verifier" "codeverifier"
    "devicecode" "device_code"
    "id_token" "access" "refresh" "client_secret" "bearer" "credential")
  "Lowercased substrings that mark a JSON key as holding a secret. Matching keys
are replaced with a redaction marker regardless of value. Conservative by design:
prefer over-redaction of unknown auth-shaped fields to leaking a credential.")

(defparameter *codex-redaction-marker* "***REDACTED***"
  "Replacement value for any field whose key matches *CODEX-SECRET-KEY-SUBSTRINGS*.")

(defun codex-secret-key-p (key)
  "True when KEY (a JSON object key) names a secret-shaped field."
  (let ((k (string-downcase (princ-to-string key))))
    (some (lambda (needle) (search needle k)) *codex-secret-key-substrings*)))

(defun codex-alist-p (value)
  "True when VALUE looks like an alist of (key . datum) pairs with atom keys."
  (and (consp value)
       (every (lambda (element)
                (and (consp element)
                     (atom (car element))))
              value)))

(defun codex-redact (value)
  "Return VALUE with secret-shaped fields recursively redacted.

Hash tables and alists are treated as JSON objects: any key matching
CODEX-SECRET-KEY-P has its value replaced with *CODEX-REDACTION-MARKER*; other
values recurse. Sequences recurse element-wise. String leaves are scrubbed via
SCRUB-INTERACTION-LOG-TEXT so token-shaped substrings pasted into free text are
also caught."
  (typecase value
    (hash-table
     (let ((out (make-hash-table :test (hash-table-test value))))
       (maphash (lambda (k v)
                  (setf (gethash k out)
                        (if (codex-secret-key-p k)
                            *codex-redaction-marker*
                            (codex-redact v))))
                value)
       out))
    (string (scrub-interaction-log-text value))
    (cons
     (if (codex-alist-p value)
         (mapcar (lambda (pair)
                   (if (codex-secret-key-p (car pair))
                       (cons (car pair) *codex-redaction-marker*)
                       (cons (car pair) (codex-redact (cdr pair)))))
                 value)
         (mapcar #'codex-redact value)))
    (vector
     (if (stringp value)
         (scrub-interaction-log-text value)
         (map 'vector #'codex-redact value)))
    (t value)))

