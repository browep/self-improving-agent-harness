(in-package #:self-improving-agent-harness)

;;;; Claude Agent SDK direct backend seam (issue #68).
;;;;
;;;; This is a narrow, selectable *direct* Anthropic Messages API transport,
;;;; deliberately separate from CLAUDE-BACKEND (which spawns the official
;;;; Claude Code CLI binary in src/claude-backend.lisp). This backend never
;;;; spawns a process and never opens an MCP/CLOG channel; it speaks plain
;;;; HTTPS to https://api.anthropic.com/v1/messages via Drakma. Its only
;;;; credential boundary is the same runtime-only CLAUDE_CODE_OAUTH_TOKEN used
;;;; by the CLI backend; it never reads or falls back to ANTHROPIC_API_KEY.
;;;;
;;;; Scope (issue #68): text-only completion requests (model, messages,
;;;; optional system, stream:true). No tools, no --resume-style session
;;;; continuation, no CLOG wiring. The wire contract below -- headers, the
;;;; streamed Server-Sent Events shape, and the JSON error envelope -- was
;;;; captured from an authorized local proxy sitting in front of a known-good
;;;; official client turn. The request is always sent with stream:true and the
;;;; response is always Server-Sent Events on success, but COMPLETE buffers
;;;; and normalizes that stream internally: callers of COMPLETE always get
;;;; exactly one COMPLETION-RESPONSE, never a sequence of partial deltas.
;;;;
;;;; The real, credential-gated live call against api.anthropic.com is
;;;; deliberately NOT exercised here -- that is issue #70's opt-in smoke.
;;;; Every offline test in tests/claude-sdk-backend.lisp injects a fake
;;;; TRANSPORT function so this backend's tests never touch the network.

(define-condition claude-sdk-backend-error (error)
  ((reason :initarg :reason :reader claude-sdk-backend-error-reason))
  (:report (lambda (condition stream)
             (format stream "Claude SDK backend error: ~A"
                     (claude-sdk-backend-error-reason condition)))))

(defun claude-sdk-error (format-control &rest args)
  (error 'claude-sdk-backend-error :reason (apply #'format nil format-control args)))

(defun claude-sdk-normalize-token (value)
  "Trim VALUE and remove one matching layer of .env-style surrounding quotes."
  (when (stringp value)
    (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) value)))
      (if (and (>= (length trimmed) 2)
               (member (char trimmed 0) '(#\" #\'))
               (char= (char trimmed 0) (char trimmed (1- (length trimmed)))))
          (subseq trimmed 1 (1- (length trimmed)))
          trimmed))))

(defun require-claude-sdk-oauth-token ()
  "Return the runtime CLAUDE_CODE_OAUTH_TOKEN, or signal a safe missing-token error.

This is the only credential this backend ever consults. It never reads
ANTHROPIC_API_KEY, and never falls back to it when the OAuth token is absent
or blank."
  (let ((token (claude-sdk-normalize-token (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN"))))
    (unless (and token (plusp (length token)))
      (claude-sdk-error
       "authentication is not configured. Generate a long-lived OAuth token with `claude setup-token` on a machine logged in to the intended Claude subscription, then provide it as CLAUDE_CODE_OAUTH_TOKEN and retry."))
    token))

;;; ---------------------------------------------------------------------
;;; Captured wire contract
;;; ---------------------------------------------------------------------

(defparameter *claude-sdk-messages-url* "https://api.anthropic.com/v1/messages"
  "The Anthropic Messages API endpoint this backend posts to.")

(defparameter *claude-sdk-anthropic-version* "2023-06-01"
  "Captured `anthropic-version` header value.")

(defparameter *claude-sdk-anthropic-beta* "oauth-2025-04-20"
  "Captured `anthropic-beta` header value required for OAuth (setup-token) auth.")

(defparameter *claude-sdk-user-agent* "claude-cli/2.1.218 (external, sdk-cli)"
  "Captured `User-Agent` header value, matching the pinned Claude Code CLI version.")

(defparameter *claude-sdk-x-app* "cli"
  "Captured `x-app` header value.")

(defparameter *claude-sdk-default-max-tokens* 4096
  "Default Anthropic Messages `max_tokens` when neither the completion request's
OPTIONS nor the backend supply one. The Messages API requires this field; this
harness never guesses a value large enough to matter, only a conservative
floor so a plain request does not 400 for a missing required field.")

(defparameter *claude-sdk-request-timeout-seconds* 120
  "Wall-clock timeout in seconds for one Anthropic Messages API completion
request, including the time spent buffering its streamed response.

NIL disables the overall timeout. Bound or set at runtime to tune hang
diagnosis without rebuilding the image.")

(defparameter *claude-sdk-connection-timeout-seconds* 30
  "Seconds to wait while establishing the Anthropic API TCP connection.
Passed to Drakma as :CONNECTION-TIMEOUT. NIL means no connection timeout.")

(defun claude-sdk-request-headers (token)
  "Return the exact captured Anthropic Messages API header set for TOKEN.

TOKEN is the runtime CLAUDE_CODE_OAUTH_TOKEN value; it appears only in the
Authorization value of the returned alist -- never logged, never included in
any signalled condition."
  (list (cons "Authorization" (format nil "Bearer ~A" token))
        (cons "Accept" "application/json")
        (cons "Content-Type" "application/json")
        (cons "User-Agent" *claude-sdk-user-agent*)
        (cons "anthropic-version" *claude-sdk-anthropic-version*)
        (cons "x-app" *claude-sdk-x-app*)
        (cons "anthropic-beta" *claude-sdk-anthropic-beta*)))

;;; ---------------------------------------------------------------------
;;; Request payload (text-only: model, messages, optional system, stream)
;;; ---------------------------------------------------------------------

(defun claude-sdk-system-prompt (request)
  "Return REQUEST's system-role text, or NIL when absent/blank.

Only the first system-role message is used, matching CLAUDE-SYSTEM-PROMPT's
convention in the sibling CLI backend (src/claude-backend.lisp). Unlike that
backend, no tool-execution instructions are appended here: this transport
never advertises tools (issue #68 scope)."
  (loop for message in (completion-request-messages request)
        when (and (string= "system" (or (getf message :role) ""))
                  (stringp (getf message :content))
                  (plusp (length (getf message :content))))
          do (return (getf message :content))))

(defun claude-sdk-request-messages (request)
  "Return REQUEST's user/assistant turns as Anthropic Messages API message objects.

System-role turns are excluded here; CLAUDE-SDK-SYSTEM-PROMPT extracts them
separately for the top-level `system` field. Only string content is
forwarded -- this backend is deliberately text-only for issue #68, so any
non-string turn (e.g. a stray tool-shaped message) degrades to empty text
rather than guessing a serialization."
  (loop for message in (completion-request-messages request)
        for role = (or (getf message :role) "")
        when (or (string= role "user") (string= role "assistant"))
          collect (list :role role
                        :content (let ((content (getf message :content)))
                                   (if (stringp content) content "")))))

(defun claude-sdk-request-max-tokens (request backend)
  "Resolve `max_tokens`: per-request OPTIONS win, then a backend-level
override, then the conservative global default."
  (flet ((positive-integer (value) (and (integerp value) (plusp value) value)))
    (or (positive-integer (getf (completion-request-options request) :max-tokens))
        (positive-integer (claude-sdk-backend-max-tokens backend))
        *claude-sdk-default-max-tokens*)))

(defun claude-sdk-request-payload (request backend)
  "Return REQUEST as an Anthropic Messages API payload plist, before JSON encoding.

Text-only: MODEL, MAX-TOKENS, MESSAGES, STREAM t, and SYSTEM only when
present. Deliberately no `tools`, no `tool_choice`, and no resume-style field
(issue #68 scope; native tool support is a follow-up)."
  (let ((system (claude-sdk-system-prompt request)))
    (append
     (list :model (completion-request-model request)
           :max-tokens (claude-sdk-request-max-tokens request backend)
           :messages (claude-sdk-request-messages request)
           :stream t)
     (when system (list :system system)))))

(defun claude-sdk-request-json (payload)
  "Serialize PAYLOAD (a keyword plist) to the Anthropic Messages API JSON contract.

Reuses OPENROUTER-JSON-VALUE's generic keyword->snake_case conversion and its
JSON-illegal-control-character sanitization (src/backend.lisp); both are
provider-agnostic infrastructure already exercised by the OpenRouter/Synthetic
adapters."
  (with-output-to-string (stream)
    (yason:encode (openrouter-json-value payload) stream)))

;;; ---------------------------------------------------------------------
;;; Server-Sent Events parsing
;;; ---------------------------------------------------------------------

(defun claude-sdk-split-sse-lines (text)
  "Split TEXT into logical lines, tolerating CRLF, bare LF, and a final
unterminated line (no trailing newline)."
  (let ((lines '()) (start 0) (length (length text)))
    (loop
      (let ((newline (position #\Newline text :start start)))
        (unless newline
          (when (< start length)
            (push (subseq text start) lines))
          (return))
        (let ((line-end newline))
          (when (and (> line-end start) (char= (char text (1- line-end)) #\Return))
            (decf line-end))
          (push (subseq text start line-end) lines))
        (setf start (1+ newline))))
    (nreverse lines)))

(defun claude-sdk-parse-sse-events (text)
  "Parse TEXT (a fully buffered Server-Sent Events body) into an ordered list of frames.

Each frame is a plist (:EVENT EVENT-NAME-OR-NIL :DATA PARSED-JSON-OR-NIL
:RAW-DATA RAW-DATA-STRING). Follows standard SSE field-parsing rules:
`:`-prefixed lines are comments and are ignored, multiple `data:` lines within
one frame are joined with a newline before JSON decoding, and a blank line
dispatches the pending frame. A trailing frame without an explicit blank
terminator is still dispatched, so a body missing its final newline is never
silently dropped. Unparseable DATA yields :DATA NIL with :RAW-DATA preserved,
so a malformed frame degrades gracefully instead of aborting the whole parse."
  (let ((frames '()) (event-name nil) (data-lines '()))
    (flet ((dispatch ()
             (when (or event-name data-lines)
               (let ((raw (format nil "~{~A~^~%~}" (nreverse data-lines))))
                 (push (list :event event-name
                             :data (and (plusp (length raw))
                                        (ignore-errors (yason:parse raw)))
                             :raw-data raw)
                       frames)))
             (setf event-name nil data-lines '())))
      (dolist (line (claude-sdk-split-sse-lines text))
        (cond
          ((zerop (length line)) (dispatch))
          ((char= (char line 0) #\:) nil) ; comment line
          ((uiop:string-prefix-p "event:" line)
           (setf event-name (string-trim '(#\Space) (subseq line (length "event:")))))
          ((uiop:string-prefix-p "data:" line)
           (let ((value (subseq line (length "data:"))))
             (push (if (and (plusp (length value)) (char= (char value 0) #\Space))
                       (subseq value 1)
                       value)
                   data-lines)))
          (t nil))) ; unrecognized SSE field (e.g. id:/retry:); ignored
      (dispatch))
    (nreverse frames)))

;;; ---------------------------------------------------------------------
;;; Response normalization: buffered SSE frames -> one COMPLETION-RESPONSE
;;; ---------------------------------------------------------------------

(defun claude-sdk-join-text-blocks (table)
  "Concatenate hash-table TABLE (content-block index -> accumulated text) in
ascending index order."
  (let ((indices (sort (loop for key being the hash-keys of table collect key) #'<)))
    (apply #'concatenate 'string (mapcar (lambda (index) (gethash index table)) indices))))

(defun claude-sdk-signal-stream-error (data event-name)
  "Signal CLAUDE-SDK-BACKEND-ERROR for a `data:`-decoded stream error frame.

DATA is the parsed JSON object (or NIL if it failed to parse); EVENT-NAME is
the frame's `event:` value. Never echoes anything beyond the provider's own
error type/message -- no raw body, no headers."
  (let* ((error-object (and data (openrouter-json-field data "error")))
         (error-type (and error-object (openrouter-json-field error-object "type")))
         (error-message (and error-object (openrouter-json-field error-object "message"))))
    (claude-sdk-error "the Anthropic Messages API returned a stream error~@[ (~A)~]: ~A"
                       error-type
                       (or error-message
                           (and (stringp event-name) (format nil "unparseable ~A frame" event-name))
                           "no message provided"))))

(defun claude-sdk-response-from-events (events request)
  "Normalize a full ordered list of parsed Anthropic Messages SSE frames.

EVENTS is the return value of CLAUDE-SDK-PARSE-SSE-EVENTS. Returns exactly one
COMPLETION-RESPONSE assembled from the terminal state of the stream: this
backend never exposes intermediate deltas to callers (issue #68 -- \"a single
normal completion-response, no UI partials\"). Content-block text deltas are
accumulated per index and joined in ascending index order; usage/model/
stop_reason/message-id are read from message_start and the final
message_delta. `ping`, `content_block_start`/`content_block_stop`,
`message_stop`, and any unrecognized future event type are ignored,
forward-compatibly."
  (let ((model nil) (message-id nil) (stop-reason nil)
        (input-tokens nil) (output-tokens nil)
        (text-blocks (make-hash-table)) (saw-message-start nil))
    (dolist (event events)
      (let* ((data (getf event :data))
             (event-name (getf event :event))
             (type (and data (openrouter-json-field data "type"))))
        (cond
          ((or (and (stringp event-name) (string-equal event-name "error"))
               (and (stringp type) (string= type "error")))
           (claude-sdk-signal-stream-error data event-name))
          ((null data) nil) ; unparseable, non-error frame; ignore rather than fail the turn
          ((string= (or type "") "message_start")
           (setf saw-message-start t)
           (let* ((message (openrouter-json-field data "message"))
                  (usage (and message (openrouter-json-field message "usage"))))
             (setf model (and message (openrouter-json-field message "model")))
             (setf message-id (and message (openrouter-json-field message "id")))
             (let ((input (and usage (openrouter-json-field usage "input_tokens"))))
               (when (realp input) (setf input-tokens input)))))
          ((string= (or type "") "content_block_delta")
           (let* ((index (openrouter-json-field data "index"))
                  (delta (openrouter-json-field data "delta")))
             (when (and (integerp index)
                        delta
                        (string= (or (openrouter-json-field delta "type") "") "text_delta"))
               (let ((text (openrouter-json-field delta "text")))
                 (when (stringp text)
                   (setf (gethash index text-blocks)
                         (concatenate 'string (or (gethash index text-blocks) "") text)))))))
          ((string= (or type "") "message_delta")
           (let* ((delta (openrouter-json-field data "delta"))
                  (usage (openrouter-json-field data "usage")))
             (let ((reason (and delta (openrouter-json-field delta "stop_reason"))))
               (when (stringp reason) (setf stop-reason reason)))
             (let ((output (and usage (openrouter-json-field usage "output_tokens"))))
               (when (realp output) (setf output-tokens output)))))
          (t nil)))) ; message_stop, content_block_start/stop, ping, and any
                      ; other future event type are intentionally no-ops.
    (unless saw-message-start
      (claude-sdk-error
       "the Anthropic Messages API stream ended without a message_start event; the response could not be normalized."))
    (make-completion-response
     :text (claude-sdk-join-text-blocks text-blocks)
     :model (or model (completion-request-model request))
     :raw events
     :tool-calls '()
     :finish-reason stop-reason
     :provider-request-id message-id
     :usage (append (when input-tokens (list :prompt-tokens input-tokens))
                     (when output-tokens (list :completion-tokens output-tokens))
                     (when (and input-tokens output-tokens)
                       (list :total-tokens (+ input-tokens output-tokens)))))))

(defun claude-sdk-response-from-body (body request)
  "Parse a fully buffered Server-Sent Events BODY string into one
COMPLETION-RESPONSE for REQUEST."
  (claude-sdk-response-from-events (claude-sdk-parse-sse-events body) request))

;;; ---------------------------------------------------------------------
;;; HTTP transport and error mapping
;;; ---------------------------------------------------------------------

(defun claude-sdk-safe-diagnostic (value token)
  "Return a bounded, credential-safe diagnostic string derived from VALUE.

TOKEN, when supplied, is redacted from VALUE before any truncation, logging,
or condition is constructed, mirroring CLAUDE-SAFE-DIAGNOSTIC in the sibling
CLI backend (src/claude-backend.lisp). Also runs SCRUB-INTERACTION-LOG-TEXT
(generic secret-pattern redaction) and TRUNCATE-PROVIDER-ERROR-BODY (generic
whitespace collapse + length bound), both from src/backend.lisp/logging.lisp,
so a raw provider error body never reaches a log or condition unbounded."
  (let* ((raw (princ-to-string (or value "")))
         (without-token
           (if (and (stringp token) (plusp (length token)))
               (let ((result raw))
                 (loop for found = (search token result)
                       while found
                       do (setf result
                                (concatenate 'string (subseq result 0 found)
                                             "[REDACTED]"
                                             (subseq result (+ found (length token)))))
                       finally (return result)))
               raw))
         (scrubbed (scrub-interaction-log-text without-token)))
    (truncate-provider-error-body scrubbed)))

(defun claude-sdk-signal-http-error (status-code body token)
  "Signal CLAUDE-SDK-BACKEND-ERROR for a non-2xx Messages API HTTP response.

Parses BODY as the Anthropic `{\"type\":\"error\",\"error\":{...}}` envelope
when possible; a non-JSON or unparseable BODY still produces a bounded, safe
message naming only the HTTP status. TOKEN is redacted before any text is
retained (see CLAUDE-SDK-SAFE-DIAGNOSTIC); the raw BODY itself is never
echoed verbatim, only its (redacted, bounded) error message or a truncated
snippet."
  (let* ((parsed (and (stringp body) (plusp (length body)) (ignore-errors (yason:parse body))))
         (error-object (and parsed (openrouter-json-field parsed "error")))
         (error-type (and error-object (openrouter-json-field error-object "type")))
         (error-message (and error-object (openrouter-json-field error-object "message")))
         (safe (claude-sdk-safe-diagnostic (or error-message body "") token)))
    (claude-sdk-error "Anthropic Messages API request failed with HTTP status ~D~@[ (~A)~]: ~A"
                       status-code error-type safe)))

(defun claude-sdk-live-transport (url headers content-octets)
  "POST CONTENT-OCTETS to URL with HEADERS via Drakma.

Returns (values body-text status-code). Content-Type is pulled out of HEADERS
and passed through Drakma's dedicated keyword so exactly one Content-Type
header reaches the wire; every other header in HEADERS (including
Authorization) is forwarded verbatim via :ADDITIONAL-HEADERS. The response
body -- Server-Sent Events on success, a JSON error envelope on failure -- is
fully buffered and safely UTF-8 decoded via OPENROUTER-RESPONSE-BODY-STRING
(src/backend.lisp) before this function returns; SSE parsing happens
afterward, entirely in Lisp, in CLAUDE-SDK-PARSE-SSE-EVENTS."
  (let* ((content-type (or (cdr (assoc "Content-Type" headers :test #'string-equal))
                            "application/json"))
         (other-headers (remove "Content-Type" headers :key #'car :test #'string-equal)))
    (multiple-value-bind (body status-code response-headers)
        (drakma:http-request url
                              :method :post
                              :content content-octets
                              :content-type content-type
                              :additional-headers other-headers
                              :connection-timeout *claude-sdk-connection-timeout-seconds*)
      (declare (ignore response-headers))
      (values (openrouter-response-body-string body) status-code))))

;;; ---------------------------------------------------------------------
;;; Backend class and COMPLETE
;;; ---------------------------------------------------------------------

(defclass claude-sdk-backend (backend)
  ((transport :initarg :transport :initform #'claude-sdk-live-transport
              :reader claude-sdk-backend-transport)
   (max-tokens :initarg :max-tokens :initform nil :reader claude-sdk-backend-max-tokens)
   (timeout :initarg :timeout :initform *claude-sdk-request-timeout-seconds*
            :reader claude-sdk-backend-timeout))
  (:documentation "Direct Claude Agent SDK / Anthropic Messages API transport,
distinct from the CLI-spawning CLAUDE-BACKEND.

TRANSPORT is an injectable (URL HEADERS CONTENT-OCTETS) -> (values BODY-TEXT
STATUS-CODE) function; it defaults to CLAUDE-SDK-LIVE-TRANSPORT (real Drakma
I/O) and is overridden by every offline test."))

(defun make-claude-sdk-backend (&key (transport #'claude-sdk-live-transport)
                                  max-tokens (timeout *claude-sdk-request-timeout-seconds*))
  "Construct a claude-sdk backend without reading credentials or doing I/O."
  (make-instance 'claude-sdk-backend :name "claude-sdk" :transport transport
                 :max-tokens max-tokens :timeout timeout))

(defmethod complete ((backend claude-sdk-backend) request)
  "POST REQUEST to the Anthropic Messages API and return one buffered COMPLETION-RESPONSE.

Streams the response internally as Server-Sent Events but never exposes
partial deltas to the caller: the entire body is buffered, safely UTF-8
decoded, and normalized into exactly one COMPLETION-RESPONSE, matching the
harness-facing COMPLETE contract used by every other backend. Text-only: no
tools, no `--resume`-style session continuation, and no CLOG/UI involvement
(issue #68 scope; native tool support and the credential-gated live smoke
against api.anthropic.com are follow-up issues).

Never logs the OAuth token, request headers, or a raw response/error body --
only bounded, redacted diagnostics reach LOG-INTERACTION or any signalled
condition (see CLAUDE-SDK-SAFE-DIAGNOSTIC)."
  (let* ((token (require-claude-sdk-oauth-token))
         (headers (claude-sdk-request-headers token))
         (payload (claude-sdk-request-payload request backend))
         (json (claude-sdk-request-json payload))
         (octets (sb-ext:string-to-octets json :external-format :utf-8))
         (transport (claude-sdk-backend-transport backend))
         (timeout (claude-sdk-backend-timeout backend))
         (start (get-internal-real-time)))
    (log-interaction :info "claude-sdk-request-started"
                     :model (completion-request-model request)
                     :max-tokens (getf payload :max-tokens)
                     :timeout-seconds (or timeout 0))
    (handler-case
        (multiple-value-bind (body status-code)
            (call-with-openrouter-timeout
             timeout
             (lambda () (funcall transport *claude-sdk-messages-url* headers octets)))
          (if (and (integerp status-code) (<= 200 status-code 299))
              (let ((response (claude-sdk-response-from-body body request)))
                (log-interaction :info "claude-sdk-request-completed"
                                 :model (or (completion-response-model response) "unavailable")
                                 :finish-reason (or (completion-response-finish-reason response) "unknown")
                                 :duration-seconds (elapsed-seconds-since start)
                                 :output-length (length (or (completion-response-text response) ""))
                                 :usage-state (if (completion-response-usage response) "reported" "unavailable"))
                response)
              (claude-sdk-signal-http-error status-code body token)))
      (claude-sdk-backend-error (condition)
        (log-interaction :error "claude-sdk-request-failed"
                         :model (completion-request-model request)
                         :duration-seconds (elapsed-seconds-since start)
                         :message (claude-sdk-backend-error-reason condition))
        (error condition))
      (error (condition)
        (let ((message (claude-sdk-safe-diagnostic (princ-to-string condition) token)))
          (log-interaction :error "claude-sdk-request-failed"
                           :model (completion-request-model request)
                           :duration-seconds (elapsed-seconds-since start)
                           :message message)
          (claude-sdk-error "the request to the Anthropic Messages API failed: ~A" message))))))
