(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

(let* ((tool-invocations 0)
       (request
         (self-improving-agent-harness:make-completion-request
          :model "syn:large:text"
          :messages
          '((:role "system"
             :content "Use available tools when required. After using echo, reply exactly with tool-loop-complete.")
            (:role "user"
             :content "Call echo with message tool-loop-ok, then provide the required final reply."))
          :options
          '(:temperature 0.0
            :max-tokens 64
            :tool-choice "auto"
            :tools ((:type "function"
                     :function (:name "echo"
                                :description "Returns the provided message."
                                :parameters (:type "object"
                                             :properties (:message (:type "string"))
                                             :required ("message"))))))))
       (backend
         (self-improving-agent-harness:make-synthetic-backend
          :api-key (uiop:getenv "SYNTHETIC_API_KEY")))
       (response
         (self-improving-agent-harness:run-tool-loop
          backend request
          `(("echo" . ,(lambda (arguments)
                          (incf tool-invocations)
                          (gethash "message" arguments)))))))
  (format t "LIVE_SYNTHETIC_TOOL_LOOP_RESPONSE~%provider=synthetic~%model=~A~%outcome=completed~%tool-invocations=~D~%text-length=~D~%"
          (self-improving-agent-harness:completion-response-model response)
          tool-invocations
          (length (self-improving-agent-harness:completion-response-text response))))