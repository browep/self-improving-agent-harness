(require :asdf)
(asdf:load-asd "/workspace/self-improving-agent-harness.asd")
(asdf:load-system :self-improving-agent-harness)
(let ((port (parse-integer (or (uiop:getenv "HARNESS_WEB_PORT") "18080"))))
  (self-improving-agent-harness:run-web-server
   :port port
   :run-session-id (uiop:getenv "HARNESS_CHAT_SESSION_ID")
   :fake-scenario (uiop:getenv "HARNESS_WEB_FAKE_SCENARIO")
   :log-directory (or (uiop:getenv "HARNESS_LOG_DIR") "/workspace/agent-logs")))
