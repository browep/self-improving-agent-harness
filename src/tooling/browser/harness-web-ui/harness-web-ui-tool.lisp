(in-package #:self-improving-agent-harness)

;;;; App-specific CLOG web UI browser tooling (issue #41).
;;;;
;;;; This file builds on the generic browser_* tool handlers defined in
;;;; src/tooling/browser/browser-tool.lisp (issue #40). The generic handlers
;;;; know nothing about the harness CLOG web UI; this layer supplies the
;;;; app-specific knowledge: the default URL, the data-testid selectors used
;;;; throughout src/web-app.lisp (see the WEB-MARK calls), and composite
;;;; verification flows that drive the generic tools in sequence to exercise
;;;; real CLOG UI flows (open, start session, send a prompt, assert the chat
;;;; log, read the run id, screenshot, close).
;;;;
;;;; The data-testid values below must stay in sync with the WEB-MARK calls in
;;;; src/web-app.lisp. Each WEB-MARK (clog:attribute element "data-testid"
;;;; <value>) call there corresponds to one entry here.

(defparameter *harness-web-ui-url* "http://localhost:18080/"
  "Default URL for the harness CLOG web UI.")

(defparameter *harness-web-ui-testids*
  '(:harness-run-id "harness-run-id"
    :backend-input "backend-input"
    :model-input "model-input"
    :start-session "start-session"
    :clear-session "clear-session"
    :session-state "session-state"
    :session-id "session-id"
    :durable-session-id "durable-session-id"
    :sidebar-toggle "sidebar-toggle"
    :session-list "session-list"
    :chat-log "chat-log"
    :prompt-composer "prompt-composer"
    :send-turn "send-turn")
  "Alist mapping keyword symbols to data-testid attribute values used in
the CLOG web UI. Use (getf *harness-web-ui-testids* :start-session) to
get the selector string.")

(defun harness-web-ui-selector (key)
  "Return a CSS attribute selector for the given data-testid KEY."
  (format nil "[data-testid=~A]" (getf *harness-web-ui-testids* key)))

;;; ---------------------------------------------------------------------------
;;; Composite verification flows.
;;; ---------------------------------------------------------------------------

(defun harness-web-ui-open (&key (url *harness-web-ui-url*))
  "Open the CLOG web UI and wait for it to render. Returns the page title."
  (let ((args (make-hash-table :test 'equal)))
    (setf (gethash "url" args) url
          (gethash "wait_for" args) (harness-web-ui-selector :send-turn))
    (browser-open-tool args)))

(defun harness-web-ui-start-session ()
  "Click the 'New session' button and assert the session state becomes ready."
  (let ((click-args (make-hash-table :test 'equal)))
    (setf (gethash "selector" click-args) (harness-web-ui-selector :start-session))
    (browser-click-tool click-args))
  ;; Wait for session-state to show "ready"
  (let ((assert-args (make-hash-table :test 'equal)))
    (setf (gethash "expression" assert-args)
          (format nil "document.querySelector('~A').textContent.includes('ready')"
                  (harness-web-ui-selector :session-state)))
    (browser-assert-tool assert-args)))

(defun harness-web-ui-send-prompt (text)
  "Type a prompt into the composer and click Send."
  (let ((type-args (make-hash-table :test 'equal)))
    (setf (gethash "selector" type-args) (harness-web-ui-selector :prompt-composer)
          (gethash "value" type-args) text)
    (browser-type-tool type-args))
  (let ((click-args (make-hash-table :test 'equal)))
    (setf (gethash "selector" click-args) (harness-web-ui-selector :send-turn))
    (browser-click-tool click-args)))

(defun harness-web-ui-assert-chat-log-contains (text)
  "Assert the chat log contains the given text."
  (let ((args (make-hash-table :test 'equal)))
    (setf (gethash "expression" args)
          (format nil "document.querySelector('~A').textContent.includes('~A')"
                  (harness-web-ui-selector :chat-log)
                  text))
    (browser-assert-tool args)))

(defun harness-web-ui-get-run-id ()
  "Return the harness run ID displayed in the UI."
  (let ((args (make-hash-table :test 'equal)))
    (setf (gethash "selector" args) (harness-web-ui-selector :harness-run-id))
    (browser-get-text-tool args)))

(defun harness-web-ui-screenshot (&key (path "/workspace/harness-web-ui-screenshot.png"))
  "Take a screenshot of the CLOG web UI."
  (let ((args (make-hash-table :test 'equal)))
    (setf (gethash "path" args) path)
    (browser-screenshot-tool args)))

(defun harness-web-ui-close ()
  "Close the browser."
  (browser-close-tool (make-hash-table :test 'equal)))
