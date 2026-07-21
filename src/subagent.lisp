(in-package #:self-improving-agent-harness)

;;; Subagent tool: run_subagent
;;;
;;; A subagent is an independent, one-shot agent run spawned on its own
;;; sb-thread by the super-agent (the interactive chat session). The subagent
;;; gets its own prompt, provider, model, and log directory. It cannot spawn
;;; further subagents (structural enforcement: run_subagent is not in its tool
;;; set) and cannot reload the harness (reload_harness is not in its tool set).
;;;
;;; Async delivery (Design A): the run_subagent tool handler returns a
;;; placeholder string immediately. The subagent runs on a thread. When it
;;; completes, the result is queued. After the super-agent's turn finishes,
;;; maybe-deliver-subagent-results drains the queue and delivers each result as
;;; a harness-initiated turn via run-synthetic-followup-turn.

;; Forward declarations for functions defined in later-loading files.
;; chat-tool-definitions is in src/chat-cli.lisp; run-synthetic-followup-turn
;; is in src/chat-turn-report.lisp. Both are resolved at runtime.
(declaim (ftype (function () list) chat-tool-definitions))
(declaim (ftype (function (t string) t) run-synthetic-followup-turn))

;;; ---------------------------------------------------------------------------
;;; Parameters
;;; ---------------------------------------------------------------------------

(defparameter *subagent-default-max-rounds* 20
  "Default tool-loop round limit for a subagent.")

(defparameter *subagent-default-timeout-seconds* 300
  "Default wall-clock timeout in seconds for a whole subagent run.")

(defparameter +subagent-system-prompt+
  (format nil
          "You are a subagent inside the Self-Improving Agent Harness. ~
Your job is to complete the task given to you and return a final answer.~%~%~
You have one tool available: run_shell, which runs a shell command in the ~
harness container and returns combined stdout/stderr. Use it to inspect ~
files, run tests, and make edits as needed.~%~%~
You cannot spawn further subagents. You cannot reload the harness. ~
Focus on your specific task and return a clear, concise final answer when ~
done.")
  "Focused system prompt for subagents. Shorter than +chat-system-prompt+ and
does not advertise run_subagent or reload_harness.")

(defvar *subagent-parent-backend* nil
  "Dynamically bound to the parent session's backend during a tool loop.

Bound by CHAT-SESSION-TURN around RUN-TOOL-LOOP so the run_subagent handler can
read the parent's backend for defaulting.")

(defvar *subagent-parent-model* nil
  "Dynamically bound to the parent session's model during a tool loop.

Bound by CHAT-SESSION-TURN around RUN-TOOL-LOOP so the run_subagent handler can
read the parent's model for defaulting.")

(defvar *subagent-counter* 0
  "Monotonic counter for subagent IDs, protected by *SUBAGENT-MUTEX*.")

(defvar *subagent-mutex*
  (sb-thread:make-mutex :name "subagent")
  "Protects *SUBAGENT-COUNTER* and *PENDING-SUBAGENT-DELIVERIES*.")

(defvar *pending-subagent-deliveries* nil
  "FIFO list of completed subagent results awaiting delivery to the super-agent.
Protected by *SUBAGENT-MUTEX*.")

;;; ---------------------------------------------------------------------------
;;; Subagent ID generation
;;; ---------------------------------------------------------------------------

(defun make-subagent-id ()
  "Return a unique subagent id as an ISO-8601 UTC timestamp.

Uses SESSION-LOG-TIMESTAMP-STRING (same format as the parent session id) so
subagent log directories are sortable and consistent with the parent. A
monotonic counter suffix is appended under the mutex to guarantee uniqueness
when multiple subagents start within the same millisecond."
  (sb-thread:with-recursive-lock (*subagent-mutex*)
    (incf *subagent-counter*)
    (format nil "~A-~D" (session-log-timestamp-string) *subagent-counter*)))

;;; ---------------------------------------------------------------------------
;;; Subagent backend construction
;;; ---------------------------------------------------------------------------

(defun subagent-backend (provider parent-backend)
  "Return a backend for the subagent.

When PROVIDER is nil or empty, reuse PARENT-BACKEND (the current session's
backend). When PROVIDER names a different provider, construct a fresh backend
via the same logic as SELECT-CHAT-BACKEND. The corresponding API key must be
present in the environment."
  (if (or (null provider)
          (and (stringp provider) (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) provider)))))
      parent-backend
      (let ((name (string-downcase
                   (string-trim '(#\Space #\Tab #\Newline #\Return) provider))))
        (cond
          ((string= name "openrouter")
           (make-openrouter-backend :api-key (uiop:getenv "OPENROUTER_API_KEY")))
          ((string= name "synthetic")
           (make-synthetic-backend :api-key (uiop:getenv "SYNTHETIC_API_KEY")))
          ((string= name "codex")
           (make-codex-app-server-backend))
          (t
           (error "Unknown subagent provider ~S. Must be openrouter, synthetic, or codex." provider))))))

;;; ---------------------------------------------------------------------------
;;; Subagent tool set (no-recursion enforcement)
;;; ---------------------------------------------------------------------------

(defun subagent-tool-definitions ()
  "Return tool definitions for a subagent: run_shell only.

This structurally enforces the no-recursion rule: the subagent has no
run_subagent tool and no reload_harness tool."
  (list (first (chat-tool-definitions))))

(defun subagent-tool-handlers ()
  "Return tool handlers for a subagent: run_shell only.

Uses a symbol designator so reload_harness can redefine shell-tool mid-session."
  '(("run_shell" . shell-tool)))

(defun subagent-options ()
  "Return completion options for a subagent: temperature, max-tokens, run_shell tool."
  (list :temperature 0.2
        :max-tokens 4096
        :tools (subagent-tool-definitions)))

;;; ---------------------------------------------------------------------------
;;; Subagent log directory setup
;;; ---------------------------------------------------------------------------

(defun subagent-log-directory (subagent-id)
  "Return the log directory path for a subagent.

Shape: agent-logs/$SESSION-subagent-$SUBAGENT_ID/"
  (merge-pathnames
   (format nil "~A-subagent-~A/" *interaction-log-file-id* subagent-id)
   "agent-logs/"))

(defun subagent-log-basename (subagent-id)
  "Return the file basename (without extension) for subagent log files."
  (format nil "~A-subagent-~A" *interaction-log-file-id* subagent-id))

;;; ---------------------------------------------------------------------------
;;; Subagent thread entry point
;;; ---------------------------------------------------------------------------

(defun subagent-thread-main (subagent-id backend model prompt max-rounds
                            &optional (timeout-seconds *subagent-default-timeout-seconds*))
  "Run the subagent on this thread. Return (values response nil) or (values nil condition).

Dynamically binds the logging variables to the subagent's own log directory so
HTTP calls and tool events are written to the subagent's files, not the
parent's. The parent's logging state is untouched (dynamic binding is
thread-local).

TIMEOUT-SECONDS is a wall-clock bound on the entire subagent run. On expiry an
sb-ext:timeout error is signaled, caught, and returned as the error value so a
timeout error string is delivered to the super-agent instead of hanging
forever."
  (let* ((log-dir (subagent-log-directory subagent-id))
         (basename (subagent-log-basename subagent-id)))
    (ensure-directories-exist log-dir)
    (let (;; Redirect logging to the subagent's own files.
          (*interaction-log-path*
            (merge-pathnames (format nil "~A.jsonl" basename) log-dir))
          (*interaction-text-log-path*
            (merge-pathnames (format nil "~A.log" basename) log-dir))
          (*interaction-session-id* subagent-id)
          (*interaction-log-file-id* basename)
          (*interaction-turn-number* nil)
          (*interaction-parent-uuid* nil)
          (*interaction-log-directory* log-dir))
      (handler-case
          (handler-case
              (let* ((messages (list (list :role "system"
                                           :content +subagent-system-prompt+)
                                     (list :role "user" :content prompt)))
                     (request (make-completion-request
                               :model model
                               :messages messages
                               :options (subagent-options))))
                (let ((response
                        (if (and (realp timeout-seconds) (plusp timeout-seconds))
                            (sb-ext:with-timeout timeout-seconds
                              (run-tool-loop backend request
                                             (subagent-tool-handlers)
                                             :max-rounds max-rounds))
                            (run-tool-loop backend request
                                           (subagent-tool-handlers)
                                           :max-rounds max-rounds))))
                  ;; run-tool-loop returns (values response history responses);
                  ;; capture only the first value so the history list does not
                  ;; leak into the error slot of multiple-value-bind.
                  response))
            (sb-ext:timeout ()
              (values nil (make-condition
                           'simple-error
                           :format-control "Subagent ~A timed out after ~A seconds."
                           :format-arguments (list subagent-id timeout-seconds)))))
        (error (condition)
          (values nil condition))))))

;;; ---------------------------------------------------------------------------
;;; Delivery queue
;;; ---------------------------------------------------------------------------

(defstruct subagent-delivery
  "A completed subagent result awaiting delivery to the super-agent."
  subagent-id
  status            ; :completed or :failed
  result            ; the answer string or error message
  provider          ; provider name string
  model             ; model id string
  duration-seconds) ; wall-clock duration of the subagent run

(defun enqueue-subagent-delivery (delivery)
  "Append DELIVERY to the pending delivery queue (thread-safe)."
  (sb-thread:with-recursive-lock (*subagent-mutex*)
    (setf *pending-subagent-deliveries*
          (append *pending-subagent-deliveries* (list delivery)))))

(defun take-next-subagent-delivery ()
  "Pop and return the next completed subagent delivery, or NIL (thread-safe)."
  (sb-thread:with-recursive-lock (*subagent-mutex*)
    (let ((next (first *pending-subagent-deliveries*)))
      (setf *pending-subagent-deliveries*
            (rest *pending-subagent-deliveries*))
      next)))

(defun clear-subagent-deliveries ()
  "Drop all pending subagent deliveries. Returns the discarded list."
  (sb-thread:with-recursive-lock (*subagent-mutex*)
    (prog1 *pending-subagent-deliveries*
      (setf *pending-subagent-deliveries* nil))))

;;; ---------------------------------------------------------------------------
;;; The run_subagent tool handler
;;; ---------------------------------------------------------------------------

(defun subagent-tool (arguments)
  "run_subagent tool handler. Spawns a subagent thread, returns a placeholder.

ARGUMENTS is a decoded JSON object (yason hash-table) with keys:
  prompt (string, required), provider (string, optional), model (string,
  optional), max_rounds (integer, optional), timeout (number, optional).

Returns immediately with a placeholder string. The subagent runs on a separate
thread. When it completes, the result is queued and delivered after the
super-agent's turn via MAYBE-DELIVER-SUBAGENT-RESULTS."
  (let* ((prompt (gethash "prompt" arguments))
         (provider (gethash "provider" arguments))
         (model (or (gethash "model" arguments) *subagent-parent-model*))
         (max-rounds (or (gethash "max_rounds" arguments)
                         *subagent-default-max-rounds*))
         (timeout-seconds (or (gethash "timeout" arguments)
                              *subagent-default-timeout-seconds*))
         (subagent-id (make-subagent-id))
         (backend (subagent-backend provider *subagent-parent-backend*))
         (provider-label (or provider
                             (and *subagent-parent-backend*
                                  (backend-name *subagent-parent-backend*))
                             "unknown")))
    ;; Validate prompt.
    (unless (and (stringp prompt) (plusp (length prompt)))
      (error "run_subagent requires a non-empty prompt."))
    ;; Validate model.
    (unless (and (stringp model) (plusp (length model)))
      (error "run_subagent requires a model (explicit or inherited from the session)."))
    ;; Capture parent logging context lexically so the subagent thread can
    ;; log subagent-completed back to the parent's JSONL. sb-thread:make-thread
    ;; does NOT inherit dynamic variable bindings from the parent thread, so
    ;; we must close over the values here and rebind them inside the thread.
    (let ((parent-log-path *interaction-log-path*)
          (parent-text-log-path *interaction-text-log-path*)
          (parent-session-id *interaction-session-id*)
          (parent-log-file-id *interaction-log-file-id*))
      ;; Log start in the parent's JSONL.
      (log-interaction :info "subagent-started"
                       :subagent-id subagent-id
                       :provider provider-label
                       :model model
                       :prompt (truncate-interaction-log-text prompt))
      ;; The standard TOOL_CALL console marker is emitted centrally by
      ;; OPENROUTER-TOOL-RESULT-MESSAGE when this handler is invoked.
      ;; Spawn the subagent on its own thread.
      (sb-thread:make-thread
       (lambda ()
         (let ((start (get-internal-real-time)))
           (multiple-value-bind (response error)
               (subagent-thread-main subagent-id backend model prompt max-rounds
                                    timeout-seconds)
             (let* ((duration (elapsed-seconds-since start))
                    (result-text
                      (if error
                          (format nil "[subagent ~A failed: ~A]"
                                  subagent-id (princ-to-string error))
                          (completion-response-text response))))
               ;; Rebind logging vars to the parent's (captured lexically above)
               ;; so subagent-completed is written to the parent's JSONL.
               (let ((*interaction-log-path* parent-log-path)
                     (*interaction-text-log-path* parent-text-log-path)
                     (*interaction-session-id* parent-session-id)
                     (*interaction-log-file-id* parent-log-file-id)
                     (*interaction-parent-uuid* nil))
                 (log-interaction :info "subagent-completed"
                                  :subagent-id subagent-id
                                  :status (if error "failed" "completed")
                                  :duration-seconds duration
                                  :result (truncate-interaction-log-text result-text)))
               ;; Console marker (stderr) so operators can see subagent
               ;; completion, mirroring the TOOL_DONE lines from other tools.
               (format *error-output*
                       "SUBAGENT_DONE subagent_id=~A status=~A duration_seconds=~,3F result=~S~%"
                       subagent-id
                       (if error "failed" "completed")
                       duration
                       (truncate-for-display result-text 120))
               (finish-output *error-output*)
               (enqueue-subagent-delivery
                (make-subagent-delivery
                 :subagent-id subagent-id
                 :status (if error :failed :completed)
                 :result result-text
                 :provider provider-label
                 :model model
                 :duration-seconds duration))))))
       :name (format nil "subagent-~A" subagent-id)))
    ;; Return placeholder immediately so the super-agent's turn continues.
    (format nil
            "[subagent ~A started; provider=~A model=~A; ~
result will be delivered when complete]"
            subagent-id provider-label model)))

;;; ---------------------------------------------------------------------------
;;; Delivery drain
;;; ---------------------------------------------------------------------------

(defun maybe-deliver-subagent-results (session)
  "Drain completed subagent results and deliver each as a harness-initiated turn.

Each completed subagent result is injected as a separate harness-initiated turn
via RUN-SYNTHETIC-FOLLOWUP-TURN so the super-agent gets a fresh inference round
to react to each one. Deliveries are drained one at a time. If the queue is
empty, this is a no-op."
  (loop
    for delivery = (take-next-subagent-delivery)
    while delivery
    do (let* ((status-label
               (if (eq (subagent-delivery-status delivery) :completed)
                   "completed" "failed"))
              (content
               (format nil "[subagent ~A ~A] ~A"
                       (subagent-delivery-subagent-id delivery)
                       status-label
                       (subagent-delivery-result delivery))))
         (run-synthetic-followup-turn session content))))
