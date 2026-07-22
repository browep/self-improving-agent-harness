;;; This file is loadable two ways:
;;;   1. As a component of the :self-improving-agent-harness/tests system, where
;;;      tests/package.lisp has already created the test package.
;;;   2. STANDALONE, via `--load <this-file>` after loading only the main
;;;      :self-improving-agent-harness system (the way scripts/run-browser-verify.lisp
;;;      and the issue #42 verification command invoke it). In that case the
;;;      test package does not exist yet, so ensure it is loaded first. The
;;;      guard is a no-op when the package already exists.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:self-improving-agent-harness/tests)
    (load (merge-pathnames "../../../package.lisp" (or *load-truename*
                                                     *compile-file-truename*)))))

(in-package #:self-improving-agent-harness/tests)

;;;; CLOG web UI browser integration test + verification artifact bundle
;;;; (GitHub issue #42).
;;;;
;;;; This is a STANDALONE integration test, not part of the normal
;;;; self-improving-agent-harness/tests suite. It drives the REAL CLOG web UI
;;;; (served at http://localhost:18080/ by scripts/web.lisp) through the
;;;; app-specific harness-web-ui-* tooling (issue #41), which in turn drives
;;;; the generic browser_* tool handlers (issue #40) over the Playwright stdio
;;;; bridge (issues #38/#39). It proves the whole browser-tooling stack can
;;;; open the CLOG UI, wait for the WebSocket-built DOM, start a session, type
;;;; a prompt, send a turn, and assert the user message lands in the chat log.
;;;;
;;;; Because it needs a running CLOG server and a real headless Chromium, it
;;;; is NOT wired into RUN-TESTS. Load it explicitly and call
;;;; RUN-BROWSER-VERIFICATION-TEST:
;;;;
;;;;   sbcl --noinform --non-interactive \
;;;;     --load /opt/quicklisp/setup.lisp \
;;;;     --eval '(asdf:load-asd "/workspace/self-improving-agent-harness.asd")' \
;;;;     --eval '(asdf:load-system :self-improving-agent-harness)' \
;;;;     --load tests/tooling/browser/harness-web-ui/harness-web-ui-integration.lisp \
;;;;     --eval '(self-improving-agent-harness/tests:run-browser-verification-test)'
;;;;
;;;; The test produces an artifact bundle under OUTPUT-DIR (default
;;;; /tmp/browser-verify/<run-id>/):
;;;;   01-initial-load.png        02-after-start-session.png   03-after-send.png
;;;;   dom-snapshots.json         console.log                  manifest.json

;;; ---------------------------------------------------------------------------
;;; Internal helpers.
;;; ---------------------------------------------------------------------------

;; The harness-web-ui-* helpers live in the SELF-IMPROVING-AGENT-HARNESS
;; package and are exported, so they are visible here (this package :USEs
;; it). A few transport helpers (browser-ensure-bridge, browser-json-to-string,
;; browser-make-params) are NOT exported; reach them with the double-colon
;; package-internal prefix, mirroring tests/openrouter-adapter.lisp.

(defun bv-timestamp ()
  "Return an ISO-8601 UTC timestamp string for the manifest."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

(defun bv-ensure-dir (dir)
  "Create DIR (and parents) if missing; return its truename as a string."
  (ensure-directories-exist dir)
  (namestring (truename dir)))

(defun bv-run-id-dir (output-dir)
  "Return a fresh per-run subdirectory under OUTPUT-DIR.

Uses a timestamp + random suffix so repeated runs do not clobber each other."
  (bv-ensure-dir
   (merge-pathnames
    (format nil "run-~A-~36R/" (bv-timestamp) (random 1000000))
    (uiop:ensure-pathname output-dir :ensure-directory t))))

(defun bv-selector (key)
  "Convenience wrapper around HARNESS-WEB-UI-SELECTOR for the testids we use."
  (harness-web-ui-selector key))

(defun bv-get-text (key)
  "Return the trimmed textContent of the element with data-testid KEY."
  (let ((args (self-improving-agent-harness::browser-make-params
               "selector" (bv-selector key))))
    (string-trim '(#\Space #\Tab #\Newline #\Return)
                 (browser-get-text-tool args))))

(defun bv-eval (expression)
  "Evaluate EXPRESSION in the page and return the rendered result string."
  (let ((args (self-improving-agent-harness::browser-make-params
               "expression" expression)))
    (browser-eval-tool args)))

(defun bv-assert-now (expression)
  "One-shot assert: return (VALUES PASS-P RESULT-STRING)."
  (let* ((args (self-improving-agent-harness::browser-make-params
                "expression" expression))
         (result (browser-assert-tool args)))
    (values (and (stringp result) (search "PASS" result :test #'char=))
            result)))

(defun bv-assert-poll (expression description &key (timeout 15) (interval 0.25))
  "Poll a browser_assert expression until it PASSes or TIMEOUT seconds elapse.

CLOG renders the DOM over WebSocket, so a server-side click handler that sets
inner-html only reaches the browser after a WebSocket round-trip. A one-shot
assert fired immediately after the click can race the wire and report FAIL even
though the update is in flight. Polling for up to TIMEOUT seconds absorbs that
race while still failing fast when something is genuinely wrong.

Returns (VALUES PASS-P RESULT-STRING)."
  (format t "~&[browser-verify] polling (up to ~As): ~A~%" timeout description)
  (loop repeat (max 1 (floor timeout interval))
        for (passp result) = (multiple-value-list (bv-assert-now expression))
        when passp
          do (return (values t result))
        do (sleep interval)
        finally
           (return (values nil result))))

(defun bv-screenshot (path)
  "Take a full-page screenshot to PATH; return PATH."
  (let ((args (self-improving-agent-harness::browser-make-params "path" (namestring path))))
    (browser-screenshot-tool args)
    path))

(defun bv-dom-snapshot ()
  "Capture a JSON object of the key data-testid elements' textContent.

Returned as a Lisp alist (KEY . TEXT) so the caller can fold it into both the
dom-snapshots.json artifact and the manifest."
  (flet ((grab (key)
           (let ((expr (format nil
                               "(()=>{var e=document.querySelector('~A');~
                                return e?e.textContent.trim():null;})()"
                               (bv-selector key))))
             (cons (string key) (or (bv-eval expr) "")))))
    (list (grab :harness-run-id)
          (grab :session-state)
          (grab :session-id)
          (grab :chat-log)
          (grab :prompt-composer))))

(defun bv-get-console ()
  "Drain the Playwright bridge's buffered console/pageerror messages.

Returns a list of decoded message hash tables (or NIL if the bridge is gone)."
  (let ((bridge (self-improving-agent-harness::browser-ensure-bridge)))
    (when bridge
      (let* ((result (pw-call bridge "get_console"))
             (messages (and (hash-table-p result)
                            (gethash "messages" result))))
        (when (listp messages)
          messages)))))

(defun bv-write-json-file (path value)
  "Write VALUE as pretty JSON to PATH. VALUE may be a hash table, list, or
vector; lists are encoded as JSON arrays."
  (with-open-file (stream path :direction :output
                          :if-exists :supersede :if-does-not-exist :create)
    ;; This yason build encodes hash tables as JSON objects and vectors as
    ;; JSON arrays (the same convention used by browser-json-to-string in
    ;; src/tooling/browser/browser-tool.lisp). Coerce plain lists to vectors
    ;; so callers can pass either form.
    (yason:encode
     (etypecase value
       (hash-table value)
       (list (coerce value 'vector))
       (vector value))
     stream))
  path)

(defun bv-write-text-file (path text)
  "Write TEXT to PATH, overwriting any existing file."
  (with-open-file (stream path :direction :output
                          :if-exists :supersede :if-does-not-exist :create)
    (write-string text stream))
  path)

;;; ---------------------------------------------------------------------------
;;; Manifest step record.
;;; ---------------------------------------------------------------------------

(defstruct bv-step
  "One recorded step of the verification flow for the manifest."
  index
  name
  timestamp
  assertions        ; list of (description pass-p result-string)
  screenshot       ; relative filename or NIL
  dom-snapshot)    ; alist of (key . text) or NIL

(defun bv-step-add-assertion (step description passp result)
  "Record an assertion outcome on STEP and return PASSP."
  (push (list description passp result) (bv-step-assertions step))
  passp)

;;; ---------------------------------------------------------------------------
;;; Main verification flow.
;;; ---------------------------------------------------------------------------

(defun run-browser-verification-test (&key (output-dir "/tmp/browser-verify")
                                      (url self-improving-agent-harness:*harness-web-ui-url*))
  "Drive the real CLOG web UI end-to-end and produce a verification artifact bundle.

OUTPUT-DIR is the parent directory for the per-run artifact bundle (default
/tmp/browser-verify). A fresh timestamped subdirectory is created for each
invocation so repeated runs do not clobber each other. URL is the CLOG web UI
address (default *HARNESS-WEB-UI-URL*, http://localhost:18080/).

Returns (VALUES PASS-P BUNDLE-DIR) where PASS-P is a boolean and BUNDLE-DIR is
the directory holding the artifacts. Signals an error only if the browser
tooling itself is unavailable; assertion failures are recorded in the manifest
and reflected in PASS-P, not raised, so a partial run still yields evidence."
  (let* ((bundle-dir (bv-run-id-dir output-dir))
         (steps nil)
         (console-messages nil)
         (start-iso (bv-timestamp))
         (pass-p t)
         (open-result nil)
         (run-id-text nil)
         (final-state-text nil))
    (format t "~&[browser-verify] bundle dir: ~A~%" bundle-dir)
    (format t "~&[browser-verify] url: ~A~%" url)
    (unwind-protect
         (progn
           ;; --- Step 1: open the CLOG web UI -------------------------------
           ;; harness-web-ui-open navigates and waits for the send-turn testid
           ;; to appear, which proves the CLOG DOM built over WebSocket.
           (let ((step (make-bv-step :index 1 :name "open-clog-web-ui"
                                     :timestamp (bv-timestamp))))
             (setf open-result (harness-web-ui-open :url url))
             (format t "~&[browser-verify] step 1 open: ~A~%" open-result)
             ;; Assert the open returned a title (proves navigation succeeded).
             (let ((passp (bv-step-add-assertion
                            step "browser_open returns a non-empty status string"
                            (and (stringp open-result)
                                 (search "Browser opened" open-result :test #'char=))
                            open-result)))
               (unless passp (setf pass-p nil)))
             ;; Assert the send-turn testid is present (DOM built over WS).
             (multiple-value-bind (passp result)
                 (bv-assert-poll
                  (format nil "!!document.querySelector('~A')"
                          (bv-selector :send-turn))
                  "send-turn testid is present after open")
               (bv-step-add-assertion step "send-turn testid is present after open"
                                      passp result)
               (unless passp (setf pass-p nil)))
             (setf (bv-step-dom-snapshot step) (bv-dom-snapshot))
             (setf (bv-step-screenshot step) "01-initial-load.png")
             (bv-screenshot (merge-pathnames "01-initial-load.png" bundle-dir))
             (push step steps))

           ;; --- Step 2: assert run-id contains "2026" ---------------------
           ;; Proves the page rendered with real data (the harness run id,
           ;; e.g. 2026-07-22T04:40:00.000Z, comes from HARNESS_CHAT_SESSION_ID).
           (setf run-id-text (bv-get-text :harness-run-id))
           (format t "~&[browser-verify] run-id text: [~A]~%" run-id-text)
           (let ((passp (and (stringp run-id-text)
                             (search "2026" run-id-text :test #'char=))))
             (unless passp (setf pass-p nil))
             ;; Fold this assertion into step 1's record (it is part of the
             ;; initial-load verification) rather than inventing a screenshot.
             (let ((s1 (find 1 steps :key #'bv-step-index)))
               (bv-step-add-assertion
                s1 "harness-run-id text contains \"2026\""
                passp (format nil "run-id=~A" run-id-text))))

           ;; --- Step 3: read initial session-state ------------------------
           (let ((initial-state (bv-get-text :session-state)))
             (format t "~&[browser-verify] initial session-state: [~A]~%"
                     initial-state)
             (let ((s1 (find 1 steps :key #'bv-step-index)))
               (bv-step-add-assertion
                s1 "session-state is \"not started\" before start-session"
                (string= "not started" initial-state)
                (format nil "state=~A" initial-state))
               (unless (string= "not started" initial-state) (setf pass-p nil))))

           ;; --- Step 4: click start-session, assert state -> ready --------
           (let ((step (make-bv-step :index 2 :name "start-session"
                                     :timestamp (bv-timestamp))))
             (let ((click-args (self-improving-agent-harness::browser-make-params
                               "selector" (bv-selector :start-session))))
               (browser-click-tool click-args))
             (format t "~&[browser-verify] step 2 clicked start-session~%")
             (multiple-value-bind (passp result)
                 (bv-assert-poll
                  (format nil "document.querySelector('~A').textContent.includes('ready')"
                          (bv-selector :session-state))
                  "session-state contains \"ready\" after start-session")
               (bv-step-add-assertion step "session-state contains \"ready\" after start-session"
                                      passp result)
               (unless passp (setf pass-p nil)))
             (setf (bv-step-dom-snapshot step) (bv-dom-snapshot))
             (setf (bv-step-screenshot step) "02-after-start-session.png")
             (bv-screenshot (merge-pathnames "02-after-start-session.png" bundle-dir))
             (push step steps))

           ;; --- Step 5: type a prompt and click send-turn -----------------
           (let ((step (make-bv-step :index 3 :name "send-turn"
                                     :timestamp (bv-timestamp)))
                 (prompt "hello from integration test"))
             (harness-web-ui-send-prompt prompt)
             (format t "~&[browser-verify] step 3 sent prompt: ~A~%" prompt)
             ;; The user message should appear in the chat log immediately
             ;; (the send handler renders it before the provider call).
             (multiple-value-bind (passp result)
                 (bv-assert-poll
                  (format nil
                          "document.querySelector('~A').textContent.includes('~A')"
                          (bv-selector :chat-log) prompt)
                  "chat-log contains the sent user message")
               (bv-step-add-assertion step "chat-log contains the sent user message"
                                      passp result)
               (unless passp (setf pass-p nil)))
             (setf (bv-step-dom-snapshot step) (bv-dom-snapshot))
             (setf (bv-step-screenshot step) "03-after-send.png")
             (bv-screenshot (merge-pathnames "03-after-send.png" bundle-dir))
             (push step steps))

           ;; --- Step 6: capture console messages --------------------------
           (setf console-messages (bv-get-console))
           (format t "~&[browser-verify] captured ~A console message(s)~%"
                   (length console-messages))

           ;; Final state read for the manifest summary.
           (setf final-state-text (bv-get-text :session-state)))
      ;; --- Always close the browser, even on a non-local exit. ----------
      (ignore-errors (harness-web-ui-close)))

    ;; --- Write the artifact bundle ---------------------------------------
    (bv-write-artifacts bundle-dir url steps console-messages
                        start-iso pass-p run-id-text final-state-text)

    (format t "~&[browser-verify] ~A~%"
            (if pass-p "ALL ASSERTIONS PASSED" "ONE OR MORE ASSERTIONS FAILED"))
    (format t "~&[browser-verify] artifacts: ~A~%" bundle-dir)
    (values pass-p bundle-dir)))

;;; ---------------------------------------------------------------------------
;;; Artifact bundle writers.
;;; ---------------------------------------------------------------------------

(defun bv-console-messages-to-objects (messages)
  "Normalize decoded console message hash tables into JSON-compatible hash tables."
  (mapcar (lambda (msg)
            (let ((obj (make-hash-table :test 'equal)))
              (setf (gethash "type" obj) (or (and (hash-table-p msg)
                                                  (gethash "type" msg)) "unknown")
                    (gethash "kind" obj) (or (and (hash-table-p msg)
                                                  (gethash "kind" msg)) "")
                    (gethash "text" obj) (or (and (hash-table-p msg)
                                                  (gethash "text" msg)) ""))
              obj))
          messages))

(defun bv-dom-snapshot-to-object (snapshot)
  "Convert a dom-snapshot alist ((\"KEY\" . \"text\") ...) into a JSON object."
  (let ((obj (make-hash-table :test 'equal)))
    (loop for (key . val) in snapshot
          do (setf (gethash key obj) val))
    obj))

(defun bv-step-to-object (step)
  "Convert a BV-STEP into a JSON object for the manifest."
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "index" obj) (bv-step-index step)
          (gethash "name" obj) (bv-step-name step)
          (gethash "timestamp" obj) (bv-step-timestamp step)
          (gethash "screenshot" obj) (bv-step-screenshot step))
    (setf (gethash "assertions" obj)
          (mapcar (lambda (a)
                    (let ((o (make-hash-table :test 'equal)))
                      (setf (gethash "description" o) (first a)
                            (gethash "pass" o) (second a)
                            (gethash "result" o) (third a))
                      o))
                  (reverse (bv-step-assertions step))))
    (setf (gethash "dom" obj) (bv-dom-snapshot-to-object (bv-step-dom-snapshot step)))
    obj))

(defun bv-write-artifacts (bundle-dir url steps console-messages
                           start-iso pass-p run-id-text final-state-text)
  "Write the full verification artifact bundle into BUNDLE-DIR.

Files produced:
  01-initial-load.png, 02-after-start-session.png, 03-after-send.png
    (already written during the flow; this function only writes the text/JSON
    artifacts and the manifest.)
  dom-snapshots.json  - per-step DOM text of the key data-testid elements
  console.log         - human-readable browser console output
  manifest.json       - run metadata, steps, assertions, screenshots, console"
  (let ((steps-in-order (sort steps #'< :key #'bv-step-index)))

    ;; dom-snapshots.json: an array of per-step DOM snapshots.
    (bv-write-json-file
     (merge-pathnames "dom-snapshots.json" bundle-dir)
     (mapcar #'bv-step-to-object steps-in-order))

    ;; console.log: human-readable, one message per line.
    (let ((lines
            (with-output-to-string (out)
              (format out "# Browser console messages captured during the run~%")
              (format out "# bundle: ~A~%" bundle-dir)
              (if (null console-messages)
                  (format out "# (no console messages captured)~%")
                  (dolist (msg console-messages)
                    (let ((type (and (hash-table-p msg) (gethash "type" msg)))
                          (kind (and (hash-table-p msg) (gethash "kind" msg)))
                          (text (and (hash-table-p msg) (gethash "text" msg))))
                      (format out "[~A/~A] ~A~%" (or type "?") (or kind "") (or text ""))))))))
      (bv-write-text-file (merge-pathnames "console.log" bundle-dir) lines))

    ;; manifest.json: the run metadata + steps + assertions + screenshots +
    ;; console messages, all in one machine-readable file.
    (let ((manifest (make-hash-table :test 'equal)))
      (setf (gethash "schema" manifest) "self-improving-agent-harness/browser-verify/v1")
      (setf (gethash "url" manifest) url)
      (setf (gethash "started_at" manifest) start-iso)
      (setf (gethash "finished_at" manifest) (bv-timestamp))
      (setf (gethash "pass" manifest) pass-p)
      (setf (gethash "run_id_text" manifest) run-id-text)
      (setf (gethash "final_session_state" manifest) final-state-text)
      (setf (gethash "bundle_dir" manifest) (namestring bundle-dir))
      (setf (gethash "steps" manifest)
            (mapcar #'bv-step-to-object steps-in-order))
      (setf (gethash "screenshots" manifest)
            (mapcar #'bv-step-screenshot steps-in-order))
      (setf (gethash "console_messages" manifest)
            (bv-console-messages-to-objects console-messages))
      (bv-write-json-file (merge-pathnames "manifest.json" bundle-dir) manifest))
    (values)))
