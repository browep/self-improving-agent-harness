(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

(let* ((request
         (self-improving-agent-harness:make-completion-request
          :model "syn:large:text"
          :messages '((:role "system" :content "Reply exactly with integration-ok.")
                      (:role "user" :content "Return the required phrase."))
          ;; GLM's reasoning tokens count against the OpenAI-compatible output
          ;; budget. Leave enough room for both reasoning and the fixed final
          ;; phrase; a 16-token cap can produce a successful but empty content
          ;; field.
          :options '(:temperature 0.0 :max-tokens 256)))
       (backend
         (self-improving-agent-harness:make-synthetic-backend
          :api-key (uiop:getenv "SYNTHETIC_API_KEY")))
       (response (self-improving-agent-harness:complete backend request)))
  (format t "LIVE_SYNTHETIC_RESPONSE~%provider=synthetic~%model=~A~%outcome=completed~%text-length=~D~%"
          (self-improving-agent-harness:completion-response-model response)
          (length (self-improving-agent-harness:completion-response-text response))))