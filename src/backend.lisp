(in-package #:self-improving-agent-harness)

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

(defun openrouter-json-value (value)
  (cond
    ((and (listp value) (keywordp (first value)))
     (let ((object (make-hash-table :test #'equal)))
       (loop for (key item) on value by #'cddr
             do (setf (gethash (openrouter-json-name key) object)
                      (openrouter-json-value item)))
       object))
    ((listp value) (mapcar #'openrouter-json-value value))
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
           (content (openrouter-tool-result-content result)))
      (log-interaction :info "tool-completed"
                       :tool (or name "unknown")
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
                     (let ((response (complete backend current-request)))
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

(defmethod complete ((backend openrouter-backend) request)
  "POST REQUEST to OpenRouter with timeout and durable HTTP failure logging.

Successful responses are returned as COMPLETION-RESPONSE values. Transport
failures log PROVIDER-HTTP-ERROR with duration/status/body snippet before the
condition is re-signaled for the chat turn failure path."
  (let ((api-key (openrouter-backend-api-key backend)))
    (unless (and (stringp api-key) (plusp (length api-key)))
      (error "OPENROUTER_API_KEY is required for OpenRouter requests."))
    (let* ((url (openrouter-completions-url backend))
           (timeout *openrouter-request-timeout-seconds*)
           (connection-timeout *openrouter-connection-timeout-seconds*)
           (start (get-internal-real-time)))
      (handler-case
          (call-with-openrouter-timeout
           timeout
           (lambda ()
             (multiple-value-bind (body status-code response-headers)
                 (drakma:http-request
                  url
                  :method :post
                  :content (openrouter-request-octets request)
                  :content-type "application/json; charset=utf-8"
                  :connection-timeout connection-timeout
                  :additional-headers
                  `(("Authorization" . ,(format nil "Bearer ~A" api-key))))
               (declare (ignore response-headers))
               (let* ((body-text (openrouter-response-body-string body))
                      (duration (elapsed-seconds-since start)))
                 (unless (<= 200 status-code 299)
                   (let ((message (openrouter-http-error-message status-code body-text)))
                     (log-interaction :error "provider-http-error"
                                      :model (completion-request-model request)
                                      :status-code status-code
                                      :duration-seconds duration
                                      :timeout-seconds (or timeout 0)
                                      :message message
                                      :body-snippet
                                      (truncate-provider-error-body body-text))
                     (error "~A" message)))
                 (openrouter-response-from-json (yason:parse body-text))))))
        (error (condition)
          ;; Ensure transport/timeout failures always leave a durable breadcrumb
          ;; even when the caller has not yet logged provider-response.
          (let* ((text (princ-to-string condition))
                 (already-logged
                   (or (search "OpenRouter request failed with HTTP status" text)
                       (search "provider-http-error" text))))
            (unless already-logged
              (log-interaction :error "provider-http-error"
                               :model (completion-request-model request)
                               :duration-seconds (elapsed-seconds-since start)
                               :timeout-seconds (or timeout 0)
                               :message (truncate-provider-error-body text)))
            (error condition)))))))
