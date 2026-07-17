(in-package #:self-improving-agent-harness)

(defparameter +chat-system-prompt+
  "Use run_shell when it helps answer the user. Use reload_harness after editing harness Lisp sources when the change must take effect in this same chat process. When finished, return a final response without tool calls.")

(defstruct (chat-session
            (:constructor %make-chat-session
                (&key backend model options handlers max-rounds history failed-turn-p
                      last-provider-responses last-accounting)))
  "Persistent, in-memory state for one interactive chat process.

HISTORY contains the initial system message followed by every completed user
turn, tool-loop continuation message, tool result, and final assistant reply.
A failed turn deliberately does not mutate HISTORY, so a later retry has a
well-defined request boundary."
  backend
  model
  options
  handlers
  max-rounds
  history
  failed-turn-p
  ;; Kept only in session memory so callers can audit an ordered successful turn.
  ;; Reports consume LAST-ACCOUNTING, never these raw-capable response objects.
  last-provider-responses
  last-accounting)

(defun make-chat-session (&key backend model options handlers (max-rounds 60)
                            (system-prompt +chat-system-prompt+))
  "Create a session with exactly one initial system message.

OPTIONS and HANDLERS may be either concrete values or zero-argument function
designators (symbols preferred). When a designator is supplied,
CHAT-SESSION-TURN re-resolves it on every turn so reload_harness can update
tool schemas and tool implementations without rebuilding the session.
Handler alists should map tool names to symbols (not #'function objects) when
hot reload is desired."
  (%make-chat-session
   :backend backend
   :model model
   :options options
   :handlers handlers
   :max-rounds max-rounds
   :history (list (list :role "system" :content system-prompt))
   :failed-turn-p nil))

(defun resolve-chat-session-options (session)
  "Return the effective completion options for SESSION.

If CHAT-SESSION-OPTIONS is a function designator, call it each turn so tool
schemas and sampling knobs can hot-reload. Concrete plists are returned as-is."
  (let ((options (chat-session-options session)))
    (cond
      ((null options) nil)
      ((functionp options) (funcall options))
      ((and (symbolp options) (fboundp options)) (funcall options))
      (t options))))

(defun resolve-chat-session-handlers (session)
  "Return the effective tool-handler alist for SESSION.

If CHAT-SESSION-HANDLERS is a function designator, call it each turn. Handler
values may themselves be symbols; OPENROUTER-TOOL-HANDLER coerces them at call
time so reloaded DEFUN bodies are visible mid-session."
  (let ((handlers (chat-session-handlers session)))
    (cond
      ((null handlers) nil)
      ((functionp handlers) (funcall handlers))
      ((and (symbolp handlers) (fboundp handlers)) (funcall handlers))
      (t handlers))))

(defun ensure-chat-session-system-prompt (session &optional (system-prompt +chat-system-prompt+))
  "Keep the leading system message aligned with SYSTEM-PROMPT when possible.

Only rewrites a still-leading system message. Does not invent a system message
if history was customized away from the default shape."
  (let ((history (chat-session-history session)))
    (when (and history
               (string= "system" (getf (first history) :role))
               (not (string= system-prompt (getf (first history) :content))))
      (setf (chat-session-history session)
            (cons (list :role "system" :content system-prompt)
                  (rest history))))
    session))

(defun chat-session-turn (session content)
  "Run one non-empty user turn and append its complete exchange to SESSION.

Returns the final COMPLETION-RESPONSE. Empty input is ignored and returns NIL
without calling the backend. Errors leave the previous history unchanged and
are recorded in the configured interaction log before being re-signaled.

OPTIONS/HANDLERS designators and +CHAT-SYSTEM-PROMPT+ are re-resolved here so
reload_harness can update tool wiring and the system prompt for later turns of
an already-running interactive process.

Turn initiator is taken from *INTERACTION-TURN-INITIATOR* (human by default;
synthetic follow-ups bind it to \"harness\") and written into JSONL."
  (when (and (stringp content) (plusp (length content)))
    ;; Close the interactive prompt separator when armed by WRITE-CHAT-PROMPT.
    ;; Safe no-op for one-shot turns and when the close already ran.
    (when (fboundp 'maybe-write-chat-prompt-closing)
      (maybe-write-chat-prompt-closing))
    (ensure-chat-session-system-prompt session)
    (log-interaction :info "turn-received"
                     :initiator *interaction-turn-initiator*
                     :content content)
    (let* ((messages (append (chat-session-history session)
                             (list (list :role "user" :content content))))
           (options (resolve-chat-session-options session))
           (handlers (resolve-chat-session-handlers session))
           (tool-names
             (mapcar (lambda (entry)
                       (if (consp entry) (car entry) entry))
                     handlers))
           (request (make-completion-request
                     :model (chat-session-model session)
                     :messages messages
                     :options options)))
      (log-interaction :info "turn-submitted"
                       :initiator *interaction-turn-initiator*
                       :model (chat-session-model session)
                       :message-count (length messages)
                       :tool-names (mapcar #'princ-to-string tool-names)
                       :content content)
      (handler-case
          (multiple-value-bind (response continuation-history provider-responses)
              (run-tool-loop (chat-session-backend session)
                             request
                             handlers
                             :max-rounds (chat-session-max-rounds session))
            (setf (chat-session-history session)
                  (append continuation-history
                          (list (list :role "assistant"
                                      :content (completion-response-text response)))))
            (setf (chat-session-last-provider-responses session) provider-responses
                  (chat-session-last-accounting session)
                  (provider-accounting-summary (chat-session-backend session)
                                               provider-responses))
            (log-interaction :info "turn-completed"
                             :initiator *interaction-turn-initiator*
                             :model (completion-response-model response)
                             :content (completion-response-text response)
                             :round (length provider-responses))
            response)
        (error (condition)
          (log-interaction :error "turn-failed"
                           :initiator *interaction-turn-initiator*
                           :message (princ-to-string condition))
          (error condition))))))

(defun note-chat-session-failure (session)
  "Mark SESSION as having a failed turn without retaining partial turn state."
  (setf (chat-session-failed-turn-p session) t)
  session)
