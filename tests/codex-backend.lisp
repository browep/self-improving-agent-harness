(in-package #:self-improving-agent-harness/tests)

;;;; Deterministic, process-free, network-free tests for the codex-app-server
;;;; backend adapter (issue #18, Phase 4). The adapter's connection factory is
;;;; injected with a fake-server connection built from pre-seeded framed
;;;; responses (client request ids run 1,2,3 for initialize/account/turn).

(defun cb-fake-backend (server-frames &optional (turn-method "thread/runTurn"))
  "Return a codex-app-server backend whose connection factory yields a fresh
fake connection seeded with SERVER-FRAMES on every COMPLETE call."
  (self-improving-agent-harness:make-codex-app-server-backend
   :turn-method turn-method
   :connection-factory
   (lambda ()
     (multiple-value-bind (conn out) (cas-connection server-frames)
       (declare (ignore out))
       conn))))

(defun cb-authed-frames (&key (turn-result nil))
  "Frames for a successful authenticated session: initialize (id 1),
account/read chatgpt (id 2), and a turn result (id 3)."
  (list (cas-frame (cas-response 1 (cas-obj "ok" t)))
        (cas-frame (cas-response 2 (cas-obj "authMode" "chatgpt" "planType" "plus")))
        (cas-frame (cas-response 3 (or turn-result
                                       (cas-obj "text" "hello from codex"))))))

(defun run-codex-backend-success-tests ()
  (let* ((backend (cb-fake-backend (cb-authed-frames)))
         (request (self-improving-agent-harness:make-completion-request
                   :model "gpt-5-codex"
                   :messages '((:role "user" :content "hi"))))
         (response (self-improving-agent-harness:complete backend request)))
    (ensure-true (string= "codex-app-server"
                          (self-improving-agent-harness:backend-name backend))
                 "backend has the stable codex-app-server name")
    (ensure-true (equal "hello from codex"
                        (self-improving-agent-harness:completion-response-text response))
                 "turn text is surfaced in the completion response")
    (ensure-true (equal "gpt-5-codex"
                        (self-improving-agent-harness:completion-response-model response))
                 "response records a model label")
    ;; No authoritative usage -> usage plist has no numeric values -> unavailable.
    (let* ((summary (self-improving-agent-harness::provider-accounting-summary
                     backend (list response)))
           (aggregate (getf summary :aggregate)))
      (ensure-true (eq :unavailable (getf aggregate :total-tokens))
                   "token accounting is unavailable when Codex reports no usage")
      (ensure-true (eq :unavailable (getf aggregate :cost-usd))
                   "cost accounting is unavailable when Codex reports no cost"))))

(defun run-codex-backend-authoritative-usage-tests ()
  ;; When Codex DOES report numeric usage, it flows through as actual.
  (let* ((turn (cas-obj "text" "counted"
                        "usage" (cas-obj "inputTokens" 5 "outputTokens" 7 "totalTokens" 12)))
         (backend (cb-fake-backend (cb-authed-frames :turn-result turn)))
         (request (self-improving-agent-harness:make-completion-request
                   :messages '((:role "user" :content "hi"))))
         (response (self-improving-agent-harness:complete backend request))
         (summary (self-improving-agent-harness::provider-accounting-summary
                   backend (list response)))
         (aggregate (getf summary :aggregate)))
    (ensure-true (eql 12 (getf aggregate :total-tokens))
                 "authoritative total tokens flow through as actual")
    (ensure-true (equal "actual" (getf aggregate :total-tokens-state))
                 "authoritative usage is marked actual")))

(defun run-codex-backend-auth-rejection-tests ()
  ;; apiKey auth must be rejected with no OPENAI_API_KEY fallback.
  (let* ((frames (list (cas-frame (cas-response 1 (cas-obj "ok" t)))
                       (cas-frame (cas-response 2 (cas-obj "authMode" "apiKey")))))
         (backend (cb-fake-backend frames))
         (request (self-improving-agent-harness:make-completion-request
                   :messages '((:role "user" :content "hi")))))
    (handler-case
        (progn (self-improving-agent-harness:complete backend request)
               (error "Test failed: apiKey auth must be rejected by the backend"))
      (self-improving-agent-harness:codex-app-server-error (condition)
        (let ((reason (self-improving-agent-harness:codex-app-server-error-reason condition)))
          (ensure-true (search "OPENAI_API_KEY" reason)
                       "backend rejection forbids the OPENAI_API_KEY fallback")))))
  ;; Missing auth (no authMode) is also rejected.
  (let* ((frames (list (cas-frame (cas-response 1 (cas-obj "ok" t)))
                       (cas-frame (cas-response 2 (cas-obj)))))
         (backend (cb-fake-backend frames))
         (request (self-improving-agent-harness:make-completion-request
                   :messages '((:role "user" :content "hi")))))
    (handler-case
        (progn (self-improving-agent-harness:complete backend request)
               (error "Test failed: missing auth must be rejected by the backend"))
      (self-improving-agent-harness:codex-app-server-error () t))))

(defun run-codex-backend-redaction-tests ()
  ;; A turn result carrying a token-shaped field must not survive into RAW.
  (let* ((turn (cas-obj "text" "ok" "access_token" "sk-leak-should-not-survive"))
         (backend (cb-fake-backend (cb-authed-frames :turn-result turn)))
         (request (self-improving-agent-harness:make-completion-request
                   :messages '((:role "user" :content "hi"))))
         (response (self-improving-agent-harness:complete backend request))
         (raw (self-improving-agent-harness:completion-response-raw response))
         (flat (with-output-to-string (s) (yason:encode raw s))))
    (ensure-true (not (search "should-not-survive" flat))
                 "backend RAW is redacted; no token value survives")))

(defun cb-verify (server-frames &optional (turn-method "thread/runTurn"))
  "Run verify-codex-chatgpt-auth against a fake connection seeded with
SERVER-FRAMES, returning (values evidence success)."
  (self-improving-agent-harness:verify-codex-chatgpt-auth
   :turn-method turn-method
   :codex-version "codex-test-0.0"
   :connection-factory
   (lambda ()
     (multiple-value-bind (conn out) (cas-connection server-frames)
       (declare (ignore out))
       conn))))

(defun run-codex-verify-tests ()
  ;; Success: chatgpt auth + a completed turn -> ok, success t.
  (multiple-value-bind (evidence success) (cb-verify (cb-authed-frames))
    (ensure-true (eq t success) "verify succeeds with chatgpt auth and a completed turn")
    (ensure-true (equal "ok" (getf evidence :status)) "evidence status is ok on success")
    (ensure-true (equal "chatgpt" (getf evidence :auth-mode)) "evidence records chatgpt auth mode")
    (ensure-true (equal "completed" (getf evidence :turn-outcome)) "evidence records a completed turn")
    (ensure-true (equal "codex-test-0.0" (getf evidence :codex-version)) "evidence records the codex version")
    ;; Accounting stays unavailable in the verify path.
    (ensure-true (equal "unavailable" (getf evidence :cost-usd)) "verify cost stays unavailable")
    (ensure-true (equal "unavailable" (getf evidence :input-tokens)) "verify input tokens stay unavailable"))
  ;; Failure: apiKey auth -> failed, success nil, redacted reason, no fallback.
  (let ((frames (list (cas-frame (cas-response 1 (cas-obj "ok" t)))
                      (cas-frame (cas-response 2 (cas-obj "authMode" "apiKey"))))))
    (multiple-value-bind (evidence success) (cb-verify frames)
      (ensure-true (null success) "verify fails on apiKey auth")
      (ensure-true (equal "failed" (getf evidence :status)) "evidence status is failed on rejection")
      (ensure-true (search "OPENAI_API_KEY" (getf evidence :reason))
                   "verify failure reason forbids the OPENAI_API_KEY fallback")))
  ;; Evidence must never carry token material: seed a leak in the account read.
  (let ((frames (list (cas-frame (cas-response 1 (cas-obj "ok" t)))
                      (cas-frame (cas-response 2 (cas-obj "authMode" "chatgpt"
                                                          "access_token" "sk-verify-leak-xyz")))
                      (cas-frame (cas-response 3 (cas-obj "text" "verified"))))))
    (multiple-value-bind (evidence success) (cb-verify frames)
      (declare (ignore success))
      (let ((flat (with-output-to-string (s)
                    (self-improving-agent-harness:format-codex-verification-evidence evidence s))))
        (ensure-true (not (search "sk-verify-leak-xyz" flat))
                     "formatted verify evidence contains no token material")))))

(defun run-codex-backend-tests ()
  (run-codex-backend-success-tests)
  (run-codex-backend-authoritative-usage-tests)
  (run-codex-backend-auth-rejection-tests)
  (run-codex-backend-redaction-tests)
  (run-codex-verify-tests)
  (format t "Codex app-server backend adapter tests passed.~%")
  t)
