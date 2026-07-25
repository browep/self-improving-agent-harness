(in-package #:self-improving-agent-harness/tests)

;;; Unit tests for the pure (non-CLOG-DOM) logic in src/web-app.lisp: backend/
;;; model option lists, backend construction dispatch, the durable-session
;;; registry, and the issue #90 Model-dropdown-refresh decision logic.
;;;
;;; src/web-app.lisp also contains CLOG DOM-construction/event-wiring code
;;; (web-create-editable-dropdown, web-render-chat-message, the click/change
;;; handlers registered inside WEB-ON-NEW-WINDOW, etc.) that requires a live
;;; browser/CLOG connection to exercise meaningfully; that behavior is instead
;;; verified live via the browser_* Playwright tools (see issue #90 evidence)
;;; and, for the app-specific selectors/flows, by the separate STANDALONE
;;; integration test in tests/tooling/browser/harness-web-ui/. This file
;;; covers everything in src/web-app.lisp that does not require a DOM.

(defun web-app-tests-reset-session-registry ()
  "Clear the process-global browser session registry between test cases.

*WEB-SESSIONS*/*WEB-SESSION-ORDER* are shared global state (mirroring the real
CLOG server's lifetime), so tests that register sessions must not leak into
each other or into a real running web server sharing this image."
  (clrhash self-improving-agent-harness::*web-sessions*)
  (setf self-improving-agent-harness::*web-session-order* '()))

(defun run-web-app-tests ()
  ;; --- web-backend-options -------------------------------------------------
  (ensure-equal '("synthetic" "openrouter" "codex" "claude" "claude-sdk")
                (self-improving-agent-harness::web-backend-options)
                "the backend dropdown offers exactly the five supported backends")

  ;; --- web-model-options-for-backend ---------------------------------------
  (ensure-equal '("claude-fable-5" "claude-opus-4-8" "claude-opus-4-7"
                  "claude-opus-4-6" "claude-opus-4-5-20251101"
                  "claude-opus-4-1-20250805" "claude-sonnet-5"
                  "claude-sonnet-4-6" "claude-sonnet-4-5-20250929"
                  "claude-haiku-4-5-20251001")
                (self-improving-agent-harness::web-model-options-for-backend "claude-sdk")
                "claude-sdk offers the current Claude SDK model list")
  (ensure-equal '("gpt-4-turbo" "gpt-4o" "claude-3.5-sonnet"
                  "meta-llama/llama-2-70b-chat" "microsoft/phi-3-mini")
                (self-improving-agent-harness::web-model-options-for-backend "openrouter")
                "openrouter offers its own distinct model list")
  (ensure-equal '("gpt-4-turbo" "gpt-4o" "gpt-3.5-turbo" "claude-3.5-sonnet")
                (self-improving-agent-harness::web-model-options-for-backend "synthetic")
                "synthetic offers its own distinct model list")
  (ensure-equal '("gpt-5-codex")
                (self-improving-agent-harness::web-model-options-for-backend "codex")
                "codex offers exactly its one supported model")
  (ensure-equal '("sonnet" "opus")
                (self-improving-agent-harness::web-model-options-for-backend "claude")
                "claude (CLI) offers its short model aliases")
  (ensure-equal '()
                (self-improving-agent-harness::web-model-options-for-backend "unknown-backend")
                "an unrecognized backend name returns an empty model list rather than erroring")
  ;; Issue #90 regression: each backend's option list must be genuinely
  ;; distinct so switching backends is observable at all.
  (ensure-true (not (equal (self-improving-agent-harness::web-model-options-for-backend "claude-sdk")
                          (self-improving-agent-harness::web-model-options-for-backend "synthetic")))
               "claude-sdk and synthetic model lists differ (precondition for issue #90's fix to matter)")

  ;; --- web-model-value-after-backend-change (issue #90 fix logic) ---------
  (ensure-equal "gpt-4o"
                (self-improving-agent-harness::web-model-value-after-backend-change
                 "gpt-4o" "openrouter")
                "a model value already valid for the new backend is preserved")
  (ensure-equal "gpt-4o"
                (self-improving-agent-harness::web-model-value-after-backend-change
                 "gpt-4o" "synthetic")
                "a model value valid for both the old and new backend is preserved across the switch")
  (ensure-equal "claude-sonnet-5"
                (self-improving-agent-harness::web-model-value-after-backend-change
                 "gpt-4o" "claude-sdk")
                "a model value invalid for the new backend falls back to that backend's default")
  (ensure-equal "claude-haiku-4-5-20251001"
                (self-improving-agent-harness::web-model-value-after-backend-change
                 "claude-sonnet-5" "synthetic")
                "switching claude-sdk -> synthetic with an invalid carried-over value falls back to synthetic's default")
  (ensure-equal (self-improving-agent-harness::web-default-model-for-backend "openrouter")
                (self-improving-agent-harness::web-model-value-after-backend-change
                 "" "openrouter")
                "an empty current model value falls back to the new backend's default")
  (ensure-equal (self-improving-agent-harness::web-default-model-for-backend "openrouter")
                (self-improving-agent-harness::web-model-value-after-backend-change
                 nil "openrouter")
                "a nil current model value falls back to the new backend's default without erroring")
  (ensure-equal (self-improving-agent-harness::web-default-model-for-backend "openrouter")
                (self-improving-agent-harness::web-model-value-after-backend-change
                 "   " "openrouter")
                "a whitespace-only current model value falls back to the new backend's default")
  (ensure-equal "gpt-4o"
                (self-improving-agent-harness::web-model-value-after-backend-change
                 "  gpt-4o  " "synthetic")
                "a current model value is trimmed before validity is checked")

  ;; --- web-selected-backend: dispatch and credential-free construction -----
  (let ((self-improving-agent-harness::*web-fake-scenario* nil))
    (ensure-equal "openrouter" (backend-name (self-improving-agent-harness::web-selected-backend "openrouter"))
                  "the openrouter backend name selects an openrouter backend instance")
    (ensure-equal "synthetic" (backend-name (self-improving-agent-harness::web-selected-backend "synthetic"))
                  "the synthetic backend name selects a synthetic backend instance")
    (ensure-equal "codex-app-server" (backend-name (self-improving-agent-harness::web-selected-backend "codex"))
                  "the codex backend name selects a codex-app-server backend instance")
    (ensure-equal "claude" (backend-name (self-improving-agent-harness::web-selected-backend "claude"))
                  "the claude backend name selects a claude CLI backend instance")
    (ensure-equal "claude-sdk" (backend-name (self-improving-agent-harness::web-selected-backend "claude-sdk"))
                  "the claude-sdk backend name selects a claude-sdk backend instance")
    (handler-case
        (progn
          (self-improving-agent-harness::web-selected-backend "not-a-real-backend")
          (error "Test failed: an unknown backend name must signal an error"))
      (error (condition)
        (ensure-true (search "not-a-real-backend" (princ-to-string condition))
                     "an unknown backend name's error message names the rejected value"))))

  ;; web-selected-backend must never perform network I/O or require
  ;; credentials merely to construct the backend object (matches every
  ;; backend's own make-BACKEND-NAME-backend contract).
  (let ((saved-openrouter (uiop:getenv "OPENROUTER_API_KEY"))
        (saved-synthetic (uiop:getenv "SYNTHETIC_API_KEY")))
    (unwind-protect
         (progn
           (sb-posix:unsetenv "OPENROUTER_API_KEY")
           (sb-posix:unsetenv "SYNTHETIC_API_KEY")
           (ensure-true (self-improving-agent-harness::web-selected-backend "openrouter")
                        "constructing the openrouter backend does not require a credential to be present")
           (ensure-true (self-improving-agent-harness::web-selected-backend "synthetic")
                        "constructing the synthetic backend does not require a credential to be present"))
      (when saved-openrouter (setf (uiop:getenv "OPENROUTER_API_KEY") saved-openrouter))
      (when saved-synthetic (setf (uiop:getenv "SYNTHETIC_API_KEY") saved-synthetic))))

  ;; --- web-selected-backend: deterministic fake-tool-success scenario -----
  (let ((self-improving-agent-harness::*web-fake-scenario* "tool-success"))
    (ensure-equal "web-fake" (backend-name (self-improving-agent-harness::web-selected-backend "openrouter"))
                  "the tool-success fake scenario overrides normal backend dispatch")
    (ensure-equal "web-fake" (backend-name (self-improving-agent-harness::web-selected-backend "claude-sdk"))
                  "the tool-success fake scenario overrides even claude-sdk dispatch"))

  ;; --- web-register-session / web-known-sessions: in-memory registry ------
  (web-app-tests-reset-session-registry)
  (unwind-protect
       (let* ((response (make-completion-response :text "ok" :model "test/model"))
              (backend-a (make-instance 'scripted-backend :name "scripted" :responses (list response)))
              (backend-b (make-instance 'scripted-backend :name "scripted" :responses (list response)))
              (session-a (make-web-session :backend backend-a :model "test/model"
                                          :durable-session-id "2020-01-01T00:00:00.000Z"))
              (session-b (make-web-session :backend backend-b :model "test/model"
                                          :durable-session-id "2020-06-01T00:00:00.000Z")))
         (ensure-equal '() (self-improving-agent-harness::web-known-sessions :refresh nil)
                       "the registry starts empty before any session is registered")
         (self-improving-agent-harness::web-register-session session-a)
         (self-improving-agent-harness::web-register-session session-b)
         (ensure-equal (list session-b session-a)
                       (self-improving-agent-harness::web-known-sessions :refresh nil)
                       "known sessions sort newest-durable-id-first regardless of registration order")
         (ensure-equal (web-session-id session-a)
                       (web-session-id (self-improving-agent-harness::web-register-session session-a))
                       "re-registering the same session object is idempotent (returns the same session)")
         (ensure-equal 2 (length (self-improving-agent-harness::web-known-sessions :refresh nil))
                       "re-registering an already-registered session does not duplicate it in the order list")
         (ensure-equal (format nil "2020-06-01T00:00:00.000Z · 0 turns")
                       (self-improving-agent-harness::web-session-summary session-b)
                       "session summary reports the durable id and a pluralized zero-turn count")
         (web-session-submit session-b "hello")
         (ensure-equal (format nil "2020-06-01T00:00:00.000Z · 1 turn")
                       (self-improving-agent-harness::web-session-summary session-b)
                       "session summary reports a singular turn count after one completed turn"))
    (web-app-tests-reset-session-registry))

  ;; --- web-load-durable-session: materializing a snapshot descriptor ------
  (web-app-tests-reset-session-registry)
  (unwind-protect
       (progn
         ;; A descriptor with a recognized backend name is honored as-is.
         (let ((session (self-improving-agent-harness::web-load-durable-session
                         (list :session-id "2021-01-01T00:00:00.000Z"
                               :backend "synthetic" :model "syn:large:text"
                               :max-rounds 12 :history nil))))
           (ensure-equal "2021-01-01T00:00:00.000Z" (self-improving-agent-harness::web-session-durable-session-id session)
                        "a loaded durable session keeps the descriptor's durable session id")
           (ensure-equal "synthetic" (backend-name (self-improving-agent-harness::chat-session-backend (web-session-chat-session session)))
                        "a loaded durable session's backend matches its descriptor's recognized backend name")
           (ensure-equal "syn:large:text" (self-improving-agent-harness::chat-session-model (web-session-chat-session session))
                        "a loaded durable session's model matches its descriptor")
           (ensure-equal 12 (chat-session-max-rounds (web-session-chat-session session))
                        "a loaded durable session's max-rounds matches its descriptor"))
         ;; An unrecognized/missing backend name in the descriptor defaults
         ;; safely to claude-sdk rather than erroring or silently trusting an
         ;; arbitrary string.
         (let ((session (self-improving-agent-harness::web-load-durable-session
                         (list :session-id "2021-02-01T00:00:00.000Z"
                               :backend "not-a-real-backend" :model nil
                               :max-rounds nil :history nil))))
           (ensure-equal "claude-sdk" (backend-name (self-improving-agent-harness::chat-session-backend (web-session-chat-session session)))
                        "an unrecognized descriptor backend name safely defaults to claude-sdk")
           (ensure-equal (self-improving-agent-harness::web-default-model-for-backend "claude-sdk")
                        (self-improving-agent-harness::chat-session-model (web-session-chat-session session))
                        "a descriptor with no model falls back to that backend's default model")
           (ensure-equal 60 (chat-session-max-rounds (web-session-chat-session session))
                        "a descriptor with no max-rounds falls back to 60"))
         ;; Loading the same durable session id twice returns the existing
         ;; in-memory session rather than constructing a second one.
         (let* ((first-load (self-improving-agent-harness::web-load-durable-session
                             (list :session-id "2021-03-01T00:00:00.000Z" :backend "synthetic")))
                (second-load (self-improving-agent-harness::web-load-durable-session
                              (list :session-id "2021-03-01T00:00:00.000Z" :backend "synthetic"))))
           (ensure-equal (web-session-id first-load) (web-session-id second-load)
                        "loading an already-registered durable session id returns the same browser session")))
    (web-app-tests-reset-session-registry))

  (format t "Web-app tests passed.~%")
  t)
