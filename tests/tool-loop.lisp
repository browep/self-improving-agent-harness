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
;; XML/text-embedded tool-call recovery (Synthetic/GLM compatibility fallback).
(let* ((handler-arguments nil)
         (xml-response
           (make-completion-response
            :text "Working on it.<tool_call>echo<arg_key>message</arg_key><arg_value>from-xml</arg_value></tool_call>"
            :model "test/model"
            :finish-reason "stop"
            :tool-calls '()))
         (final-response
           (make-completion-response :text "xml-done" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list xml-response final-response)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "use echo")))
            `(("echo" . ,(lambda (arguments)
                            (setf handler-arguments arguments)
                            (format nil "echoed: ~A"
                                    (gethash "message" arguments))))))))
    (ensure-equal "xml-done" (completion-response-text result)
                  "complete XML-ish tool markup is recovered and continues the loop")
    (ensure-equal "from-xml" (gethash "message" handler-arguments)
                  "recovered XML tool arguments are decoded for the handler")
    (let* ((continuation (first (scripted-backend-received-requests backend)))
           (messages (completion-request-messages continuation))
           (assistant-message (second messages))
           (tool-message (third messages)))
      (ensure-equal "assistant" (getf assistant-message :role)
                    "XML recovery still emits an assistant tool-call message")
      (ensure-equal "Working on it." (getf assistant-message :content)
                    "leading prose before <tool_call> is preserved as assistant content")
      (ensure-equal "tool" (getf tool-message :role)
                    "XML recovery emits a tool result message")
      (ensure-equal "echoed: from-xml" (getf tool-message :content)
                    "XML recovery tool result contains handler output")))
  ;; Controlled recovery permits only an explicit quoted run_shell command in a closed block.
  (let ((calls (self-improving-agent-harness::parse-text-embedded-tool-calls
                "<tool_call>run_shell command=\"pwd\"</arg_value></tool_call>")))
    (ensure-equal "run_shell" (getf (first calls) :name)
                  "controlled malformed recovery preserves the requested tool")
    (ensure-equal "{\"command\":\"pwd\"}" (getf (first calls) :arguments)
                  "controlled malformed recovery extracts only the explicit quoted command"))
(let* ((handler-called nil)
         (truncated-response
           (make-completion-response
            :text "Confirmed — heredoc cut off.<tool_call>run_shell<arg_key>command</arg_key><arg_value>cat > big.md << 'EOF'
# title
still going"
            :model "test/model"
            :finish-reason "length"
            :tool-calls '()))
         (final-response
           (make-completion-response :text "handled-truncation" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list truncated-response final-response)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "write the file")))
            `(("run_shell" . ,(lambda (arguments)
                                 (declare (ignore arguments))
                                 (setf handler-called t)
                                 "should-not-run"))))))
    (ensure-equal "handled-truncation" (completion-response-text result)
                  "truncated XML tool markup continues the loop without hanging")
    (ensure-true (not handler-called)
                 "truncated XML tool markup does not execute the tool handler")
    (let* ((continuation (first (scripted-backend-received-requests backend)))
           (tool-message (third (completion-request-messages continuation))))
      (ensure-equal "tool" (getf tool-message :role)
                    "truncated recovery still produces a tool result message")
      (ensure-true (search "TOOL_ERROR: Truncated text tool call"
                           (getf tool-message :content))
                   "truncated recovery returns an explicit non-execution error")
      (ensure-true (search "native tools/tool_calls"
                           (getf tool-message :content))
                   "truncated recovery tells the model to use native tool_calls")))
(let* ((handler-arguments nil)
         (native-response
           (make-completion-response
            :text "ignore this <tool_call>echo<arg_key>message</arg_key><arg_value>xml-should-lose</arg_value></tool_call>"
            :model "test/model"
            :tool-calls '((:id "call-native" :type "function" :name "echo"
                           :arguments "{\"message\":\"native-wins\"}"))))
         (final-response
           (make-completion-response :text "native-done" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list native-response final-response)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request :model "test/model" :messages '())
            `(("echo" . ,(lambda (arguments)
                            (setf handler-arguments arguments)
                            "ok"))))))
    (ensure-equal "native-done" (completion-response-text result)
                  "native tool_calls still complete the loop when XML text is also present")
    (ensure-equal "native-wins" (gethash "message" handler-arguments)
                  "native message.tool_calls win over XML markup in content"))

  ;; Empty finish_reason=length finals must not silently end the turn blank.
  (let* ((empty-length
           (make-completion-response
            :text ""
            :model "test/model"
            :finish-reason "length"
            :tool-calls '()))
         (recovered
           (make-completion-response
            :text "recovered-after-empty-length"
            :model "test/model"
            :finish-reason "stop"
            :tool-calls '()))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list empty-length recovered)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "continue")))
            '())))
    (ensure-equal "recovered-after-empty-length" (completion-response-text result)
                  "empty finish_reason=length auto-continues once and returns later text")
    (ensure-equal 2 (length (scripted-backend-received-requests backend))
                  "empty-length recovery records the original request plus one continuation")
    (let* ((continuation (first (scripted-backend-received-requests backend)))
           (messages (completion-request-messages continuation))
           (nudge (car (last messages))))
      (ensure-equal "user" (getf nudge :role)
                    "empty-length recovery appends a user nudge")
      (ensure-true (search "finish_reason=length" (getf nudge :content))
                   "empty-length nudge mentions finish_reason=length")))

  (let* ((empty-length
           (make-completion-response
            :text ""
            :model "test/model"
            :finish-reason "length"
            :tool-calls '()))
         (still-empty
           (make-completion-response
            :text "   "
            :model "test/model"
            :finish-reason "length"
            :tool-calls '()))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list empty-length still-empty)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "continue")))
            '())))
    (ensure-true (search "[harness]" (completion-response-text result))
                 "repeated empty finish_reason=length synthesizes a visible diagnostic")
    (ensure-true (search "finish_reason=length" (completion-response-text result))
                 "diagnostic mentions finish_reason=length")
    (ensure-equal "length" (completion-response-finish-reason result)
                  "diagnostic preserves the provider finish_reason"))

  (let* ((whitespace-stop
           (make-completion-response
            :text "   "
            :model "test/model"
            :finish-reason "stop"
            :tool-calls '()))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list whitespace-stop)))
         (result
           (self-improving-agent-harness:run-tool-loop
            backend
            (make-completion-request
             :model "test/model"
             :messages '((:role "user" :content "hi")))
            '())))
    (ensure-equal "   " (completion-response-text result)
                  "empty-ish stop responses are left alone (not length-retried)"))

  (format t "Tool-loop tests passed.~%")
  t)
