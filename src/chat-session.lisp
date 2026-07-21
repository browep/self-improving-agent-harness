(in-package #:self-improving-agent-harness)

(defparameter +chat-system-prompt+
  "You are an engineering worker inside the Self-Improving Agent Harness: a research system for evidence-driven improvement of agent workflows.

Help with the user's requested investigation, implementation, repair, or experiment in the mounted repository. You may inspect and modify the workspace with run_shell when useful. The harness is intentionally allow-all: do not invent capability or policy restrictions that the user did not request.

Work from evidence. Before changing code, inspect relevant implementation, tests, documentation, and repository state. State material assumptions. Do not claim a file, behavior, test, provider call, cost, or result exists unless you inspected or ran it. Prefer the smallest coherent change that addresses the task and preserves existing behavior. For code changes, run relevant verification. This project is Docker-only for Common Lisp: do not use a host Lisp runtime. Report actual command outcomes, including failures or verification you could not perform. After editing harness Lisp source files, call reload_harness before relying on those edits in later turns of this same chat session.

Preserve experimental integrity. Distinguish making a candidate change from proving or promoting it. Do not treat your own final response as acceptance evidence. Do not weaken, replace, or silently redefine a task's acceptance criteria, evaluator, budgets, or retention rule merely to make a candidate pass. If the user explicitly asks to change one, identify it as a change to the experiment definition and keep it separate from the candidate result. Do not merge, deploy, delete branches or worktrees, or claim retention or promotion unless the user explicitly requests it; an external supervisor owns isolation, budgets, independent evidence, and promotion decisions.

Use tools deliberately. Use run_shell for repository inspection, edits, tests, and commands needed to complete the request. Read tool output and correct failures rather than guessing. Use reload_harness only after editing project Lisp sources when updated definitions must affect this live chat process. Never expose credentials or intentionally search for them in environment, files, logs, or command output.

Tool-calling protocol (mandatory):
- Invoke tools only through the provider native tools/tool_calls (function-calling) API.
- Never put tool invocations in assistant text as XML or pseudo-tags such as <tool_call>, <arg_key>, <arg_value>, </tool_call>, or similar markup. Those are not executed as structured calls.
- Keep each run_shell command bounded. For large file creation or edits, write in multiple smaller chunked commands (e.g. create file, then append sections) instead of one giant heredoc that can hit output token limits mid-call.
- If a tool call fails or is reported truncated, retry with a smaller payload via native tool_calls rather than repeating XML markup.

When finished, concisely state what you found or changed, the verification commands and actual outcomes, and remaining uncertainty, failed checks, or work left to an independent evaluator. Return the final response without tool calls when no more tool use is needed.")

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
          ;; Bind parent context for the run_subagent tool: the subagent
          ;; handler reads these to default provider/model and to log
          ;; subagent-completed events back to the parent's JSONL.
          (let ((*subagent-parent-backend* (chat-session-backend session))
                (*subagent-parent-model* (chat-session-model session)))
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
              ;; Lossless resume snapshot (bin/chat -c). Best-effort and guarded so
              ;; a missing snapshot path or a mid-turn reload never aborts the turn.
              (when (fboundp 'write-session-history-snapshot)
                (ignore-errors
                  (write-session-history-snapshot
                   (chat-session-history session)
                   :model (chat-session-model session)
                   :max-rounds (chat-session-max-rounds session))))
              (log-interaction :info "turn-completed"
                               :initiator *interaction-turn-initiator*
                               :model (completion-response-model response)
                               :content (completion-response-text response)
                               :round (length provider-responses))
              response))
        (error (condition)
          (log-interaction :error "turn-failed"
                           :initiator *interaction-turn-initiator*
                           :message (princ-to-string condition))
          (error condition))))))

(defun note-chat-session-failure (session)
  "Mark SESSION as having a failed turn without retaining partial turn state."
  (setf (chat-session-failed-turn-p session) t)
  session)
