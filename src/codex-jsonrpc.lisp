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
PARAMS, when supplied, is a hash table or alist/plist already in JSON shape."
  (let ((object (make-hash-table :test #'equal)))
    (setf (gethash "jsonrpc" object) "2.0"
          (gethash "id" object) id
          (gethash "method" object) method)
    (when params
      (setf (gethash "params" object) params))
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
;;; Content-Length framing (the framing Codex/LSP-style app-servers use).
;;; ---------------------------------------------------------------------------

(defun codex-encode-jsonrpc-message (object)
  "Serialize OBJECT to a Content-Length-framed JSON-RPC message string.

The body is UTF-8 JSON; the header reports the body's UTF-8 byte length, per the
LSP-style framing Codex app-server uses over stdio."
  (let* ((body (with-output-to-string (stream) (yason:encode object stream)))
         (byte-length (length (sb-ext:string-to-octets body :external-format :utf-8))))
    (format nil "Content-Length: ~D~C~C~C~C~A"
            byte-length #\Return #\Newline #\Return #\Newline body)))

(defun codex-read-jsonrpc-headers (stream)
  "Read framing headers from STREAM until the blank separator line.

Returns an alist of (lowercased-name . value), or NIL at end of stream before
any header. Header lines are CRLF-terminated; a bare LF is tolerated."
  (let ((headers '())
        (saw-any nil))
    (loop
      (let ((line (read-line stream nil :eof)))
        (when (eq line :eof)
          (return (and saw-any (nreverse headers))))
        (setf line (string-right-trim '(#\Return) line))
        (when (zerop (length line))
          (return (nreverse headers)))
        (setf saw-any t)
        (let ((colon (position #\: line)))
          (when colon
            (push (cons (string-downcase (string-trim " " (subseq line 0 colon)))
                        (string-trim " " (subseq line (1+ colon))))
                  headers)))))))

(defun codex-header-value (headers name)
  (cdr (assoc (string-downcase name) headers :test #'string=)))

(defun codex-read-jsonrpc-message (stream)
  "Read one Content-Length-framed JSON-RPC message from STREAM.

Returns the decoded message (a yason hash table) or :EOF at clean end of stream.
Signals an error on a malformed frame (missing/invalid Content-Length)."
  (let ((headers (codex-read-jsonrpc-headers stream)))
    (when (null headers)
      (return-from codex-read-jsonrpc-message :eof))
    (let ((length-header (codex-header-value headers "content-length")))
      (unless length-header
        (error "Codex JSON-RPC frame is missing a Content-Length header."))
      (let ((byte-length (ignore-errors (parse-integer length-header))))
        (unless (and (integerp byte-length) (>= byte-length 0))
          (error "Codex JSON-RPC frame has an invalid Content-Length ~S." length-header))
        (let ((body (make-string byte-length)))
          ;; The body length is a BYTE count; for ASCII JSON (the common case for
          ;; these control messages) this matches the character count. Read that
          ;; many characters, then decode.
          (let ((read (read-sequence body stream)))
            (when (< read byte-length)
              (error "Codex JSON-RPC frame body truncated: expected ~D, got ~D."
                     byte-length read)))
          (handler-case
              (yason:parse body)
            (error (condition)
              (error "Codex JSON-RPC frame body is not valid JSON: ~A" condition))))))))

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

