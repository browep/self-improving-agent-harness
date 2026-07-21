(in-package #:self-improving-agent-harness)

;;; Minimal CLOG presentation for the in-memory WEB-SESSION adapter.
;;; The browser remains a local, trusted surface: no credential or provider
;;; transport data is sent to it.

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

(defun web-render-event (timeline event)
  (let* ((kind (getf event :kind))
         (text (or (getf event :text) (getf event :result)
                   (getf event :message) ""))
         (item (web-mark (clog:create-div timeline
                                          :class "event"
                                          :content (format nil "<strong>~A</strong> ~A"
                                                           (web-html-escape kind)
                                                           (web-html-escape text)))
                         (format nil "event-~D" (getf event :sequence)))))
    (when (string= kind "tool-call-completed")
      (setf (clog:attribute item "data-tool-call-id") (getf event :tool-call-id)))
    item))

(defun web-on-new-window (body)
  (setf (clog:title (clog:html-document body)) "Self-improving Agent Harness")
  (let* ((root (clog:create-div body :class "harness-web"))
         (heading (clog:create-section root :h1 :content "Harness chat"))
         (start (web-mark (clog:create-button root :content "Start session") "start-session"))
         (state (web-mark (clog:create-div root :content "not started") "session-state"))
         (session-id (web-mark (clog:create-div root :content "") "session-id"))
         (composer (web-mark (clog:create-form-element root :textarea) "prompt-composer"))
         (send (web-mark (clog:create-button root :content "Send") "send-turn"))
         (timeline (web-mark (clog:create-div root :class "timeline") "timeline"))
         (session nil))
    (declare (ignore heading))
    (setf (clog:attribute composer "placeholder") "Enter a prompt")
    (setf (clog:disabledp send) t)
    (clog:set-on-click
     start
     (lambda (obj)
       (declare (ignore obj))
       (setf session (make-web-session
                      :backend (make-web-fake-backend)
                      :model "web/fake"
                      :handlers `(("echo" . ,(lambda (arguments)
                                               (format nil "echo: ~A" (gethash "message" arguments)))))))
       (setf (clog:inner-html state) "ready"
             (clog:inner-html session-id) (web-session-id session)
             (clog:disabledp send) nil)
       (web-render-event timeline (first (web-session-events session)))))
    (clog:set-on-click
     send
     (lambda (obj)
       (declare (ignore obj))
       (when session
         (web-session-submit session (clog:value composer))
         (setf (clog:value composer) "")
         (dolist (event (rest (web-session-events session)))
           (web-render-event timeline event)))))
    (clog:run body)))

(defun run-web-server (&key (host "0.0.0.0") (port 18080))
  "Start the local CLOG app. Docker controls host exposure separately."
  (clog:initialize #'web-on-new-window :host host :port port)
  (format t "WEB_READY url=http://127.0.0.1:~D/~%" port)
  (finish-output)
  (loop (sleep 60)))
