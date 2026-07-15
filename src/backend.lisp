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
     :usage (list :prompt-tokens (openrouter-json-field usage "prompt_tokens")
                  :completion-tokens
                  (openrouter-json-field usage "completion_tokens")
                  :total-tokens (openrouter-json-field usage "total_tokens")))))

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

(defun openrouter-tool-handler (handlers name)
  (cdr (assoc name handlers :test #'string=)))

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
  (let ((handler (openrouter-tool-handler handlers (getf tool-call :name))))
    (unless handler
      (error "No handler is registered for tool ~S." (getf tool-call :name)))
    (let* ((arguments (openrouter-tool-arguments tool-call))
           (result
             (handler-case
                 (funcall handler arguments)
               (error ()
                 (format nil "TOOL_ERROR: Tool ~A failed."
                         (getf tool-call :name))))))
      (list :role "tool"
            :tool-call-id (getf tool-call :id)
            :content (openrouter-tool-result-content result)))))

(defun run-tool-loop (backend request handlers &key (max-rounds 8))
  "Run REQUEST through BACKEND, executing registered tool calls until completion."
  (labels ((run-next-round (current-request round)
             (let ((response (complete backend current-request)))
               (if (null (completion-response-tool-calls response))
                   (values response (completion-request-messages current-request))
                   (progn
                     (when (>= round max-rounds)
                       (error "Tool-call loop exceeded its ~D round limit." max-rounds))
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
                       (run-next-round next-request (1+ round))))))))
    (run-next-round request 0)))

(defmethod complete ((backend openrouter-backend) request)
  (let ((api-key (openrouter-backend-api-key backend)))
    (unless (and (stringp api-key) (plusp (length api-key)))
      (error "OPENROUTER_API_KEY is required for OpenRouter requests."))
    (multiple-value-bind (body status-code response-headers)
        (drakma:http-request
         (openrouter-completions-url backend)
         :method :post
         :content (openrouter-request-octets request)
         :content-type "application/json; charset=utf-8"
         :additional-headers
         `(("Authorization" . ,(format nil "Bearer ~A" api-key))))
      (declare (ignore response-headers))
      (unless (<= 200 status-code 299)
        (error "OpenRouter request failed with HTTP status ~D." status-code))
      (openrouter-response-from-json
       (yason:parse (openrouter-response-body-string body))))))
