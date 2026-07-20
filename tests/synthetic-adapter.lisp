(in-package #:self-improving-agent-harness/tests)

(defun run-synthetic-adapter-tests ()
  "Synthetic is an explicit OpenAI-compatible backend, not OpenRouter reuse."
  (let* ((backend (self-improving-agent-harness::make-synthetic-backend
                   :api-key "synthetic-test-key"))
         (request (make-completion-request
                   :model "hf:example/model"
                   :messages '((:role "system" :content "Be concise.")
                               (:role "user" :content "Say hello."))
                   :options '(:temperature 0.2 :max-tokens 64))))
    (ensure-equal "synthetic" (backend-name backend)
                  "Synthetic backend has a stable name")
    (ensure-equal "https://api.synthetic.new/openai/v1"
                  (self-improving-agent-harness::synthetic-backend-base-url backend)
                  "Synthetic uses its documented OpenAI-compatible base URL")
    (ensure-equal "https://api.synthetic.new/openai/v1/chat/completions"
                  (self-improving-agent-harness::synthetic-completions-url backend)
                  "Synthetic targets the Chat Completions endpoint")
    (ensure-equal "synthetic-test-key"
                  (self-improving-agent-harness::synthetic-backend-api-key backend)
                  "Synthetic retains only its runtime API key")
    (ensure-true (search "\"model\":\"hf:example/model\""
                         (self-improving-agent-harness::synthetic-request-json request))
                 "Synthetic serializes the selected exact model ID")
    (handler-case
        (progn
          (complete (self-improving-agent-harness::make-synthetic-backend) request)
          (error "Test failed: missing Synthetic credentials must signal an error"))
      (error (condition)
        (ensure-true (search "SYNTHETIC_API_KEY" (princ-to-string condition))
                     "missing Synthetic credentials fail before a request"))))
  (format t "Synthetic adapter selection and request tests passed.~%")
  t)