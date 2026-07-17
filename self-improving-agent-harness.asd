(asdf:defsystem #:self-improving-agent-harness
  :description "A Common Lisp harness for controlled self-improving agent experiments."
  :author "Paul Brower"
  :license "MIT"
  :depends-on (#:drakma #:yason)
  :serial t
  :components ((:file "src/package")
               (:file "src/backend")
               (:file "src/logging")
               (:file "src/shell-tool")
               (:file "src/reload")
               (:file "src/chat-session")
               (:file "src/chat-cli")
               (:file "src/main"))
  :in-order-to ((test-op (test-op "self-improving-agent-harness/tests"))))

(asdf:defsystem #:self-improving-agent-harness/tests
  :depends-on (#:self-improving-agent-harness)
  :serial t
  :components ((:file "tests/package")
               (:file "tests/backend")
               (:file "tests/openrouter-adapter")
               (:file "tests/tool-loop")
               (:file "tests/chat-session")
               (:file "tests/shell-tool")
               (:file "tests/reload")
               (:file "tests/logging"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :self-improving-agent-harness/tests :run-tests)))
