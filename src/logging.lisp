(in-package #:self-improving-agent-harness)

(defvar *interaction-log-path* nil
  "Path to the append-only per-session JSONL interaction log, or NIL when disabled.

DEFVAR (not DEFPARAMETER) so reload_harness does not wipe the live session log
path when src/logging.lisp is reloaded mid-chat.")

(defvar *interaction-log-directory* nil
  "Directory that holds per-session $ISO-TIMESTAMP.jsonl interaction logs, or NIL.

DEFVAR so reload_harness preserves the active logging directory.")

(defvar *interaction-log-file-id* nil
  "ISO-8601 UTC timestamp basename (without .jsonl) of the active per-session log file, or NIL.

DEFVAR so reload_harness preserves the active log file id.")

(defvar *interaction-session-id* nil
  "Dynamically bound non-secret correlation ID for interaction diagnostics.

This may be a caller-supplied supervisor id. The durable log file basename is
always an ISO-8601 UTC timestamp stored in *INTERACTION-LOG-FILE-ID*
($ISO-TIMESTAMP.jsonl).")

(defvar *interaction-turn-number* nil
  "Dynamically bound one-based submitted-turn number for interaction diagnostics.")

(defvar *interaction-parent-uuid* nil
  "UUID of the previous JSONL record in this session, for Claude-style parent links.")

(defvar *interaction-turn-initiator* "human"
  "Who initiated the current user turn: \"human\", \"harness\", or \"command\".

Bound around synthetic follow-ups and slash-command driven turns so JSONL
records can show initiator without guessing from message text.")

(defvar *interaction-log-record-content* t
  "When true, durable JSONL records may include message/tool/provider text.

Secrets are still scrubbed via SCRUB-INTERACTION-LOG-TEXT. Set to NIL for
metadata-only logs (legacy redaction mode).")

(defparameter *interaction-log-content-limit* 8000
  "Maximum characters of a single content string retained in JSONL.")

(defun interaction-log-timestamp ()
  "Return an ISO-8601 UTC timestamp with millisecond precision when available."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (let* ((internal (get-internal-real-time))
           (ms (mod (floor (* (/ (float internal 1.0d0)
                                 internal-time-units-per-second)
                              1000d0))
                    1000)))
      (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D.~3,'0DZ"
              year month day hour minute second ms))))

(defun uuid-v4-string ()
  "Return a lowercase RFC 4122 version-4 UUID string.

Uses /proc/sys/kernel/random/uuid when present, otherwise a random fallback
with the version/variant bits forced correctly."
  (let ((from-proc
          (ignore-errors
            (string-trim
             '(#\Space #\Tab #\Newline #\Return)
             (uiop:read-file-string #P"/proc/sys/kernel/random/uuid")))))
    (if (and from-proc
             (= (length from-proc) 36)
             (char= (char from-proc 14) #\4))
        (string-downcase from-proc)
        (let ((bytes (make-array 16 :element-type '(unsigned-byte 8))))
          (dotimes (i 16)
            (setf (aref bytes i) (random 256)))
          ;; version 4
          (setf (aref bytes 6) (logior (logand (aref bytes 6) #x0f) #x40))
          ;; RFC 4122 variant
          (setf (aref bytes 8) (logior (logand (aref bytes 8) #x3f) #x80))
          (format nil
                  "~(~2,'0x~2,'0x~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x~)"
                  (aref bytes 0) (aref bytes 1) (aref bytes 2) (aref bytes 3)
                  (aref bytes 4) (aref bytes 5)
                  (aref bytes 6) (aref bytes 7)
                  (aref bytes 8) (aref bytes 9)
                  (aref bytes 10) (aref bytes 11) (aref bytes 12)
                  (aref bytes 13) (aref bytes 14) (aref bytes 15))))))

(defun session-log-timestamp-string ()
  "Return a UTC ISO-8601 timestamp suitable as a session log basename.

Format is YYYY-MM-DDTHH:MM:SS.mmmZ (millisecond precision). Colons are kept so
the name remains a readable ISO timestamp; this runtime is Linux/Docker only."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (let* ((internal (get-internal-real-time))
           (ms (mod (floor (* (/ (float internal 1.0d0)
                                 internal-time-units-per-second)
                              1000d0))
                    1000)))
      (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D.~3,'0DZ"
              year month day hour minute second ms))))

(defun session-id-looks-like-iso-timestamp-p (value)
  "True when VALUE looks like an ISO-8601 UTC timestamp usable as a log basename.

Accepts YYYY-MM-DDTHH:MM:SSZ and YYYY-MM-DDTHH:MM:SS.sssZ (fraction optional)."
  (and (stringp value)
       (>= (length value) 20)
       (char= (char value 4) #\-)
       (char= (char value 7) #\-)
       (char= (char value 10) #\T)
       (char= (char value 13) #\:)
       (char= (char value 16) #\:)
       (char= (char value (1- (length value))) #\Z)
       (every (lambda (character)
                (or (digit-char-p character)
                    (find character "T:.-Z")))
              value)))

(defun ensure-session-file-id (&optional preferred)
  "Return an ISO-8601 UTC timestamp string for the session log file basename.

PREFERRED is kept when it already looks like an ISO timestamp; otherwise a
fresh timestamp is generated for the filename only."
  (let ((candidate (or preferred *interaction-session-id*)))
    (if (session-id-looks-like-iso-timestamp-p candidate)
        candidate
        (session-log-timestamp-string))))

(defun session-jsonl-filename (session-id)
  "Return the per-session JSONL filename for SESSION-ID."
  (format nil "~A.jsonl" session-id))

(defun configure-interaction-logging (directory &key session-id)
  "Write future interaction events to DIRECTORY/$ISO-TIMESTAMP.jsonl, or disable when NIL.

SESSION-ID, when supplied, becomes *INTERACTION-SESSION-ID* for stderr/event
correlation. The durable log basename is that value when it is already an
ISO-8601 UTC timestamp; otherwise a fresh timestamp is generated for the
filename only. Parent-record linkage is reset for the new session file."
  (setf *interaction-log-directory* nil
        *interaction-log-path* nil
        *interaction-log-file-id* nil
        *interaction-parent-uuid* nil)
  (when session-id
    (setf *interaction-session-id* session-id))
  (if directory
      (let* ((dir (uiop:ensure-directory-pathname directory))
             (file-id (ensure-session-file-id (or session-id *interaction-session-id*)))
             (path (merge-pathnames (session-jsonl-filename file-id) dir)))
        (ensure-directories-exist path)
        (with-open-file (stream path :direction :output :if-does-not-exist :create
                                :if-exists :append :external-format :utf-8)
          (finish-output stream))
        ;; If the caller did not supply a correlation id, use the file timestamp.
        (unless *interaction-session-id*
          (setf *interaction-session-id* file-id))
        (setf *interaction-log-file-id* file-id
              *interaction-log-directory* dir
              *interaction-log-path* path)
        path)
      nil))

(defun safe-interaction-label-p (value)
  "True when VALUE is a compact non-secret diagnostic label."
  (and (stringp value) (plusp (length value)) (<= (length value) 160)
       (every (lambda (character)
                (or (alphanumericp character)
                    (find character "._/-")))
              value)))

(defun scrub-interaction-log-text (text)
  "Return TEXT with common secret patterns redacted for durable logs."
  (let ((out (if (stringp text) text (princ-to-string text))))
    (labels ((replace-all (string pattern replacement)
               (loop for start = (search pattern string :test #'char-equal)
                     while start
                     do (setf string
                              (concatenate 'string
                                           (subseq string 0 start)
                                           replacement
                                           (subseq string (+ start (length pattern)))))
                     finally (return string))))
      ;; Cheap, conservative redactions for tokens often pasted into prompts.
      (setf out (replace-all out "OPENROUTER_API_KEY=" "OPENROUTER_API_KEY=***"))
      (let ((markers '("sk-" "sk-or-")))
        (dolist (marker markers)
          (loop with start = 0
                for pos = (search marker out :start2 start)
                while pos
                do (let* ((end pos)
                          (limit (length out)))
                     (loop for i from pos below limit
                           while (or (alphanumericp (char out i))
                                     (find (char out i) "-_"))
                           do (setf end (1+ i)))
                     (setf out (concatenate 'string
                                            (subseq out 0 pos)
                                            marker
                                            "***"
                                            (subseq out end))
                           start (+ pos (length marker) 3))))))
      out)))

(defun truncate-interaction-log-text (text &optional (limit *interaction-log-content-limit*))
  "Truncate TEXT to LIMIT characters for JSONL payloads."
  (let ((s (scrub-interaction-log-text text)))
    (if (and (integerp limit) (> (length s) limit))
        (concatenate 'string (subseq s 0 limit) "...[truncated]")
        s)))

(defun interaction-log-content-field-p (key)
  "True when KEY is a textual traffic field that may hold user/model content."
  (member key '(:content :message :command :output :arguments :text
                :request-json :response-text :tool-result :followup-content
                :body-snippet :error-message :file)
          :test #'eq))

(defun safe-interaction-log-fields (fields)
  "Filter/normalize FIELDS for a durable diagnostic log.

Always allow-lists compact metadata. When *INTERACTION-LOG-RECORD-CONTENT* is
true, also retains scrubbed/truncated traffic text (prompts, assistant output,
tool commands/results, provider summaries) so JSONL can reconstruct model <->
harness back-and-forth. Secret-looking substrings are scrubbed."
  (loop for (key value) on fields by #'cddr
        append
        (cond
          ((and (member key '(:model :mode :tool :reason :command-name :source
                              :initiator :status :finish-reason :role
                              :provider-request-id)
                        :test #'eq)
                (or (safe-interaction-label-p value)
                    (and (stringp value) (plusp (length value)) (<= (length value) 200))))
           (list key value))
          ((and (member key '(:max-rounds :output-length :exit-status :turn
                              :queue-length :round :message-count :tool-call-count
                              :prompt-tokens :completion-tokens :total-tokens
                              :status-code :file-count
                              :loaded-file-count :total-file-count)
                        :test #'eq)
                (integerp value))
           (list key value))
          ((and (eq key :failed-turn-p) (typep value 'boolean))
           (list key value))
          ((and (member key '(:duration-seconds :timeout-seconds) :test #'eq)
                (numberp value))
           (list key value))
          ((and (eq key :tool-names) (listp value)
                (every #'stringp value))
           (list key value))
          ((and *interaction-log-record-content*
                (interaction-log-content-field-p key)
                (or (stringp value) (pathnamep value) (numberp value) (symbolp value)))
           (list key (truncate-interaction-log-text value)))
          (t nil))))

(defun interaction-event-type (event)
  "Map an internal lifecycle EVENT name to a Claude-like top-level type string."
  (cond
    ((member event '("turn-received" "turn-submitted" "turn-empty"
                     "synthetic-followup-started")
             :test #'string=)
     "user")
    ((member event '("turn-completed") :test #'string=)
     "assistant")
    ((member event '("tool-call" "tool-completed" "tool-failed"
                     "provider-request" "provider-response"
                     "provider-request-failed" "provider-http-error"
                     "reload-started" "reload-progress" "reload-completed"
                     "reload-failed")
             :test #'string=)
     "tool")
    (t
     ;; session-*, command-completed, turn-failed, synthetic schedule, etc.
     "system")))

(defun claude-json-name (keyword)
  "Return Claude Code-style camelCase JSON field name for KEYWORD.

Unlike OPENROUTER-JSON-NAME (snake_case for the provider API), durable session
transcript envelopes use camelCase keys such as parentUuid and sessionId."
  (let* ((parts (uiop:split-string (string-downcase (symbol-name keyword))
                                   :separator '(#\-)))
         (first (first parts))
         (rest (rest parts)))
    (apply #'concatenate 'string
           first
           (mapcar #'string-capitalize rest))))

(defun claude-json-value (value)
  "Convert a keyword plist / list tree into a YASON-ready structure with camelCase keys."
  (cond
    ((and (listp value) (keywordp (first value)))
     (let ((object (make-hash-table :test #'equal)))
       (loop for (key item) on value by #'cddr
             do (setf (gethash (claude-json-name key) object)
                      (claude-json-value item)))
       object))
    ((listp value) (mapcar #'claude-json-value value))
    (t value)))

(defun build-interaction-record (level event fields)
  "Build one Claude-style session JSONL record (keyword plist) for EVENT.

Includes top-level INITIATOR (human|harness|command) so operators can filter
synthetic follow-ups from human turns without parsing message text."
  (let* ((record-uuid (uuid-v4-string))
         (parent *interaction-parent-uuid*)
         (type (interaction-event-type event))
         (initiator
           (or (getf fields :initiator)
               *interaction-turn-initiator*
               "human"))
         (safe (safe-interaction-log-fields
                (if (getf fields :initiator)
                    fields
                    (append fields (list :initiator initiator)))))
         (payload (append (list :event event
                                :level (string-downcase (symbol-name level))
                                :initiator initiator)
                          (when *interaction-turn-number*
                            (list :turn *interaction-turn-number*))
                          safe)))
    (setf *interaction-parent-uuid* record-uuid)
    (append (list :type type
                  :uuid record-uuid
                  :parent-uuid parent
                  :session-id (or *interaction-log-file-id* *interaction-session-id*)
                  :timestamp (interaction-log-timestamp)
                  :is-sidechain nil
                  :initiator initiator)
            (when *interaction-turn-number*
              (list :turn *interaction-turn-number*))
            (list :payload payload))))

(defun log-interaction (level event &rest fields)
  "Append one Claude-style JSONL interaction record when logging is configured.

Records are written to agent-logs/$ISO-TIMESTAMP.jsonl under the workspace (one
file per session). Shape mirrors Claude Code session transcripts
(type/uuid/parentUuid/sessionId/timestamp/initiator/payload).

INITIATOR is recorded at the top level and inside payload (human|harness|command).
When *INTERACTION-LOG-RECORD-CONTENT* is true, scrubbed traffic text is included
so model <-> harness back-and-forth is reconstructable from JSONL."
  (when *interaction-log-path*
    (unless *interaction-log-file-id*
      (setf *interaction-log-file-id* (ensure-session-file-id *interaction-session-id*)))
    (unless *interaction-session-id*
      (setf *interaction-session-id* *interaction-log-file-id*))
    (with-open-file (stream *interaction-log-path* :direction :output
                            :if-does-not-exist :create :if-exists :append
                            :external-format :utf-8)
      (yason:encode (claude-json-value
                     (build-interaction-record level event fields))
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
