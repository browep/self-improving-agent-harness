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
    (ensure-equal "claude-cli/2.1.218 (external, sdk-cli)" *claude-sdk-user-agent*
                  "the captured user-agent string is exact")
    (ensure-equal *claude-sdk-anthropic-version* (cdr (assoc "anthropic-version" headers :test #'string-equal))
                  "anthropic-version matches the captured contract")
    (ensure-equal "2023-06-01" *claude-sdk-anthropic-version*
                  "anthropic-version is the captured 2023-06-01")
    (ensure-equal "cli" (cdr (assoc "x-app" headers :test #'string-equal))
                  "x-app identifies as cli")
    (ensure-equal *claude-sdk-anthropic-beta* (cdr (assoc "anthropic-beta" headers :test #'string-equal))
                  "anthropic-beta matches the captured contract")
    (ensure-equal "oauth-2025-04-20" *claude-sdk-anthropic-beta*
                  "anthropic-beta is the captured oauth-2025-04-20"))
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
    (ensure-true (not (member :tools payload)) "payload never declares tools")
    (ensure-true (not (member :tool-choice payload)) "payload never forces tool_choice")
    (ensure-true (not (member :resume payload)) "payload carries no resume-style field"))

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

  (format t "Claude-sdk direct backend transport tests passed.~%")
  t)
