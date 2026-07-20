(in-package #:self-improving-agent-harness/tests)

(defun run-backend-selection-tests ()
  "HARNESS_BACKEND selects openrouter (default) or codex subscription only.

OpenAI Platform API-key billing is rejected. No OPENAI_API_KEY path exists."
  (labels ((env (name) (uiop:getenv name))
           (set-env (name value)
             (if (null value)
                 (sb-posix:unsetenv name)
                 (setf (uiop:getenv name) value)))
           (with-restored-env (thunk)
             (let ((saved-backend (env "HARNESS_BACKEND"))
                   (saved-or (env "OPENROUTER_API_KEY"))
                   (saved-oa (env "OPENAI_API_KEY")))
               (unwind-protect (funcall thunk)
                 (set-env "HARNESS_BACKEND" saved-backend)
                 (set-env "OPENROUTER_API_KEY" saved-or)
                 (set-env "OPENAI_API_KEY" saved-oa)))))
    (with-restored-env
     (lambda ()
       (set-env "HARNESS_BACKEND" nil)
       (set-env "OPENROUTER_API_KEY" "or-from-env")
       (set-env "OPENAI_API_KEY" "must-not-be-used")
       (let ((b (select-chat-backend)))
         (ensure-true (typep b 'self-improving-agent-harness:openrouter-backend)
                      "default select-chat-backend is openrouter")
         (ensure-equal "or-from-env" (openrouter-backend-api-key b)
                       "default selector reads OPENROUTER_API_KEY")
         (ensure-true (backend-api-key-configured-p b)
                      "openrouter with key reports api-key-configured"))

       (set-env "HARNESS_BACKEND" "openrouter")
       (let ((b (select-chat-backend)))
         (ensure-true (typep b 'self-improving-agent-harness:openrouter-backend)
                      "explicit openrouter selects openrouter"))

       (set-env "HARNESS_BACKEND" "codex")
       (let ((b (select-chat-backend)))
         (ensure-true (typep b 'self-improving-agent-harness:codex-app-server-backend)
                      "HARNESS_BACKEND=codex selects codex-app-server-backend")
         (ensure-equal "codex-app-server" (backend-name b)
                       "codex backend name is codex-app-server")
         (ensure-true (not (backend-api-key-configured-p b))
                      "codex subscription backend has no API key")
         ;; OPENAI_API_KEY must not be consulted for construction.
         (ensure-true (string= "must-not-be-used" (env "OPENAI_API_KEY"))
                      "OPENAI_API_KEY remains untouched and unused for codex"))

       (set-env "HARNESS_BACKEND" "CODEX")
       (let ((b (select-chat-backend)))
         (ensure-true (typep b 'self-improving-agent-harness:codex-app-server-backend)
                      "HARNESS_BACKEND=codex is case-insensitive"))

       ;; OpenAI Platform API-key path is explicitly rejected.
       (set-env "HARNESS_BACKEND" "openai")
       (handler-case
           (progn
             (select-chat-backend)
             (error "Test failed: HARNESS_BACKEND=openai must be rejected"))
         (error (condition)
           (let ((text (princ-to-string condition)))
             (ensure-true (search "openai" (string-downcase text))
                          "rejection mentions openai")
             (ensure-true (or (search "OPENAI_API_KEY" text)
                              (search "Platform" text)
                              (search "subscription" (string-downcase text)))
                          "rejection points at subscription vs Platform billing"))))

       (set-env "HARNESS_BACKEND" "not-a-provider")
       (handler-case
           (progn
             (select-chat-backend)
             (error "Test failed: unknown HARNESS_BACKEND must signal"))
         (error (condition)
           (ensure-true (search "HARNESS_BACKEND" (princ-to-string condition))
                        "unknown HARNESS_BACKEND errors clearly")))

       ;; Explicit :backend wins; openai platform constructor does not exist.
       (let ((b (select-chat-backend
                 :backend (make-codex-app-server-backend))))
         (ensure-true (typep b 'self-improving-agent-harness:codex-app-server-backend)
                      "explicit :backend overrides HARNESS_BACKEND"))

       (let ((summary (run-harness :backend (make-codex-app-server-backend))))
         (ensure-true (eq :ready (getf summary :status))
                      "run-harness ready with codex backend")
         (ensure-equal "codex-app-server" (getf summary :backend)
                       "run-harness identifies codex backend")
         (ensure-true (not (getf summary :api-key-present))
                      "run-harness does not claim an API key for codex")))))

  (format t "Backend selection (openrouter|codex; no OpenAI Platform) tests passed.~%")
  t)
