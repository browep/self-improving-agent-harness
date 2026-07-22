(in-package #:self-improving-agent-harness)

;;; Browser UI adapter. UI events are transient; the shared CHAT-SESSION history
;;; and the durable agent-logs snapshot are the cross-client source of truth.

(defstruct (web-session
            (:constructor %make-web-session
                (&key id durable-session-id run-session-id chat-session events state turn-number log-context)))
  id
  durable-session-id
  run-session-id
  chat-session
  events
  state
  turn-number
  log-context)

(defun web-session-record-event (session kind &rest fields)
  "Append one ordered in-memory UI event. Durable records are emitted by CHAT-SESSION-TURN."
  (let ((event (append (list :kind kind
                             :sequence (1+ (length (web-session-events session)))
                             :turn (web-session-turn-number session))
                       fields)))
    (setf (web-session-events session)
          (append (web-session-events session) (list event)))
    event))

(defun web-event-visible-in-chat-log-p (event)
  "Expose user, assistant, and tool lifecycle events in the browser transcript."
  (member (getf event :kind)
          '("user-message" "assistant-message" "tool-call-started" "tool-call-completed"
            "tool-call-failed" "turn-failed")
          :test #'string=))

(defun make-web-session-log-context (log-directory durable-session-id)
  "Configure a durable session once and capture its dynamic logging bindings."
  (when log-directory
    (configure-interaction-logging log-directory :session-id durable-session-id)
    (list :path *interaction-log-path*
          :text-path *interaction-text-log-path*
          :history-path *session-history-path*
          :directory *interaction-log-directory*
          :file-id *interaction-log-file-id*
          :correlation-id *interaction-session-id*
          :parent-uuid *interaction-parent-uuid*)))

(defun call-with-web-session-log-context (session thunk)
  "Run THUNK with SESSION's durable logging bindings, retaining event linkage."
  (let ((context (web-session-log-context session)))
    (if (null context)
        (funcall thunk)
        (let ((*interaction-log-path* (getf context :path))
              (*interaction-text-log-path* (getf context :text-path))
              (*session-history-path* (getf context :history-path))
              (*interaction-log-directory* (getf context :directory))
              (*interaction-log-file-id* (getf context :file-id))
              (*interaction-session-id* (getf context :correlation-id))
              (*interaction-parent-uuid* (getf context :parent-uuid)))
          (unwind-protect (funcall thunk)
            (setf (getf context :parent-uuid) *interaction-parent-uuid*))))))

(defun make-web-session (&key backend model run-session-id options handlers (max-rounds 60)
                            history durable-session-id log-directory)
  "Create a browser session backed by normal chat history and optional durable logs.

DURABLE-SESSION-ID is the shared CLI/web identity. ID remains a browser UI UUID."
  (let* ((durable-id (or durable-session-id (session-log-timestamp-string)))
         (chat (make-chat-session :backend backend :model model :options options
                                  :handlers handlers :max-rounds max-rounds))
         (session (%make-web-session
                   :id (uuid-v4-string)
                   :durable-session-id durable-id
                   :run-session-id run-session-id
                   :chat-session chat
                   :events '() :state :ready :turn-number 0
                   :log-context (make-web-session-log-context log-directory durable-id))))
    (when history
      (setf (chat-session-history chat) history
            (web-session-turn-number session)
            (count "user" history :key (lambda (message) (getf message :role)) :test #'string=))
      (dolist (message history)
        (let ((role (getf message :role)) (content (getf message :content)))
          (when (and (stringp content) (member role '("user" "assistant") :test #'string=))
            (web-session-record-event session
                                      (if (string= role "user") "user-message" "assistant-message")
                                      :text content)))))
    (web-session-record-event session "session-started"
                              :session-id (web-session-id session)
                              :durable-session-id durable-id
                              :run-session-id run-session-id :state "ready"
                              :model model :backend (backend-name backend) :max-rounds max-rounds)
    session))

(defun web-session-submit (session content)
  "Run a browser turn through CHAT-SESSION-TURN with the session's log bindings."
  (let ((trimmed (and (stringp content) (string-trim '(#\Space #\Tab #\Newline #\Return) content))))
    (when (or (null trimmed) (zerop (length trimmed)))
      (web-session-record-event session "turn-empty" :state "ready")
      (return-from web-session-submit nil))
    (when (eq (web-session-state session) :running)
      (error "A browser turn is already running for this session."))
    (incf (web-session-turn-number session))
    (setf (web-session-state session) :running)
    (web-session-record-event session "user-message" :text content)
    (web-session-record-event session "assistant-pending" :state "running")
    (handler-case
        (let ((response
                (call-with-web-session-log-context
                 session
                 (lambda ()
                   (chat-session-turn
                    (web-session-chat-session session) content
                    :observer (lambda (kind &rest fields)
                                (apply #'web-session-record-event session kind fields)))))))
          (web-session-record-event session "assistant-message"
                                    :text (completion-response-text response))
          (setf (web-session-state session) :ready)
          (web-session-record-event session "turn-completed" :state "ready"
                                    :text (completion-response-text response))
          response)
      (error (condition)
        (let ((detail (scrub-interaction-log-text (princ-to-string condition))))
          (note-chat-session-failure (web-session-chat-session session))
          (setf (web-session-state session) :failed-turn)
          (web-session-record-event
           session "turn-failed" :state "failed-turn"
           :message (format nil "Provider request failed: ~A~%Retry is available."
                            (if (> (length detail) 600) (subseq detail 0 600) detail)))
          nil)))))

(defun web-session-clear (session)
  "Start a new browser conversation; prior durable history remains discoverable."
  (when (eq (web-session-state session) :running)
    (error "Cannot clear a browser session while its turn is running."))
  (let ((old-chat (web-session-chat-session session)))
    (setf (web-session-id session) (uuid-v4-string)
          (web-session-chat-session session)
          (make-chat-session :backend (chat-session-backend old-chat)
                             :model (chat-session-model old-chat)
                             :options (chat-session-options old-chat)
                             :handlers (chat-session-handlers old-chat)
                             :max-rounds (chat-session-max-rounds old-chat))
          (web-session-events session) '()
          (web-session-state session) :ready
          (web-session-turn-number session) 0)
    (web-session-record-event session "session-cleared" :session-id (web-session-id session)
                              :durable-session-id (web-session-durable-session-id session)
                              :run-session-id (web-session-run-session-id session) :state "ready")
    session))
