(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

(let* ((request
         (self-improving-agent-harness:make-completion-request
          :model "syn:large:text"
          :messages '((:role "system" :content "Reply exactly with integration-ok.")
                      (:role "user" :content "Return the required phrase."))
          :options '(:temperature 0.0 :max-tokens 16)))
       (backend
         (self-improving-agent-harness:make-synthetic-backend
          :api-key (uiop:getenv "SYNTHETIC_API_KEY")))
       (response (self-improving-agent-harness:complete backend request)))
  (format t "LIVE_SYNTHETIC_RESPONSE~%provider=synthetic~%model=~A~%outcome=completed~%text-length=~D~%"
          (self-improving-agent-harness:completion-response-model response)
          (length (self-improving-agent-harness:completion-response-text response))))