(asdf:defsystem #:self-improving-agent-harness
  :description "A Common Lisp harness for controlled self-improving agent experiments."
  :author "Paul Brower"
  :license "MIT"
  :depends-on (#:drakma #:yason #:sb-posix #:clog)
  :serial t
  :components ((:file "src/package")
               (:file "src/backend")
               (:file "src/logging")
               (:file "src/codex-jsonrpc")
               (:file "src/codex-app-server")
               (:file "src/codex-backend")
               (:file "src/claude-backend")
               (:file "src/shell-tool")
               (:file "src/web-search")
               (:file "src/model-metadata")
               (:file "src/reload")
               (:file "src/subagent")
               (:file "src/chat-session")
               (:file "src/web-session")
               (:file "src/web-app")
               (:file "src/tooling/browser/playwright-bridge")
               (:file "src/tooling/browser/browser-tool")
               (:file "src/tooling/browser/harness-web-ui/harness-web-ui-tool")
               (:file "src/chat-turn-report")
               (:file "src/chat-cli")
               (:file "src/claude-mcp")
               (:file "src/main"))
  :in-order-to ((test-op (test-op "self-improving-agent-harness/tests"))))

(asdf:defsystem #:self-improving-agent-harness/tests
  :depends-on (#:self-improving-agent-harness)
  :serial t
  :components ((:file "tests/package")
               (:file "tests/backend")
               (:file "tests/backend-selection")
               (:file "tests/codex-jsonrpc")
               (:file "tests/codex-app-server")
               (:file "tests/codex-backend")
               (:file "tests/claude-backend")
               (:file "tests/openrouter-adapter")
               (:file "tests/synthetic-adapter")
               (:file "tests/tool-loop")
               (:file "tests/chat-session")
               (:file "tests/env-file")
               (:file "tests/shell-tool")
               (:file "tests/web-search")
               (:file "tests/model-metadata")
               (:file "tests/reload")
               (:file "tests/logging")
               (:file "tests/resume")
               (:file "tests/subagent")
               (:file "tests/web-session")
               ;; Standalone CLOG web UI browser integration test
               ;; (issue #42). NOT invoked by RUN-TESTS: it needs a
               ;; live CLOG server + headless Chromium. Load and run
               ;; it explicitly via scripts/run-browser-verify.lisp
               ;; or RUN-BROWSER-VERIFICATION-TEST.
               (:file "tests/tooling/browser/harness-web-ui/harness-web-ui-integration"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :self-improving-agent-harness/tests :run-tests)))
