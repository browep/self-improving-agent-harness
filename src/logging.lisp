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

(defvar *interaction-text-log-path* nil
  "Path to the human-readable per-session HTTP `.log` file, or NIL when disabled.

Shares the JSONL session basename with a `.log` extension
(agent-logs/$ISO-TIMESTAMP.log). DEFVAR (not DEFPARAMETER) so reload_harness
does not wipe the live session text-log path when src/logging.lisp is reloaded
mid-chat.")

(defvar *session-history-path* nil
  "Path to the per-session lossless history snapshot (.history.json), or NIL.

Shares the session basename with the JSONL/text logs. Holds the exact
CHAT-SESSION-HISTORY message array (roles, content, tool_calls, tool_call_id)
so BIN/CHAT -c can resume with full tool context. DEFVAR so reload_harness does
not wipe the live path mid-chat.")

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
filename only. Parent-record linkage is reset for the new session file.

If DIRECTORY cannot be created or written (e.g. a read-only /workspace mount
under bin/test), durable logging is disabled with a stderr warning rather than
signaling: an unwritable log path must not abort an interactive chat. Returns
the log path on success, or NIL when logging is disabled or unavailable."
  (setf *interaction-log-directory* nil
        *interaction-log-path* nil
        *interaction-text-log-path* nil
        *session-history-path* nil
        *interaction-log-file-id* nil
        *interaction-parent-uuid* nil)
  (when session-id
    (setf *interaction-session-id* session-id))
  (if directory
      (handler-case
          (let* ((dir (uiop:ensure-directory-pathname directory))
                 (file-id (ensure-session-file-id (or session-id *interaction-session-id*)))
                 (path (merge-pathnames (session-jsonl-filename file-id) dir))
                 (text-path (merge-pathnames (format nil "~A.log" file-id) dir))
                 (history-path (merge-pathnames (format nil "~A.history.json" file-id) dir)))
            (ensure-directories-exist path)
            (with-open-file (stream path :direction :output :if-does-not-exist :create
                                    :if-exists :append :external-format :utf-8)
              (finish-output stream))
            (with-open-file (stream text-path :direction :output :if-does-not-exist :create
                                    :if-exists :append :external-format :utf-8)
              (finish-output stream))
            ;; If the caller did not supply a correlation id, use the file timestamp.
            (unless *interaction-session-id*
              (setf *interaction-session-id* file-id))
            (setf *interaction-log-file-id* file-id
                  *interaction-log-directory* dir
                  *interaction-log-path* path
                  *interaction-text-log-path* text-path
                  *session-history-path* history-path)
            path)
        (error (condition)
          (setf *interaction-log-directory* nil
                *interaction-log-path* nil
                *interaction-text-log-path* nil
                *session-history-path* nil
                *interaction-log-file-id* nil)
          (ignore-errors
            (format *error-output*
                    "~&WARNING durable interaction logging disabled: cannot write ~A (~A)~%"
                    directory condition)
            (finish-output *error-output*))
          nil))
      nil))

(defun safe-interaction-label-p (value)
  "True when VALUE is a compact non-secret diagnostic label."
  (and (stringp value) (plusp (length value)) (<= (length value) 160)
       (every (lambda (character)
                (or (alphanumericp character)
                    (find character "._/-")))
              value)))

(defun scrub-interaction-log-text (text)
  "Return TEXT with common secret patterns redacted for durable logs.

INVARIANT: every replacement helper here MUST advance past the text it inserts.
A naive search-from-0 replace whose REPLACEMENT contains its own PATTERN loops
forever, growing the string until the heap exhausts (this scrubbing runs on tool
output, so `cat`-ing a source file that mentions OPENROUTER_API_KEY= once hung
the whole chat). RUN-SCRUB-TERMINATION-REGRESSION in tests/logging.lisp guards it."
  (let ((out (if (stringp text) text (princ-to-string text))))
    (labels ((replace-all (string pattern replacement)
               ;; Advance past each replacement instead of re-searching from 0.
               ;; The old version searched from the start every iteration, so a
               ;; REPLACEMENT that itself contains PATTERN (e.g. replacing
               ;; "OPENROUTER_API_KEY=" with "OPENROUTER_API_KEY=***") matched
               ;; forever, growing STRING without bound until the heap exhausted.
               (let ((out (make-string-output-stream))
                     (start 0)
                     (pattern-length (length pattern)))
                 (loop for pos = (search pattern string :start2 start :test #'char-equal)
                       while pos
                       do (write-string string out :start start :end pos)
                          (write-string replacement out)
                          (setf start (+ pos pattern-length))
                       finally (write-string string out :start start))
                 (get-output-stream-string out))))
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
                :body-snippet :error-message :file :request-snippet
                :prompt :result)
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
                              :provider-request-id :tool-call-id
                              :url :url-path :attempt-id :phase :error-class
                              :subagent-id :provider)
                        :test #'eq)
                (or (safe-interaction-label-p value)
                    (and (stringp value) (plusp (length value)) (<= (length value) 200))))
           (list key value))
          ((and (member key '(:max-rounds :output-length :exit-status :turn
                              :queue-length :round :message-count :tool-call-count
                              :prompt-tokens :completion-tokens :total-tokens
                              :status-code :file-count
                              :loaded-file-count :total-file-count
                              :request-bytes :body-bytes
                              :request-chars :body-chars
                              :connection-timeout-seconds
                              :length-retry :length-retry-limit :length-retries)
                        :test #'eq)
                (integerp value))
           (list key value))
          ((and (member key '(:failed-turn-p :slow-p) :test #'eq)
                (typep value 'boolean))
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
                     "provider-empty-length-retry" "provider-empty-length-final"
                     "http-request-started" "http-request-completed"
                     "reload-started" "reload-progress" "reload-completed"
                     "reload-failed"
                     "subagent-started" "subagent-completed")
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

(defun log-http-text (level event format-control &rest args)
  "Append one human-readable line to the per-session `.log` file when configured.

LEVEL is a keyword (:info/:warn/:error); EVENT is the lifecycle event name.
FORMAT-CONTROL/ARGS produce the message, which is scrubbed of secrets before
writing. Line shape:

  <ISO-timestamp> <LEVEL> [session=<id> round=<n> attempt=<id>] <event>: <message>

Writing is best-effort: any failure is swallowed so a text-log problem never
breaks or aborts a chat turn (FR-1.5)."
  (when *interaction-text-log-path*
    (ignore-errors
      (let* ((message (scrub-interaction-log-text
                       (apply #'format nil format-control args)))
             (round (if *interaction-turn-number* *interaction-turn-number* nil)))
        (with-open-file (stream *interaction-text-log-path*
                                :direction :output
                                :if-does-not-exist :create
                                :if-exists :append
                                :external-format :utf-8)
          (format stream "~A ~A [session=~A round=~A] ~A: ~A~%"
                  (interaction-log-timestamp)
                  (string-upcase (symbol-name level))
                  (or *interaction-log-file-id* *interaction-session-id* "-")
                  (or round "-")
                  event
                  message)
          (finish-output stream))))))

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

;;; ---------------------------------------------------------------------------
;;; Lossless per-session history snapshot (bin/chat -c resume, Track B).
;;;
;;; The JSONL diagnostic log truncates content and omits the assistant
;;; tool_calls array / tool_call_id as first-class fields, so it cannot faithfully
;;; replay a tool-augmented conversation. Instead we snapshot the exact
;;; CHAT-SESSION-HISTORY message array (the same plists the OpenRouter API
;;; consumes) to agent-logs/$ISO-TIMESTAMP.history.json after every successful
;;; turn. That file is the source of truth for resume.

(defparameter +session-history-schema-version+ 1
  "Schema version of the .history.json snapshot format.")

(defun session-history-snapshot-object (history &key model max-rounds)
  "Return a keyword plist describing HISTORY for JSON encoding.

MESSAGES preserves the raw CHAT-SESSION-HISTORY plists (role/content plus any
tool-calls / tool-call-id), which OPENROUTER-JSON-VALUE renders to snake_case
(tool_calls, tool_call_id) exactly as the provider API expects."
  (append (list :schema-version +session-history-schema-version+)
          (when *interaction-log-file-id*
            (list :session-id *interaction-log-file-id*))
          (when model (list :model model))
          (when (integerp max-rounds) (list :max-rounds max-rounds))
          (list :saved-at (interaction-log-timestamp)
                :messages history)))

(defun write-session-history-snapshot (history &key model max-rounds)
  "Atomically write HISTORY to *SESSION-HISTORY-PATH* as JSON, if configured.

Best-effort: any failure is swallowed so a snapshot problem never aborts a chat
turn. Writes to a sibling temp file then renames over the target, so a crash
mid-write cannot leave a half-written snapshot that would corrupt a later
resume.

Session basenames contain colons and dots (ISO-8601 timestamps), which SBCL's
NAME/TYPE pathname parsing splits unpredictably. We therefore build the temp and
final paths as explicit namestrings and rename by namestring, never relying on
PATHNAME-NAME/PATHNAME-TYPE round-tripping."
  (when (and *session-history-path* (listp history))
    (ignore-errors
      (let* ((final-ns (uiop:native-namestring *session-history-path*))
             (temp-ns (concatenate 'string final-ns ".tmp"))
             (object (session-history-snapshot-object
                      history :model model :max-rounds max-rounds)))
        (with-open-file (stream temp-ns :direction :output
                                :if-does-not-exist :create
                                :if-exists :supersede
                                :external-format :utf-8)
          (yason:encode (openrouter-json-value object) stream)
          (terpri stream)
          (finish-output stream))
        ;; POSIX rename(2) is atomic and overwrites the destination. We call
        ;; it directly (not CL:RENAME-FILE) because SBCL's RENAME-FILE re-parses
        ;; the target against the source pathname and mangles the multi-dot,
        ;; colon-bearing ISO-timestamp basenames used here.
        (sb-posix:rename temp-ns final-ns)
        *session-history-path*))))

(defun session-history-json-key->keyword (name)
  "Convert a snake_case JSON message key back to the keyword plist key.

Inverse of OPENROUTER-JSON-NAME for message fields (e.g. \"tool_calls\" ->
:TOOL-CALLS, \"tool_call_id\" -> :TOOL-CALL-ID, \"role\" -> :ROLE)."
  (intern (string-upcase (substitute #\- #\_ name)) :keyword))

(defun session-history-json->plist (value)
  "Recursively convert decoded YASON JSON VALUE into keyword-plist message form.

Hash-tables become keyword plists (snake_case keys un-mangled); lists recurse;
scalars pass through. Used to restore CHAT-SESSION-HISTORY from a snapshot."
  (cond
    ((hash-table-p value)
     (let ((plist '()))
       (maphash (lambda (k v)
                  (push (session-history-json-key->keyword k) plist)
                  (push (session-history-json->plist v) plist))
                value)
       (nreverse plist)))
    ((listp value) (mapcar #'session-history-json->plist value))
    (t value)))

(defun read-session-history-snapshot (path)
  "Read a .history.json snapshot at PATH and return its message plist list.

Returns the restored CHAT-SESSION-HISTORY message list (each a keyword plist),
or NIL when PATH is missing/unreadable/empty. Signals nothing on a malformed
file: resume must degrade gracefully."
  (ignore-errors
    (when (and path (probe-file path))
      (with-open-file (stream path :direction :input :external-format :utf-8)
        (let* ((yason:*parse-object-as* :hash-table)
               (object (yason:parse stream)))
          (when (hash-table-p object)
            (let ((messages (gethash "messages" object)))
              (when (listp messages)
                (mapcar #'session-history-json->plist messages)))))))))

(defun read-session-snapshot-metadata (path)
  "Read a .history.json snapshot and return (VALUES SESSION-ID MODEL MAX-ROUNDS).

Any component is NIL when absent/unreadable. Used by the resume path to adopt
the prior session's id (so resumed turns append to the same log files), model,
and tool-loop round limit. Never signals: resume must degrade gracefully."
  (block nil
    (handler-case
        (when (and path (probe-file path))
          (with-open-file (stream path :direction :input :external-format :utf-8)
            (let* ((yason:*parse-object-as* :hash-table)
                   (object (yason:parse stream)))
              (when (hash-table-p object)
                (let ((max-rounds (gethash "max_rounds" object)))
                  (return
                    (values (gethash "session_id" object)
                            (gethash "model" object)
                            (and (integerp max-rounds) max-rounds))))))))
      (error () nil))
    (values nil nil nil)))

(defun most-recent-session-snapshot (log-directory)
  "Return the pathname of the most recent .history.json in LOG-DIRECTORY, or NIL.

Session basenames are ISO-8601 UTC timestamps, which sort lexically in
chronological order, so the lexically-greatest name is the newest session.

Enumerates every file in the directory and filters by the \".history.json\"
suffix on its namestring rather than globbing, because the colons/dots in
session basenames make PATHNAME wildcard matching unreliable."
  (ignore-errors
    (let* ((dir (uiop:ensure-directory-pathname log-directory))
           (candidates
             (remove-if-not
              (lambda (p)
                (let ((name (file-namestring p)))
                  (and (>= (length name) 13)
                       (string= ".history.json" name
                                :start2 (- (length name) 13)))))
              (uiop:directory-files dir))))
      (when candidates
        (first (sort candidates #'string> :key #'file-namestring))))))
