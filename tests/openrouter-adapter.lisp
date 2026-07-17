(in-package #:self-improving-agent-harness/tests)

(defun ensure-equal (expected actual description)
  (unless (equal expected actual)
    (error "Test failed: ~A~%Expected: ~S~%Actual: ~S"
           description expected actual)))

(defun run-openrouter-adapter-tests ()
  (let* ((request (make-completion-request
                   :model "openai/gpt-4.1-mini"
                   :messages '((:role "system" :content "Be concise.")
                               (:role "user" :content "Say hello."))
                   :options '(:temperature 0.2 :max-tokens 64)))
         (backend (make-openrouter-backend :api-key "test-key"))
         (payload (self-improving-agent-harness::openrouter-request-payload
                   request)))
    (ensure-equal "test-key" (openrouter-backend-api-key backend)
                  "backend retains its runtime API key")
    (ensure-equal "openai/gpt-4.1-mini" (getf payload :model)
                  "request payload retains the selected model")
    (ensure-equal '((:role "system" :content "Be concise.")
                    (:role "user" :content "Say hello."))
                  (getf payload :messages)
                  "request payload retains ordered messages")
    (ensure-equal 0.2 (getf payload :temperature)
                  "request payload includes temperature")
    (ensure-equal 64 (getf payload :max-tokens)
                  "request payload includes the output-token limit"))
  (let* ((raw-function (list (cons "name" "echo")
                             (cons "arguments" "json-arguments")))
         (raw-tool-call (list (cons "id" "call-123")
                              (cons "type" "function")
                              (cons "function" raw-function)))
         (raw-message (list (cons "content" "")
                            (cons "tool_calls" (list raw-tool-call))))
         (raw-choice (list (cons "finish_reason" "tool_calls")
                           (cons "message" raw-message)))
         (raw-response (list (cons "id" "gen-123")
                             (cons "model" "openai/gpt-4.1-mini")
                             (cons "choices" (list raw-choice))
                             (cons "usage" (list (cons "prompt_tokens" 10)
                                                 (cons "completion_tokens" 5)
                                                 (cons "total_tokens" 15)
                                                 (cons "cost" 0.0025)))))
         (response (self-improving-agent-harness::openrouter-response-from-json
                    raw-response)))
    (ensure-equal "" (completion-response-text response)
                  "response parser retains assistant content")
    (ensure-equal "openai/gpt-4.1-mini" (completion-response-model response)
                  "response parser retains resolved model")
    (ensure-equal "tool_calls"
                  (self-improving-agent-harness:completion-response-finish-reason
                   response)
                  "response parser retains finish reason")
    (ensure-equal "gen-123"
                  (self-improving-agent-harness:completion-response-provider-request-id
                   response)
                  "response parser retains the provider request ID")
    (ensure-equal '(:prompt-tokens 10 :completion-tokens 5 :total-tokens 15
                    :cost-usd 0.0025)
                  (self-improving-agent-harness:completion-response-usage response)
                  "response parser normalizes token usage and authoritative provider cost")
    (ensure-equal '(:id "call-123" :type "function" :name "echo"
                    :arguments "json-arguments")
                  (first (self-improving-agent-harness:completion-response-tool-calls
                          response))
                  "response parser normalizes tool calls"))
  (flet ((normalized-usage-for-cost (cost-marker)
           (let* ((usage (if (eq cost-marker :absent)
                             '(("prompt_tokens" . 4) ("completion_tokens" . 2)
                               ("total_tokens" . 6))
                             `(("prompt_tokens" . 4) ("completion_tokens" . 2)
                               ("total_tokens" . 6) ("cost" . ,cost-marker))))
                  (raw-response `(("id" . "cost-test") ("model" . "test/model")
                                  ("choices" . ((("message" . (("content" . "ok")))) ) )
                                  ("usage" . ,usage))))
             (completion-response-usage
              (self-improving-agent-harness::openrouter-response-from-json raw-response)))))
    (ensure-equal 0 (getf (normalized-usage-for-cost 0) :cost-usd)
                  "response parser preserves an authoritative zero provider cost")
    (ensure-true (not (member :cost-usd (normalized-usage-for-cost :absent)))
                 "response parser marks absent provider cost by omitting cost-usd")
    (ensure-true (not (member :cost-usd (normalized-usage-for-cost "0.0025")))
                 "response parser rejects string provider cost as non-authoritative")
    (ensure-equal '(:prompt-tokens 4 :completion-tokens 2 :total-tokens 6)
                  (normalized-usage-for-cost :absent)
                  "response parser retains supplied token fields when cost is absent"))
  (let* ((request (make-completion-request
                   :model "openai/gpt-4.1-mini"
                   :messages '((:role "system" :content "Be concise.")
                               (:role "user" :content "Say hello."))
                   :options '(:temperature 0.2 :max-tokens 64)))
         (json (self-improving-agent-harness::openrouter-request-json request))
         (compact-json (remove-if (lambda (character)
                                    (member character
                                            '(#\Space #\Tab #\Newline #\Return)))
                                  json)))
    (ensure-true (search "\"model\":\"openai/gpt-4.1-mini\"" compact-json)
                 "request JSON contains the selected model")
    (ensure-true (search "\"role\":\"system\"" compact-json)
                 "request JSON serializes the system role")
    (ensure-true (search "\"max_tokens\":64" compact-json)
                 "request JSON uses OpenRouter's max_tokens field"))
  (let* ((request (make-completion-request
                   :model "test/model"
                   :messages '((:role "user" :content "Use the echo tool."))
                   :options
                   '(:tools ((:type "function"
                              :function (:name "echo"
                                         :description "Returns its message."
                                         :parameters (:type "object"
                                                      :properties (:message (:type "string"))
                                                      :required ("message"))))))))
         (json (self-improving-agent-harness::openrouter-request-json request)))
    (ensure-true (search "\"tools\"" json)
                 "request JSON serializes tool definitions")
    (ensure-true (search "\"name\":\"echo\"" json)
                 "request JSON serializes the declared tool name"))
  (let* ((em-dash (string (code-char #x2014)))
         (request (make-completion-request
                   :model "test/model"
                   :messages `((:role "user" :content ,(format nil "tool output: ~A" em-dash)))))
         (octets (self-improving-agent-harness::openrouter-request-octets request))
         (decoded (sb-ext:octets-to-string octets :external-format :utf-8)))
    (ensure-true (search em-dash decoded)
                 "request transport encodes Unicode tool output as UTF-8 octets"))
  (ensure-equal "{\"id\":\"gen-123\"}"
                (self-improving-agent-harness::openrouter-response-body-string
                 #(123 34 105 100 34 58 34 103 101 110 45 49 50 51 34 125))
                "response decoder converts Drakma octets to UTF-8 text")

  ;; Hang-diagnosis helpers for HTTP error visibility / timeouts.
  (let ((snippet
          (self-improving-agent-harness::truncate-provider-error-body
           (format nil "line1~%line2   extra")
           20)))
    (ensure-true (not (find #\Newline snippet))
                 "provider error body snippets are single-line")
    (ensure-true (<= (length snippet) 20)
                 "provider error body snippets honor the character limit"))
  (let ((message
          (self-improving-agent-harness::openrouter-http-error-message
           429
           "{\"error\":{\"message\":\"Rate limit exceeded\"}}")))
    (ensure-true (search "HTTP status 429" message)
                 "HTTP error message includes the status code")
    (ensure-true (search "Rate limit exceeded" message)
                 "HTTP error message includes a body snippet"))
  (handler-case
      (progn
        (self-improving-agent-harness::call-with-openrouter-timeout
         0.05
         (lambda ()
           (sleep 1)
           t))
        (error "Test failed: openrouter timeout helper must signal on expiry"))
    (error (condition)
      (ensure-true (search "timed out" (princ-to-string condition))
                   "openrouter timeout helper signals a timeout error")))
  (ensure-equal t
                (self-improving-agent-harness::call-with-openrouter-timeout
                 nil
                 (lambda () t))
                "nil timeout leaves the thunk result unchanged")

  (format t "OpenRouter adapter payload, response, and JSON tests passed.~%")
  t)

