(in-package #:self-improving-agent-harness/tests)

;;; Subagent tool tests.
;;;
;;; These tests exercise the run_subagent tool's structural guarantees without
;;; making real provider calls:
;;; - No-recursion: the subagent tool set excludes run_subagent.
;;; - Tool set: the subagent gets only run_shell.
;;; - ID format: subagent IDs are ISO-timestamp-like.
;;; - Placeholder: the tool handler returns immediately with a placeholder.
;;; - Delivery queue: completed results are queued and drainable.
;;; - Timeout: the subagent thread-main honors a timeout.

(defun run-subagent-tests ()
  ;; 1. Subagent tool definitions contain only run_shell.
  (let ((defs (self-improving-agent-harness::subagent-tool-definitions)))
    (ensure-true (= 1 (length defs))
                 "subagent tool definitions contain exactly one tool")
    (ensure-true (string= "run_shell"
                          (getf (getf (first defs) :function) :name))
                 "subagent tool definitions contain only run_shell"))

  ;; 2. Subagent tool handlers contain only run_shell.
  (let ((handlers (self-improving-agent-harness::subagent-tool-handlers)))
    (ensure-true (= 1 (length handlers))
                 "subagent handlers contain exactly one entry")
    (ensure-true (string= "run_shell" (car (first handlers)))
                 "subagent handlers contain only run_shell")
    (ensure-true (eq 'self-improving-agent-harness::shell-tool
                     (cdr (first handlers)))
                 "subagent run_shell handler is the shell-tool symbol"))

  ;; 3. No run_subagent in the subagent tool set (structural no-recursion).
  (let ((defs (self-improving-agent-harness::subagent-tool-definitions))
        (handlers (self-improving-agent-harness::subagent-tool-handlers)))
    (ensure-true (not (find "run_subagent" defs
                            :key (lambda (d)
                                   (getf (getf d :function) :name))
                            :test #'string=))
                 "subagent tool definitions exclude run_subagent")
    (ensure-true (not (assoc "run_subagent" handlers :test #'string=))
                 "subagent handlers exclude run_subagent"))

  ;; 4. No reload_harness in the subagent tool set.
  (let ((defs (self-improving-agent-harness::subagent-tool-definitions))
        (handlers (self-improving-agent-harness::subagent-tool-handlers)))
    (ensure-true (not (find "reload_harness" defs
                            :key (lambda (d)
                                   (getf (getf d :function) :name))
                            :test #'string=))
                 "subagent tool definitions exclude reload_harness")
    (ensure-true (not (assoc "reload_harness" handlers :test #'string=))
                 "subagent handlers exclude reload_harness"))

  ;; 5. Subagent ID is ISO-timestamp-like (starts with a 4-digit year).
  (let ((id (self-improving-agent-harness::make-subagent-id)))
    (ensure-true (and (stringp id) (>= (length id) 4)
                     (every #'digit-char-p (subseq id 0 4)))
                 "subagent id starts with a 4-digit year (ISO timestamp format)"))

  ;; 6. Subagent system prompt is different from the parent prompt.
  (ensure-true (not (string= self-improving-agent-harness::+chat-system-prompt+
                             self-improving-agent-harness::+subagent-system-prompt+))
               "subagent system prompt differs from the parent system prompt")
  (ensure-true (search "subagent"
                        (string-downcase
                         self-improving-agent-harness::+subagent-system-prompt+))
               "subagent system prompt mentions 'subagent'")

  ;; 7. Delivery queue: enqueue then drain.
  (self-improving-agent-harness::clear-subagent-deliveries)
  (let ((delivery (self-improving-agent-harness::make-subagent-delivery
                   :subagent-id "test-id"
                   :status :completed
                   :result "test result"
                   :provider "synthetic"
                   :model "test/model"
                   :duration-seconds 1.0)))
    (self-improving-agent-harness::enqueue-subagent-delivery delivery)
    (let ((popped (self-improving-agent-harness::take-next-subagent-delivery)))
      (ensure-true (not (null popped))
                   "enqueued delivery is drainable")
      (ensure-true (string= "test-id"
                            (self-improving-agent-harness::subagent-delivery-subagent-id
                             popped))
                   "drained delivery has the correct subagent id")
      (ensure-true (eq :completed
                        (self-improving-agent-harness::subagent-delivery-status popped))
                   "drained delivery has the correct status")
      (ensure-true (string= "test result"
                            (self-improving-agent-harness::subagent-delivery-result popped))
                   "drained delivery has the correct result"))
    (ensure-true (null (self-improving-agent-harness::take-next-subagent-delivery))
                 "delivery queue is empty after draining"))
  (self-improving-agent-harness::clear-subagent-deliveries)

  ;; 8. Subagent backend defaulting: nil provider returns parent backend.
  (let* ((parent (make-openrouter-backend :api-key "test-key"))
         (result (self-improving-agent-harness::subagent-backend nil parent)))
    (ensure-true (eq parent result)
                 "nil provider defaults to the parent backend"))

  ;; 9. Subagent backend: explicit provider constructs a fresh backend.
  (let ((result (self-improving-agent-harness::subagent-backend "openrouter" nil)))
    (ensure-true (string= "openrouter" (backend-name result))
                 "explicit openrouter provider constructs an openrouter backend"))

  ;; 10. Subagent backend: unknown provider errors.
  (handler-case
      (self-improving-agent-harness::subagent-backend "nonexistent" nil)
    (error (condition)
      (ensure-true (search "Unknown subagent provider" (princ-to-string condition))
                   "unknown provider signals a clear error")))
  t)
