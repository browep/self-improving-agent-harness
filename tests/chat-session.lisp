(in-package #:self-improving-agent-harness/tests)

(defun message-role (message)
  (getf message :role))

(defun run-chat-session-tests ()
  (let* ((first-response (make-completion-response :text "first answer" :model "test/model"))
         (second-response (make-completion-response :text "second answer" :model "test/model"))
         (backend (make-instance 'scripted-backend
                                 :name "scripted"
                                 :responses (list first-response second-response)))
         (session (make-chat-session :backend backend :model "test/model"
                                     :options '(:max-tokens 512) :handlers '())))
    (ensure-true (null (chat-session-turn session "") )
                 "empty interactive input is ignored")
    (ensure-equal 0 (length (scripted-backend-received-requests backend))
                  "empty interactive input makes no backend request")
    (chat-session-turn session "first question")
    (chat-session-turn session "second question")
    (let* ((requests (reverse (scripted-backend-received-requests backend)))
           (second-request (second requests))
           (second-messages (completion-request-messages second-request)))
      (ensure-equal 4 (length second-messages)
                    "second turn carries the prior completed exchange")
      (ensure-equal "system" (message-role (first second-messages))
                    "history begins with the system prompt")
      (ensure-equal "first question" (getf (second second-messages) :content)
                    "second request retains the first user turn")
      (ensure-equal "first answer" (getf (third second-messages) :content)
                    "second request retains the first assistant response")
      (ensure-equal "second question" (getf (fourth second-messages) :content)
                    "second request ends with the current user turn")))
  (let* ((tool-response
           (make-completion-response
            :text ""
            :model "test/model"
            :tool-calls '((:id "call-session" :type "function" :name "echo"
                           :arguments "{\"message\":\"tool input\"}"))))
         (final-response (make-completion-response :text "tool answer" :model "test/model"))
         (backend (make-instance 'scripted-backend :name "scripted"
                                 :responses (list tool-response final-response)))
         (session (make-chat-session
                   :backend backend :model "test/model"
                   :handlers `(("echo" . ,(lambda (arguments)
                                            (format nil "echo: ~A"
                                                    (gethash "message" arguments))))))))
    (chat-session-turn session "use the tool")
    (let ((history (chat-session-history session)))
      (ensure-equal '("system" "user" "assistant" "tool" "assistant")
                    (mapcar #'message-role history)
                    "interactive history preserves tool-loop message order")
      (ensure-equal "call-session" (getf (fourth history) :tool-call-id)
                    "interactive tool result stays linked to its tool call")
      (ensure-equal "tool answer" (getf (fifth history) :content)
                    "interactive history retains the final tool-turn response")))
  (let* ((backend (make-instance 'scripted-backend :name "scripted" :responses '()))
         (session (make-chat-session :backend backend :model "test/model" :handlers '())))
    (note-chat-session-failure session)
    (ensure-true (chat-session-failed-turn-p session)
                 "a failed interactive turn is recorded without exposing error detail"))
  (format t "Chat-session tests passed.~%")
  t)
