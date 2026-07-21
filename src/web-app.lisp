(in-package #:self-improving-agent-harness)

;;; Minimal CLOG presentation for the in-memory WEB-SESSION adapter.
;;; The browser remains a local, trusted surface: no credential or provider
;;; transport data is sent to it.

(defvar *web-run-session-id* nil
  "The existing HARNESS_CHAT_SESSION_ID that owns this CLOG server process.")
(defvar *web-fake-scenario* nil
  "Optional deterministic server scenario, set once by RUN-WEB-SERVER.")
(defvar *web-log-directory* "/workspace/agent-logs"
  "Durable shared CLI/CLOG session directory.")

(defvar *web-sessions* (make-hash-table :test #'equal))
(defvar *web-session-order* '())

(defun web-register-session (session)
  "Keep browser sessions available for later selection while this server runs."
  (setf (gethash (web-session-id session) *web-sessions*) session)
  (pushnew (web-session-id session) *web-session-order* :test #'string=)
  session)

(defun web-load-durable-session (descriptor)
  "Materialize a durable CLI or web snapshot as a selectable browser session."
  (let ((durable-id (getf descriptor :session-id)))
    (or (find durable-id (web-known-sessions :refresh nil)
              :key #'web-session-durable-session-id :test #'string=)
        (web-register-session
         (make-web-session
          :backend (web-selected-backend (or (getf descriptor :backend) "synthetic"))
          :model (or (getf descriptor :model) "syn:large:text")
          :max-rounds (or (getf descriptor :max-rounds) 60)
          :history (getf descriptor :history)
          :durable-session-id durable-id
          :run-session-id *web-run-session-id*
          :log-directory *web-log-directory*
          :handlers `(("echo" . ,(lambda (arguments)
                                    (format nil "echo: ~A" (gethash "message" arguments))))))))))

(defun web-known-sessions (&key (refresh t))
  "Return durable sessions newest-first, including CLI-created snapshots."
  (when refresh
    (dolist (descriptor (or (list-session-snapshots *web-log-directory*) '()))
      (web-load-durable-session descriptor)))
  (remove nil (mapcar (lambda (id) (gethash id *web-sessions*)) *web-session-order*)))

(defun web-session-summary (session)
  (format nil "~A · ~D turn~:P" (subseq (web-session-durable-session-id session) 0 8)
          (web-session-turn-number session)))

(defclass web-fake-backend (backend)
  ((responses :initarg :responses :accessor web-fake-backend-responses)))

(defmethod complete ((backend web-fake-backend) request)
  (declare (ignore request))
  (or (pop (web-fake-backend-responses backend))
      (make-completion-response :text "The deterministic browser session is ready."
                                :model "web/fake" :finish-reason "stop")))

(defun make-web-fake-backend ()
  (make-instance
   'web-fake-backend :name "web-fake"
   :responses
   (list
    (make-completion-response
     :model "web/fake"
     :tool-calls '((:id "scripted-1" :type "function" :name "echo"
                    :arguments "{\"message\":\"browser tool flow\"}")))
    (make-completion-response :text "Deterministic tool flow completed."
                              :model "web/fake" :finish-reason "stop"))))

(defun web-selected-backend (name)
  "Construct the selected provider adapter without exposing credentials to the UI."
  (if (string= (or *web-fake-scenario* "") "tool-success")
      (make-web-fake-backend)
      (cond ((string= name "synthetic") (make-synthetic-backend :api-key (uiop:getenv "SYNTHETIC_API_KEY")))
            ((string= name "openrouter") (make-openrouter-backend :api-key (uiop:getenv "OPENROUTER_API_KEY")))
            ((string= name "codex") (make-codex-app-server-backend))
            (t (error "Backend must be synthetic, openrouter, or codex.")))))

(defun web-html-escape (text)
  (with-output-to-string (out)
    (loop for character across (or text "") do
      (write-string (case character
                      (#\& "&amp;") (#\< "&lt;") (#\> "&gt;")
                      (#\" "&quot;") (#\' "&#39;") (t (string character))) out))))

(defun web-mark (element test-id)
  (setf (clog:attribute element "data-testid") test-id)
  element)

(defun web-style (element value)
  (setf (clog:attribute element "style") value)
  element)

(defun web-render-chat-message (chat-log event)
  "Render only durable user/assistant cards; provider/tool telemetry stays internal."
  (when (web-event-visible-in-chat-log-p event)
    (let* ((kind (getf event :kind))
           (userp (string= kind "user-message"))
           (role (if userp "You" "Assistant"))
           (text (or (getf event :text) ""))
           (item (web-mark
                  (clog:create-div chat-log
                                   :class (if userp "chat-message user" "chat-message assistant")
                                   :content (format nil "<div class=\"role\">~A</div><div>~A</div>"
                                                    role (web-html-escape text)))
                  (format nil "message-~D" (getf event :sequence)))))
      (web-style item (format nil "box-sizing:border-box;width:100%;padding:12px 14px;border-radius:6px;line-height:1.4;white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:0.92rem;border-left:3px solid ~A;~A"
                              (if userp "#3b82f6" "#94a3b8")
                              (if userp "background:#eff6ff;color:#0f172a" "background:#f8fafc;color:#334155")))
      item)))

(defun web-on-new-window (body)
  (setf (clog:title (clog:html-document body)) "Self-improving Agent Harness")
  (let* ((root (web-style (clog:create-div body :class "harness-web")
                          "height:100vh;box-sizing:border-box;padding:18px;display:flex;flex-direction:column;gap:14px;font-family:system-ui,sans-serif;background:#fff;color:#0f172a"))
         (controls (web-style (clog:create-div root :class "session-controls")
                              "display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding-bottom:12px;border-bottom:1px solid #cbd5e1"))
         (heading (clog:create-section controls :h1 :content "Harness chat"))
         (run-label (clog:create-div controls :content "Harness run ID:"))
         (run-id (web-mark (clog:create-div controls :content (or *web-run-session-id* "not supplied")) "harness-run-id"))
         (backend-label (clog:create-div controls :content "Backend:"))
         (backend-input (web-mark (web-style (clog:create-form-element controls :text) "width:110px;padding:6px;font-family:ui-monospace,monospace") "backend-input"))
         (model-label (clog:create-div controls :content "Model:"))
         (model-input (web-mark (web-style (clog:create-form-element controls :text) "width:160px;padding:6px;font-family:ui-monospace,monospace") "model-input"))
         (start (web-mark (clog:create-button controls :content "New session") "start-session"))
         (clear (web-mark (clog:create-button controls :content "Clear session") "clear-session"))
         (state (web-mark (clog:create-div controls :content "not started") "session-state"))
         (browser-label (clog:create-div controls :content "Browser session ID:"))
         (session-id (web-mark (clog:create-div controls :content "") "session-id"))
         (durable-label (clog:create-div controls :content "Durable session ID:"))
         (durable-session-id (web-mark (clog:create-div controls :content "") "durable-session-id"))
         (workspace (web-style (clog:create-div root :class "workspace") "flex:1;min-height:0;display:flex;gap:14px"))
         (sidebar (web-style (clog:create-div workspace :class "session-sidebar") "width:240px;flex:0 0 240px;overflow-y:auto;padding:10px;border:1px solid #cbd5e1;border-radius:12px;background:#f8fafc"))
         (sidebar-title (clog:create-div sidebar :content "Previous sessions"))
         (session-list (web-mark (clog:create-div sidebar :class "session-list") "session-list"))
         (conversation (web-style (clog:create-div workspace :class "conversation") "flex:1;min-width:0;display:flex;flex-direction:column;gap:12px"))
         (chat-log (web-mark (web-style (clog:create-div conversation :class "chat-log") "flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:10px;padding:14px;border:1px solid #cbd5e1;border-radius:12px;background:#f8fafc") "chat-log"))
         (composer-row (web-style (clog:create-div conversation :class "composer-row") "display:flex;gap:10px;align-items:flex-end"))
         (composer (web-mark (web-style (clog:create-form-element composer-row :textarea) "flex:1;min-height:54px;resize:vertical;padding:10px;font:inherit") "prompt-composer"))
         (send (web-mark (web-style (clog:create-button composer-row :content "Send") "min-width:92px;height:54px;font:inherit") "send-turn"))
         (session nil)
         (rendered-sequence 0))
    (declare (ignore heading run-label run-id browser-label durable-label sidebar-title backend-label model-label))
    (setf (clog:value backend-input) "synthetic"
          (clog:value model-input) "syn:large:text")
    (setf (clog:attribute composer "placeholder") "Enter a prompt")
    (setf (clog:disabledp send) t)
    (labels ((render-active-session ()
               (setf (clog:inner-html chat-log) ""
                     (clog:inner-html state) (if session "ready" "not started")
                     (clog:inner-html session-id) (if session (web-session-id session) "")
                     (clog:inner-html durable-session-id) (if session (web-session-durable-session-id session) "")
                     (clog:disabledp send) (null session)
                     (clog:value composer) "")
               (when session
                 (dolist (event (web-session-events session))
                   (web-render-chat-message chat-log event))
                 (setf rendered-sequence (length (web-session-events session)))))
             (load-session (selected)
               (setf session selected)
               (render-active-session))
             (render-session-list ()
               (setf (clog:inner-html session-list) "")
               (dolist (candidate (web-known-sessions))
                 (let ((button (web-style
                                (web-mark (clog:create-button session-list :content (web-session-summary candidate))
                                          (format nil "saved-session-~A" (web-session-id candidate)))
                                "display:block;width:100%;margin:6px 0;padding:8px;text-align:left;font-family:ui-monospace,monospace")))
                   (clog:set-on-click button (lambda (obj) (declare (ignore obj)) (load-session candidate)))))))
      (render-session-list)
      (clog:set-on-click
       start
       (lambda (obj)
         (declare (ignore obj))
         (let ((backend-name (string-downcase (string-trim '(#\Space #\Tab #\Newline #\Return) (clog:value backend-input))))
               (model-name (string-trim '(#\Space #\Tab #\Newline #\Return) (clog:value model-input))))
           (setf session (web-register-session
                          (make-web-session :backend (web-selected-backend backend-name) :model model-name
                                            :run-session-id *web-run-session-id*
                                            :log-directory *web-log-directory*
                                            :handlers `(("echo" . ,(lambda (arguments) (format nil "echo: ~A" (gethash "message" arguments))))))))
           (render-session-list)
           (render-active-session))))
      (clog:set-on-click
       send
       (lambda (obj)
         (declare (ignore obj))
         (when session
           (web-session-submit session (clog:value composer))
           (setf (clog:value composer) "")
           (dolist (event (web-session-events session))
             (when (> (getf event :sequence) rendered-sequence)
               (web-render-chat-message chat-log event)))
           (setf rendered-sequence (length (web-session-events session)))
           (render-session-list))))
      (clog:set-on-click
       clear
       (lambda (obj)
         (declare (ignore obj))
         (when session
           (web-session-clear session)
           (web-register-session session)
           (render-session-list)
           (render-active-session))))
    (clog:run body))))

(defun run-web-server (&key (host "0.0.0.0") (port 18080) run-session-id fake-scenario
                            (log-directory "/workspace/agent-logs"))
  "Start the local CLOG app. Docker controls host exposure separately."
  (setf *web-run-session-id* run-session-id
        *web-fake-scenario* fake-scenario
        *web-log-directory* log-directory)
  (clog:initialize #'web-on-new-window :host host :port port)
  (format t "WEB_READY url=http://127.0.0.1:~D/ run_session_id=~A~%"
          port (or run-session-id "none"))
  (finish-output)
  (loop (sleep 60)))
