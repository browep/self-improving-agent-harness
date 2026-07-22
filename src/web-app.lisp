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
(defvar *web-turn-in-progress-p* nil
  "True while a browser chat turn is running. Used by WEB-RELOAD-BROWSERS to
defer a forced refresh until the turn completes and the final assistant
message is recorded, so a reconnecting tab sees the complete transcript.")
(defvar *web-browser-reload-pending-p* nil
  "Set by WEB-RELOAD-BROWSERS when a refresh is requested during a turn. The
send handler checks this after the turn completes and triggers the refresh.")

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
          :backend (web-selected-backend (let ((saved (getf descriptor :backend)))
                                           (if (member saved '("synthetic" "openrouter" "codex") :test #'string=)
                                               saved
                                               "synthetic")))
          :model (or (getf descriptor :model) "syn:large:text")
          :max-rounds (or (getf descriptor :max-rounds) 60)
          :history (getf descriptor :history)
          :durable-session-id durable-id
          :run-session-id *web-run-session-id*
          :options 'chat-options
          :log-directory *web-log-directory*
          :handlers 'chat-handlers)))))

(defun web-known-sessions (&key (refresh t))
  "Return durable sessions newest-first, including CLI-created snapshots.

Sessions are sorted by durable-session-id (an ISO-8601 UTC timestamp) in
descending lexical order so the latest session appears at the top regardless
of registration order."
  (when refresh
    (dolist (descriptor (or (list-session-snapshots *web-log-directory*) '()))
      (web-load-durable-session descriptor)))
  (sort (remove nil (mapcar (lambda (id) (gethash id *web-sessions*)) *web-session-order*))
        #'string> :key #'web-session-durable-session-id))

(defun web-session-summary (session)
  (format nil "~A · ~D turn~:P" (web-session-durable-session-id session)
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
            (t (error "Backend must be synthetic, openrouter, or codex; got ~S." name)))))

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

(defun web-split-lines (text)
  "Split TEXT into a list of lines on #\Newline, stripping trailing #\Return."
  (let ((text (or text ""))
        (lines '())
        (start 0))
    (loop for i from 0 below (length text)
          for ch = (char text i)
          when (char= ch #\Newline)
            do (push (string-right-trim '(#\Return) (subseq text start i)) lines)
               (setf start (1+ i)))
    (push (string-right-trim '(#\Return) (subseq text start)) lines)
    (nreverse lines)))

(defun web-render-chat-message (chat-log event)
  "Render chat messages and tool lifecycle cards, including recovered malformed calls."
  (when (web-event-visible-in-chat-log-p event)
    (let* ((kind (getf event :kind))
           (userp (string= kind "user-message"))
           (assistantp (string= kind "assistant-message"))
           (tool-start-p (string= kind "tool-call-started"))
           (toolp (or tool-start-p (string= kind "tool-call-completed")))
           (role (cond (userp "You") (assistantp "Assistant")
                       ((string= kind "turn-failed") "Provider error")
                       (tool-start-p (format nil "Tool call \u00b7 ~A" (or (getf event :tool-name) "unknown")))
                       (t (format nil "Tool result \u00b7 ~A" (or (getf event :tool-name) "unknown")))))
           (text (cond (tool-start-p (or (getf event :arguments) "{}"))
                       ((string= kind "tool-call-completed") (or (getf event :result) ""))
                       (t (or (getf event :text) (getf event :message) ""))))
           (color (cond (userp "#3b82f6") (assistantp "#94a3b8") (tool-start-p "#d97706") (t "#059669")))
           (background (cond (userp "#eff6ff") (assistantp "#f8fafc") (tool-start-p "#fffbeb") (t "#ecfdf5")))
           (item (web-mark (clog:create-div chat-log :class "chat-message")
                           (format nil "message-~D" (getf event :sequence)))))
      (web-style item (format nil "box-sizing:border-box;width:100%;padding:12px 14px;border-radius:6px;line-height:1.4;white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:0.92rem;border-left:3px solid ~A;background:~A;color:#0f172a" color background))
      (clog:create-div item :class "role" :content role)
      (let ((lines (when toolp (web-split-lines text))))
        (if (and toolp (> (length lines) 10))
            (let* ((visible-text (format nil "~{~A~^~%~}" (subseq lines 0 10)))
                   (hidden-count (- (length lines) 10))
                   (hidden-text (format nil "~{~A~^~%~}" (subseq lines 10)))
                   (visible-div (clog:create-div item :content (web-html-escape visible-text)))
                   (hidden-div (web-style (clog:create-div item :content (web-html-escape hidden-text)) "display:none"))
                   (toggle (web-style (clog:create-button item :content (format nil "Show ~D more line~:P" hidden-count))
                                      "margin-top:6px;padding:2px 8px;font-size:0.85rem;cursor:pointer;border:1px solid #cbd5e1;border-radius:4px;background:#fff;color:#0f172a")))
              (declare (ignore visible-div))
              (clog:set-on-click toggle
                (lambda (obj)
                  (declare (ignore obj))
                  (if (string= (clog:attribute hidden-div "style") "display:none")
                      (progn
                        (setf (clog:attribute hidden-div "style") "display:block")
                        (setf (clog:inner-html toggle) "Show less"))
                      (progn
                        (setf (clog:attribute hidden-div "style") "display:none")
                        (setf (clog:inner-html toggle) (format nil "Show ~D more line~:P" hidden-count)))))))
            (clog:create-div item :content (web-html-escape text))))
      item)))

(defun web-render-context-line (chat-log session start-time)
  "Render a context details line after an assistant message, mirroring the CLI.

Shows model, provider rounds, turn duration, history message count, and the
token/context-window fill suffix that the CLI prints as <<< DONE."
  (let* ((chat (web-session-chat-session session))
         (rounds (length (chat-session-last-provider-responses chat)))
         (duration (elapsed-seconds-since start-time))
         (model (chat-session-model chat))
         (history-count (length (chat-session-history chat)))
         (backend (chat-session-backend chat))
         (accounting (chat-session-last-accounting chat))
         (suffix (format-context-fill-suffix backend model accounting))
         (base (format nil "model=~A  rounds=~D  duration_seconds=~,3F  history=~D messages"
                       model rounds duration history-count))
         (text (if (and suffix (plusp (length suffix)))
                   (format nil "~A  ~A" base suffix)
                   base))
         (item (web-style (clog:create-div chat-log :class "context-line" :content text)
                          "width:100%;padding:4px 14px;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:0.8rem;color:#94a3b8;border-top:1px solid #e2e8f0")))
    (declare (ignore item))))

(defun web-clear-thinking-indicator (body indicator)
  "Stop the live thinking timer and remove the indicator element from the DOM.

Clears the window.__harnessThinkingTimer interval and destroys the INDICATOR
CLOG element. Uses a single-line JS string (no FORMAT line-continuation tildes)
so the cleanup is always valid JavaScript and the indicator never lingers
after a turn completes."
  (clog:js-execute body
                   "if(window.__harnessThinkingTimer){clearInterval(window.__harnessThinkingTimer);window.__harnessThinkingTimer=null;}")
  (when indicator
    (clog:destroy indicator)))

(defun web-on-new-window (body)
  (setf (clog:title (clog:html-document body)) "Self-improving Agent Harness")
  (clog:js-execute body
                   (concatenate 'string
                                "var m=document.querySelector('meta[name=\"viewport\"]');"
                                " if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}"
                                " m.content='width=device-width,initial-scale=1,interactive-widget=resizes-content';"))
  (let* ((root (web-style (clog:create-div body :class "harness-web")
                          "min-height:100vh;min-height:100dvh;box-sizing:border-box;padding:clamp(10px,2vw,18px);display:flex;flex-direction:column;gap:12px;font-family:system-ui,sans-serif;background:#fff;color:#0f172a;overflow-x:hidden"))
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
         (workspace (web-style (clog:create-div root :class "workspace") "flex:1;min-height:0;display:flex;flex-wrap:wrap;align-content:flex-start;gap:12px"))
         (sidebar (web-style (clog:create-div workspace :class "session-sidebar") "width:240px;max-width:100%;flex:1 1 220px;overflow-y:auto;padding:10px;border:1px solid #cbd5e1;border-radius:12px;background:#f8fafc;box-sizing:border-box"))
         (sidebar-title (web-mark (web-style (clog:create-div sidebar :content "▸ Previous sessions")
                                             "width:100%;font-weight:600;padding:6px 8px;cursor:pointer;box-sizing:border-box;user-select:none")
                                   "sidebar-toggle"))
         (session-list (web-mark (web-style (clog:create-div sidebar :class "session-list") "display:none") "session-list"))
         (conversation (web-style (clog:create-div workspace :class "conversation") "flex:999 1 360px;min-width:0;min-height:0;display:flex;flex-direction:column;gap:10px"))
         (chat-log (web-mark (web-style (clog:create-div conversation :class "chat-log") "flex:1;min-height:0;max-height:65vh;max-height:65dvh;overflow-y:auto;display:flex;flex-direction:column;gap:10px;padding:10px;border:1px solid #cbd5e1;border-radius:12px;background:#f8fafc;box-sizing:border-box") "chat-log"))
         (composer-row (web-style (clog:create-div conversation :class "composer-row") "display:flex;flex-wrap:wrap;gap:8px;align-items:stretch"))
         (composer (web-mark (web-style (clog:create-text-area composer-row :rows 2) "flex:1 1 240px;min-height:54px;resize:vertical;padding:10px;font:inherit;box-sizing:border-box") "prompt-composer"))
         (send (web-mark (web-style (clog:create-button composer-row :content "Send") "flex:1 1 92px;min-width:92px;min-height:54px;font:inherit") "send-turn"))
         (session nil)
         (rendered-sequence 0)
         (request-in-progress-p nil)
         (sessions-collapsed-p t))
    (declare (ignore heading run-label run-id browser-label durable-label backend-label model-label))
    (setf (clog:value backend-input) "synthetic"
          (clog:value model-input) "syn:large:text")
    (setf (clog:attribute composer "placeholder") "Enter a prompt")
    (setf (clog:disabledp send) t)
    (clog:set-on-focus
     composer
     (lambda (obj)
       (declare (ignore obj))
       ;; On mobile the soft keyboard can cover the input; scroll it into view.
       (clog:js-execute composer
                        (format nil "setTimeout(function(){~A.scrollIntoView({block:'center',behavior:'smooth'});},300)"
                                (clog:script-id composer)))))
    (labels ((render-active-session ()
               (setf (clog:inner-html chat-log) ""
                     (clog:inner-html state) (cond (request-in-progress-p "Request in progress — waiting for provider response (up to 120 seconds)…")
                                                   (session "ready")
                                                   (t "not started"))
                     (clog:inner-html session-id) (if session (web-session-id session) "")
                     (clog:inner-html durable-session-id) (if session (web-session-durable-session-id session) "")
                     (clog:disabledp send) (or (null session) request-in-progress-p)
                     (clog:value composer) ""
                     (clog:value backend-input) (if session (backend-name (chat-session-backend (web-session-chat-session session))) "synthetic")
                     (clog:value model-input) (if session (chat-session-model (web-session-chat-session session)) "syn:large:text"))
               (when session
                 (dolist (event (web-session-events session))
                   (web-render-chat-message chat-log event))
                 (setf rendered-sequence (length (web-session-events session)))
                 ;; Scroll the transcript to the bottom so a freshly loaded
                 ;; previous conversation shows the most recent messages first.
                 (clog:js-execute chat-log
                                  (format nil "~A.scrollTop = ~A.scrollHeight;"
                                          (clog:script-id chat-log)
                                          (clog:script-id chat-log))))
               ;; Reflect the active session in the URL hash so a browser
               ;; refresh returns to the same conversation.
               (setf (clog:hash (clog:location body))
                     (if session
                         (format nil "#~A" (web-session-durable-session-id session))
                         "")))
             (load-session (selected)
               (setf session selected)
               (render-active-session)
               ;; Collapse the previous-sessions list after selecting one so
               ;; the conversation gets the full sidebar space.
               (setf sessions-collapsed-p t)
               (render-sidebar-toggle))
             (render-session-list ()
               (setf (clog:inner-html session-list) "")
               (dolist (candidate (web-known-sessions))
                 (let ((button (web-style
                                (web-mark (clog:create-button session-list :content (web-session-summary candidate))
                                          (format nil "saved-session-~A" (web-session-id candidate)))
                                "display:block;width:100%;margin:6px 0;padding:8px;text-align:left;font-family:ui-monospace,monospace")))
                   (clog:set-on-click button (lambda (obj) (declare (ignore obj)) (load-session candidate))))))
             (render-sidebar-toggle ()
               (setf (clog:inner-html sidebar-title)
                     (if sessions-collapsed-p "▸ Previous sessions" "▾ Previous sessions"))
               (setf (clog:attribute session-list "style")
                     (if sessions-collapsed-p "display:none" "display:block"))))
      (render-session-list)
      (render-sidebar-toggle)
      ;; On a fresh page load (or refresh), restore the session indicated
      ;; by the URL hash anchor so the user returns to the same conversation.
      (let* ((raw-hash (clog:hash (clog:location body)))
             (durable-id (when (and (stringp raw-hash) (plusp (length raw-hash)))
                           (string-trim '(#\#) raw-hash))))
        (when (and durable-id (plusp (length durable-id)))
          (let ((found (find durable-id (web-known-sessions)
                             :key #'web-session-durable-session-id :test #'string=)))
            (when found
              (load-session found)))))
      (clog:set-on-click
       sidebar-title
       (lambda (obj)
         (declare (ignore obj))
         (setf sessions-collapsed-p (not sessions-collapsed-p))
         (render-sidebar-toggle)))
      (clog:set-on-click
       start
       (lambda (obj)
         (declare (ignore obj))
         (let ((backend-name (string-downcase (string-trim '(#\Space #\Tab #\Newline #\Return) (clog:value backend-input))))
               (model-name (string-trim '(#\Space #\Tab #\Newline #\Return) (clog:value model-input))))
           (setf session (web-register-session
                          (make-web-session :backend (web-selected-backend backend-name) :model model-name
                                            :run-session-id *web-run-session-id*
                                            :options 'chat-options
                                            :log-directory *web-log-directory*
                                            :handlers 'chat-handlers)))
           (render-session-list)
           (render-active-session))))
      (clog:set-on-click
       send
       (lambda (obj)
         (declare (ignore obj))
         (when (and session (not request-in-progress-p))
           (let ((text (clog:value composer))
                 (turn-start (get-internal-real-time)))
             ;; Mutate the browser immediately before entering the synchronous
             ;; server-side provider/tool loop, so a slow provider no longer
             ;; looks like a dead Send click.
             (setf request-in-progress-p t
                   *web-turn-in-progress-p* t
                   (clog:inner-html state) "Request in progress — waiting for provider response (up to 120 seconds)…"
                   (clog:disabledp send) t)
             ;; Clear the input and show the user message right away so the
             ;; UI feels responsive before the synchronous provider call blocks.
             (setf (clog:value composer) "")
             (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
               (when (plusp (length trimmed))
                 (web-render-chat-message chat-log
                                          (list :kind "user-message"
                                                :sequence (1+ (length (web-session-events session)))
                                                :text text))
                 ;; Skip this event when rendering post-submit events since
                 ;; we already rendered it manually above.
                 (incf rendered-sequence)
                 (clog:js-execute chat-log
                                  (format nil "~A.scrollTop = ~A.scrollHeight;"
                                          (clog:script-id chat-log)
                                          (clog:script-id chat-log)))))
             ;; Add a live "thinking" indicator in the chat log that shows
             ;; elapsed inference time via a JS interval timer. The timer id
             ;; is stored on the window object so we can clear it when the
             ;; turn completes. Rendered as subtle grey text, not a card.
             ;; The INDICATOR binding wraps the UNWIND-PROTECT so the cleanup
             ;; form can destroy the same CLOG element by reference.
             (let ((indicator (web-style (clog:create-div chat-log :class "thinking-indicator"
                                                          :content "Thinking… 0.0s")
                                         "width:100%;padding:2px 14px;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:0.85rem;color:#94a3b8;box-sizing:border-box")))
               (clog:js-execute body
                                (format nil
                                         "window.__harnessThinkingStart=Date.now();~
                                          window.__harnessThinkingTimer=setInterval(function(){~
                                            var el=~A;~
                                            if(el){var s=((Date.now()-window.__harnessThinkingStart)/1000).toFixed(1);~
                                            el.textContent='Thinking\u2026 '+s+'s';}~
                                          },100);"
                                         (clog:script-id indicator)))
               (unwind-protect
                    (progn
                      (web-session-submit session text)
                      (dolist (event (web-session-events session))
                        (when (> (getf event :sequence) rendered-sequence)
                          (web-render-chat-message chat-log event)))
                      (setf rendered-sequence (length (web-session-events session)))
                      (render-session-list)
                      ;; Clear the thinking indicator timer and remove the element.
                      (web-clear-thinking-indicator body indicator)
                      ;; Show a context details line after the assistant message,
                      ;; mirroring the CLI's <<< DONE outcome line.
                      (web-render-context-line chat-log session turn-start)
                      ;; Scroll to bottom again after the full turn completes so
                      ;; the assistant response is visible.
                      (clog:js-execute chat-log
                                       (format nil "~A.scrollTop = ~A.scrollHeight;"
                                               (clog:script-id chat-log)
                                               (clog:script-id chat-log))))
                 (web-clear-thinking-indicator body indicator)
                 (setf request-in-progress-p nil
                       *web-turn-in-progress-p* nil
                       (clog:inner-html state) "ready"
                       (clog:disabledp send) nil)
                 ;; If reload_harness was called during this turn, the browser
                 ;; refresh was deferred until now so the final assistant message
                 ;; is already in the session events before the tab reconnects.
                 (when *web-browser-reload-pending-p*
                   (web-reload-browsers))))))))
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
  ;; Register a thin indirection so reload_harness can redefine
  ;; WEB-ON-NEW-WINDOW and have new browser connections pick up the
  ;; updated code without restarting the CLOG server. CLOG stores the
  ;; function object passed to INITIALIZE; a bare #'WEB-ON-NEW-WINDOW
  ;; would snapshot the function that existed at startup time and keep
  ;; calling the old one after a reload. The lambda resolves the symbol
  ;; on every connection, so it always calls the current definition.
  (clog:initialize (lambda (body) (web-on-new-window body))
                   :host host :port port)
  ;; After a successful reload_harness, re-register the on-new-window
  ;; handler so CLOG drops any function object it snapshotted at startup
  ;; and dispatches new connections through the lambda indirection above
  ;; (which resolves the current WEB-ON-NEW-WINDOW). This is a no-op for
  ;; the lambda case but is essential when the server was started with a
  ;; bare #'WEB-ON-NEW-WINDOW before this indirection existed.
  (add-post-reload-hook
   (lambda ()
     (when (clog:is-running-p)
       (clog:set-on-new-window (lambda (body) (web-on-new-window body))
                               :path "/"))))
  (format t "WEB_READY url=http://127.0.0.1:~D/ run_session_id=~A~%"
          port (or run-session-id "none"))
  (finish-output)
  (loop (sleep 60)))

(defun web-reload-browsers ()
  "Send location.reload() to every live CLOG browser connection.

Called as a post-reload hook so open tabs pick up reloaded UI code without a
manual refresh. If a browser chat turn is in progress (*WEB-TURN-IN-PROGRESS-P*),
the refresh is deferred: the send handler checks *WEB-BROWSER-RELOAD-PENDING-P*
after the turn completes and the final assistant message is recorded, then
calls this function so a reconnecting tab sees the complete transcript."
  (when (and (find-package :clog)
             (fboundp (intern "IS-RUNNING-P" :clog))
             (funcall (intern "IS-RUNNING-P" :clog)))
    (if *web-turn-in-progress-p*
        ;; Defer: the send handler will call us after the turn finishes.
        (setf *web-browser-reload-pending-p* t)
        (progn
          (setf *web-browser-reload-pending-p* nil)
          (let ((ids '()))
            (maphash (lambda (k v) (declare (ignore v)) (push k ids))
                     (symbol-value (intern "*CONNECTION-IDS*" :clog-connection)))
            (dolist (id ids)
              (ignore-errors
                (funcall (intern "EXECUTE" :clog-connection) id "location.reload();"))))))))

;;; Reload-time re-registration for an already-running CLOG server.
;;;
;;; run-web-server registers a post-reload hook, but only when it executes.
;;; When reload_harness LOADs this file into an image where the CLOG server
;;; is already running (the normal case: PID 7 started scripts/web.lisp and
;;; is now in its sleep loop), that registration never happened. This
;;; top-level form runs at LOAD time and, if CLOG is up, immediately
;;; re-points the on-new-window handler at the current WEB-ON-NEW-WINDOW
;;; and registers the hook so future reloads keep it current.
(when (and (find-package :clog)
           (fboundp (intern "IS-RUNNING-P" :clog))
           (funcall (intern "IS-RUNNING-P" :clog)))
  (funcall (intern "SET-ON-NEW-WINDOW" :clog)
           (lambda (body) (web-on-new-window body))
           :path "/")
  (add-post-reload-hook
   (lambda ()
     (when (funcall (intern "IS-RUNNING-P" :clog))
       (funcall (intern "SET-ON-NEW-WINDOW" :clog)
                (lambda (body) (web-on-new-window body))
                :path "/"))))
  ;; Force every open browser tab to refresh after a reload so it picks
  ;; up the reloaded UI code. The new connection re-runs the current
  ;; web-on-new-window and restores the session from the URL hash.
  (add-post-reload-hook #'web-reload-browsers))
