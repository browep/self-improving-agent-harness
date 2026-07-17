(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

;;; Thin launcher only. Chat CLI logic lives in src/chat-cli.lisp so
;;; reload_harness / /reload can redefine prompts and handlers in-process.
(self-improving-agent-harness:run-chat-cli)
