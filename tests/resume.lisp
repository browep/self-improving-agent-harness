(in-package #:self-improving-agent-harness/tests)

;;; Track B resume tests: lossless per-session history snapshot round-trip,
;;; most-recent-snapshot selection, and metadata adoption.

(defun resume-test-history ()
  "A representative tool-augmented history including an assistant tool_calls
message and a role:\"tool\" result with a tool_call_id."
  (list (list :role "system" :content "sys prompt")
        (list :role "user" :content "list files")
        (list :role "assistant" :content nil
              :tool-calls
              (list (list :id "call_abc" :type "function"
                          :function (list :name "run_shell"
                                          :arguments "{\"command\": \"ls\"}"))))
        (list :role "tool" :tool-call-id "call_abc" :content "a.txt then b.txt")
        (list :role "assistant" :content "There are two files.")))

(defun run-snapshot-roundtrip-test (directory)
  "Write a history snapshot and assert it reloads byte-for-byte (structurally)."
  (let ((session-id "2000-01-01T00:00:00.000Z")
        (history (resume-test-history)))
    (configure-interaction-logging directory :session-id session-id)
    (let ((path (write-session-history-snapshot history
                                                :model "test/model"
                                                :max-rounds 33)))
      (ensure-true path "snapshot writer returns the snapshot path")
      (ensure-true (probe-file path) "snapshot file exists on disk")
      (let ((loaded (read-session-history-snapshot path)))
        (ensure-true (= (length history) (length loaded))
                     "reloaded history has the same message count")
        (ensure-true (equal history loaded)
                     "reloaded history is structurally EQUAL to the original")
        ;; Spot-check the tool-augmented messages survived losslessly.
        (let ((assistant (nth 2 loaded))
              (tool (nth 3 loaded)))
          (ensure-true (getf assistant :tool-calls)
                       "assistant tool_calls array is restored")
          (ensure-true (string= "call_abc"
                                (getf (first (getf assistant :tool-calls)) :id))
                       "restored tool call retains its id")
          (ensure-true (string= "call_abc" (getf tool :tool-call-id))
                       "role:tool message retains its tool_call_id")
          (ensure-true (string= "a.txt then b.txt" (getf tool :content))
                       "tool result content is restored verbatim (not truncated)")))
      ;; Metadata adoption.
      (multiple-value-bind (sid model max-rounds)
          (read-session-snapshot-metadata path)
        (ensure-true (string= session-id sid)
                     "snapshot metadata restores the session id")
        (ensure-true (string= "test/model" model)
                     "snapshot metadata restores the model")
        (ensure-true (eql 33 max-rounds)
                     "snapshot metadata restores max-rounds")))))

(defun run-most-recent-snapshot-test (directory)
  "The lexically-greatest ISO basename is chosen as the most recent session."
  (configure-interaction-logging directory :session-id "2001-01-01T00:00:00.000Z")
  (write-session-history-snapshot (resume-test-history) :model "m" :max-rounds 1)
  (configure-interaction-logging directory :session-id "2003-03-03T03:03:03.000Z")
  (write-session-history-snapshot (resume-test-history) :model "m" :max-rounds 1)
  (configure-interaction-logging directory :session-id "2002-02-02T02:02:02.000Z")
  (write-session-history-snapshot (resume-test-history) :model "m" :max-rounds 1)
  (let ((chosen (most-recent-session-snapshot directory)))
    (ensure-true chosen "most-recent-session-snapshot returns a path")
    (ensure-true (search "2003-03-03T03:03:03.000Z" (file-namestring chosen))
                 "most-recent-session-snapshot picks the newest ISO basename")))

(defun run-missing-snapshot-test (directory)
  "A directory with no snapshots yields NIL, and a bad path degrades gracefully."
  (ensure-true (null (most-recent-session-snapshot directory))
               "empty directory has no most-recent snapshot")
  (ensure-true (null (read-session-history-snapshot
                      (merge-pathnames "does-not-exist.history.json" directory)))
               "reading a missing snapshot returns NIL rather than signaling"))

(defun run-resume-tests ()
  (let ((base (uiop:ensure-directory-pathname
               (format nil "/tmp/resume-tests-~A/" (random 1000000)))))
    (unwind-protect
         (progn
           (run-snapshot-roundtrip-test
            (uiop:ensure-directory-pathname (merge-pathnames "roundtrip/" base)))
           (run-most-recent-snapshot-test
            (uiop:ensure-directory-pathname (merge-pathnames "recent/" base)))
           (run-missing-snapshot-test
            (uiop:ensure-directory-pathname (merge-pathnames "empty/" base)))
           ;; Reset logging state so later tests are unaffected.
           (configure-interaction-logging nil)
           (format t "Resume snapshot tests passed.~%")
           t)
      (ignore-errors (uiop:delete-directory-tree base :validate t)))))
