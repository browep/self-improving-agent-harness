(in-package #:self-improving-agent-harness)

(defparameter *interaction-log-path* nil
  "Path to the append-only JSON-lines interaction log, or NIL when disabled.")

(defvar *interaction-session-id* nil
  "Dynamically bound non-secret correlation ID for interaction diagnostics.")

(defvar *interaction-turn-number* nil
  "Dynamically bound one-based submitted-turn number for interaction diagnostics.")

(defun interaction-log-timestamp ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour minute second)))

(defun configure-interaction-logging (directory)
  "Write future interaction events to DIRECTORY/chat.log, or disable when NIL."
  (setf *interaction-log-path*
        (when directory
          (let ((path (merge-pathnames "chat.log"
                                       (uiop:ensure-directory-pathname directory))))
            (ensure-directories-exist path)
            (with-open-file (stream path :direction :output :if-does-not-exist :create
                                    :if-exists :append :external-format :utf-8)
              (finish-output stream))
            path))))

(defun log-interaction (level event &rest fields)
  "Append one UTF-8 JSON-lines interaction event when logging is configured."
  (when *interaction-log-path*
    (with-open-file (stream *interaction-log-path* :direction :output
                            :if-does-not-exist :create :if-exists :append
                            :external-format :utf-8)
      (yason:encode (openrouter-json-value
                     (append (list :timestamp (interaction-log-timestamp)
                                   :level (string-downcase (symbol-name level))
                                   :event event)
                             (when *interaction-session-id*
                               (list :session-id *interaction-session-id*))
                             (when *interaction-turn-number*
                               (list :turn *interaction-turn-number*))
                             fields))
                    stream)
      (terpri stream)
      (finish-output stream))))

(defun emit-chat-event (event &rest fields)
  "Write one machine-parseable JSONL chat-boundary event to standard error.

The caller supplies lifecycle or turn EVENT fields.  Dynamically bound session
and turn correlation context is included without putting assistant text on
stderr."
  (fresh-line *error-output*)
  (yason:encode
   (openrouter-json-value
    (append (list :event event)
            (when *interaction-session-id*
              (list :session-id *interaction-session-id*))
            (when *interaction-turn-number*
              (list :turn *interaction-turn-number*))
            fields))
   *error-output*)
  (terpri *error-output*)
  (finish-output *error-output*))
