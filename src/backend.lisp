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

(defclass synthetic-backend (openrouter-backend) ()
  (:documentation "Synthetic's OpenAI-compatible Chat Completions backend.

This deliberately reuses the proven OpenAI-compatible serialization and
tool-call protocol while retaining a distinct provider identity, base URL, and
SYNTHETIC_API_KEY credential boundary."))

(defun make-openrouter-backend (&key api-key
                                  (base-url "https://openrouter.ai/api/v1"))
  "Construct an OpenRouter backend configuration without performing I/O."
  (make-instance 'openrouter-backend
                 :name "openrouter"
                 :api-key api-key
                 :base-url base-url))

(defun make-synthetic-backend (&key api-key
                                 (base-url "https://api.synthetic.new/openai/v1"))
  "Construct a Synthetic OpenAI-compatible backend without performing I/O."
  (make-instance 'synthetic-backend
                 :name "synthetic"
                 :api-key api-key
                 :base-url base-url))

(defun synthetic-backend-base-url (backend)
  "Return BACKEND's configured Synthetic OpenAI-compatible base URL."
  (openrouter-backend-base-url backend))

(defun synthetic-backend-api-key (backend)
  "Return BACKEND's runtime Synthetic API key. Never log this value."
  (openrouter-backend-api-key backend))

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
                      ;; JSON Schema requires a present `required` member to be
                      ;; an array. YASON encodes Lisp NIL as null, so represent
                      ;; an explicitly empty required list as an empty vector.
                      (if (and (eq key :required) (null item))
                          #()
                          (openrouter-json-value item))))
       object))
    ((listp value) (mapcar #'openrouter-json-value value))
    ((stringp value) (sanitize-json-control-characters value))
    (t value)))

(defun openrouter-request-json (request)
  "Serialize REQUEST to OpenRouter's JSON field naming convention."
  (with-output-to-string (stream)
    (yason:encode (openrouter-json-value (openrouter-request-payload request))
                  stream)))

(defun synthetic-request-json (request)
  "Serialize REQUEST to Synthetic's OpenAI-compatible JSON contract."
  (openrouter-request-json request))

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

(defun openrouter-message-text (message)
  "Extract plain assistant/user text from a provider message object.

CONTENT may be a string, null, or an OpenAI-style array of parts
({type:text,text:...}, ...). Non-text parts are ignored. Returns an empty string when no
usable text is present so callers never see NIL content."
  (let ((content (openrouter-json-field message "content")))
    (cond
      ((null content) "")
      ((stringp content) content)
      ((or (listp content) (vectorp content))
       (with-output-to-string (out)
         (dolist (part (openrouter-list content))
           (let* ((ptype (openrouter-json-field part "type"))
                  (text (or (openrouter-json-field part "text")
                            (openrouter-json-field part "content"))))
             (when (and (stringp text)
                        (plusp (length text))
                        (or (null ptype)
                            (string= ptype "text")
                            (string= ptype "output_text")))
               (write-string text out))))))
      (t (princ-to-string content)))))

(defun empty-completion-text-p (text)
  "True when TEXT is missing or only whitespace."
  (or (null text)
      (and (stringp text)
           (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) text))))))

(defun truncated-empty-final-response-p (response)
  "True when RESPONSE ended the tool loop with finish_reason=length and no text.

Observed with reasoning-heavy models (e.g. GLM via Synthetic): a large HTTP body
can still normalize to empty message.content when the model exhausts max_tokens
on hidden/reasoning tokens. Treating that as a successful final answer makes the
chat look dead (blank stdout + <<< DONE)."
  (and response
       (let ((calls (completion-response-tool-calls response)))
         (or (null calls) (zerop (length calls))))
       (let ((reason (completion-response-finish-reason response)))
         (and (stringp reason) (string-equal reason "length")))
       (empty-completion-text-p (completion-response-text response))))

(defparameter *tool-loop-length-retry-limit* 1
  "How many times RUN-TOOL-LOOP may auto-continue after an empty finish_reason=length
final response before synthesizing a visible diagnostic answer.

0 disables auto-continue (still synthesizes a diagnostic). Bound or set at runtime.")

(defparameter +truncated-empty-final-nudge+
  "HARNESS: Your previous completion hit finish_reason=length with empty message content (no tool calls and no user-visible text). This usually means max_tokens was consumed by reasoning or an unfinished answer. Continue from the current task and produce either a concise final answer or a smaller native tool call. Do not repeat large tool outputs."
  "User message injected to recover from an empty truncated final response.")

(defun synthesize-truncated-empty-final-response (response)
  "Return RESPONSE rewritten with a visible diagnostic final text.

Preserves model/raw/usage/finish-reason so accounting and logs stay accurate."
  (make-completion-response
   :text (format nil
                 "[harness] Model returned finish_reason=length with empty content ~
(no tool calls). The turn produced no user-visible answer—often because ~
max_tokens was exhausted by reasoning or a truncated draft. Retry with a ~
smaller next step, raise max_tokens, or continue the task explicitly.")
   :model (completion-response-model response)
   :raw (completion-response-raw response)
   :tool-calls (completion-response-tool-calls response)
   :finish-reason (completion-response-finish-reason response)
   :provider-request-id (completion-response-provider-request-id response)
   :usage (completion-response-usage response)))

(defun openrouter-response-from-json (raw-response)
  "Normalize one decoded, non-streaming OpenRouter response alist."
  (let* ((choice (first (openrouter-list
                         (openrouter-json-field raw-response "choices"))))
         (message (openrouter-json-field choice "message"))
         (usage (openrouter-json-field raw-response "usage")))
    (make-completion-response
     :text (openrouter-message-text message)
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

(defun synthetic-completions-url (backend)
  "Return Synthetic's Chat Completions endpoint for BACKEND."
  (openrouter-completions-url backend))

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

(defun truncate-for-tool-display (text &optional (max-chars 80))
  "Return TEXT limited to MAX-CHARS for console display, appending an ellipsis.

Shared by the centralized TOOL_CALL/TOOL_DONE markers so every tool gets a
bounded, consistent preview without each handler reimplementing truncation."
  (if (and (stringp text) (> (length text) max-chars))
      (concatenate 'string (subseq text 0 max-chars) "...")
      (or text "")))

(defun emit-tool-call-marker (name arguments-json)
  "Print the standard TOOL_CALL console marker (stderr) for any tool.

Centralizing this in OPENROUTER-TOOL-RESULT-MESSAGE means every registered tool
gets a visible spawn line on the console without each handler emitting its own."
  (format *error-output*
          "TOOL_CALL name=~A arguments=~S~%"
          (or name "unknown")
          (truncate-for-tool-display arguments-json 120))
  (finish-output *error-output*))

(defun emit-tool-done-marker (name status duration-seconds result)
  "Print the standard TOOL_DONE console marker (stderr) for any tool.

STATUS is a short label such as ok, error, or recovered. RESULT is the
already-truncated tool result content for preview."
  (format *error-output*
          "TOOL_DONE name=~A status=~A duration_seconds=~,3F result=~S~%"
          (or name "unknown") status duration-seconds
          (truncate-for-tool-display result 120))
  (finish-output *error-output*))

(defun openrouter-tool-result-message (tool-call handlers)
  (let* ((name (getf tool-call :name))
         (synthetic (getf tool-call :synthetic-result)))
    ;; Recovered truncated/malformed text tool calls carry SYNTHETIC-RESULT and
    ;; must not execute a handler (the command payload may be incomplete).
    (if (stringp synthetic)
        (let* ((call-start (get-internal-real-time))
               (content (truncate-tool-result-content synthetic)))
          (emit-tool-call-marker name (or (getf tool-call :arguments) "{}"))
          (log-interaction :error "tool-failed"
                           :tool (or name "unknown")
                           :tool-call-id (or (getf tool-call :id) "none")
                           :reason "text-tool-call-recovery"
                           :recovery (let ((r (getf tool-call :recovery)))
                                       (when r (string-downcase (symbol-name r))))
                           :arguments (or (getf tool-call :arguments) "{}")
                           :tool-result content
                           :output-length (length content))
          (emit-tool-done-marker name "recovered"
                                  (/ (float (- (get-internal-real-time) call-start) 0d0)
                                     internal-time-units-per-second)
                                  content)
          (list :role "tool"
                :tool-call-id (getf tool-call :id)
                :content content))
        (let ((handler (openrouter-tool-handler handlers name)))
          (unless handler
            (error "No handler is registered for tool ~S." name))
          (let* ((arguments (openrouter-tool-arguments tool-call))
                 (arg-text
                   (handler-case
                       (with-output-to-string (stream)
                         (yason:encode arguments stream))
                     (error () (princ-to-string (getf tool-call :arguments)))))
                 (call-start (get-internal-real-time)))
            (emit-tool-call-marker name arg-text)
            (let* ((result
                     (handler-case
                         (funcall handler arguments)
                       (error ()
                         (format nil "TOOL_ERROR: Tool ~A failed." name))))
                   (content (truncate-tool-result-content
                             (openrouter-tool-result-content result)))
                   (duration (/ (float (- (get-internal-real-time) call-start) 0d0)
                               internal-time-units-per-second)))
              (log-interaction :info "tool-completed"
                               :tool (or name "unknown")
                               :tool-call-id (or (getf tool-call :id) "none")
                               :arguments arg-text
                               :tool-result (if (stringp content) content (princ-to-string content))
                               :output-length (if (stringp content) (length content) 0)
                               :recovery (let ((r (getf tool-call :recovery)))
                                           (when r (string-downcase (symbol-name r)))))
              (emit-tool-done-marker name
                                     (if (search "TOOL_ERROR" (or content "")) "error" "ok")
                                     duration content)
              (list :role "tool"
                    :tool-call-id (getf tool-call :id)
                    :content content)))))))

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

(defparameter *openai-compatible-provider-label* "OpenRouter"
  "Provider label for dynamic OpenAI-compatible transport diagnostics.

OPENROUTER-BACKEND keeps the default. SYNTHETIC-BACKEND dynamically binds this
to Synthetic around the inherited, protocol-identical transport method.")

(defparameter *openai-compatible-key-environment-variable* "OPENROUTER_API_KEY"
  "Credential name used only in safe missing-credential diagnostics.")

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


(defun text-embedded-tool-call-prefix-p (text)
  "Return true when TEXT appears to contain an XML-ish embedded tool call."
  (and (stringp text)
       (or (search "<tool_call>" text :test #'char-equal)
           (search "<|tool_call_begin|>" text)
           (search "<run_shell><![CDATA[" text :test #'char-equal))))

(defun parse-cdata-run-shell-tool-call (text)
  "Recover Qwen's complete <run_shell><![CDATA[COMMAND]]></run_shell> dialect."
  (let ((open (search "<run_shell><![CDATA[" text :test #'char-equal)))
    (when open
      (let* ((start (+ open (length "<run_shell><![CDATA[")))
             (end (search "]]></run_shell>" text :start2 start :test #'char-equal)))
        (when (and end (> end start))
          (let ((command (subseq text start end)))
            (values (list (make-recovered-tool-call "run_shell"
                                                    (encode-tool-arguments-json (list (cons "command" command)))
                                                    :recovery :cdata-run-shell))
                    (string-trim '(#\Space #\Tab #\Newline #\Return) (subseq text 0 open))
                    :cdata-run-shell)))))))

(defun parse-kimi-text-tool-calls (text)
  "Recover complete Kimi sentinel tool markup without guessing arguments.

Accepted shape: <|tool_call_begin|>functions.NAME:INDEX
<|tool_call_argument_begin|>JSON<|tool_call_end|>.  JSON remains subject to
normal tool schema validation before execution."
  (let ((begin (search "<|tool_call_begin|>" text))
        (section (search "<|tool_calls_section_begin|>" text)))
    (when begin
      (let* ((name-start (+ begin (length "<|tool_call_begin|>")))
             (argument-marker (or (search "<|tool_call_argument_begin|>" text :start2 name-start) -1))
             (end (and (>= argument-marker 0) (search "<|tool_call_end|>" text :start2 (+ argument-marker (length "<|tool_call_argument_begin|>")))))
             (raw-name (and (>= argument-marker 0) (string-trim '(#\Space #\Tab #\Newline #\Return) (subseq text name-start argument-marker))))
             (name (and raw-name (let* ((without-prefix (if (and (>= (length raw-name) 10) (string-equal "functions." raw-name :end2 10)) (subseq raw-name 10) raw-name))
                                        (colon (position #\: without-prefix)))
                                   (if colon (subseq without-prefix 0 colon) without-prefix))))
             (argument-start (+ argument-marker (length "<|tool_call_argument_begin|>")))
             (arguments (and end (string-trim '(#\Space #\Tab #\Newline #\Return) (subseq text argument-start end)))))
        (when (and name end arguments (plusp (length arguments)) (char= (char arguments 0) #\{))
          (values (list (make-recovered-tool-call name arguments :recovery :kimi-sentinel))
                  (string-trim '(#\Space #\Tab #\Newline #\Return) (subseq text 0 (or section begin)))
                  :kimi-sentinel))))))

(defun parse-text-embedded-tool-call-arguments (body)
  "Parse zero or more <arg_key>/<arg_value> pairs from BODY into an alist.

Returns the alist, or :INCOMPLETE when markup is truncated/unclosed."
  (let ((cursor 0)
        (pairs '()))
    (loop
      (let ((key-open (search "<arg_key>" body :start2 cursor :test #'char-equal)))
        (unless key-open
          (return))
        (let* ((key-start (+ key-open (length "<arg_key>")))
               (key-close (search "</arg_key>" body :start2 key-start :test #'char-equal)))
          (unless key-close
            (return-from parse-text-embedded-tool-call-arguments :incomplete))
          (let* ((key (string-trim '(#\Space #\Tab #\Newline #\Return)
                                   (subseq body key-start key-close)))
                 (value-open (search "<arg_value>" body
                                     :start2 (+ key-close (length "</arg_key>"))
                                     :test #'char-equal)))
            (unless value-open
              (return-from parse-text-embedded-tool-call-arguments :incomplete))
            (let* ((value-start (+ value-open (length "<arg_value>")))
                   (value-close (search "</arg_value>" body
                                        :start2 value-start
                                        :test #'char-equal)))
              (unless value-close
                (return-from parse-text-embedded-tool-call-arguments :incomplete))
              (push (cons key (subseq body value-start value-close)) pairs)
              (setf cursor (+ value-close (length "</arg_value>"))))))))
    (nreverse pairs)))

(defun encode-tool-arguments-json (pairs)
  "Encode PARS alist as a JSON object string for tool-call arguments."
  (with-output-to-string (stream)
    (let ((object (make-hash-table :test #'equal)))
      (dolist (pair pairs)
        (setf (gethash (car pair) object) (cdr pair)))
      (yason:encode object stream))))

(defun make-recovered-tool-call (name arguments-json &key (recovery :xml-text)
                                                    synthetic-result)
  "Build a normalized tool-call plist, optionally with a non-executing result."
  (list :id (format nil "recovered-~A"
                    (string-downcase (symbol-name (gensym "TC"))))
        :type "function"
        :name name
        :arguments (or arguments-json "{}")
        :recovery recovery
        :synthetic-result synthetic-result))

(defun parse-controlled-text-tool-call-attributes (tool-name body)
  "Safely recover RUN_SHELL COMMAND='...' from a closed malformed text call.

This narrow compatibility path never infers missing values or accepts unquoted
arguments; callers only use it for a complete </tool_call> block."
  (when (string-equal tool-name "run_shell")
    (let ((start (search "command=" body :test #'char-equal)))
      (when start
        (let* ((quote-index (+ start (length "command=")))
               (quote (and (< quote-index (length body))
                           (char body quote-index))))
          (when (member quote '(#\' #\"))
            (let ((end (position quote body :start (1+ quote-index))))
              (when (and end (> end (1+ quote-index)))
                (list (cons "command" (subseq body (1+ quote-index) end)))))))))))

(defun parse-text-embedded-tool-calls (text)
  "Parse XML-ish <tool_call> blocks from TEXT.

Returns three values:
  1. list of normalized tool-call plists (possibly empty)
  2. leading prose before the first tool_call, or NIL
  3. recovery status: NIL, :XML-TEXT, or :TRUNCATED

Complete calls become tool-call plists with :RECOVERY :XML-TEXT.
Incomplete markup yields one synthetic tool-call with :SYNTHETIC-RESULT set so
the tool loop can return an error without executing a handler."
  (unless (text-embedded-tool-call-prefix-p text)
    (return-from parse-text-embedded-tool-calls (values '() nil nil)))
  (let* ((start (search "<tool_call>" text :test #'char-equal))
         (leading (when (and start (plusp start))
                    (string-right-trim
                     '(#\Space #\Tab #\Newline #\Return)
                     (subseq text 0 start))))
         (cursor start)
         (calls '())
         (status nil))
    (loop while (and cursor (< cursor (length text)))
          do (let ((open (search "<tool_call>" text :start2 cursor :test #'char-equal)))
               (unless open
                 (return))
               (let ((name-start (+ open (length "<tool_call>"))))
                 (loop while (and (< name-start (length text))
                                  (find (char text name-start)
                                        '(#\Space #\Tab #\Newline #\Return)))
                       do (incf name-start))
                 (let ((name-end name-start))
                   (loop while (and (< name-end (length text))
                                    (let ((ch (char text name-end)))
                                      (or (alphanumericp ch)
                                          (find ch "_-"))))
                         do (incf name-end))
                   (let ((name (string-trim '(#\Space #\Tab #\Newline #\Return)
                                            (subseq text name-start name-end))))
                     (when (zerop (length name))
                       (setf status :truncated)
                       (push (make-recovered-tool-call
                              "unknown"
                              "{}"
                              :recovery :truncated
                              :synthetic-result
                              "TOOL_ERROR: Truncated or malformed text tool call was not executed. Use the native tools/tool_calls API, not <tool_call> XML. For run_shell, call function name run_shell with JSON arguments {\"command\":\"pwd\"}; do not put arguments in markup.")
                             calls)
                       (return))
                     (let* ((close (search "</tool_call>" text
                                           :start2 name-end
                                           :test #'char-equal))
                            (body-end (or close (length text)))
                            (body (subseq text name-end body-end))
                            (pairs (parse-text-embedded-tool-call-arguments body)))
                       (cond
                         ((and close (null pairs)
                               (parse-controlled-text-tool-call-attributes name body))
                          (setf status (or status :controlled-text))
                          (push (make-recovered-tool-call
                                 name
                                 (encode-tool-arguments-json
                                  (parse-controlled-text-tool-call-attributes name body))
                                 :recovery :controlled-text)
                                calls)
                          (setf cursor (+ close (length "</tool_call>"))))
                         ((or (eq pairs :incomplete) (null close))
                          (setf status :truncated)
                          (push (make-recovered-tool-call
                                 name
                                 "{}"
                                 :recovery :truncated
                                 :synthetic-result
                                 (format nil
                                         "TOOL_ERROR: Truncated text tool call for ~A was not executed (incomplete <tool_call> markup or finish_reason=length). Retry using native tool_calls: function name ~A with a JSON arguments object (for run_shell: {\"command\":\"pwd\"}), never XML markup."
                                         name name))
                                calls)
                          (return))
                         (t
                          (setf status (or status :xml-text))
                          (push (make-recovered-tool-call
                                 name
                                 (encode-tool-arguments-json pairs)
                                 :recovery :xml-text)
                                calls)
                          (setf cursor (+ close (length "</tool_call>")))))))))))
    (values (nreverse calls)
            (and leading (plusp (length leading)) leading)
            status)))


(defun maybe-recover-text-embedded-tool-calls (response)
  "If RESPONSE has no structured tool-calls, recover XML-ish calls from text.

Native message.tool_calls always win. Recovery is a compatibility fallback for
providers/models that emit <tool_call>/<arg_key>/<arg_value> markup in content
instead of the OpenAI-compatible tool_calls array. Incomplete markup never
executes a handler; it becomes a synthetic error tool result."
  (let ((existing (completion-response-tool-calls response))
        (text (completion-response-text response))
        (finish (completion-response-finish-reason response)))
    (cond
      ((and existing (plusp (length existing)))
       response)
      ((not (text-embedded-tool-call-prefix-p text))
       response)
      (t
       (multiple-value-bind (calls leading status)
           (cond ((search "<|tool_call_begin|>" text)
                  (parse-kimi-text-tool-calls text))
                 ((search "<run_shell><![CDATA[" text :test #'char-equal)
                  (parse-cdata-run-shell-tool-call text))
                 (t (parse-text-embedded-tool-calls text)))
         (if (null calls)
             response
             (progn
               (log-interaction :warn "tool-call-text-recovery"
                                :recovery (string-downcase (symbol-name status))
                                :finish-reason (or finish "unknown")
                                :tool-call-count (length calls)
                                :tool-names (mapcar (lambda (call)
                                                      (or (getf call :name) "unknown"))
                                                    calls)
                                :response-text text)
               (make-completion-response
                :text (or leading "")
                :model (completion-response-model response)
                :raw (completion-response-raw response)
                :tool-calls calls
                :finish-reason finish
                :provider-request-id (completion-response-provider-request-id response)
                :usage (completion-response-usage response)))))))))


(defun run-tool-loop (backend request handlers &key (max-rounds 60) observer)
  "Run REQUEST through BACKEND, executing registered tool calls until completion.

HANDLERS is an alist of tool-name to function designator (function object or
symbol). Symbols are resolved on each tool call so reload_harness can replace
handler implementations mid-session.

MAX-ROUNDS is the requested tool-call round limit; the effective limit is 3x this value. The third
return value is the ordered provider-response trace required by the supervisor
accounting boundary; callers that only consume two values are unchanged.

Provider timing: PROVIDER-REQUEST is logged before COMPLETE starts, and
PROVIDER-RESPONSE includes DURATION-SECONDS so hangs waiting on the API are
visible even when the process is later killed."
  (let ((effective-max-rounds (* 3 max-rounds)))
    (labels ((emit-observer (kind &rest fields)
               (when observer
                 (apply observer kind fields)))
             (tool-names-from-options (options)
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
                                  (or *openrouter-request-timeout-seconds* 0))
                 (emit-observer "provider-round-started"
                                :round round
                                :model (completion-request-model current-request))))
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
                                    :round round))
                 (emit-observer "provider-round-completed"
                                :round round
                                :model (or (completion-response-model response)
                                           (completion-request-model current-request))
                                :finish-reason (or (completion-response-finish-reason response)
                                                   "unknown"))))
             (run-next-round (current-request round responses length-retries)
               (log-provider-request current-request round)
               (let ((start (get-internal-real-time)))
                 (handler-case
                     (let* ((*provider-round* round)
                            (response (maybe-recover-text-embedded-tool-calls
                                       (complete backend current-request))))
                       (log-provider-response current-request round response
                                              (elapsed-seconds-since start))
                       (cond
                         ((completion-response-tool-calls response)
                          (when (>= round effective-max-rounds)
                            (error "Tool-call loop exceeded its ~D round limit."
                                   effective-max-rounds))
                          (let* ((tool-calls (completion-response-tool-calls response))
                                 (next-messages
                                   (append (completion-request-messages current-request)
                                           (list (openrouter-assistant-tool-call-message response))
                                           (mapcar (lambda (tool-call)
                                                     (emit-observer "tool-call-started"
                                                                    :round round
                                                                    :tool-call-id (getf tool-call :id)
                                                                    :tool-name (getf tool-call :name)
                                                                    :arguments (getf tool-call :arguments))
                                                     (let ((tool-result
                                                             (openrouter-tool-result-message tool-call handlers)))
                                                       (emit-observer "tool-call-completed"
                                                                      :round round
                                                                      :tool-call-id (getf tool-call :id)
                                                                      :tool-name (getf tool-call :name)
                                                                      :result (getf tool-result :content))
                                                       tool-result))
                                                   tool-calls)))
                                 (next-request
                                   (make-completion-request
                                    :model (completion-request-model current-request)
                                    :messages next-messages
                                    :options (completion-request-options current-request))))
                            (run-next-round next-request (1+ round)
                                            (cons response responses)
                                            length-retries)))
                         ((and (truncated-empty-final-response-p response)
                               (integerp *tool-loop-length-retry-limit*)
                               (< length-retries *tool-loop-length-retry-limit*)
                               (< round effective-max-rounds))
                          ;; Empty finish_reason=length is not a successful final
                          ;; answer. Nudge once (by default) so the model can emit
                          ;; visible text or a smaller tool call instead of a blank turn.
                          (log-interaction :warn "provider-empty-length-retry"
                                           :round round
                                           :model (or (completion-response-model response)
                                                      (completion-request-model current-request))
                                           :finish-reason
                                           (or (completion-response-finish-reason response)
                                               "length")
                                           :length-retry (1+ length-retries)
                                           :length-retry-limit *tool-loop-length-retry-limit*)
                          (let* ((next-messages
                                   (append (completion-request-messages current-request)
                                           (list (list :role "assistant"
                                                       :content
                                                       (or (completion-response-text response) ""))
                                                 (list :role "user"
                                                       :content +truncated-empty-final-nudge+))))
                                 (next-request
                                   (make-completion-request
                                    :model (completion-request-model current-request)
                                    :messages next-messages
                                    :options (completion-request-options current-request))))
                            (run-next-round next-request (1+ round)
                                            (cons response responses)
                                            (1+ length-retries))))
                         ((truncated-empty-final-response-p response)
                          (log-interaction :warn "provider-empty-length-final"
                                           :round round
                                           :model (or (completion-response-model response)
                                                      (completion-request-model current-request))
                                           :finish-reason
                                           (or (completion-response-finish-reason response)
                                               "length")
                                           :length-retries length-retries)
                          (let ((synthetic (synthesize-truncated-empty-final-response response)))
                            (values synthetic
                                    (completion-request-messages current-request)
                                    (nreverse (cons synthetic responses)))))
                         (t
                          (values response
                                  (completion-request-messages current-request)
                                  (nreverse (cons response responses))))))
                   (error (condition)
                     (log-interaction :error "provider-request-failed"
                                      :round round
                                      :model (completion-request-model current-request)
                                      :duration-seconds (elapsed-seconds-since start)
                                      :message (princ-to-string condition))
                     (error condition))))))
      (run-next-round request 0 '() 0))))

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
  "Build a concise OpenAI-compatible HTTP error string including a body snippet."
  (let* ((snippet (truncate-provider-error-body body-text))
         (suffix (if (plusp (length snippet))
                     (format nil " body=~S" snippet)
                     "")))
    (format nil "~A request failed with HTTP status ~D.~A"
            *openai-compatible-provider-label* status-code suffix)))

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
         (error "~A request timed out after ~A seconds."
                *openai-compatible-provider-label* timeout-seconds))))
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
      (error "~A is required for ~A requests."
             *openai-compatible-key-environment-variable*
             *openai-compatible-provider-label*))
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

            (defmethod complete ((backend synthetic-backend) request)
            "POST REQUEST to Synthetic through the inherited OpenAI-compatible transport.

            The dynamic labels preserve provider-specific, non-secret diagnostics while
            keeping the request/tool-call serialization shared with OpenRouter."
            (let ((*openai-compatible-provider-label* "Synthetic")
            (*openai-compatible-key-environment-variable* "SYNTHETIC_API_KEY"))
            (call-next-method)))
