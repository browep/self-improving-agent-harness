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

(defun turn-accounting-tokens (accounting)
  "Return (values input-tokens output-tokens total-tokens) from ACCOUNTING.

ACCOUNTING is the plist stored in CHAT-SESSION-LAST-ACCOUNTING. Token values
are integers when the provider supplied them, or :unavailable otherwise."
  (let* ((aggregate (getf accounting :aggregate))
         (input (getf aggregate :input-tokens))
         (output (getf aggregate :output-tokens))
         (total (getf aggregate :total-tokens)))
    (values input output total)))

(defun last-round-context-tokens (accounting)
  "Return the prompt-token count of the last provider round in ACCOUNTING.

The aggregate input/total tokens sum prompt_tokens across ALL rounds, but each
round's prompt_tokens already includes the full conversation history. Summing
them massively inflates the apparent context usage (e.g. 14 rounds at ~70K each
sums to ~970K, but the actual context fill is just the last round's ~70K).

The last round's prompt_tokens is the true measure of context-window fill
because it contains the entire conversation up to that point. Returns NIL when
no per-round invocation data is available or the last round lacks numeric
input tokens."
  (let* ((invocations (getf accounting :invocations))
         (last-invocation (first (last invocations))))
    (when (and last-invocation
               (integerp (getf last-invocation :input-tokens)))
      (getf last-invocation :input-tokens))))

(defun format-context-fill-suffix (backend model accounting)
  "Return a string suffix for the DONE line describing token usage and context fill.

Returns \"\" when no token information is available at all. The suffix never
contains the literal \"model=\" (a reload-test invariant), so the model id is not
embedded; only the context-length ceiling and fill percentage appear.

Format when context length is known:
  tokens=in/out/total context=used/max (P%)
Format when only tokens are known (no context ceiling):
  tokens=in/out/total
Tokens that are :unavailable are shown as \"?\".

The tokens=in/out/total values are the AGGREGATE sums across all rounds (total
tokens billed). The context=used value is the LAST ROUND's prompt_tokens, which
is the true context-window fill (the last request contains the full conversation
history). Using the aggregate sum for context fill would be wrong because each
round's prompt_tokens already includes all prior history, so summing them
double-counts."
  (multiple-value-bind (input output total)
      (turn-accounting-tokens accounting)
    (let ((has-tokens (or (integerp input) (integerp output) (integerp total))))
      (if (not has-tokens)
          ""
          (let* ((ctx-len (model-context-length backend model))
                 (in-str (if (integerp input) (princ-to-string input) "?"))
                 (out-str (if (integerp output) (princ-to-string output) "?"))
                 (tot-str (if (integerp total) (princ-to-string total) "?"))
                 (token-part (format nil "tokens=~A/~A/~A" in-str out-str tot-str)))
            (if (integerp ctx-len)
                (let* ((used (or (last-round-context-tokens accounting)
                                 total input 0))
                       (pct (context-fill-percentage used ctx-len)))
                  (format nil "~A context=~D/~D~@[ (~D%)~]"
                          token-part used ctx-len pct))
                token-part))))))

(defun write-final-response-outcome (&key rounds duration-seconds
                                       (backend nil) (model nil) (accounting nil))
  "Print the post-turn outcome line to stderr for human interactive/one-shot modes.

Format:
  <<< DONE rounds=N duration_seconds=S.SSS [tokens=in/out/total context=used/max (P%)]

The token/context suffix is appended only when accounting data is present and
the model id is never embedded (no \"model=\" substring), preserving the
reload-test invariant."
  (let ((suffix (format-context-fill-suffix backend model accounting)))
    (format *error-output*
            "~%<<< DONE rounds=~D duration_seconds=~,3F~@[ ~A~]~%"
            rounds duration-seconds
            (and (plusp (length suffix)) suffix))
    (finish-output *error-output*)))

(defun report-completed-chat-turn (session start-internal-time response
                                   &key (leading-newline t))
  "Print RESPONSE text and the structured final-response OUTCOME.

LEADING-NEWLINE is true for interactive turns (separate the answer from the
prompt chrome) and false for one-shot mode.

When the model returns no user-visible text, print an explicit placeholder so
the console never looks like a silent hang. finish_reason is included when
present (e.g. length) to make truncated empty finals diagnosable without JSONL."
  (let* ((duration (elapsed-seconds-since start-internal-time))
         (rounds (count-tool-loop-rounds
                  (chat-session-last-provider-responses session)))
         (raw-text (completion-response-text response))
         (finish (completion-response-finish-reason response))
         (blank-p (or (null raw-text)
                     (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                 raw-text)))))
         (text
           (if blank-p
               (format nil
                       "[harness] Empty model response~@[ (finish_reason=~A)~]."
                       finish)
               raw-text)))
    (when blank-p
      (format *error-output*
              "WARN empty-final-response rounds=~D finish_reason=~A~%"
              rounds (or finish "unknown"))
      (finish-output *error-output*))
    (if leading-newline
        (format t "~%~A~%" text)
        (format t "~A~%" text))
    ;; Use the session (request) model for the context-length lookup, not the
    ;; response model: providers often resolve aliases (e.g. syn:large:text ->
    ;; zai-org/GLM-5.2) so the response model id may not appear in the /models
    ;; listing that keys the metadata cache. Fall back to the response model.
    (write-final-response-outcome
     :rounds rounds
     :duration-seconds duration
     :backend (chat-session-backend session)
     :model (or (chat-session-model session)
                (completion-response-model response))
     :accounting (chat-session-last-accounting session))
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
        (maybe-deliver-subagent-results session)
        response)
    (error (condition)
      (note-chat-session-failure session)
      (format *error-output*
              "~%TURN_FAILED: ~A; session continues and prior history is retained.~%"
              condition)
      (finish-output *error-output*)
      ;; Still allow a follow-up if reload succeeded before the primary turn failed.
      (maybe-run-synthetic-followup-turns session)
      (maybe-deliver-subagent-results session)
      nil)))
