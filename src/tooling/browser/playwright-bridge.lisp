(in-package #:self-improving-agent-harness)

;;;; Generic Playwright stdio transport (issue #39).
;;;;
;;;; This is the Lisp-side transport that spawns the Node Playwright bridge
;;;; subprocess (src/tooling/browser/playwright-bridge.js, created in issue
;;;; #38) and exchanges line-delimited JSON-RPC over piped stdio. It mirrors
;;;; the existing src/codex-app-server.lisp supervisor pattern exactly:
;;;; uiop:launch-program with piped stdin/stdout, newline-delimited JSON
;;;; framing, a monotonically increasing request id, and an unwind-protect
;;;; cleanup macro.
;;;;
;;;; This layer is GENERIC: it has no app-specific knowledge (no CLOG, no
;;;; data-testid, no localhost:18080). Callers send JSON-RPC method names and
;;;; params and receive decoded result hash tables.

(defparameter *playwright-bridge-script*
  (merge-pathnames "src/tooling/browser/playwright-bridge.js"
                   (uiop:getcwd))
  "Path to the Node Playwright bridge script, resolved relative to the
workspace root (the current working directory at load time). Overridable via
MAKE-PLAYWRIGHT-BRIDGE's :SCRIPT-PATH argument.")

(defparameter *playwright-bridge-ready-timeout-seconds* 10
  "Wall-clock seconds to wait for the bridge's ready marker on startup before
signalling an error. Guards against a Node/Playwright environment that fails
to launch (e.g. missing browser binary) hanging the harness forever.")

(defparameter *playwright-bridge-response-timeout-seconds* 30
  "Wall-clock seconds to wait for a single matching JSON-RPC response before
signalling an error. Guards against a hung page or a slow Playwright call.")

(define-condition playwright-bridge-error (error)
  ((reason :initarg :reason :reader playwright-bridge-error-reason))
  (:report (lambda (condition stream)
             (format stream "Playwright bridge error: ~A"
                     (playwright-bridge-error-reason condition))))
  (:documentation "Signalled for Playwright bridge protocol/lifecycle failures.
REASON is a human-readable string safe for logs."))

(defun pw-error (format-control &rest args)
  (error 'playwright-bridge-error
         :reason (apply #'format nil format-control args)))

;;; ---------------------------------------------------------------------------
;;; Bridge handle.
;;; ---------------------------------------------------------------------------

(defstruct (playwright-bridge
            (:constructor %make-playwright-bridge))
  "A live JSON-RPC transport to the Node Playwright bridge subprocess.

PROCESS-INFO is the uiop process-info returned by uiop:launch-program.
INPUT-STREAM is the subprocess stdin we WRITE requests to. OUTPUT-STREAM is the
subprocess stdout we READ responses from. NEXT-ID is the monotonically
increasing JSON-RPC request id counter (starts at 1). DEAD-P is set when EOF is
detected on stdout or the process exits, so callers can avoid using a dead
bridge."
  process-info
  input-stream
  output-stream
  (next-id 1 :type integer)
  (dead-p nil :type boolean))

(defun pw-next-id (bridge)
  "Return and consume the next monotonically increasing JSON-RPC id for BRIDGE."
  (prog1 (playwright-bridge-next-id bridge)
    (incf (playwright-bridge-next-id bridge))))

(defun pw-alive-p (bridge)
  "Return true if BRIDGE's subprocess is still running and not marked dead."
  (and (not (playwright-bridge-dead-p bridge))
       (let ((process (playwright-bridge-process-info bridge)))
         (and process (uiop:process-alive-p process)))))

;;; ---------------------------------------------------------------------------
;;; JSON-RPC framing (line-delimited, compact).
;;; ---------------------------------------------------------------------------

(defun pw-encode-request (id method params)
  "Serialize a JSON-RPC request to a single newline-terminated JSON line.

ID is the request id, METHOD the RPC method name, PARAMS a yason hash table
(or NIL for an empty object). Uses yason directly (mirroring
CODEX-ENCODE-JSONRPC-MESSAGE) so the output is compact single-line JSON with
control characters escaped, which keeps the line-delimited framing intact."
  (let ((object (make-hash-table :test #'equal)))
    (setf (gethash "id" object) id
          (gethash "method" object) method
          (gethash "params" object) (or params (make-hash-table :test #'equal)))
    (let ((body (with-output-to-string (stream) (yason:encode object stream))))
      (concatenate 'string body (string #\Newline)))))

(defun pw-parse-line (line)
  "Parse a single JSON line with yason, returning the decoded hash table.
Signals a PLAYWRIGHT-BRIDGE-ERROR on a non-empty line that is not valid JSON."
  (handler-case
      (yason:parse line)
    (error (condition)
      (pw-error "bridge line is not valid JSON: ~A" condition))))

(defun pw-read-line (bridge)
  "Read one line from BRIDGE's stdout, returning the trimmed string, or :EOF.

Returns :EOF when the stream hits end-of-file (the subprocess died). On EOF the
bridge's DEAD-P flag is set so subsequent calls fail fast. Blank lines are
skipped."
  (loop
    (let ((line (read-line (playwright-bridge-output-stream bridge) nil :eof)))
      (when (eq line :eof)
        (setf (playwright-bridge-dead-p bridge) t)
        (return :eof))
      (setf line (string-right-trim '(#\Return) line))
      (unless (zerop (length (string-trim " " line)))
        (return line)))))

;;; ---------------------------------------------------------------------------
;;; Request/response.
;;; ---------------------------------------------------------------------------

(defun pw-send (bridge method params)
  "Build and send a JSON-RPC request to BRIDGE, returning the id used.

METHOD is the RPC method name; PARAMS is a yason hash table (or NIL). Writes a
single compact JSON line to the subprocess stdin and flushes. Does not wait for
a response (see PW-CALL)."
  (let ((id (pw-next-id bridge))
        (input (playwright-bridge-input-stream bridge)))
    (write-string (pw-encode-request id method params) input)
    (finish-output input)
    id))

(defun pw-call (bridge method &optional params)
  "Send a JSON-RPC request to BRIDGE and return the matching result.

Calls PW-SEND to issue the request, then reads lines from stdout until a
response whose \"id\" matches the sent id arrives. If the response has an
\"error\" key, signals a PLAYWRIGHT-BRIDGE-ERROR with the error message. If it
has a \"result\" key, returns that result (a hash table). Times out after
*PLAYWRIGHT-BRIDGE-RESPONSE-TIMEOUT-SECONDS*. If stdout hits EOF (the process
died), sets DEAD-P and signals an error."
  (let ((id (pw-send bridge method params)))
    (handler-case
        (sb-ext:with-timeout *playwright-bridge-response-timeout-seconds*
          (loop
            (let ((line (pw-read-line bridge)))
              (when (eq line :eof)
                (pw-error "bridge closed stdout while awaiting response to ~A."
                          method))
              (let ((message (pw-parse-line line)))
                (when (and (hash-table-p message)
                           (eql (gethash "id" message) id))
                  (let ((err (gethash "error" message)))
                    (when err
                      (let ((msg (and (hash-table-p err)
                                      (gethash "message" err))))
                        (pw-error "~A failed: ~A" method
                                  (or msg err)))))
                  (return (gethash "result" message)))))))
      (sb-ext:timeout ()
        (pw-error "timed out after ~A seconds waiting for a response to ~A."
                  *playwright-bridge-response-timeout-seconds* method)))))

;;; ---------------------------------------------------------------------------
;;; Lifecycle: spawn, ready handshake, close.
;;; ---------------------------------------------------------------------------

(defun pw-close (bridge)
  "Tear down BRIDGE: send the \"close\" method, close streams, terminate/reap.

Sends the \"close\" method via PW-SEND but does not wait for a response (the
subprocess exits as part of handling close). Then closes the input and output
streams and terminates/reaps the subprocess. Safe to call on an already-dead
bridge; all steps are wrapped in ignore-errors so cleanup never raises."
  (ignore-errors (pw-send bridge "close" nil))
  (ignore-errors (close (playwright-bridge-input-stream bridge)))
  (ignore-errors (close (playwright-bridge-output-stream bridge)))
  (let ((process (playwright-bridge-process-info bridge)))
    (when process
      (ignore-errors (uiop:terminate-process process))
      (ignore-errors (uiop:wait-process process))))
  (setf (playwright-bridge-dead-p bridge) t)
  (values))

(defun make-playwright-bridge (&key (script-path *playwright-bridge-script*))
  "Spawn the Node Playwright bridge and wait for its ready marker.

SCRIPT-PATH defaults to *PLAYWRIGHT-BRIDGE-SCRIPT* (the bridge script resolved
relative to the workspace root). Launches `node <script-path>` with piped
stdin/stdout and discarded stderr, then reads the first stdout line and parses
it as JSON, checking for a truthy \"ready\" key. Times out after
*PLAYWRIGHT-BRIDGE-READY-TIMEOUT-SECONDS* if no ready marker arrives. Returns a
PLAYWRIGHT-BRIDGE object."
  (let* ((script (uiop:ensure-pathname script-path
                                       :want-file t
                                       :truename *default-pathname-defaults*))
         (process (uiop:launch-program (list "node" (namestring script))
                                       :input :stream
                                       :output :stream
                                       :error-output nil))
         (bridge (%make-playwright-bridge
                  :process-info process
                  :input-stream (uiop:process-info-input process)
                  :output-stream (uiop:process-info-output process))))
    ;; Wait for the ready marker, bounded by a timeout so a launch failure
    ;; surfaces a diagnosable error instead of hanging.
    (handler-case
        (sb-ext:with-timeout *playwright-bridge-ready-timeout-seconds*
          (let ((line (pw-read-line bridge)))
            (cond
              ((eq line :eof)
               (pw-error "bridge closed stdout before sending a ready marker."))
              (t
               (let ((message (pw-parse-line line)))
                 (unless (and (hash-table-p message)
                              (gethash "ready" message))
                   (pw-error "bridge ready marker missing a truthy \"ready\" key: ~A"
                             line)))))))
      (sb-ext:timeout ()
        ;; The process likely failed to start; clean it up before signalling.
        (ignore-errors (pw-close bridge))
        (pw-error "timed out after ~A seconds waiting for the bridge ready marker; the Node/Playwright environment may not be available."
                  *playwright-bridge-ready-timeout-seconds*)))
    bridge))

(defmacro with-playwright-bridge ((bridge &key script-path) &body body)
  "Spawn a Playwright bridge, bind BRIDGE, run BODY, and guarantee cleanup.

SCRIPT-PATH is forwarded to MAKE-PLAYWRIGHT-BRIDGE (NIL means use the default
script path). PW-CLOSE is always run in the cleanup phase, even on a non-local
exit, so the Node subprocess is reaped."
  (let ((script-arg (or script-path '*playwright-bridge-script*)))
    `(let ((,bridge (make-playwright-bridge :script-path ,script-arg)))
       (unwind-protect (progn ,@body)
         (pw-close ,bridge)))))
