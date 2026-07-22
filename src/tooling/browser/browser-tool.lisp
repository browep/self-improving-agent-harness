(in-package #:self-improving-agent-harness)

;;;; Agent-facing browser_* tool handlers (issue #40).
;;;;
;;;; These are the thin agent-facing wrappers around the generic Playwright
;;;; stdio transport in src/tooling/browser/playwright-bridge.lisp (issue
;;;; #39). A persistent bridge is kept in the module-global
;;;; *PLAYWRIGHT-BRIDGE* so the page stays warm across tool calls: BROWSER-OPEN
;;;; lazily starts it, subsequent tools reuse it, and BROWSER-CLOSE tears it
;;;; down.
;;;;
;;;; Each handler takes a decoded JSON object (Yason hash-table of arguments)
;;;; and returns a plain string, exactly like RUN-SHELL-TOOL and
;;;; WEB-SEARCH-TOOL. Errors are caught and returned as strings so the tool
;;;; loop never sees a raw condition from a flaky browser interaction.

(defvar *playwright-bridge* nil
  "Persistent Playwright bridge for browser_* tools. Lazily started by
BROWSER-OPEN, reused by subsequent tools, closed by BROWSER-CLOSE.")

;; Ensure the Playwright bridge subprocess is terminated on Lisp image exit.
;; Without this, a node process spawned by MAKE-PLAYWRIGHT-BRIDGE could be
;; orphaned if the image exits (or is reloaded) without an explicit
;; BROWSER-CLOSE. The hook is idempotent: PW-CLOSE is wrapped in
;; IGNORE-ERRORS and tolerates an already-dead bridge.
(push (lambda ()
        (when (and *playwright-bridge* (pw-alive-p *playwright-bridge*))
          (ignore-errors (pw-close *playwright-bridge*))))
      sb-ext:*exit-hooks*)

(defparameter *browser-default-url* "http://localhost:18080/"
  "Default URL navigated to by BROWSER-OPEN when the tool call omits :url.")

(defparameter *browser-default-screenshot-path* (namestring (merge-pathnames "docs-tmp/browser-screenshot.png" (uiop:getcwd)))
  "Default file path for BROWSER-SCREENSHOT when the tool call omits :path.
Browser screenshots and videos are saved to ./docs-tmp/ by default; this
directory is gitignored and is the expected location for browser artifacts.")

(defparameter *browser-default-video-path* (namestring (merge-pathnames "docs-tmp/browser-video.webm" (uiop:getcwd)))
  "Default file path for BROWSER-VIDEO when the tool call omits :path.
Browser screenshots and videos are saved to ./docs-tmp/ by default; this
directory is gitignored and is the expected location for browser artifacts.")

(defparameter *browser-default-timeout* 30
  "Default timeout in seconds for browser navigation and assertions. Passed
to the Playwright bridge as the per-call timeout (e.g. navigate, wait_for) when
the tool call omits an explicit :timeout. Reload-friendly: redefining this
parameter at the REPL changes the default for subsequent tool calls.")

;;; ---------------------------------------------------------------------------
;;; Helpers.
;;; ---------------------------------------------------------------------------

(defun browser-bridge-dead-message ()
  "Return the standard error string telling the agent to open the browser first."
  "Browser is not open. Call browser_open first to start the browser.")

(defun browser-ensure-bridge ()
  "Return the live *PLAYWRIGHT-BRIDGE*, or NIL if it is missing or dead.

Does NOT start a bridge (only BROWSER-OPEN does). When the stored bridge is
present but dead, it is cleared so a later BROWSER-OPEN can start a fresh one."
  (cond
    ((null *playwright-bridge*) nil)
    ((pw-alive-p *playwright-bridge*) *playwright-bridge*)
    (t
     ;; A dead bridge is useless; drop it so BROWSER-OPEN starts a fresh one.
     (ignore-errors (pw-close *playwright-bridge*))
     (setf *playwright-bridge* nil)
     nil)))

(defun browser-json-to-string (value)
  "Render an arbitrary decoded JSON VALUE as a compact string for tool output.

The Playwright bridge returns Yason-decoded values: strings, numbers, T/NIL
(from JSON booleans), lists (from JSON arrays), and hash tables (from JSON
objects). Strings are returned verbatim; everything else is re-encoded as
compact JSON so the agent sees a stable, copy-pasteable representation."
  (cond
    ((null value) "null")
    ((eq value t) "true")
    ((stringp value) value)
    ((hash-table-p value)
     (with-output-to-string (stream) (yason:encode value stream)))
    ((listp value)
     (with-output-to-string (stream)
       (yason:encode (coerce value 'vector) stream)))
    (t (princ-to-string value))))

(defun browser-make-params (&rest keys-and-values)
  "Build a Yason hash-table of params from alternating key/value pairs.

NIL values are omitted so the bridge receives a compact object (its handlers
destructure with defaults). Keys are coerced to strings."
  (let ((params (make-hash-table :test #'equal)))
    (loop for (key value) on keys-and-values by #'cddr
          when value
          do (setf (gethash (string key) params) value))
    params))

(defun browser-getarg (arguments key &optional default)
  "Read KEY from the ARGUMENTS hash-table, falling back to DEFAULT."
  (or (gethash key arguments) default))

;;; ---------------------------------------------------------------------------
;;; Tool handlers.
;;; ---------------------------------------------------------------------------

(defun browser-open-tool (arguments)
  "browser_open tool handler.

Starts the persistent Playwright bridge (if not already alive), navigates to
:url (default *BROWSER-DEFAULT-URL*), and optionally waits for a CSS selector
(:wait_for). :timeout (default *BROWSER-DEFAULT-TIMEOUT*, in seconds) is
forwarded to the bridge as the navigation/wait timeout in milliseconds.
Returns a status string with the page title and final URL."
  (let ((url (browser-getarg arguments "url" *browser-default-url*))
        (wait-for (browser-getarg arguments "wait_for")))
    (log-interaction :info "tool-call" :tool "browser_open"
                     :url url :wait_for wait-for))
  (handler-case
      (progn
        ;; Lazily start the bridge if it is missing or died.
        (unless (browser-ensure-bridge)
          (setf *playwright-bridge* (make-playwright-bridge)))
        (let* ((timeout-seconds
                 (browser-getarg arguments "timeout" *browser-default-timeout*))
               (timeout-ms (round (* timeout-seconds 1000))))
          (let ((nav-result
                  (pw-call *playwright-bridge* "navigate"
                           (browser-make-params "url"
                                                (browser-getarg arguments "url"
                                                                *browser-default-url*)
                                                "timeout" timeout-ms))))
            (let ((wait-for (browser-getarg arguments "wait_for")))
              (when wait-for
                (pw-call *playwright-bridge* "wait_for"
                         (browser-make-params "selector" wait-for
                                              "timeout" timeout-ms))))
            (let ((title (gethash "title" nav-result))
                  (final-url (gethash "url" nav-result)))
              (log-interaction :info "tool-completed" :tool "browser_open"
                               :title title :url final-url)
              (format nil "Browser opened: title=~A url=~A"
                      (or title "") (or final-url ""))))))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_open"
                       :message (princ-to-string condition))
      (format nil "browser_open failed: ~A" condition))))

(defun browser-click-tool (arguments)
  "browser_click tool handler. Clicks the element at :selector and returns its text."
  (let ((selector (browser-getarg arguments "selector")))
    (log-interaction :info "tool-call" :tool "browser_click" :selector selector))
  (handler-case
      (let ((bridge (browser-ensure-bridge)))
        (if (null bridge)
            (browser-bridge-dead-message)
            (let ((result
                    (pw-call bridge "click"
                             (browser-make-params
                              "selector" (browser-getarg arguments "selector")))))
              (let ((text (gethash "text" result)))
                (log-interaction :info "tool-completed" :tool "browser_click"
                                 :text text)
                (format nil "Clicked: text=~A" (or text ""))))))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_click"
                       :message (princ-to-string condition))
      (format nil "browser_click failed: ~A" condition))))

(defun browser-type-tool (arguments)
  "browser_type tool handler. Fills :selector with :value."
  (let ((selector (browser-getarg arguments "selector"))
        (value (browser-getarg arguments "value")))
    (log-interaction :info "tool-call" :tool "browser_type"
                     :selector selector :value value))
  (handler-case
      (let ((bridge (browser-ensure-bridge)))
        (if (null bridge)
            (browser-bridge-dead-message)
            (progn
              (pw-call bridge "fill"
                       (browser-make-params
                        "selector" (browser-getarg arguments "selector")
                        "value" (browser-getarg arguments "value")))
              (log-interaction :info "tool-completed" :tool "browser_type")
              (format nil "Typed into selector ~A"
                       (browser-getarg arguments "selector")))))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_type"
                       :message (princ-to-string condition))
      (format nil "browser_type failed: ~A" condition))))

(defun browser-get-text-tool (arguments)
  "browser_get_text tool handler. Returns the text content of :selector."
  (let ((selector (browser-getarg arguments "selector")))
    (log-interaction :info "tool-call" :tool "browser_get_text"
                     :selector selector))
  (handler-case
      (let ((bridge (browser-ensure-bridge)))
        (if (null bridge)
            (browser-bridge-dead-message)
            (let ((result
                    (pw-call bridge "get_text"
                             (browser-make-params
                              "selector" (browser-getarg arguments "selector")))))
              (let ((text (gethash "text" result)))
                (log-interaction :info "tool-completed" :tool "browser_get_text"
                                 :text-length (and (stringp text) (length text)))
                (or text "")))))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_get_text"
                       :message (princ-to-string condition))
      (format nil "browser_get_text failed: ~A" condition))))

(defun browser-eval-tool (arguments)
  "browser_eval tool handler. Evaluates :expression and returns the value."
  (let ((expression (browser-getarg arguments "expression")))
    (log-interaction :info "tool-call" :tool "browser_eval"
                     :expression expression))
  (handler-case
      (let ((bridge (browser-ensure-bridge)))
        (if (null bridge)
            (browser-bridge-dead-message)
            (let* ((result
                     (pw-call bridge "eval"
                              (browser-make-params
                               "expression" (browser-getarg arguments "expression"))))
                   (value (gethash "value" result))
                   (text (browser-json-to-string value)))
              (log-interaction :info "tool-completed" :tool "browser_eval"
                               :value text)
              text)))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_eval"
                       :message (princ-to-string condition))
      (format nil "browser_eval failed: ~A" condition))))

(defun browser-screenshot-tool (arguments)
  "browser_screenshot tool handler. Saves a full-page screenshot to :path."
  (let ((path (browser-getarg arguments "path" *browser-default-screenshot-path*)))
    (log-interaction :info "tool-call" :tool "browser_screenshot" :path path))
  (handler-case
      (let ((bridge (browser-ensure-bridge)))
        (if (null bridge)
            (browser-bridge-dead-message)
            (let* ((path (browser-getarg arguments "path"
                                         *browser-default-screenshot-path*))
                   (result
                     (pw-call bridge "screenshot"
                              (browser-make-params "path" path)))
                   (saved-path (gethash "path" result))
                   (bytes (gethash "bytes" result)))
              (log-interaction :info "tool-completed" :tool "browser_screenshot"
                               :path saved-path :bytes bytes)
              (format nil "Screenshot saved: path=~A bytes=~A"
                      (or saved-path path) (or bytes 0)))))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_screenshot"
                       :message (princ-to-string condition))
      (format nil "browser_screenshot failed: ~A" condition))))

(defun browser-video-tool (arguments)
  "browser_video tool handler. Saves the recorded browser video to :path.

The bridge records video continuously from browser_open. This method
finalizes the current video file (by closing and re-opening the page),
copies it to the requested path, and opens a fresh page for continued
interaction. The caller should navigate again after saving since the
page is new. Returns the saved path and byte count."
  (let ((path (browser-getarg arguments "path" *browser-default-video-path*)))
    (log-interaction :info "tool-call" :tool "browser_video" :path path))
  (handler-case
      (let ((bridge (browser-ensure-bridge)))
        (if (null bridge)
            (browser-bridge-dead-message)
            (let* ((path (browser-getarg arguments "path"
                                         *browser-default-video-path*))
                   (result
                     (pw-call bridge "save_video"
                              (browser-make-params "path" path)))
                   (saved-path (gethash "path" result))
                   (bytes (gethash "bytes" result)))
              (log-interaction :info "tool-completed" :tool "browser_video"
                               :path saved-path :bytes bytes)
              (format nil "Video saved: path=~A bytes=~A~%Note: the page was re-opened after saving. Call browser_open to navigate again."
                      (or saved-path path) (or bytes 0)))))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_video"
                       :message (princ-to-string condition))
      (format nil "browser_video failed: ~A" condition))))

(defun browser-assert-tool (arguments)
  "browser_assert tool handler. Asserts :expression is truthy; returns PASS/FAIL."
  (let ((expression (browser-getarg arguments "expression")))
    (log-interaction :info "tool-call" :tool "browser_assert"
                     :expression expression))
  (handler-case
      (let ((bridge (browser-ensure-bridge)))
        (if (null bridge)
            (browser-bridge-dead-message)
            (let* ((result
                     (pw-call bridge "assert"
                              (browser-make-params
                               "expression" (browser-getarg arguments "expression"))))
                   (pass (gethash "pass" result))
                   (value (gethash "value" result))
                   (text (browser-json-to-string value)))
              (log-interaction :info "tool-completed" :tool "browser_assert"
                               :pass pass :value text)
              (format nil "~A: ~A"
                      (if pass "PASS" "FAIL") text))))
    (error (condition)
      (log-interaction :error "tool-failed" :tool "browser_assert"
                       :message (princ-to-string condition))
      (format nil "browser_assert failed: ~A" condition))))

(defun browser-close-tool (arguments)
  "browser_close tool handler. Tears down the persistent Playwright bridge."
  (declare (ignore arguments))
  (log-interaction :info "tool-call" :tool "browser_close")
  (handler-case
      (progn
        (when *playwright-bridge*
          (ignore-errors (pw-close *playwright-bridge*))
          (setf *playwright-bridge* nil))
        (log-interaction :info "tool-completed" :tool "browser_close")
        "Browser closed.")
    (error (condition)
      ;; Even on error, make sure we drop the bridge handle.
      (ignore-errors (setf *playwright-bridge* nil))
      (log-interaction :error "tool-failed" :tool "browser_close"
                       :message (princ-to-string condition))
      (format nil "browser_close failed: ~A" condition))))
