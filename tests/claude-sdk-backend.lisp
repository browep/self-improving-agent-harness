(in-package #:self-improving-agent-harness/tests)

;;;; Deterministic, offline tests for the Claude Agent SDK direct backend
;;;; transport (issue #68): header/payload construction, SSE-frame parsing,
;;;; response normalization, and provider-error handling. The HTTP transport
;;;; is always an injected fake function -- no test here opens a socket, reads
;;;; a real CLAUDE_CODE_OAUTH_TOKEN, or calls the live Anthropic API. The
;;;; credential-gated live smoke is a separate, explicitly opt-in follow-up
;;;; (issue #70) and is deliberately out of scope for this suite.

(defun with-claude-sdk-test-env (token thunk)
  (let ((saved-token (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN"))
        (saved-anthropic (uiop:getenv "ANTHROPIC_API_KEY")))
    (unwind-protect
         (progn
           (if token
               (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") token)
               (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN"))
           (funcall thunk))
      (if saved-token
          (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") saved-token)
          (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN"))
      (if saved-anthropic
          (setf (uiop:getenv "ANTHROPIC_API_KEY") saved-anthropic)
          (sb-posix:unsetenv "ANTHROPIC_API_KEY")))))

(defun claude-sdk-test-request (&key (content "hello") (model "claude-sdk-fixture-model")
                                  (messages nil messages-supplied-p) options)
  (make-completion-request :model model
                           :messages (if messages-supplied-p
                                         messages
                                         (list (list :role "user" :content content)))
                           :options options))

(defun claude-sdk-fixture-string (relative-path)
  (uiop:read-file-string
   (asdf:system-relative-pathname :self-improving-agent-harness relative-path)))

(defun claude-sdk-fake-transport (canned-body canned-status &optional captured)
  "Return a transport function that always answers CANNED-BODY/CANNED-STATUS.

CAPTURED, when supplied, is a fresh cons cell whose CAR is set to the (URL
HEADERS OCTETS) argument list the fake transport was called with, so callers
can assert on exactly what COMPLETE tried to send."
  (lambda (url headers octets)
    (when captured (setf (car captured) (list url headers octets)))
    (values canned-body canned-status)))

(defun run-claude-sdk-backend-tests ()
  ;; ---- Identity: a distinct class/constructor/name from the CLI `claude`
  ;; backend, selectable and constructible without any credential. ----
  (let ((backend (make-claude-sdk-backend)))
    (ensure-equal "claude-sdk" (backend-name backend)
                  "claude-sdk backend has its own stable provider identity")
    (ensure-true (typep backend 'claude-sdk-backend)
                 "make-claude-sdk-backend returns a claude-sdk-backend")
    (ensure-true (not (typep backend 'claude-backend))
                 "claude-sdk-backend is not a claude-backend subtype"))

  ;; ---- Missing token fails at completion time, before any transport call,
  ;; and never reads/accepts ANTHROPIC_API_KEY as a fallback credential. ----
  (with-claude-sdk-test-env
   nil
   (lambda ()
     (setf (uiop:getenv "ANTHROPIC_API_KEY") "anthropic-fixture-not-a-real-key")
     (let* ((called nil)
            (backend (make-claude-sdk-backend
                      :transport (lambda (&rest args)
                                   (declare (ignore args))
                                   (setf called t)
                                   (values "" 200)))))
       (handler-case
           (progn
             (complete backend (claude-sdk-test-request))
             (error "Test failed: missing CLAUDE_CODE_OAUTH_TOKEN must signal"))
         (claude-sdk-backend-error (condition)
           (let ((message (claude-sdk-backend-error-reason condition)))
             (ensure-true (search "CLAUDE_CODE_OAUTH_TOKEN" message)
                          "missing-token error names the required environment variable")
             (ensure-true (not (search "anthropic-fixture-not-a-real-key" message))
                          "missing-token error never echoes the ANTHROPIC_API_KEY fixture"))))
       (ensure-true (not called) "missing token fails before any transport call"))))

  ;; A blank token is treated as absent.
  (with-claude-sdk-test-env
   "   "
   (lambda ()
     (let ((backend (make-claude-sdk-backend
                     :transport (lambda (&rest args) (declare (ignore args)) (values "" 200)))))
       (handler-case
           (progn
             (complete backend (claude-sdk-test-request))
             (error "Test failed: blank CLAUDE_CODE_OAUTH_TOKEN must signal"))
         (claude-sdk-backend-error (condition)
           (ensure-true (search "CLAUDE_CODE_OAUTH_TOKEN" (claude-sdk-backend-error-reason condition))
                        "blank token is rejected like an absent token"))))))

  ;; A static guarantee stronger than any single runtime scenario above: the
  ;; backend never obtains an Anthropic API key.
  (let ((source (uiop:read-file-string
                 (asdf:system-relative-pathname
                  :self-improving-agent-harness "src/claude-sdk-backend.lisp"))))
    (ensure-true (not (search "uiop:getenv \"ANTHROPIC_API_KEY\"" source))
                 "claude-sdk backend never reads ANTHROPIC_API_KEY"))

  ;; ---- Header construction: the exact captured Anthropic Messages API
  ;; header contract, keyed only off the runtime token. ----
  (let ((headers (claude-sdk-request-headers "sdk-fixture-token")))
    (ensure-equal "Bearer sdk-fixture-token" (cdr (assoc "Authorization" headers :test #'string-equal))
                  "Authorization carries the OAuth token as a Bearer credential")
    (ensure-equal "application/json" (cdr (assoc "Accept" headers :test #'string-equal))
                  "Accept is application/json")
    (ensure-equal "application/json" (cdr (assoc "Content-Type" headers :test #'string-equal))
                  "Content-Type is application/json")
    (ensure-equal *claude-sdk-user-agent* (cdr (assoc "User-Agent" headers :test #'string-equal))
                  "User-Agent matches the captured claude-cli identity")
    (ensure-equal "claude-cli/2.1.218 (external, sdk-ts, agent-sdk/0.3.218)" *claude-sdk-user-agent*
                  "the captured TypeScript SDK user-agent string is exact")
    (ensure-equal *claude-sdk-anthropic-version* (cdr (assoc "anthropic-version" headers :test #'string-equal))
                  "anthropic-version matches the captured contract")
    (ensure-equal "2023-06-01" *claude-sdk-anthropic-version*
                  "anthropic-version is the captured 2023-06-01")
    (ensure-equal "cli" (cdr (assoc "x-app" headers :test #'string-equal))
                  "x-app identifies as cli")
    (ensure-equal *claude-sdk-anthropic-beta* (cdr (assoc "anthropic-beta" headers :test #'string-equal))
                  "anthropic-beta matches the captured contract")
    (ensure-equal "oauth-2025-04-20,interleaved-thinking-2025-05-14,thinking-token-count-2026-05-13,context-management-2025-06-27,prompt-caching-scope-2026-01-05,advisor-tool-2026-03-01,structured-outputs-2025-12-15,cache-diagnosis-2026-04-07" *claude-sdk-anthropic-beta*
                  "anthropic-beta matches the captured TypeScript SDK contract"))
  (ensure-equal "https://api.anthropic.com/v1/messages" *claude-sdk-messages-url*
                "the Messages endpoint is the captured URL")

  ;; ---- Payload construction: text-only, model/messages/system/stream, no
  ;; tools, no resume-style fields. ----
  (let* ((backend (make-claude-sdk-backend))
         (request (claude-sdk-test-request
                   :messages (list (list :role "system" :content "be terse")
                                    (list :role "user" :content "hi")
                                    (list :role "assistant" :content "hello")
                                    (list :role "user" :content "again"))))
         (payload (claude-sdk-request-payload request backend)))
    (ensure-equal "claude-sdk-fixture-model" (getf payload :model)
                  "payload forwards the requested model verbatim")
    (ensure-equal *claude-sdk-default-max-tokens* (getf payload :max-tokens)
                  "payload defaults max_tokens when the request has none")
    (ensure-equal t (getf payload :stream) "payload always requests stream:true")
    (ensure-equal "be terse" (getf payload :system)
                  "payload extracts the system-role message text")
    (ensure-equal '(("user" . "hi") ("assistant" . "hello") ("user" . "again"))
                  (mapcar (lambda (m) (cons (getf m :role) (getf m :content)))
                          (getf payload :messages))
                  "payload messages exclude the system turn and preserve order/content")
    (ensure-true (not (member :tools payload)) "payload omits tools when the request does not define them")
    (ensure-true (not (member :tool-choice payload)) "payload never forces tool_choice")
    (ensure-true (not (member :resume payload)) "payload carries no resume-style field"))

  ;; ---- Native Anthropic tool declarations are derived directly from the
  ;; harness's OpenAI-compatible function definitions. No CLI/MCP fallback or
  ;; credential boundary is involved. ----
  (let* ((tool (list :type "function"
                     :function (list :name "echo"
                                     :description "Return the supplied message."
                                     :parameters (list :type "object"
                                                       :properties (list :message
                                                                         (list :type "string"))
                                                       :required (list "message")))))
         (payload (claude-sdk-request-payload
                   (claude-sdk-test-request :options (list :tools (list tool)))
                   (make-claude-sdk-backend)))
         (serialized (first (getf payload :tools))))
    (ensure-equal "echo" (getf serialized :name)
                  "payload maps a function tool name to Anthropic tools[].name")
    (ensure-equal "Return the supplied message." (getf serialized :description)
                  "payload maps a function tool description to Anthropic tools[].description")
    (ensure-equal '(:type "object" :properties (:message (:type "string")) :required ("message"))
                  (getf serialized :input-schema)
                  "payload maps function parameters to Anthropic input_schema"))

  ;; system is entirely absent (not merely blank) when the request has none.
  (let* ((payload (claude-sdk-request-payload (claude-sdk-test-request :content "no system here")
                                              (make-claude-sdk-backend))))
    (ensure-true (not (member :system payload))
                 "payload omits the system key entirely when no system turn is present"))

  ;; max_tokens: request options win over a backend-level override, which
  ;; wins over the global default.
  (let ((payload (claude-sdk-request-payload
                  (claude-sdk-test-request :options (list :max-tokens 777))
                  (make-claude-sdk-backend :max-tokens 555))))
    (ensure-equal 777 (getf payload :max-tokens)
                  "request options max-tokens overrides the backend default"))
  (let ((payload (claude-sdk-request-payload
                  (claude-sdk-test-request)
                  (make-claude-sdk-backend :max-tokens 555))))
    (ensure-equal 555 (getf payload :max-tokens)
                  "a backend-level max-tokens overrides the global default"))

  ;; Non-string message content (e.g. a stray tool-shaped turn) never crashes
  ;; payload construction; it degrades to empty text rather than guessing.
  (let ((payload (claude-sdk-request-payload
                  (claude-sdk-test-request :messages (list (list :role "user" :content '(:not "a string"))))
                  (make-claude-sdk-backend))))
    (ensure-equal "" (getf (first (getf payload :messages)) :content)
                  "non-string message content degrades to empty text instead of erroring"))

  ;; ---- JSON encoding: snake_case wire fields, correct boolean/number
  ;; encoding, and control-character sanitization. ----
  (let* ((request (claude-sdk-test-request
                   :messages (list (list :role "system" :content "sys")
                                    (list :role "user" :content (format nil "line-one~Cline-two" #\Bel)))))
         (backend (make-claude-sdk-backend))
         (json (claude-sdk-request-json (claude-sdk-request-payload request backend)))
         (parsed (yason:parse json)))
    (ensure-equal "claude-sdk-fixture-model" (gethash "model" parsed)
                  "wire JSON model field round-trips")
    (ensure-equal *claude-sdk-default-max-tokens* (gethash "max_tokens" parsed)
                  "wire JSON uses snake_case max_tokens")
    (ensure-equal t (gethash "stream" parsed) "wire JSON stream is boolean true")
    (ensure-equal "sys" (gethash "system" parsed) "wire JSON system field round-trips")
    (ensure-true (not (search (string #\Bel)
                              (gethash "content" (first (coerce (gethash "messages" parsed) 'list)))))
                 "raw control characters are escaped, never sent literally in message content"))

  ;; ---- SSE frame parsing: generic Server-Sent Events semantics, independent
  ;; of the Anthropic-specific JSON payload. ----
  (let ((frames (claude-sdk-parse-sse-events
                 (format nil "event: greeting~%data: hello~%~%"))))
    (ensure-equal 1 (length frames) "one blank-line-terminated frame parses to one frame")
    (ensure-equal "greeting" (getf (first frames) :event) "event: line sets the frame's event name"))
  (let ((frames (claude-sdk-parse-sse-events
                 (format nil ": this is a comment~%event: multi~%data: line one~%data: line two~%~%"))))
    (ensure-equal 1 (length frames) "a comment line does not start a spurious frame")
    (ensure-equal "line one
line two"
                  (getf (first frames) :raw-data)
                  "multiple data: lines within one frame join with a newline"))
  (let ((frames (claude-sdk-parse-sse-events
                 (format nil "event: a~%data: 1~%~%event: b~%data: 2~%"))))
    (ensure-equal 2 (length frames) "a trailing frame without a final blank line is still dispatched")
    (ensure-equal '("a" "b") (mapcar (lambda (f) (getf f :event)) frames)
                  "frames are returned in stream order"))
  (let ((frames (claude-sdk-parse-sse-events
                 (concatenate 'string "event: crlf" (string #\Return) (string #\Newline)
                              "data: value" (string #\Return) (string #\Newline)
                              (string #\Return) (string #\Newline)))))
    (ensure-equal 1 (length frames) "CRLF line endings are tolerated")
    (ensure-equal "value" (getf (first frames) :raw-data) "CRLF frame data decodes correctly"))
  (let ((frames (claude-sdk-parse-sse-events
                 (format nil "event: greeting~%data: {\"a\":1}~%~%"))))
    (ensure-true (hash-table-p (getf (first frames) :data))
                 "data: lines that are valid JSON are pre-parsed for callers"))

  ;; ---- Streamed native tool_use blocks become harness tool calls. Both an
  ;; input object supplied at block start and streamed input_json_delta text are
  ;; supported; the latter is the Messages streaming form used for tool inputs. ----
  (let* ((body (format nil "~{~A~%~}"
                       (list "event: message_start"
                             "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":7}}}"
                             ""
                             "event: content_block_start"
                             "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_fixture_1\",\"name\":\"echo\",\"input\":{}}}"
                             ""
                             "event: content_block_delta"
                             "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"message\\\":\\\"hello\\\"}\"}}"
                             ""
                             "event: message_delta"
                             "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":4}}"
                             "")))
         (response (claude-sdk-response-from-body body (claude-sdk-test-request)))
         (call (first (completion-response-tool-calls response))))
    (ensure-equal "tool_use" (completion-response-finish-reason response)
                  "tool stream preserves Anthropic's tool_use stop reason")
    (ensure-equal "toolu_fixture_1" (getf call :id)
                  "tool_use stream preserves the provider tool ID")
    (ensure-equal "function" (getf call :type)
                  "tool_use stream normalizes to the harness function call type")
    (ensure-equal "echo" (getf call :name)
                  "tool_use stream preserves the native tool name")
    (ensure-equal "hello" (gethash "message" (yason:parse (getf call :arguments)))
                  "input_json_delta fragments assemble into the tool arguments JSON"))

  ;; ---- Response normalization from a realistic captured trace. ----
  (let* ((body (claude-sdk-fixture-string "tests/fixtures/claude-sdk-messages-basic.sse"))
         (request (claude-sdk-test-request))
         (response (claude-sdk-response-from-body body request)))
    (ensure-equal (format nil "Hello, safe world! ✨") (completion-response-text response)
                  "text deltas across multiple frames concatenate into one final string")
    (ensure-equal "claude-sonnet-5" (completion-response-model response)
                  "model comes from the message_start event")
    (ensure-equal "end_turn" (completion-response-finish-reason response)
                  "finish-reason comes from message_delta's stop_reason")
    (ensure-equal "msg_fixture_01" (completion-response-provider-request-id response)
                  "provider-request-id is the Anthropic message id")
    (ensure-equal 25 (getf (completion-response-usage response) :prompt-tokens)
                  "prompt-tokens comes from message_start usage.input_tokens")
    (ensure-equal 14 (getf (completion-response-usage response) :completion-tokens)
                  "completion-tokens comes from the final message_delta usage.output_tokens")
    (ensure-equal 39 (getf (completion-response-usage response) :total-tokens)
                  "total-tokens sums prompt and completion tokens")
    (ensure-equal '() (completion-response-tool-calls response)
                  "this text-only transport never emits tool calls")
    (ensure-equal '() (completion-response-native-tool-events response)
                  "this text-only transport never emits native tool events")
    ;; The harness-facing contract is exactly one buffered response, never a
    ;; sequence of partial deltas.
    (ensure-true (typep response 'completion-response)
                 "COMPLETE-shaped normalization returns a single completion-response"))

  ;; ---- Multiple content-block indices are concatenated in index order, not
  ;; arrival or lexical order. ----
  (let* ((body (format nil "~{~A~%~}"
                       (list "event: message_start"
                             "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi\",\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":3}}}"
                             ""
                             "event: content_block_delta"
                             "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"second\"}}"
                             ""
                             "event: content_block_delta"
                             "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"first\"}}"
                             ""
                             "event: message_delta"
                             "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}"
                             ""
                             "event: message_stop"
                             "data: {\"type\":\"message_stop\"}"
                             "")))
         (response (claude-sdk-response-from-body body (claude-sdk-test-request))))
    (ensure-equal "firstsecond" (completion-response-text response)
                  "blocks concatenate by ascending content-block index, not arrival order"))

  ;; ---- Ping frames and unrecognized future event types never contribute
  ;; text or break normalization. ----
  (let* ((body (format nil "~{~A~%~}"
                       (list "event: message_start"
                             "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ping\",\"model\":\"m\",\"usage\":{\"input_tokens\":1}}}"
                             ""
                             "event: ping"
                             "data: {\"type\":\"ping\"}"
                             ""
                             "event: content_block_delta"
                             "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}"
                             ""
                             "event: some_future_event"
                             "data: {\"type\":\"some_future_event\",\"whatever\":true}"
                             ""
                             "event: message_delta"
                             "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}"
                             ""
                             "event: message_stop"
                             "data: {\"type\":\"message_stop\"}"
                             "")))
         (response (claude-sdk-response-from-body body (claude-sdk-test-request))))
    (ensure-equal "ok" (completion-response-text response)
                  "ping and unrecognized event types are ignored, forward-compatibly"))

  ;; ---- A stream missing message_start is a clear, safe error, not a crash
  ;; or a silently empty response. ----
  (handler-case
      (progn
        (claude-sdk-response-from-body "event: message_stop
data: {\"type\":\"message_stop\"}

" (claude-sdk-test-request))
        (error "Test failed: a stream without message_start must signal"))
    (claude-sdk-backend-error (condition)
      (ensure-true (search "message_start" (claude-sdk-backend-error-reason condition))
                   "the missing-message_start error names the missing event")))

  ;; ---- A mid-stream `error` event aborts normalization with a safe,
  ;; provider-supplied message. ----
  (let ((body (format nil "~{~A~%~}"
                      (list "event: message_start"
                            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_err\",\"model\":\"m\",\"usage\":{\"input_tokens\":1}}}"
                            ""
                            "event: error"
                            "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"
                            ""))))
    (handler-case
        (progn
          (claude-sdk-response-from-body body (claude-sdk-test-request))
          (error "Test failed: a mid-stream error event must signal"))
      (claude-sdk-backend-error (condition)
        (let ((message (claude-sdk-backend-error-reason condition)))
          (ensure-true (search "overloaded_error" message) "stream error names the provider error type")
          (ensure-true (search "Overloaded" message) "stream error carries the provider error message")))))

  ;; ---- Full COMPLETE round trip: success. Exercises header/payload
  ;; construction, the injected transport seam, and response normalization
  ;; together, end to end, entirely offline. ----
  (with-claude-sdk-test-env
   "sdk-fixture-token"
   (lambda ()
     (let* ((captured (cons nil nil))
            (backend (make-claude-sdk-backend
                      :transport (claude-sdk-fake-transport
                                  (claude-sdk-fixture-string "tests/fixtures/claude-sdk-messages-basic.sse")
                                  200 captured)))
            (response (complete backend (claude-sdk-test-request :content "hi there"))))
       (ensure-equal (format nil "Hello, safe world! ✨") (completion-response-text response)
                     "a successful COMPLETE call returns the fully assembled final text")
       (ensure-equal "claude-sonnet-5" (completion-response-model response)
                     "a successful COMPLETE call reports the provider model")
       (destructuring-bind (url headers octets) (car captured)
         (ensure-equal *claude-sdk-messages-url* url "COMPLETE posts to the Messages endpoint")
         (ensure-equal "Bearer sdk-fixture-token"
                       (cdr (assoc "Authorization" headers :test #'string-equal))
                       "COMPLETE authenticates with the runtime OAuth token")
         (let ((sent (yason:parse (sb-ext:octets-to-string octets :external-format :utf-8))))
           (ensure-equal "claude-sdk-fixture-model" (gethash "model" sent)
                         "COMPLETE sends the requested model")
           (ensure-equal t (gethash "stream" sent) "COMPLETE always requests stream:true")
           (ensure-true (search "hi there"
                                (gethash "content" (first (coerce (gethash "messages" sent) 'list))))
                        "COMPLETE forwards the user turn text in the wire payload"))))))

  ;; ---- Full offline tool-loop round trip: the first streamed tool_use is
  ;; executed by the existing harness loop and its result is sent back as an
  ;; Anthropic tool_result continuation, never through a CLI fallback. ----
  (with-claude-sdk-test-env
   "sdk-fixture-token"
   (lambda ()
     (let ((payloads '()) (calls 0))
       (let* ((tool-stream (format nil "event: message_start~%data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_loop_1\",\"model\":\"m\",\"usage\":{\"input_tokens\":1}}}~%~%event: content_block_start~%data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_loop_1\",\"name\":\"echo\",\"input\":{\"message\":\"from-provider\"}}}~%~%event: message_delta~%data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}~%~%"))
              (final-stream (format nil "event: message_start~%data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_loop_2\",\"model\":\"m\",\"usage\":{\"input_tokens\":2}}}~%~%event: content_block_delta~%data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"tool loop done\"}}~%~%event: message_delta~%data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}~%~%"))
              (backend (make-claude-sdk-backend
                        :transport (lambda (url headers octets)
                                     (declare (ignore url headers))
                                     (push (yason:parse (sb-ext:octets-to-string octets :external-format :utf-8)) payloads)
                                     (incf calls)
                                     (values (if (= calls 1) tool-stream final-stream) 200))))
              (tool (list :type "function"
                          :function (list :name "echo" :description "echo"
                                          :parameters (list :type "object" :properties '()))))
              (response (run-tool-loop
                         backend
                         (claude-sdk-test-request :content "use echo" :options (list :tools (list tool)))
                         `(("echo" . ,(lambda (arguments)
                                         (format nil "echoed: ~A" (gethash "message" arguments))))))))
         (ensure-equal "tool loop done" (completion-response-text response)
                       "native Claude tool use reaches the final harness response")
         (ensure-equal 2 calls "tool loop makes a Messages continuation request")
         (let* ((first-payload (second payloads))
                (continuation (first payloads))
                (tool-schema (first (self-improving-agent-harness::openrouter-list (gethash "tools" first-payload))))
                (messages (self-improving-agent-harness::openrouter-list (gethash "messages" continuation)))
                (assistant (second messages))
                (tool-result-message (third messages))
                (tool-use (first (self-improving-agent-harness::openrouter-list (gethash "content" assistant))))
                (tool-result (first (self-improving-agent-harness::openrouter-list (gethash "content" tool-result-message)))))
           (ensure-equal "echo" (gethash "name" tool-schema)
                         "initial Messages request declares the harness tool")
           (ensure-equal "assistant" (gethash "role" assistant)
                         "continuation retains the assistant tool_use turn")
           (ensure-equal "tool_use" (gethash "type" tool-use)
                         "continuation serializes a native Anthropic tool_use block")
           (ensure-equal "toolu_loop_1" (gethash "id" tool-use)
                         "continuation retains the provider tool_use id")
           (ensure-equal "from-provider"
                         (self-improving-agent-harness::openrouter-json-field
                          (gethash "input" tool-use) "message")
                         "continuation retains the decoded tool input")
           (ensure-equal "user" (gethash "role" tool-result-message)
                         "tool output is continued in an Anthropic user turn")
           (ensure-equal "tool_result" (gethash "type" tool-result)
                         "continuation serializes an Anthropic tool_result block")
           (ensure-equal "toolu_loop_1" (gethash "tool_use_id" tool-result)
                         "tool_result references the matching native tool id")
           (ensure-equal "echoed: from-provider" (gethash "content" tool-result)
                         "tool_result carries the harness handler output"))))))

  ;; ---- Full COMPLETE round trip: provider HTTP errors are surfaced safely,
  ;; with the OAuth token and raw body redacted. ----
  (with-claude-sdk-test-env
   "sdk-fixture-token"
   (lambda ()
     (dolist (case (list (list 401 "authentication_error" "invalid x-api-key")
                          (list 429 "rate_limit_error" "Number of request tokens has exceeded your per-minute rate limit")
                          (list 529 "overloaded_error" "Overloaded")
                          (list 400 "invalid_request_error" "messages: at least one message is required")))
       (destructuring-bind (status type message) case
         (let* ((body (format nil "{\"type\":\"error\",\"error\":{\"type\":\"~A\",\"message\":\"~A (token sdk-fixture-token)\"}}"
                              type message))
                (backend (make-claude-sdk-backend
                          :transport (claude-sdk-fake-transport body status))))
           (handler-case
               (progn
                 (complete backend (claude-sdk-test-request))
                 (error "Test failed: HTTP status ~A must signal" status))
             (claude-sdk-backend-error (condition)
               (let ((reason (claude-sdk-backend-error-reason condition)))
                 (ensure-true (search (princ-to-string status) reason)
                              "the error names the HTTP status code")
                 (ensure-true (search type reason)
                              "the error names the provider error type")
                 (ensure-true (search message reason)
                              "the error carries the provider-supplied message")
                 (ensure-true (not (search "sdk-fixture-token" reason))
                              "the error never echoes the OAuth token, even when the body contains it")))))))))

  ;; A non-JSON / malformed error body degrades to a bounded, safe message
  ;; rather than crashing the harness.
  (with-claude-sdk-test-env
   "sdk-fixture-token"
   (lambda ()
     (let ((backend (make-claude-sdk-backend
                     :transport (claude-sdk-fake-transport "<html>502 Bad Gateway</html>" 502))))
       (handler-case
           (progn
             (complete backend (claude-sdk-test-request))
             (error "Test failed: a non-JSON error body must still signal a clear error"))
         (claude-sdk-backend-error (condition)
           (ensure-true (search "502" (claude-sdk-backend-error-reason condition))
                        "a malformed error body still reports the HTTP status"))))))

  ;; ---- Redaction: the OAuth token is never present in log-bound diagnostics
  ;; even when both a transport failure and a provider error body echo it. ----
  (with-claude-sdk-test-env
   "sdk-fixture-token-should-never-leak"
   (lambda ()
     (let ((backend (make-claude-sdk-backend
                     :transport (lambda (&rest args)
                                  (declare (ignore args))
                                  (error "connection reset while token=sdk-fixture-token-should-never-leak was in scope")))))
       (handler-case
           (progn
             (complete backend (claude-sdk-test-request))
             (error "Test failed: a transport-level error must still signal claude-sdk-backend-error"))
         (claude-sdk-backend-error (condition)
           (ensure-true (not (search "sdk-fixture-token-should-never-leak"
                                    (claude-sdk-backend-error-reason condition)))
                        "a raw transport error message never echoes the OAuth token"))))))

  ;; ---- Checked-in sanitized observed SDK contract: this fixture records only
  ;; allowlisted nonsecret protocol metadata plus JSON key/type shapes. It
  ;; deliberately contains no authorization/cookie fields, body examples, or
  ;; prompt/response values. The direct backend's safe wire constants must
  ;; remain aligned with this offline compatibility evidence. ----
  (let* ((fixture-text (claude-sdk-fixture-string "tests/fixtures/claude-sdk-contract.json"))
         (fixture (yason:parse fixture-text))
         (request (gethash "request" fixture))
         (response (gethash "response" fixture))
         (headers (gethash "safe_protocol_headers" request))
         (credential-markers '("authorization" "bearer " "cookie" "x-api-key"
                               "api_key" "api-key" "claude_code_oauth_token"
                               "anthropic_api_key" "sk-ant-")))
    (dolist (marker credential-markers)
      (ensure-true (not (search marker fixture-text :test #'char-equal))
                   "sanitized Claude SDK contract fixture contains no credential marker"))
    (ensure-equal "POST" (gethash "method" request)
                  "contract fixture records the observed POST method")
    (ensure-equal "api.anthropic.com" (gethash "host" request)
                  "contract fixture records the observed Messages host")
    (ensure-equal "/v1/messages" (gethash "path" request)
                  "contract fixture records the observed Messages path")
    (ensure-equal "claude-code" (gethash "client" request)
                  "contract fixture records the official client identity")
    (ensure-equal "2.1.218" (gethash "client_version" request)
                  "contract fixture records the observed official client version")
    (ensure-equal "typescript" (gethash "client_language" request)
                  "contract fixture records the observed official client language")
    (ensure-equal "application/json" (gethash "accept" headers)
                  "contract fixture records the safe Accept protocol value")
    (ensure-equal "application/json" (gethash "content-type" headers)
                  "contract fixture records the safe Content-Type protocol value")
    (ensure-equal *claude-sdk-user-agent* (gethash "user-agent" headers)
                  "backend User-Agent constant conforms to the contract fixture")
    (ensure-equal *claude-sdk-anthropic-version* (gethash "anthropic-version" headers)
                  "backend anthropic-version constant conforms to the contract fixture")
    (ensure-equal *claude-sdk-x-app* (gethash "x-app" headers)
                  "backend x-app constant conforms to the contract fixture")
    (ensure-equal *claude-sdk-anthropic-beta* (gethash "anthropic-beta" headers)
                  "backend complete beta-list constant conforms to the contract fixture")
    (ensure-equal "POST" (string-upcase (symbol-name *claude-sdk-http-method*))
                  "backend HTTP method constant conforms to the contract fixture")
    (ensure-equal (format nil "https://~A~A" (gethash "host" request) (gethash "path" request))
                  *claude-sdk-messages-url*
                  "backend Messages URL constant conforms to the contract fixture")
    (ensure-equal 200 (gethash "status_code" response)
                  "contract fixture records the observed success status")
    (ensure-equal "text/event-stream" (gethash "content_type" response)
                  "contract fixture records the observed SSE content type")
    (ensure-true (hash-table-p (gethash "json_shape" request))
                 "contract fixture describes the request as JSON key/type shapes")
    (ensure-true (hash-table-p (gethash "sse_json_shape" response))
                 "contract fixture describes SSE events as JSON key/type shapes"))

  (format t "Claude-sdk direct backend transport tests passed.~%")
  t)
