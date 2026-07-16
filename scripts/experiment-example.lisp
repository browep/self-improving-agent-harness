(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)
(load "examples/offline-summary.lisp")

(format t "~S~%"
        (self-improving-agent-harness:serialize-domain-object
         self-improving-agent-harness::offline-summary-example))
