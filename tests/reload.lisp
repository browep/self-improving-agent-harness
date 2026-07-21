(in-package #:self-improving-agent-harness/tests)

(defun reload-result-field (message key)
  "Extract a status=... field value from a structured reload tool result."
  (let* ((token (format nil "~A=" key))
         (start (search token message)))
    (when start
      (let* ((value-start (+ start (length token)))
             (value-end (or (position #\Space message :start value-start)
                            (position #\Newline message :start value-start)
                            (length message))))
        (subseq message value-start value-end)))))

(defun run-reload-tests ()
  (self-improving-agent-harness:clear-synthetic-followups)
  (let ((message (self-improving-agent-harness:reload-harness-tool nil)))
    (ensure-true (search "Reloaded self-improving-agent-harness" message)
                 "reload tool reports a successful in-process reload")
    (ensure-true (search "self-improving-agent-harness.asd" message)
                 "reload tool names the project ASD")
    (ensure-true (search "status=" message)
                 "reload tool returns a structured status line")
    (ensure-equal "ok" (reload-result-field message "status")
                  "clean reload reports status=ok after filtering benign redefinitions")
    (ensure-true (search "files=" message)
                 "reload tool reports how many source files were loaded")
    (ensure-true (search "warnings=0" message)
                 "clean reload reports zero non-benign warnings")
    (ensure-true (search "notes=0" message)
                 "clean reload reports zero compiler notes")
    (ensure-true (search "benign_redefinitions=" message)
                 "reload tool counts expected redefinition warnings separately"))

  ;; Non-benign diagnostics are included in the structured tool result.
  (let ((message
          (self-improving-agent-harness::format-reload-tool-result
           :status "warning"
           :asd #P"/workspace/self-improving-agent-harness.asd"
           :file-count 8
           :warning-count 1
           :note-count 0
           :benign-count 12
           :diagnostics '("style-warning: src/example.lisp: The variable X is defined but never used.")
           :error-message nil)))
    (ensure-true (search "status=warning" message)
                 "warning status is encoded for the tool caller")
    (ensure-true (search "warnings=1" message)
                 "warning count is encoded for the tool caller")
    (ensure-true (search "style-warning: src/example.lisp:" message)
                 "non-benign diagnostic text is included for the tool caller"))

  ;; Load/read failures become status=error tool results with detail, not an empty failure.
  (let ((message
          (self-improving-agent-harness::format-reload-tool-result
           :status "error"
           :asd #P"/workspace/self-improving-agent-harness.asd"
           :file-count 0
           :warning-count 0
           :note-count 0
           :benign-count 0
           :diagnostics '()
           :error-message "error: src/broken.lisp: end of file on #<STREAM>")))
    (ensure-equal "error" (reload-result-field message "status")
                  "failed reload reports status=error")
    (ensure-true (search "error: src/broken.lisp:" message)
                 "failed reload includes the error detail for the tool caller"))

  (let* ((tool-response
           (make-completion-response
            :text ""
            :model "test/model"
            :tool-calls '((:id "call-reload" :type "function" :name "reload_harness"
                           :arguments "{}"))))
         (final-response
           (make-completion-response :text "reloaded in-process" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list tool-response final-response)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "Reload the harness.")))
            `(("reload_harness" . ,#'self-improving-agent-harness:reload-harness-tool)))))
    (ensure-equal "reloaded in-process" (completion-response-text result)
                  "reload_harness participates in the normal tool loop")
    (let* ((continuation (first (scripted-backend-received-requests backend)))
           (tool-message (third (completion-request-messages continuation))))
      (ensure-equal "tool" (getf tool-message :role)
                    "reload tool result is returned as a tool message")
      (ensure-true (search "status=" (getf tool-message :content))
                   "structured reload status reaches the model")
      (ensure-true (search "Reloaded self-improving-agent-harness"
                           (getf tool-message :content))
                   "reload tool result content reaches the model")))
  (let ((session (make-chat-session :backend nil :model "test/model" :handlers '())))
    (ensure-equal 60 (chat-session-max-rounds session)
                  "session default max-rounds remains 60")
    (setf (chat-session-max-rounds session) 24)
    (ensure-equal 24 (chat-session-max-rounds session)
                  "session max-rounds can be updated in-process"))
  (ensure-true (boundp 'self-improving-agent-harness:+chat-input-prompt+)
               "chat CLI prompt parameter is part of the reloadable system")
  (ensure-true (fboundp 'self-improving-agent-harness:write-chat-prompt)
               "write-chat-prompt is reloadable")
  (ensure-true (fboundp 'self-improving-agent-harness:run-chat-cli)
               "run-chat-cli is reloadable")
  (ensure-true (fboundp 'self-improving-agent-harness:process-interactive-user-turn)
               "process-interactive-user-turn is reloadable for mid-session outcome changes")
  (ensure-true (fboundp 'self-improving-agent-harness:write-final-response-outcome)
               "write-final-response-outcome is reloadable")
  ;; Outcome formatting is dispatched by name from the interactive loop.
  (let ((stderr (make-string-output-stream)))
    (let ((*error-output* stderr))
      (self-improving-agent-harness:write-final-response-outcome
       :rounds 3 :duration-seconds 1.5d0))
    (let ((out (get-output-stream-string stderr)))
      (ensure-true (search "<<< DONE rounds=3 duration_seconds=1.500" out)
                   "final-response outcome reports rounds and duration")
      (ensure-true (not (search "model=" out))
                   "final-response outcome no longer embeds the model id")))

  ;; Token/context suffix: appended when accounting is supplied, and the
  ;; context-length ceiling is known. The model id must never appear (no
  ;; "model=" substring), only the numeric ceiling and fill percentage.
  (self-improving-agent-harness::reset-model-metadata-cache)
  (let ((backend (self-improving-agent-harness::make-openrouter-backend :api-key "k")))
    (self-improving-agent-harness::store-model-metadata
     "openrouter"
     (yason:parse
      "{\"data\":[{\"id\":\"test/model\",\"context_length\":200000,\"top_provider\":{\"context_length\":200000}}]}"))
    (let ((stderr (make-string-output-stream)))
      (let ((*error-output* stderr))
        (self-improving-agent-harness:write-final-response-outcome
         :rounds 2 :duration-seconds 0.5d0
         :backend backend
         :model "test/model"
         :accounting (list :aggregate
                           (list :input-tokens 1500 :input-tokens-state "actual"
                                 :output-tokens 500 :output-tokens-state "actual"
                                 :total-tokens 2000 :total-tokens-state "actual"
                                 :cost-usd 0 :cost-usd-state "actual"))))
      (let ((out (get-output-stream-string stderr)))
        (ensure-true (search "<<< DONE rounds=2 duration_seconds=0.500" out)
                     "outcome still reports rounds and duration with suffix")
        (ensure-true (search "tokens=1500/500/2000" out)
                     "outcome reports input/output/total tokens")
        (ensure-true (search "context=2000/200000 (1%)" out)
                     "outcome reports context fill with percentage")
        (ensure-true (not (search "model=" out))
                   "outcome suffix never embeds the model id")))
    (self-improving-agent-harness::reset-model-metadata-cache))

  ;; CLI sessions store options/handlers as symbols so later turns re-resolve.
  (let ((session (self-improving-agent-harness::make-cli-chat-session nil "test/model" 9)))
    (ensure-equal 'self-improving-agent-harness:chat-options
                  (chat-session-options session)
                  "CLI sessions store chat-options as a symbol designator")
    (ensure-equal 'self-improving-agent-harness:chat-handlers
                  (chat-session-handlers session)
                  "CLI sessions store chat-handlers as a symbol designator")
    (let ((handlers (self-improving-agent-harness:resolve-chat-session-handlers session)))
      (ensure-equal 'self-improving-agent-harness::shell-tool
                    (cdr (assoc "run_shell" handlers :test #'string=))
                    "resolved CLI handlers use symbol tool implementations")
      (ensure-equal 'self-improving-agent-harness::reload-tool
                    (cdr (assoc "reload_harness" handlers :test #'string=))
                    "resolved CLI handlers keep reload_harness as a symbol")))

  ;; Symbol tool handlers are resolved at call time (hot-reload friendly).
  (let* ((calls 0)
         (tool-response
           (make-completion-response
            :text ""
            :model "test/model"
            :tool-calls '((:id "call-symbol" :type "function" :name "mark"
                           :arguments "{}"))))
         (final-response
           (make-completion-response :text "symbol-handler-ok" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list tool-response final-response))))
    (setf (fdefinition 'self-improving-agent-harness/tests::reloadable-mark-tool)
          (lambda (arguments)
            (declare (ignore arguments))
            (incf calls)
            "marked"))
    (let ((result
            (self-improving-agent-harness:run-tool-loop
             backend
             (make-completion-request
              :model "test/model"
              :messages '((:role "user" :content "mark it")))
             '(("mark" . self-improving-agent-harness/tests::reloadable-mark-tool)))))
      (ensure-equal "symbol-handler-ok" (completion-response-text result)
                    "symbol tool handlers participate in the tool loop")
      (ensure-equal 1 calls
                    "symbol tool handlers are funcalled through the designator")))

  ;; Re-resolving options/handlers designators picks up redefined functions.
  (let* ((session (make-chat-session
                   :backend nil
                   :model "test/model"
                   :options 'self-improving-agent-harness/tests::reloadable-chat-options
                   :handlers 'self-improving-agent-harness/tests::reloadable-chat-handlers)))
    (setf (fdefinition 'self-improving-agent-harness/tests::reloadable-chat-options)
          (lambda () '(:max-tokens 1)))
    (setf (fdefinition 'self-improving-agent-harness/tests::reloadable-chat-handlers)
          (lambda () '(("echo" . self-improving-agent-harness/tests::reloadable-echo-v1))))
    (ensure-equal '(:max-tokens 1)
                  (self-improving-agent-harness:resolve-chat-session-options session)
                  "options designator is resolved on demand")
    (setf (fdefinition 'self-improving-agent-harness/tests::reloadable-chat-options)
          (lambda () '(:max-tokens 2 :temperature 0.1)))
    (ensure-equal '(:max-tokens 2 :temperature 0.1)
                  (self-improving-agent-harness:resolve-chat-session-options session)
                  "redefined options designator is visible without rebuilding the session")
    (ensure-equal 'self-improving-agent-harness/tests::reloadable-echo-v1
                  (cdr (assoc "echo"
                              (self-improving-agent-harness:resolve-chat-session-handlers session)
                              :test #'string=))
                  "handlers designator is resolved on demand")
    (setf (fdefinition 'self-improving-agent-harness/tests::reloadable-chat-handlers)
          (lambda () '(("echo" . self-improving-agent-harness/tests::reloadable-echo-v2))))
    (ensure-equal 'self-improving-agent-harness/tests::reloadable-echo-v2
                  (cdr (assoc "echo"
                              (self-improving-agent-harness:resolve-chat-session-handlers session)
                              :test #'string=))
                  "redefined handlers designator is visible without rebuilding the session"))

  ;; Leading system prompt tracks +chat-system-prompt+ across reloads.
  (let* ((session (make-chat-session :backend nil :model "test/model" :handlers '()))
         (original self-improving-agent-harness:+chat-system-prompt+))
    (unwind-protect
         (progn
           (setf self-improving-agent-harness:+chat-system-prompt+
                 "updated system prompt for reload tests")
           (self-improving-agent-harness:ensure-chat-session-system-prompt session)
           (ensure-equal "updated system prompt for reload tests"
                         (getf (first (chat-session-history session)) :content)
                         "ensure-chat-session-system-prompt rewrites the leading system message"))
      (setf self-improving-agent-harness:+chat-system-prompt+ original)))

  (ensure-true (fboundp 'self-improving-agent-harness:process-interactive-input)
               "process-interactive-input is reloadable interactive dispatch")
  (ensure-true (fboundp 'self-improving-agent-harness:run-interactive-loop)
               "run-interactive-loop is the thin long-lived interactive frame")

  ;; Synthetic follow-up queue: schedule + consume without a human message.
  (self-improving-agent-harness:clear-synthetic-followups)
  (ensure-true (null self-improving-agent-harness:*pending-synthetic-followups*)
               "synthetic follow-up queue starts empty in this test")
  (self-improving-agent-harness:schedule-synthetic-followup
   "auto follow-up please use new tools"
   :source "test")
  (ensure-equal 1 (length self-improving-agent-harness:*pending-synthetic-followups*)
                "schedule-synthetic-followup enqueues one item")
  (ensure-equal "auto follow-up please use new tools"
                (self-improving-agent-harness:take-next-synthetic-followup)
                "take-next-synthetic-followup returns FIFO content")
  (ensure-true (null self-improving-agent-harness:*pending-synthetic-followups*)
               "queue is empty after taking the only item")

  ;; Successful reload_harness schedules a synthetic follow-up automatically.
  (self-improving-agent-harness:clear-synthetic-followups)
  (let ((message (self-improving-agent-harness:reload-harness-tool nil)))
    (ensure-equal "ok" (reload-result-field message "status")
                  "reload for synthetic-followup scheduling reports status=ok")
    (ensure-true (plusp (length self-improving-agent-harness:*pending-synthetic-followups*))
                 "successful reload_harness schedules a synthetic follow-up")
    (ensure-true (search "reload_harness finished"
                         (first self-improving-agent-harness:*pending-synthetic-followups*))
                 "synthetic follow-up text mentions reload_harness")
    (self-improving-agent-harness:clear-synthetic-followups))

  ;; maybe-run-synthetic-followup-turns issues a real chat turn with the queued text.
  (self-improving-agent-harness:clear-synthetic-followups)
  (let* ((followup-response
           (make-completion-response :text "synthetic-followup-ok" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list followup-response)))
         (session (make-chat-session :backend backend :model "test/model"
                                     :options '(:max-tokens 32) :handlers '())))
    (self-improving-agent-harness:schedule-synthetic-followup
     "[harness] test synthetic follow-up" :source "test")
    (let ((stdout (make-string-output-stream))
          (stderr (make-string-output-stream)))
      (let ((*standard-output* stdout)
            (*error-output* stderr))
        (self-improving-agent-harness:maybe-run-synthetic-followup-turns session))
      (let ((err (get-output-stream-string stderr)))
        (ensure-true (search "SYNTHETIC_FOLLOWUP begin initiator=harness" err)
                     "synthetic follow-up announces begin on stderr")
        (ensure-true (search "SYNTHETIC_FOLLOWUP end initiator=harness status=ok" err)
                     "synthetic follow-up announces end on stderr")))
    (ensure-equal "synthetic-followup-ok"
                  (getf (car (last (chat-session-history session))) :content)
                  "synthetic follow-up appends the assistant reply to history")
    (let* ((requests (reverse (scripted-backend-received-requests backend)))
           (messages (completion-request-messages (first requests))))
      (ensure-equal 1 (length requests)
                    "synthetic follow-up performs one provider request")
      (ensure-equal "[harness] test synthetic follow-up"
                    (getf (car (last messages)) :content)
                    "synthetic follow-up sends the queued user content")
      (ensure-true (null self-improving-agent-harness:*pending-synthetic-followups*)
                   "synthetic follow-up queue is consumed after running")))

  ;; Scheduling is suppressed while a synthetic follow-up is running.
  (self-improving-agent-harness:clear-synthetic-followups)
  (let ((self-improving-agent-harness:*suppress-synthetic-followup-scheduling* t))
    (self-improving-agent-harness:schedule-synthetic-followup "should not queue" :source "test")
    (ensure-true (null self-improving-agent-harness:*pending-synthetic-followups*)
                 "suppress flag blocks schedule-synthetic-followup"))

  
  ;; Successful reload leaves started/progress/completed breadcrumbs with duration.
  (let* ((directory #P"/tmp/self-improving-agent-harness-reload-progress-test/")
         (session-id "2026-01-01T00:00:00.007Z")
         (path (merge-pathnames (format nil "~A.jsonl" session-id) directory)))
    (when (probe-file directory)
      (uiop:delete-directory-tree directory :validate t))
    (ensure-directories-exist directory)
    (unwind-protect
         (progn
           (self-improving-agent-harness:clear-synthetic-followups)
           (self-improving-agent-harness::configure-interaction-logging
            directory :session-id session-id)
           (let ((message (self-improving-agent-harness:reload-harness-tool nil)))
             (ensure-equal "ok" (reload-result-field message "status")
                           "progress-instrumented reload still reports status=ok"))
           (let ((content (uiop:read-file-string path)))
             (ensure-true (search "\"event\":\"reload-started\"" content)
                          "reload logs reload-started")
             (ensure-true (search "\"event\":\"reload-progress\"" content)
                          "reload logs per-file reload-progress")
             (ensure-true (search "\"event\":\"reload-completed\"" content)
                          "reload logs reload-completed")
             (ensure-true (search "\"event\":\"tool-completed\"" content)
                          "reload still logs tool-completed")
             (ensure-true (search "\"durationSeconds\":" content)
                          "reload completion includes durationSeconds")))
      (self-improving-agent-harness::configure-interaction-logging nil)
      (self-improving-agent-harness:clear-synthetic-followups)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t))))

  (format t "Reload-hook tests passed.~%")
  t)
