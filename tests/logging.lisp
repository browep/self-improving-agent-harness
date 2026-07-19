(in-package #:self-improving-agent-harness/tests)

(defun logging-test-session-path (directory session-id)
  (merge-pathnames
   (format nil "~A.jsonl" session-id)
   directory))

(defun only-jsonl-files (directory)
  (remove-if-not
   (lambda (path)
     (string= "jsonl" (string-downcase (or (pathname-type path) ""))))
   (uiop:directory-files directory)))

(defun run-scrub-termination-regression ()
  "Fail (bounded) if SCRUB-INTERACTION-LOG-TEXT ever loops forever again.

Historically REPLACE-ALL re-searched from index 0, so replacing
\"OPENROUTER_API_KEY=\" with \"OPENROUTER_API_KEY=***\" matched endlessly and grew
the string until the heap exhausted -- hanging any chat that logged tool output
mentioning the key. The WITH-TIMEOUT converts a regression into a clean, fast
failure instead of another silent hang."
  (handler-case
      (sb-ext:with-timeout 10
        (let ((result (self-improving-agent-harness::scrub-interaction-log-text
                       "OPENROUTER_API_KEY=sk-live-secret and again OPENROUTER_API_KEY= here")))
          (ensure-true (search "OPENROUTER_API_KEY=***" result)
                       "scrub redacts the OPENROUTER_API_KEY= marker")
          (ensure-true (not (search "sk-live-secret" result))
                       "scrub redacts sk- token bodies")
          (ensure-true (< (length result) 200)
                       "scrub does not grow the string without bound")))
    (sb-ext:timeout ()
      (error "Test failed: scrub-interaction-log-text did not terminate (infinite-loop regression).")))
  (format t "Scrub termination regression passed.~%")
  t)

(defun run-logging-tests ()
  (run-scrub-termination-regression)
  (let* ((directory #P"/tmp/self-improving-agent-harness-logging-test/")
         (session-id "2026-01-01T00:00:00.001Z")
         (path (logging-test-session-path directory session-id)))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id session-id)
           (self-improving-agent-harness::log-interaction
            :info "turn-received" :content "OPENROUTER_API_KEY=sk-test-do-not-persist")
           (self-improving-agent-harness::log-interaction
            :error "turn-failed" :message "Tool handler \"run_shell\" failed.")
           (let ((content (uiop:read-file-string path)))
             (ensure-true (probe-file path)
                          "interaction log uses a per-session $ISO-TIMESTAMP.jsonl file")
             (ensure-true (search "\"type\":\"user\"" content)
                          "interaction log uses Claude-style type=user for turns")
             (ensure-true (search "\"type\":\"system\"" content)
                          "interaction log uses Claude-style type=system for failures")
             (ensure-true (search "\"sessionId\":" content)
                          "interaction log includes camelCase sessionId via openrouter-json")
             (ensure-true (search "\"parentUuid\":" content)
                          "interaction log includes Claude-style parentUuid linkage")
             (ensure-true (search "\"uuid\":" content)
                          "interaction log includes a per-record uuid")
             (ensure-true (search "turn-received" content)
                          "interaction log retains the turn lifecycle event")
             (ensure-true (search "\"initiator\":\"human\"" content)
                          "interaction log records initiator at top level")
             (ensure-true (search "OPENROUTER_API_KEY=***" content)
                          "interaction log retains scrubbed turn content")
             (ensure-true (not (search "sk-test-do-not-persist" content))
                          "interaction log redacts secret-looking token bodies")
             (ensure-true (search "Tool handler" content)
                          "interaction log can retain failure message text when content logging is on")
             (ensure-true (not (probe-file (merge-pathnames "chat.log" directory)))
                          "legacy shared chat.log is no longer written")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  (let* ((directory #P"/tmp/self-improving-agent-harness-turn-logging-test/")
         (session-id "2026-01-01T00:00:00.002Z")
         (path (logging-test-session-path directory session-id))
         (backend (make-instance 'scripted-backend :name "scripted" :responses '()))
         (session (make-chat-session :backend backend :model "test/model" :handlers '())))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id session-id)
           (handler-case
               (chat-session-turn session "trigger a scripted backend failure")
             (error () nil))
           (let ((content (uiop:read-file-string path)))
             (ensure-true (search "turn-received" content)
                          "chat session logs the received user turn")
             (ensure-true (search "turn-failed" content)
                          "chat session logs failed turns")
             (ensure-true (search "\"initiator\":\"human\"" content)
                          "chat session turn records include initiator=human")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  (let* ((directory #P"/tmp/self-improving-agent-harness-tool-logging-test/")
         (session-id "2026-01-01T00:00:00.003Z")
         (path (logging-test-session-path directory session-id))
         (arguments (make-hash-table :test #'equal)))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (setf (gethash "command" arguments) "exit 9")
    (unwind-protect
         (progn
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id session-id)
           (handler-case
               (run-shell-tool arguments)
             (error () nil))
           (let ((content (uiop:read-file-string path)))
             (ensure-true (search "tool-call" content)
                          "shell tool logs its command invocation")
             (ensure-true (search "\"type\":\"tool\"" content)
                          "shell tool events use Claude-style type=tool")
             (ensure-true (search "tool-failed" content)
                          "shell tool logs failed command execution")
             (ensure-true (search "exit 9" content)
                          "shell tool log can retain the command when content logging is on")
             (ensure-true (search "\"initiator\":" content)
                          "tool log records include initiator")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  (let* ((directory #P"/tmp/self-improving-agent-harness-correlation-logging-test/")
         (session-id "2026-01-01T00:00:00.004Z")
         (path (logging-test-session-path directory session-id)))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id session-id)
           (let ((self-improving-agent-harness::*interaction-turn-number* 2))
             (self-improving-agent-harness::log-interaction :info "turn-completed")
             (let ((*error-output* (make-string-output-stream)))
               (dolist (event '("turn-submitted" "turn-completed" "turn-failed" "turn-empty"))
                 (self-improving-agent-harness:emit-chat-event event))
               (let ((events (get-output-stream-string *error-output*)))
                 (ensure-true (search (format nil "\"session_id\":\"~A\"" session-id) events)
                              "chat boundary events include their session ID")
                 (ensure-true (search "\"turn\":2" events)
                              "chat boundary events include their submitted turn number")
                 (dolist (event '("turn-submitted" "turn-completed" "turn-failed" "turn-empty"))
                   (ensure-true (search event events)
                                "chat boundary event states remain distinguishable")))))
           (let ((content (uiop:read-file-string path)))
             (ensure-true (search (format nil "\"sessionId\":\"~A\"" session-id) content)
                          "per-session diagnostic log includes the session ID")
             (ensure-true (search "\"turn\":2" content)
                          "per-session diagnostic log includes the turn number")
             (ensure-true (search "\"type\":\"assistant\"" content)
                          "turn-completed maps to Claude-style type=assistant")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  ;; Non-timestamp preferred ids still get an ISO-timestamp-named session file.
  (let* ((directory #P"/tmp/self-improving-agent-harness-iso-normalize-test/"))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id "event-session-16")
           (self-improving-agent-harness::log-interaction :info "session-start" :mode "interactive")
           (let* ((files (only-jsonl-files directory))
                  (correlation self-improving-agent-harness::*interaction-session-id*)
                  (file-id self-improving-agent-harness::*interaction-log-file-id*))
             (ensure-true (= 1 (length files))
                          "exactly one per-session jsonl file is created")
             (ensure-true (string= correlation "event-session-16")
                          "non-timestamp correlation ids remain available for stderr events")
             (ensure-true (self-improving-agent-harness::session-id-looks-like-iso-timestamp-p file-id)
                          "non-timestamp correlation ids still use an ISO timestamp log basename")
             (ensure-true (probe-file (logging-test-session-path directory file-id))
                          "session file path matches the ISO timestamp file id")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  ;; initiator=harness is visible for synthetic follow-up style turns.
  (let* ((directory #P"/tmp/self-improving-agent-harness-initiator-logging-test/")
         (session-id "2026-01-01T00:00:00.005Z")
         (path (logging-test-session-path directory session-id)))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id session-id)
           (let ((self-improving-agent-harness:*interaction-turn-initiator* "harness"))
             (self-improving-agent-harness::log-interaction
              :info "turn-received" :content "[harness] synthetic follow-up"))
           (let ((content (uiop:read-file-string path)))
             (ensure-true (search "\"initiator\":\"harness\"" content)
                          "harness-initiated turns record initiator=harness")
             (ensure-true (search "[harness] synthetic follow-up" content)
                          "harness-initiated turn content is retained in JSONL")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))


  ;; Hang-diagnosis events keep tool typing and retain status/duration metadata.
  (let* ((directory #P"/tmp/self-improving-agent-harness-hang-diagnosis-logging-test/")
         (session-id "2026-01-01T00:00:00.006Z")
         (path (logging-test-session-path directory session-id)))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (unwind-protect
         (progn
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id session-id)
           (self-improving-agent-harness::log-interaction
            :info "provider-request" :round 0 :model "test/model"
            :timeout-seconds 120)
           (self-improving-agent-harness::log-interaction
            :error "provider-http-error" :status-code 500
            :duration-seconds 1.25
            :body-snippet "internal error detail"
            :message "OpenRouter request failed with HTTP status 500.")
           (self-improving-agent-harness::log-interaction
            :info "reload-progress" :tool "reload_harness"
            :loaded-file-count 2 :total-file-count 5
            :file "src/backend.lisp")
           (let ((content (uiop:read-file-string path)))
             (ensure-true (search "\"event\":\"provider-request\"" content)
                          "provider-request remains durable")
             (ensure-true (search "\"timeoutSeconds\":120" content)
                          "provider timeout metadata is retained")
             (ensure-true (search "\"event\":\"provider-http-error\"" content)
                          "provider-http-error is durable")
             (ensure-true (search "\"statusCode\":500" content)
                          "HTTP status codes are retained")
             (ensure-true (search "internal error detail" content)
                          "HTTP body snippets are retained when content logging is on")
             (ensure-true (search "\"event\":\"reload-progress\"" content)
                          "reload-progress is durable")
             (ensure-true (search "src/backend.lisp" content)
                          "reload progress retains the relative file path")
             (ensure-true (search "\"type\":\"tool\"" content)
                          "hang-diagnosis provider/reload events map to type=tool")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))
  (format t "Interaction logging tests passed.~%")
  t)
