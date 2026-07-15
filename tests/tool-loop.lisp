(in-package #:self-improving-agent-harness/tests)

(defclass scripted-backend (backend)
  ((responses :initarg :responses :accessor scripted-backend-responses)
   (received-requests :initform '() :accessor scripted-backend-received-requests)))

(defmethod complete ((backend scripted-backend) request)
  (push request (scripted-backend-received-requests backend))
  (or (pop (scripted-backend-responses backend))
      (error "Test backend exhausted its scripted responses.")))

(defun ensure-error-containing (thunk expected description)
  (handler-case
      (progn
        (funcall thunk)
        (error "Test failed: ~A did not signal an error" description))
    (error (condition)
      (ensure-true (search expected (princ-to-string condition)) description))))

(defun run-tool-loop-tests ()
  (let* ((tool-response
           (make-completion-response
            :text ""
            :model "test/model"
            :tool-calls '((:id "call-123" :type "function" :name "echo"
                           :arguments "{\"message\":\"hello\"}"))))
         (final-response
           (make-completion-response :text "done" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list tool-response final-response)))
         (handler-arguments nil)
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "Say hello using echo.")))
            `(("echo" . ,(lambda (arguments)
                            (setf handler-arguments arguments)
                            (format nil "echoed: ~A" (gethash "message" arguments))))))))
    (ensure-equal "done" (completion-response-text result)
                  "tool loop returns the final assistant response")
    (ensure-equal "hello" (gethash "message" handler-arguments)
                  "tool handler receives decoded JSON arguments")
    (ensure-equal 2 (length (scripted-backend-received-requests backend))
                  "tool loop submits a continuation after executing a tool")
    (let* ((continuation
             (first (scripted-backend-received-requests backend)))
           (messages (completion-request-messages continuation))
           (assistant-message (second messages))
           (tool-message (third messages)))
      (ensure-equal "assistant" (getf assistant-message :role)
                    "continuation includes the assistant tool-call message")
      (ensure-true (null (getf assistant-message :content))
                   "tool-only assistant messages use OpenRouter's null content convention")
      (ensure-equal "call-123" (getf (first (getf assistant-message :tool-calls)) :id)
                    "continuation retains the provider tool-call ID")
      (ensure-equal "tool" (getf tool-message :role)
                    "continuation includes a tool result message")
      (ensure-equal "call-123" (getf tool-message :tool-call-id)
                    "tool result references the matching tool call")
      (ensure-equal "echoed: hello" (getf tool-message :content)
                    "tool result contains handler output")))
  (ensure-error-containing
   (lambda ()
     (self-improving-agent-harness:run-tool-loop
      (make-instance 'scripted-backend
                     :name "scripted"
                     :responses (list (make-completion-response
                                       :tool-calls '((:id "call-unknown" :type "function"
                                                      :name "missing" :arguments "{}")))))
      (make-completion-request :model "test/model" :messages '())
      '()))
   "No handler is registered for tool"
   "unknown tool calls produce an explicit outcome")
  (ensure-error-containing
   (lambda ()
     (self-improving-agent-harness:run-tool-loop
      (make-instance 'scripted-backend
                     :name "scripted"
                     :responses (list (make-completion-response
                                       :tool-calls '((:id "call-invalid" :type "function"
                                                      :name "echo" :arguments "{not-json")))))
      (make-completion-request :model "test/model" :messages '())
      `(("echo" . ,(lambda (arguments) arguments)))))
   "invalid JSON arguments"
   "malformed tool arguments produce a redacted outcome")
  (let* ((tool-response
           (make-completion-response
            :model "test/model"
            :tool-calls '((:id "call-failure" :type "function" :name "echo"
                           :arguments "{}"))))
         (final-response (make-completion-response :text "the tool failed" :model "test/model"))
         (backend (make-instance 'scripted-backend :name "scripted"
                                 :responses (list tool-response final-response)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request :model "test/model" :messages '())
            `(("echo" . ,(lambda (arguments)
                            (declare (ignore arguments))
                            (error "private handler detail")))))))
    (ensure-equal "the tool failed" (completion-response-text result)
                  "handler failures continue to a final model response")
    (let* ((continuation (first (scripted-backend-received-requests backend)))
           (tool-message (second (completion-request-messages continuation))))
      (ensure-true (search "TOOL_ERROR: Tool echo failed." (getf tool-message :content))
                   "handler failures are returned to the model as tool output")
      (ensure-true (not (search "private handler detail" (getf tool-message :content)))
                   "handler failure details remain redacted from the model")))
  (ensure-error-containing
   (lambda ()
     (self-improving-agent-harness:run-tool-loop
      (make-instance 'scripted-backend
                     :name "scripted"
                     :responses (list (make-completion-response
                                       :tool-calls '((:id "call-limit" :type "function"
                                                      :name "echo" :arguments "{}")))))
      (make-completion-request :model "test/model" :messages '())
      `(("echo" . ,(lambda (arguments) arguments)))
      :max-rounds 0))
   "Tool-call loop exceeded its 0 round limit"
   "exhausted tool-loop round limits produce an explicit outcome")
  (format t "Tool-loop tests passed.~%")
  t)
