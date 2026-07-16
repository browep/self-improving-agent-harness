(require :asdf)
(asdf:load-asd (truename "self-improving-agent-harness.asd"))
(asdf:load-system :self-improving-agent-harness)

(let ((result (self-improving-agent-harness:run-fixed-baseline)))
  (format t "~S~%" result)
  (unless (eq :success (getf result :outcome))
    (uiop:quit 1)))
