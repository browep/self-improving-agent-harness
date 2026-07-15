(in-package #:self-improving-agent-harness)

(defparameter +chat-system-prompt+
  "Use run_shell when it helps answer the user. When finished, return a final response without tool calls.")

(defstruct (chat-session
            (:constructor %make-chat-session
                (&key backend model options handlers max-rounds history failed-turn-p)))
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
  failed-turn-p)

(defun make-chat-session (&key backend model options handlers (max-rounds 8)
                            (system-prompt +chat-system-prompt+))
  "Create a session with exactly one initial system message."
  (%make-chat-session
   :backend backend
   :model model
   :options options
   :handlers handlers
   :max-rounds max-rounds
   :history (list (list :role "system" :content system-prompt))
   :failed-turn-p nil))

(defun chat-session-turn (session content)
  "Run one non-empty user turn and append its complete exchange to SESSION.

Returns the final COMPLETION-RESPONSE.  Empty input is ignored and returns NIL
without calling the backend.  Errors from a turn leave the previous history
unchanged so the caller can safely continue the session."
  (when (and (stringp content) (plusp (length content)))
    (let* ((messages (append (chat-session-history session)
                             (list (list :role "user" :content content))))
           (request (make-completion-request
                     :model (chat-session-model session)
                     :messages messages
                     :options (chat-session-options session))))
      (multiple-value-bind (response continuation-history)
          (run-tool-loop (chat-session-backend session)
                         request
                         (chat-session-handlers session)
                         :max-rounds (chat-session-max-rounds session))
        (setf (chat-session-history session)
              (append continuation-history
                      (list (list :role "assistant"
                                  :content (completion-response-text response)))))
        response))))

(defun note-chat-session-failure (session)
  "Mark SESSION as having a failed turn without retaining partial turn state."
  (setf (chat-session-failed-turn-p session) t)
  session)
