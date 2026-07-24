(in-package #:self-improving-agent-harness/tests)

;;;; Test-first contract for the TypeScript Agent SDK bridge backend.  The runner
;;;; is injectable so this suite stays Docker-offline and never contacts Claude.

(defun with-claude-shim-test-token (value thunk)
  (let ((saved (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN")))
    (unwind-protect
         (progn
           (if value
               (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") value)
               (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN"))
           (funcall thunk))
      (if saved
          (setf (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN") saved)
          (sb-posix:unsetenv "CLAUDE_CODE_OAUTH_TOKEN")))))

(defun claude-shim-test-request ()
  (make-completion-request
   :model "claude-sonnet-5"
   :messages (list (list :role "user" :content "Use the supplied tool, then say done."))))

(defun run-claude-shim-backend-tests ()
  ;; The OAuth guard must fire before a bridge process is started.
  (with-claude-shim-test-token
   nil
   (lambda ()
     (let* ((called nil)
           (backend (make-claude-shim-backend
                     :runner (lambda (&rest ignored)
                               (declare (ignore ignored))
                               (setf called t)
                               "{}"))))
       (handler-case
           (progn
             (complete backend (claude-shim-test-request))
             (error "Test failed: missing shim OAuth token must signal"))
         (claude-shim-backend-error (condition)
           (ensure-true (search "CLAUDE_CODE_OAUTH_TOKEN"
                                (claude-shim-backend-error-reason condition))
                        "shim missing-token error identifies its OAuth variable")))
       (ensure-true (not called) "shim missing token fails before bridge runner"))))

  ;; Native SDK tool activity is already executed by the SDK. It is emitted to
  ;; the existing UI/session event seam, never returned as a pending Lisp call.
  (with-claude-shim-test-token
   "test-shim-oauth"
   (lambda ()
     (let* ((seen-request (claude-shim-test-request))
           (backend
             (make-claude-shim-backend
              :runner (lambda (request token timeout)
                        (declare (ignore timeout))
                        (setf seen-request request)
                        (ensure-equal "test-shim-oauth" token
                                      "OAuth token reaches only bridge runner")
                        "{\"schema\":\"claude-shim/v1\",\"type\":\"result\",\"text\":\"done\",\"model\":\"claude-sonnet-5\",\"finish_reason\":\"stop\",\"native_tool_events\":[{\"tool_call_id\":\"toolu_1\",\"tool_name\":\"run_shell\",\"arguments\":\"{\\\"command\\\":\\\"printf shim-ok\\\"}\",\"result\":\"shim-ok\",\"status\":\"completed\"}]}"))))
       (let ((response (complete backend (claude-shim-test-request))))
         (ensure-equal "claude-shim" (backend-name backend)
                       "shim backend has a stable provider name")
         (ensure-equal "done" (completion-response-text response)
                       "bridge result text normalizes to completion response")
         (ensure-equal '() (completion-response-tool-calls response)
                       "SDK-owned tool is never pending a second harness execution")
         (let ((event (first (completion-response-native-tool-events response))))
           (ensure-equal "run_shell" (getf event :tool-name)
                         "native SDK tool name reaches existing lifecycle seam")
           (ensure-equal "shim-ok" (getf event :result)
                         "native SDK tool result reaches existing lifecycle seam"))
         (ensure-equal "claude-sonnet-5" (completion-request-model seen-request)
                       "exact selected model is forwarded to bridge runner"))))))
