(in-package #:self-improving-agent-harness)

;;; Per-turn reporting helpers for the chat CLI.
;;;
;;; These live in their own file so outcome formatting can change under
;;; reload_harness. RUN-INTERACTIVE must call PROCESS-INTERACTIVE-USER-TURN by
;;; name on every iteration; an already-running loop then picks up new
;;; definitions without restarting the process. Editing the body of
;;; RUN-INTERACTIVE itself still requires re-entering that function.

(defun elapsed-seconds-since (start-internal-time)
  "Return fractional seconds elapsed since START-INTERNAL-TIME."
  (/ (float (- (get-internal-real-time) start-internal-time) 0d0)
     internal-time-units-per-second))

(defun count-tool-loop-rounds (provider-responses)
  "Count provider rounds used for one completed turn.

Each entry in PROVIDER-RESPONSES is one backend COMPLETE call from RUN-TOOL-LOOP,
including the final no-tool-call response. NIL/empty means zero rounds."
  (if (listp provider-responses)
      (length provider-responses)
      0))

(defun write-final-response-outcome (&key rounds duration-seconds)
  "Print the post-turn outcome line to stderr for human interactive/one-shot modes.

Format:
  <<< DONE rounds=N duration_seconds=S.SSS"
  (format *error-output*
          "~%<<< DONE rounds=~D duration_seconds=~,3F~%"
          rounds duration-seconds)
  (finish-output *error-output*))

(defun report-completed-chat-turn (session start-internal-time response
                                   &key (leading-newline t))
  "Print RESPONSE text and the structured final-response OUTCOME.

LEADING-NEWLINE is true for interactive turns (separate the answer from the
prompt chrome) and false for one-shot mode."
  (let ((duration (elapsed-seconds-since start-internal-time))
        (rounds (count-tool-loop-rounds
                 (chat-session-last-provider-responses session)))
        (text (completion-response-text response)))
    (if leading-newline
        (format t "~%~A~%" text)
        (format t "~A~%" text))
    (write-final-response-outcome :rounds rounds :duration-seconds duration)
    response))

(defun run-synthetic-followup-turn (session content)
  "Run one automatic follow-up user turn and print its outcome.

CONTENT is injected as a normal user message so OPTIONS/HANDLERS re-resolve and
the provider sees any tools registered before RELOAD-HARNESS completed. Errors
are reported like interactive turns and do not abort the session.

Console markers are intentionally loud so operators can see harness-initiated
turns without reading JSONL. JSONL records set initiator=harness."
  (format *error-output* "~%")
  (format *error-output* "================================================================~%")
  (format *error-output* "SYNTHETIC_FOLLOWUP begin initiator=harness source=queue~%")
  (format *error-output* "SYNTHETIC_FOLLOWUP content=~S~%"
          (if (and (stringp content) (> (length content) 240))
              (concatenate 'string (subseq content 0 240) "...")
              content))
  (format *error-output* "================================================================~%")
  (finish-output *error-output*)
  (log-interaction :info "synthetic-followup-started"
                   :initiator "harness"
                   :source "queue"
                   :content content)
  (let ((*interaction-turn-initiator* "harness"))
    (handler-case
        (let* ((start (get-internal-real-time))
               (response (chat-session-turn session content)))
          (report-completed-chat-turn session start response :leading-newline t)
          (format *error-output* "SYNTHETIC_FOLLOWUP end initiator=harness status=ok~%")
          (finish-output *error-output*)
          (log-interaction :info "synthetic-followup-completed"
                           :initiator "harness"
                           :status "ok")
          response)
      (error (condition)
        (note-chat-session-failure session)
        (format *error-output*
                "~%TURN_FAILED: synthetic follow-up: ~A; session continues and prior history is retained.~%"
                condition)
        (format *error-output* "SYNTHETIC_FOLLOWUP end initiator=harness status=error~%")
        (finish-output *error-output*)
        (log-interaction :error "synthetic-followup-failed"
                         :initiator "harness"
                         :status "error"
                         :message (princ-to-string condition))
        nil))))

(defun maybe-run-synthetic-followup-turns (session)
  "Drain at most one pending synthetic follow-up for SESSION.

Only one auto turn runs per call so a follow-up that reloads again cannot
chain forever here. Additional queued items remain for a later call. While the
follow-up runs, new SCHEDULE-SYNTHETIC-FOLLOWUP calls are suppressed."
  (let ((content (take-next-synthetic-followup)))
    (when content
      (format *error-output*
              "SYNTHETIC_FOLLOWUP dequeue remaining=~D~%"
              (length *pending-synthetic-followups*))
      (finish-output *error-output*)
      (let ((*suppress-synthetic-followup-scheduling* t))
        (run-synthetic-followup-turn session content)))))

(defun process-interactive-user-turn (session input)
  "Run one non-command interactive user turn and print its outcome.

Called by name from RUN-INTERACTIVE each loop iteration so reload_harness can
replace timing/outcome behavior mid-session. Errors are recorded on SESSION and
reported on stderr without aborting the interactive loop.

After a successful primary turn (and also after a failed one that may still have
scheduled work), run at most one pending synthetic follow-up turn so reload +
new tool registration can continue without another human message."
  (handler-case
      (let* ((start (get-internal-real-time))
             (response (chat-session-turn session input)))
        (report-completed-chat-turn session start response :leading-newline t)
        (maybe-run-synthetic-followup-turns session)
        response)
    (error (condition)
      (note-chat-session-failure session)
      (format *error-output*
              "~%TURN_FAILED: ~A; session continues and prior history is retained.~%"
              condition)
      (finish-output *error-output*)
      ;; Still allow a follow-up if reload succeeded before the primary turn failed.
      (maybe-run-synthetic-followup-turns session)
      nil)))
