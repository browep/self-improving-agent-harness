(in-package #:self-improving-agent-harness)

;; LOG-INTERACTION and LOG-HTTP-TEXT live in src/logging.lisp, which loads after
;; this file (logging's EMIT-CHAT-EVENT in turn depends on backend's JSON
;; helpers, a deliberate mutual reference resolved at runtime). Declare them so
;; the forward call in COMPLETE does not raise an undefined-function warning.
(declaim (ftype (function (t t &rest t) t) log-interaction)
         (ftype (function (t t t &rest t) t) log-http-text))

(defclass backend ()
  ((name :initarg :name :reader backend-name
         :documentation "Stable provider identifier used in experiment traces."))
  (:documentation "Abstract model-provider backend."))

(defgeneric complete (backend request)
  (:documentation "Return a COMPLETION-RESPONSE for REQUEST using BACKEND.

Concrete adapters own transport, authentication, error mapping, and raw provider
response capture. The core harness should depend only on this generic function."))

(defstruct (completion-request
            (:constructor make-completion-request
                (&key model messages options)))
  "A provider-neutral completion request.

MESSAGES is deliberately left as a provider-neutral data structure until the
first adapter's serialization contract is accepted. OPTIONS holds optional
provider-neutral controls such as temperature or maximum output tokens."
  model
  messages
  options)

(defstruct (completion-response
            (:constructor make-completion-response
                (&key text model raw tool-calls finish-reason provider-request-id usage)))
  "A provider-neutral response plus unmodified provider data in RAW."
  text
  model
  raw
  tool-calls
  finish-reason
  provider-request-id
  usage)

(defclass openrouter-backend (backend)
  ((base-url :initarg :base-url
             :initform "https://openrouter.ai/api/v1"
             :reader openrouter-backend-base-url)
   (api-key :initarg :api-key
            :reader openrouter-backend-api-key))
  (:documentation "Configuration for the first backend adapter.

API keys are supplied at runtime, typically from OPENROUTER_API_KEY, never
committed to the repository."))

(defun make-openrouter-backend (&key api-key
                                  (base-url "https://openrouter.ai/api/v1"))
  "Construct an OpenRouter backend configuration without performing I/O."
  (make-instance 'openrouter-backend
                 :name "openrouter"
                 :api-key api-key
                 :base-url base-url))

(defun openrouter-request-payload (request)
  "Return REQUEST as a provider payload before JSON serialization.

The payload intentionally retains the project's keyword-based representation;
the transport layer owns conversion to OpenRouter's JSON field names."
  (append (list :model (completion-request-model request)
                :messages (completion-request-messages request))
          (completion-request-options request)))

(defun openrouter-json-name (keyword)
  (substitute #\_ #\- (string-downcase (symbol-name keyword))))

(defun sanitize-json-control-characters (string)
  "Return STRING with JSON-illegal raw control characters made safe.

RFC 8259 forbids unescaped U+0000..U+001F in JSON strings. YASON escapes the
five short forms (\\b \\t \\n \\f \\r) but emits the remaining control
characters (NUL, U+0001..U+0007, U+000B, U+000E..U+001F including ESC/U+001B)
RAW, which produces a body a strict server rejects with \"JSON parsing failed\"
(HTTP 400). Tool output frequently contains such bytes (e.g. ANSI ESC color
codes). We replace each such character with its \\uXXXX escape sequence as
literal text; YASON then escapes the backslash-safe result, so the value round
trips as the intended escape rather than an invalid raw byte."
  (if (and (stringp string)
           (some (lambda (character)
                   (let ((code (char-code character)))
                     (and (< code #x20)
                          (not (member code '(#x08 #x09 #x0a #x0c #x0d))))))
                 string))
      (with-output-to-string (out)
        (loop for character across string
              for code = (char-code character)
              do (if (and (< code #x20)
                          (not (member code '(#x08 #x09 #x0a #x0c #x0d))))
                     (format out "\\u~4,'0x" code)
                     (write-char character out))))
      string))

(defun openrouter-json-value (value)
  (cond
    ((and (listp value) (keywordp (first value)))
     (let ((object (make-hash-table :test #'equal)))
       (loop for (key item) on value by #'cddr
             do (setf (gethash (openrouter-json-name key) object)
                      (openrouter-json-value item)))
       object))
    ((listp value) (mapcar #'openrouter-json-value value))
    ((stringp value) (sanitize-json-control-characters value))
    (t value)))

(defun openrouter-request-json (request)
  "Serialize REQUEST to OpenRouter's JSON field naming convention."
  (with-output-to-string (stream)
    (yason:encode (openrouter-json-value (openrouter-request-payload request))
                  stream)))

(defun openrouter-request-octets (request)
  "Encode REQUEST JSON as UTF-8 bytes for Drakma's HTTP transport."
  (sb-ext:string-to-octets (openrouter-request-json request)
                           :external-format :utf-8))

(defun openrouter-json-field (object name)
  "Read NAME from a decoded OpenRouter JSON object represented as an alist."
  (etypecase object
    (hash-table (gethash name object))
    (list (cdr (assoc name object :test #'string=)))))

(defun openrouter-list (value)
  (typecase value
    (null '())
    (list value)
    (vector (coerce value 'list))))

(defun openrouter-normalize-tool-call (tool-call)
  (let ((function (openrouter-json-field tool-call "function")))
    (list :id (openrouter-json-field tool-call "id")
          :type (openrouter-json-field tool-call "type")
          :name (openrouter-json-field function "name")
          :arguments (openrouter-json-field function "arguments"))))

(defun openrouter-response-from-json (raw-response)
  "Normalize one decoded, non-streaming OpenRouter response alist."
  (let* ((choice (first (openrouter-list
                         (openrouter-json-field raw-response "choices"))))
         (message (openrouter-json-field choice "message"))
         (usage (openrouter-json-field raw-response "usage")))
    (make-completion-response
     :text (or (openrouter-json-field message "content") "")
     :model (openrouter-json-field raw-response "model")
     :raw raw-response
     :tool-calls (mapcar #'openrouter-normalize-tool-call
                         (openrouter-list
                          (openrouter-json-field message "tool_calls")))
     :finish-reason (openrouter-json-field choice "finish_reason")
     :provider-request-id (openrouter-json-field raw-response "id")
     :usage (append
             (list :prompt-tokens (openrouter-json-field usage "prompt_tokens")
                   :completion-tokens
                   (openrouter-json-field usage "completion_tokens")
                   :total-tokens (openrouter-json-field usage "total_tokens"))
             (let ((cost (openrouter-json-field usage "cost")))
               (if (realp cost) (list :cost-usd cost) '()))))))

(defun openrouter-completions-url (backend)
  (format nil "~A/chat/completions"
          (string-right-trim "/" (openrouter-backend-base-url backend))))

(defun openrouter-response-body-string (body)
  "Convert Drakma's text or octet response body to UTF-8 JSON text."
  (typecase body
    (string body)
    (vector
     (sb-ext:octets-to-string
      (map '(vector (unsigned-byte 8)) #'identity body)
      :external-format :utf-8))))

(defun openrouter-response-body-bytes (body)
  "Return the encoded byte length of Drakma's response BODY.

For an octet vector this is its length; for a decoded string it is the UTF-8
encoded length. Distinct from BODY-CHARS (decoded character count)."
  (typecase body
    (string (length (sb-ext:string-to-octets body :external-format :utf-8)))
    ((vector (unsigned-byte 8)) (length body))
    (vector (length body))
    (t 0)))

(defun coerce-tool-handler (handler name)
  "Return a callable tool handler from HANDLER.

HANDLER may be a function object or a symbol function designator. Symbols are
preferred for live chat sessions: reload_harness redefines the symbol's
function cell, and the next tool call picks it up without recreating the
session. Captured function objects stay frozen until the session is rebuilt."
  (cond
    ((null handler) nil)
    ((functionp handler) handler)
    ((symbolp handler)
     (unless (fboundp handler)
       (error "Tool ~S handler symbol ~S is not fbound." name handler))
     handler)
    (t
     (error "Tool ~S has invalid handler designator ~S." name handler))))

(defun openrouter-tool-handler (handlers name)
  "Look up NAME in HANDLERS and coerce it to a callable designator."
  (coerce-tool-handler (cdr (assoc name handlers :test #'string=)) name))

(defparameter *tool-result-content-limit* 16000
  "Maximum characters of a single tool result retained in chat history and sent
back to the model. NIL disables truncation.

Chat history keeps every tool result and re-sends the whole transcript each
round, so an unbounded result (e.g. `cat` of a large file) is re-serialized on
every subsequent round and drives the process toward heap exhaustion. Capping
the result here bounds both live history size and per-round allocation. Bound or
set at runtime (reload_harness picks it up) to tune the cap.")

(defun truncate-tool-result-content (content)
  "Return CONTENT capped to *TOOL-RESULT-CONTENT-LIMIT* with a clear marker.

Only string results are truncated; the marker records the original length so the
model can narrow the command and re-run it rather than silently losing data."
  (if (and (stringp content)
           (integerp *tool-result-content-limit*)
           (plusp *tool-result-content-limit*)
           (> (length content) *tool-result-content-limit*))
      (let ((limit *tool-result-content-limit*))
        (format nil "~A~%...[tool output truncated to ~D of ~D characters; re-run a narrower command for more]"
                (subseq content 0 limit) limit (length content)))
      content))

(defun openrouter-tool-result-content (result)
  (if (stringp result)
      result
      (with-output-to-string (stream)
        (yason:encode result stream))))

(defun openrouter-assistant-tool-call-message (response)
  (let ((text (completion-response-text response)))
    (list :role "assistant"
          :content (and (plusp (length text)) text)
          :tool-calls
          (mapcar (lambda (tool-call)
                    (list :id (getf tool-call :id)
                          :type (getf tool-call :type)
                          :function (list :name (getf tool-call :name)
                                          :arguments (getf tool-call :arguments))))
                  (completion-response-tool-calls response)))))

(defun openrouter-tool-arguments (tool-call)
  (handler-case
      (yason:parse (getf tool-call :arguments))
    (error ()
      (error "Tool ~S supplied invalid JSON arguments." (getf tool-call :name)))))

(defun openrouter-tool-result-message (tool-call handlers)
  (let* ((name (getf tool-call :name))
         (handler (openrouter-tool-handler handlers name)))
    (unless handler
      (error "No handler is registered for tool ~S." name))
    (let* ((arguments (openrouter-tool-arguments tool-call))
           (arg-text
             (handler-case
                 (with-output-to-string (stream)
                   (yason:encode arguments stream))
               (error () (princ-to-string (getf tool-call :arguments)))))
           (result
             (handler-case
                 (funcall handler arguments)
               (error ()
                 (format nil "TOOL_ERROR: Tool ~A failed." name))))
           (content (truncate-tool-result-content
                     (openrouter-tool-result-content result))))
      (log-interaction :info "tool-completed"
                       :tool (or name "unknown")
                       :tool-call-id (or (getf tool-call :id) "none")
                       :arguments arg-text
                       :tool-result (if (stringp content) content (princ-to-string content))
                       :output-length (if (stringp content) (length content) 0))
      (list :role "tool"
            :tool-call-id (getf tool-call :id)
            :content content))))

(defun response-accounting-value (response usage-key)
  "Return USAGE-KEY only when this response supplies a numeric actual value."
  (let ((value (getf (completion-response-usage response) usage-key)))
    (and (realp value) value)))

(defun aggregate-response-accounting (responses usage-key unavailable-reason)
  "Aggregate USAGE-KEY only if every response supplies an actual numeric value."
  (let ((values (mapcar (lambda (response)
                          (response-accounting-value response usage-key))
                        responses)))
    (if (every #'realp values)
        (values (reduce #'+ values :initial-value 0) "actual" nil)
        (values :unavailable "unavailable" unavailable-reason))))

(defun provider-accounting-summary (backend responses)
  "Return an allow-listed accounting trace for ordered successful RESPONSES.

The trace intentionally contains no raw payload, request messages, tool calls, or
assistant/tool content. Cost totals are actual only when every provider response
includes a numeric usage.cost value; partial cost is never summed."
  (let ((invocations
          (mapcar
           (lambda (response)
             (multiple-value-bind (input input-state input-reason)
                 (aggregate-response-accounting (list response) :prompt-tokens
                                               "provider-did-not-supply-input-tokens")
               (multiple-value-bind (output output-state output-reason)
                   (aggregate-response-accounting (list response) :completion-tokens
                                                 "provider-did-not-supply-output-tokens")
                 (multiple-value-bind (total total-state total-reason)
                     (aggregate-response-accounting (list response) :total-tokens
                                                   "provider-did-not-supply-total-tokens")
                   (multiple-value-bind (cost cost-state cost-reason)
                       (aggregate-response-accounting (list response) :cost-usd
                                                     "provider-did-not-supply-authoritative-cost")
                     (list :model (or (completion-response-model response) "unavailable")
                           :provider (backend-name backend)
                           :request-id-present (not (null (completion-response-provider-request-id response)))
                           :outcome "completed"
                           :input-tokens input :input-tokens-state input-state :input-tokens-reason input-reason
                           :output-tokens output :output-tokens-state output-state :output-tokens-reason output-reason
                           :total-tokens total :total-tokens-state total-state :total-tokens-reason total-reason
                           :cost-usd cost :cost-usd-state cost-state :cost-usd-reason cost-reason))))))
           responses)))
    (multiple-value-bind (input input-state input-reason)
        (aggregate-response-accounting responses :prompt-tokens
                                      "one-or-more-invocations-missing-input-tokens")
      (multiple-value-bind (output output-state output-reason)
          (aggregate-response-accounting responses :completion-tokens
                                        "one-or-more-invocations-missing-output-tokens")
        (multiple-value-bind (total total-state total-reason)
            (aggregate-response-accounting responses :total-tokens
                                          "one-or-more-invocations-missing-total-tokens")
          (multiple-value-bind (cost cost-state cost-reason)
              (aggregate-response-accounting responses :cost-usd
                                            "one-or-more-invocations-missing-authoritative-cost")
            (list :provider-call-count (length responses)
                  :invocations invocations
                  :aggregate (list :input-tokens input :input-tokens-state input-state
                                   :input-tokens-reason input-reason
                                   :output-tokens output :output-tokens-state output-state
                                   :output-tokens-reason output-reason
                                   :total-tokens total :total-tokens-state total-state
                                   :total-tokens-reason total-reason
                                   :cost-usd cost :cost-usd-state cost-state
                                   :cost-usd-reason cost-reason))))))))

(defparameter *openrouter-request-timeout-seconds* 120
  "Wall-clock timeout in seconds for one OpenRouter HTTP completion request.

NIL disables the overall timeout. Connection establishment still uses
*OPENROUTER-CONNECTION-TIMEOUT-SECONDS*. Bound or set at runtime to tune hang
diagnosis without rebuilding the image.")

(defparameter *openrouter-connection-timeout-seconds* 30
  "Seconds to wait while establishing the OpenRouter TCP connection.

Passed to Drakma as :CONNECTION-TIMEOUT. NIL means no connection timeout.")

(defparameter *openrouter-error-body-limit* 800
  "Maximum characters of an OpenRouter error response body retained in logs/errors.")

(defparameter *openrouter-slow-request-warn-seconds* 30
  "Elapsed-seconds threshold above which a completed OpenRouter HTTP request is
flagged as slow (SLOW-P T, logged at :WARN). NIL disables slow-request warnings.
Tunable at runtime; reload_harness picks up new values.")

(defvar *provider-round* nil
  "Dynamically bound tool-loop round for the in-flight COMPLETE call, or NIL.

Bound in RUN-TOOL-LOOP so HTTP-boundary events emitted inside COMPLETE can carry
the round without changing the COMPLETE generic-function signature.")

(defun run-tool-loop (backend request handlers &key (max-rounds 60))
  "Run REQUEST through BACKEND, executing registered tool calls until completion.

HANDLERS is an alist of tool-name to function designator (function object or
symbol). Symbols are resolved on each tool call so reload_harness can replace
handler implementations mid-session.

MAX-ROUNDS is the effective tool-call round limit (no multiplier). The third
return value is the ordered provider-response trace required by the supervisor
accounting boundary; callers that only consume two values are unchanged.

Provider timing: PROVIDER-REQUEST is logged before COMPLETE starts, and
PROVIDER-RESPONSE includes DURATION-SECONDS so hangs waiting on the API are
visible even when the process is later killed."
  (let ((effective-max-rounds max-rounds))
    (labels ((tool-names-from-options (options)
               (let ((tools (getf options :tools)))
                 (when (listp tools)
                   (mapcar (lambda (tool)
                             (or (getf (getf tool :function) :name)
                                 (getf tool :name)
                                 "tool"))
                           tools))))
             (log-provider-request (current-request round)
               (let* ((messages (completion-request-messages current-request))
                      (names (tool-names-from-options
                              (completion-request-options current-request))))
                 (log-interaction :info "provider-request"
                                  :round round
                                  :model (completion-request-model current-request)
                                  :message-count (length messages)
                                  :tool-names (mapcar #'princ-to-string (or names '()))
                                  :timeout-seconds
                                  (or *openrouter-request-timeout-seconds* 0))))
             (log-provider-response (current-request round response duration-seconds)
               (let ((tool-calls (completion-response-tool-calls response)))
                 (log-interaction :info "provider-response"
                                  :round round
                                  :model (or (completion-response-model response)
                                             (completion-request-model current-request))
                                  :finish-reason (or (completion-response-finish-reason response)
                                                     "unknown")
                                  :tool-call-count (length tool-calls)
                                  :duration-seconds duration-seconds
                                  :response-text (completion-response-text response)
                                  :provider-request-id
                                  (or (completion-response-provider-request-id response)
                                      "none"))
                 (dolist (tool-call tool-calls)
                   (log-interaction :info "tool-call"
                                    :tool (or (getf tool-call :name) "unknown")
                                    :arguments (or (getf tool-call :arguments) "{}")
                                    :round round))))
             (run-next-round (current-request round responses)
               (log-provider-request current-request round)
               (let ((start (get-internal-real-time)))
                 (handler-case
                     (let* ((*provider-round* round)
                            (response (complete backend current-request)))
                       (log-provider-response current-request round response
                                              (elapsed-seconds-since start))
                       (if (null (completion-response-tool-calls response))
                           (values response
                                   (completion-request-messages current-request)
                                   (nreverse (cons response responses)))
                           (progn
                             (when (>= round effective-max-rounds)
                               (error "Tool-call loop exceeded its ~D round limit."
                                      effective-max-rounds))
                             (let* ((tool-calls (completion-response-tool-calls response))
                                    (next-messages
                                      (append (completion-request-messages current-request)
                                              (list (openrouter-assistant-tool-call-message response))
                                              (mapcar (lambda (tool-call)
                                                        (openrouter-tool-result-message tool-call handlers))
                                                      tool-calls)))
                                    (next-request
                                      (make-completion-request
                                       :model (completion-request-model current-request)
                                       :messages next-messages
                                       :options (completion-request-options current-request))))
                               (run-next-round next-request (1+ round)
                                               (cons response responses))))))
                   (error (condition)
                     (log-interaction :error "provider-request-failed"
                                      :round round
                                      :model (completion-request-model current-request)
                                      :duration-seconds (elapsed-seconds-since start)
                                      :message (princ-to-string condition))
                     (error condition))))))
      (run-next-round request 0 '()))))

(defun openrouter-log-url (url)
  "Return a host-only, credential-free form of URL for logging (FR-7.2)."
  (let* ((s (if (stringp url) url (princ-to-string url)))
         (scheme-end (search "://" s)))
    (if scheme-end
        (let* ((after (+ scheme-end 3))
               (slash (position #\/ s :start after)))
          (subseq s 0 (if slash slash (length s))))
        s)))

(defun openrouter-log-url-path (url)
  "Return URL with scheme, host, and path but no query string or credentials.

Extends OPENROUTER-LOG-URL (host-only) with the request path so operators can
see which endpoint was hit, while still honoring FR-7.2: any `user:pass@`
userinfo and any `?query`/`#fragment` are stripped so no credentials leak."
  (let* ((s (if (stringp url) url (princ-to-string url)))
         (scheme-end (search "://" s)))
    (if scheme-end
        (let* ((after (+ scheme-end 3))
               ;; Drop userinfo (anything up to and including an `@` before the
               ;; first path slash) so credentials never appear.
               (slash (or (position #\/ s :start after) (length s)))
               (at (position #\@ s :start after :end slash))
               (authority-start (if at (1+ at) after))
               (scheme (subseq s 0 after))
               (rest (subseq s authority-start))
               ;; Strip query and fragment.
               (cut (min (or (position #\? rest) (length rest))
                         (or (position #\# rest) (length rest)))))
          (concatenate 'string scheme (subseq rest 0 cut)))
        s)))

(defun elapsed-seconds-since (start-internal-real-time)
  "Return fractional seconds elapsed since START-INTERNAL-REAL-TIME."
  (/ (float (- (get-internal-real-time) start-internal-real-time) 0d0)
     internal-time-units-per-second))

(defun truncate-provider-error-body (text &optional (limit *openrouter-error-body-limit*))
  "Return TEXT scrubbed to a single-line snippet of at most LIMIT characters."
  (let* ((raw (if (stringp text) text (princ-to-string text)))
         (flattened (substitute #\Space #\Newline
                                (substitute #\Space #\Return raw)))
         (collapsed
           (with-output-to-string (out)
             (let ((previous-space nil))
               (loop for character across flattened do
                 (if (char= character #\Space)
                     (unless previous-space
                       (write-char #\Space out)
                       (setf previous-space t))
                     (progn
                       (write-char character out)
                       (setf previous-space nil)))))))
         (trimmed (string-trim '(#\Space #\Tab) collapsed))
         (limit (if (and (integerp limit) (plusp limit)) limit 800)))
    (if (<= (length trimmed) limit)
        trimmed
        (concatenate 'string (subseq trimmed 0 (- limit 3)) "..."))))

(defun openrouter-http-error-message (status-code body-text)
  "Build a concise OpenRouter HTTP error string including a body snippet."
  (let* ((snippet (truncate-provider-error-body body-text))
         (suffix (if (plusp (length snippet))
                     (format nil " body=~S" snippet)
                     "")))
    (format nil "OpenRouter request failed with HTTP status ~D.~A"
            status-code suffix)))

(defun call-with-openrouter-timeout (timeout-seconds thunk)
  "Run THUNK, optionally aborting after TIMEOUT-SECONDS wall-clock seconds.

On timeout, signal a SIMPLE-ERROR whose message mentions the timeout so chat
turns can log turn-failed with a diagnosable reason."
  (cond
    ((and (realp timeout-seconds) (plusp timeout-seconds))
     (handler-case
         (sb-ext:with-timeout timeout-seconds
           (funcall thunk))
       (sb-ext:timeout ()
         (error "OpenRouter request timed out after ~A seconds."
                timeout-seconds))))
    (t (funcall thunk))))

(defun openrouter-error-phase (condition body-received-p)
  "Classify CONDITION into an HTTP-boundary phase for PROVIDER-HTTP-ERROR.

Returns one of \"connect\", \"read-timeout\", \"parse\", or \"unknown\".
BODY-RECEIVED-P is true once the HTTP response body was read (so a later failure
is a parse phase, not a transport phase). HTTP-status errors are logged inline
and never reach this classifier."
  (cond
    ;; Our own SB-EXT:WITH-TIMEOUT fired: the whole request exceeded
    ;; *OPENROUTER-REQUEST-TIMEOUT-SECONDS* while awaiting the response.
    ((typep condition 'sb-ext:timeout) "read-timeout")
    ;; Anything that failed before the body was read is a transport/connect
    ;; problem (connection refused, DNS, socket, or a usocket connect timeout).
    ((not body-received-p)
     (let ((name (string-downcase (princ-to-string (type-of condition)))))
       (if (or (search "connection" name)
               (search "connect" name)
               (search "usocket" name)
               (search "host" name)
               (search "dns" name)
               (search "socket" name)
               (search "timeout" name))
           "connect"
           "unknown")))
    ;; Body was received but a later step (JSON decode) failed.
    (t "parse")))

(defmethod complete ((backend openrouter-backend) request)
  "POST REQUEST to OpenRouter with timeout and durable HTTP-boundary logging.

Emits HTTP-REQUEST-STARTED immediately before the blocking transport call and
HTTP-REQUEST-COMPLETED after it returns (before JSON parse), each carrying an
ATTEMPT-ID and the tool-loop ROUND, to both the JSONL and text `.log` sinks. A
process killed mid-hang therefore leaves an HTTP-REQUEST-STARTED with no matching
completion/error. Transport/HTTP failures log exactly one PROVIDER-HTTP-ERROR
with PHASE and ERROR-CLASS before the condition is re-signaled.

Successful responses are returned as COMPLETION-RESPONSE values."
  (let ((api-key (openrouter-backend-api-key backend)))
    (unless (and (stringp api-key) (plusp (length api-key)))
      (error "OPENROUTER_API_KEY is required for OpenRouter requests."))
    (let* ((url (openrouter-completions-url backend))
           (log-url (openrouter-log-url url))
           (log-url-path (openrouter-log-url-path url))
           (timeout *openrouter-request-timeout-seconds*)
           (connection-timeout *openrouter-connection-timeout-seconds*)
           (round *provider-round*)
           (attempt-id (uuid-v4-string))
           (octets (openrouter-request-octets request))
           (request-bytes (length octets))
           (request-json (openrouter-request-json request))
           (request-chars (if (stringp request-json) (length request-json) 0))
           (body-received-p nil)
           (start (get-internal-real-time)))
      (log-interaction :info "http-request-started"
                       :attempt-id attempt-id
                       :round (or round 0)
                       :model (completion-request-model request)
                       :url log-url
                       :url-path log-url-path
                       :timeout-seconds (or timeout 0)
                       :connection-timeout-seconds (or connection-timeout 0)
                       :request-bytes request-bytes
                       :request-chars request-chars
                       :request-snippet request-json)
      (log-http-text :info "http-request-started"
                     "attempt=~A model=~A url=~A timeout=~As conn-timeout=~As bytes=~D chars=~D"
                     attempt-id (completion-request-model request) log-url-path
                     (or timeout "none") (or connection-timeout "none")
                     request-bytes request-chars)
      (handler-case
          (call-with-openrouter-timeout
           timeout
           (lambda ()
             (multiple-value-bind (body status-code response-headers)
                 (drakma:http-request
                  url
                  :method :post
                  :content octets
                  :content-type "application/json; charset=utf-8"
                  :connection-timeout connection-timeout
                  :additional-headers
                  `(("Authorization" . ,(format nil "Bearer ~A" api-key))))
               (declare (ignore response-headers))
               (setf body-received-p t)
               (let* ((body-text (openrouter-response-body-string body))
                      (duration (elapsed-seconds-since start))
                      (body-bytes (openrouter-response-body-bytes body))
                      (body-chars (if (stringp body-text) (length body-text) 0))
                      (slow-p (and (realp *openrouter-slow-request-warn-seconds*)
                                   (plusp *openrouter-slow-request-warn-seconds*)
                                   (> duration *openrouter-slow-request-warn-seconds*)))
                      (level (if slow-p :warn :info)))
                 (log-interaction level "http-request-completed"
                                  :attempt-id attempt-id
                                  :round (or round 0)
                                  :model (completion-request-model request)
                                  :status-code status-code
                                  :duration-seconds duration
                                  :body-bytes body-bytes
                                  :body-chars body-chars
                                  :slow-p (and slow-p t))
                 (log-http-text level "http-request-completed"
                                "attempt=~A status=~D duration=~,3Fs bytes=~D chars=~D~A"
                                attempt-id status-code duration body-bytes body-chars
                                (if slow-p " SLOW" ""))
                 (unless (<= 200 status-code 299)
                   (let ((message (openrouter-http-error-message status-code body-text)))
                     (log-interaction :error "provider-http-error"
                                      :attempt-id attempt-id
                                      :round (or round 0)
                                      :phase "http-status"
                                      :error-class "http-status"
                                      :model (completion-request-model request)
                                      :status-code status-code
                                      :duration-seconds duration
                                      :timeout-seconds (or timeout 0)
                                      :message message
                                      :body-snippet
                                      (truncate-provider-error-body body-text)
                                      ;; Include the outgoing request body so a
                                      ;; malformed-request 4xx (e.g. a serializer
                                      ;; bug producing invalid JSON) is
                                      ;; diagnosable from the error event itself,
                                      ;; not only the separate http-request-started.
                                      :request-bytes request-bytes
                                      :request-snippet request-json)
                     (log-http-text :error "provider-http-error"
                                    "attempt=~A phase=http-status status=~D duration=~,3Fs request-bytes=~D ~A"
                                    attempt-id status-code duration request-bytes message)
                     (error "~A" message)))
                 (openrouter-response-from-json (yason:parse body-text))))))
        (error (condition)
          ;; Ensure transport/timeout/parse failures always leave a durable
          ;; breadcrumb. HTTP-status errors were logged inline above; detect and
          ;; do not double-log them.
          (let* ((text (princ-to-string condition))
                 (http-status-error
                   (search "OpenRouter request failed with HTTP status" text)))
            (unless http-status-error
              (let ((phase (openrouter-error-phase condition body-received-p))
                    (duration (elapsed-seconds-since start))
                    (error-class (string-downcase (princ-to-string (type-of condition)))))
                (log-interaction :error "provider-http-error"
                                 :attempt-id attempt-id
                                 :round (or round 0)
                                 :phase phase
                                 :error-class error-class
                                 :model (completion-request-model request)
                                 :duration-seconds duration
                                 :timeout-seconds (or timeout 0)
                                 :message (truncate-provider-error-body text))
                (log-http-text :error "provider-http-error"
                               "attempt=~A phase=~A class=~A duration=~,3Fs ~A"
                               attempt-id phase error-class duration
                               (truncate-provider-error-body text))))
            (error condition)))))))
