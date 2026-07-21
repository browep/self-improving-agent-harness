(in-package #:self-improving-agent-harness)

;;; Minimal CLOG presentation for the in-memory WEB-SESSION adapter.
;;; The browser remains a local, trusted surface: no credential or provider
;;; transport data is sent to it.

(defvar *web-run-session-id* nil
  "The existing HARNESS_CHAT_SESSION_ID that owns this CLOG server process.")

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
      (web-style item (format nil "box-sizing:border-box;width:100%;padding:12px 14px;border-radius:6px;line-height:1.4;white-space:pre-wrap;border-left:3px solid ~A;~A"
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
         (run-id (web-mark (clog:create-div controls :content (or *web-run-session-id* "not supplied"))
                           "harness-run-id"))
         (start (web-mark (clog:create-button controls :content "Start session") "start-session"))
         (clear (web-mark (clog:create-button controls :content "Clear session") "clear-session"))
         (state (web-mark (clog:create-div controls :content "not started") "session-state"))
         (browser-label (clog:create-div controls :content "Browser session ID:"))
         (session-id (web-mark (clog:create-div controls :content "") "session-id"))
         (chat-log (web-mark (web-style (clog:create-div root :class "chat-log")
                                         "flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:10px;padding:14px;border:1px solid #cbd5e1;border-radius:12px;background:#f8fafc")
                             "chat-log"))
         (composer-row (web-style (clog:create-div root :class "composer-row")
                                  "display:flex;gap:10px;align-items:flex-end"))
         (composer (web-mark (web-style (clog:create-form-element composer-row :textarea)
                                         "flex:1;min-height:54px;resize:vertical;padding:10px;font:inherit")
                             "prompt-composer"))
         (send (web-mark (web-style (clog:create-button composer-row :content "Send")
                                     "min-width:92px;height:54px;font:inherit")
                         "send-turn"))
         (session nil)
         (rendered-sequence 0))
    (declare (ignore heading run-label run-id browser-label))
    (setf (clog:attribute composer "placeholder") "Enter a prompt")
    (setf (clog:disabledp send) t)
    (clog:set-on-click
     start
     (lambda (obj)
       (declare (ignore obj))
       (setf session (make-web-session
                      :backend (make-web-fake-backend)
                      :model "web/fake"
                      :run-session-id *web-run-session-id*
                      :handlers `(("echo" . ,(lambda (arguments)
                                               (format nil "echo: ~A" (gethash "message" arguments)))))))
       (setf (clog:inner-html state) "ready"
             (clog:inner-html session-id) (web-session-id session)
             (clog:disabledp send) nil
             (clog:inner-html chat-log) "")
       (setf rendered-sequence (length (web-session-events session)))))
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
         (setf rendered-sequence (length (web-session-events session))))))
    (clog:set-on-click
     clear
     (lambda (obj)
       (declare (ignore obj))
       (when session
         (web-session-clear session)
         (setf (clog:inner-html chat-log) ""
               (clog:inner-html state) "ready"
               (clog:inner-html session-id) (web-session-id session))
         (dolist (event (web-session-events session))
           (web-render-chat-message chat-log event))
         (setf rendered-sequence (length (web-session-events session))))))
    (clog:run body)))

(defun run-web-server (&key (host "0.0.0.0") (port 18080) run-session-id)
  "Start the local CLOG app. Docker controls host exposure separately."
  (setf *web-run-session-id* run-session-id)
  (clog:initialize #'web-on-new-window :host host :port port)
  (format t "WEB_READY url=http://127.0.0.1:~D/ run_session_id=~A~%"
          port (or run-session-id "none"))
  (finish-output)
  (loop (sleep 60)))
