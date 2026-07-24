(in-package #:self-improving-agent-harness)

;;;; Official TypeScript Agent SDK bridge (issue #75/#76/#86).
;;;; Lisp owns durable history and normalized events.  Node owns query().

(define-condition claude-shim-backend-error (error)
  ((reason :initarg :reason :reader claude-shim-backend-error-reason))
  (:report (lambda (condition stream)
             (format stream "Claude shim backend error: ~A"
                     (claude-shim-backend-error-reason condition)))))

(defun claude-shim-error (format-control &rest args)
  (error 'claude-shim-backend-error :reason (apply #'format nil format-control args)))

(defparameter *claude-shim-command* '("node" "/workspace/tools/claude-shim/bridge.mjs"))
(defparameter *claude-shim-request-timeout-seconds* 120)
(defparameter +claude-shim-schema+ "claude-shim/v1")

(defun claude-shim-token ()
  (let ((value (uiop:getenv "CLAUDE_CODE_OAUTH_TOKEN")))
    (unless (and (stringp value) (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return) value))))
      (claude-shim-error "CLAUDE_CODE_OAUTH_TOKEN is required for claude-shim; generate a Claude subscription setup token with `claude setup-token`."))
    value))

(defun claude-shim-request-prompt (request)
  (with-output-to-string (out)
    (let ((first t))
      (dolist (message (completion-request-messages request))
        (when (and (string= (or (getf message :role) "") "user")
                   (stringp (getf message :content)))
          (unless first (terpri out))
          (setf first nil)
          (write-string (getf message :content) out))))))

(defun claude-shim-request-json (request)
  (with-output-to-string (out)
    (yason:encode
     (let ((table (make-hash-table :test #'equal)))
       (setf (gethash "schema" table) +claude-shim-schema+
             (gethash "type" table) "request"
             (gethash "model" table) (completion-request-model request)
             (gethash "prompt" table) (claude-shim-request-prompt request))
       ;; Capture routing is explicit; normal ambient ANTHROPIC_BASE_URL is ignored.
       (let ((base-url (uiop:getenv "CLAUDE_SHIM_ANTHROPIC_BASE_URL")))
         (when (and (stringp base-url) (plusp (length base-url)))
           (setf (gethash "anthropic_base_url" table) base-url)))
       table)
     out)))

(defun run-claude-shim-bridge (request token timeout)
  "Run one Node Agent SDK bridge child. TOKEN remains child-environment-only."
  (declare (ignore token timeout))
  (handler-case
      (multiple-value-bind (stdout stderr status)
          (uiop:run-program *claude-shim-command*
                            :input (claude-shim-request-json request)
                            :output :string :error-output :string
                            :ignore-error-status t)
        (unless (and (integerp status) (zerop status))
          (claude-shim-error "claude-shim bridge exited with status ~A: ~A" status stderr))
        stdout)
    (claude-shim-backend-error (condition) (error condition))
    (error (condition)
      (claude-shim-error "could not launch the Node Claude Agent SDK bridge (~A)." (type-of condition)))))

(defun claude-shim-json-field (object field)
  (and (hash-table-p object) (gethash field object)))

(defun claude-shim-native-events (value)
  (mapcar (lambda (event)
            (list :tool-call-id (claude-shim-json-field event "tool_call_id")
                  :tool-name (claude-shim-json-field event "tool_name")
                  :arguments (or (claude-shim-json-field event "arguments") "{}")
                  :result (or (claude-shim-json-field event "result") "")
                  :error-p (string= (or (claude-shim-json-field event "status") "") "failed")))
          (openrouter-list value)))

(defun claude-shim-response-from-json (text request)
  (handler-case
      (let* ((object (yason:parse text))
             (schema (claude-shim-json-field object "schema"))
             (kind (claude-shim-json-field object "type")))
        (unless (string= schema +claude-shim-schema+)
          (claude-shim-error "claude-shim bridge returned unsupported schema ~S." schema))
        (unless (string= kind "result")
          (claude-shim-error "claude-shim bridge returned terminal type ~S, not result." kind))
        (let ((result (claude-shim-json-field object "text")))
          (unless (stringp result)
            (claude-shim-error "claude-shim bridge result did not contain text."))
          (make-completion-response
           :text result
           :model (or (claude-shim-json-field object "model") (completion-request-model request))
           :raw object
           :tool-calls '()
           :native-tool-events (claude-shim-native-events (claude-shim-json-field object "native_tool_events"))
           :finish-reason (or (claude-shim-json-field object "finish_reason") "stop")
           :provider-request-id (claude-shim-json-field object "request_id")
           :usage nil)))
    (claude-shim-backend-error (condition) (error condition))
    (error (condition)
      (claude-shim-error "could not parse claude-shim bridge result (~A)." (type-of condition)))))

(defclass claude-shim-backend (backend)
  ((runner :initarg :runner :initform #'run-claude-shim-bridge :reader claude-shim-backend-runner)
   (timeout :initarg :timeout :initform *claude-shim-request-timeout-seconds*
            :reader claude-shim-backend-timeout)))

(defun make-claude-shim-backend (&key (runner #'run-claude-shim-bridge)
                                      (timeout *claude-shim-request-timeout-seconds*))
  "Construct a claude-shim backend without credential reads or I/O."
  (make-instance 'claude-shim-backend :name "claude-shim" :runner runner :timeout timeout))

(defmethod complete ((backend claude-shim-backend) request)
  (let ((token (claude-shim-token)))
    (claude-shim-response-from-json
     (funcall (claude-shim-backend-runner backend) request token (claude-shim-backend-timeout backend))
     request)))
