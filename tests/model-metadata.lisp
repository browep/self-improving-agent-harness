(in-package #:self-improving-agent-harness/tests)

(defun run-model-metadata-tests ()
  "Cover context-length extraction, caching, and the fill-percentage helper.

These tests are offline-safe: they populate the cache directly and exercise the
pure helpers. They do not make HTTP requests."
  (self-improving-agent-harness::reset-model-metadata-cache)

  ;; context-fill-percentage: basic math and clamping.
  (ensure-equal 50 (self-improving-agent-harness::context-fill-percentage 1000 2000)
                "50% fill")
  (ensure-equal 100 (self-improving-agent-harness::context-fill-percentage 4000 2000)
                "over-full clamps to 100%")
  (ensure-equal 0 (self-improving-agent-harness::context-fill-percentage 0 2000)
                "zero usage is 0%")
  (ensure-true (null (self-improving-agent-harness::context-fill-percentage 100 nil))
              "nil context length yields nil")
  (ensure-true (null (self-improving-agent-harness::context-fill-percentage nil 2000))
               "nil usage yields nil")
  (ensure-true (null (self-improving-agent-harness::context-fill-percentage 100 0))
               "zero context length yields nil")

  ;; model-context-length-from-entry: prefers top_provider.context_length.
  (let ((entry-with-provider
          (yason:parse "{\"id\":\"m1\",\"context_length\":8000,\"top_provider\":{\"context_length\":16000}}")))
    (ensure-equal 16000
                  (self-improving-agent-harness::model-context-length-from-entry
                   entry-with-provider)
                  "prefers top_provider.context_length"))
  ;; Falls back to top-level context_length when top_provider absent.
  (let ((entry-top-only (yason:parse "{\"id\":\"m2\",\"context_length\":32000}")))
    (ensure-equal 32000
                  (self-improving-agent-harness::model-context-length-from-entry
                   entry-top-only)
                  "falls back to top-level context_length"))
  ;; Returns nil when neither field is a positive integer.
  (let ((entry-none (yason:parse "{\"id\":\"m3\"}")))
    (ensure-true (null (self-improving-agent-harness::model-context-length-from-entry
                        entry-none))
                 "no context length fields yields nil"))

  ;; store-model-metadata: populates a cache map from a parsed response.
  (let* ((json-text (concatenate 'string
                        "{\"data\":[{\"id\":\"alpha/model\",\"context_length\":128000,\"top_provider\":{\"context_length\":128000}},"
                        "{\"id\":\"beta/model\",\"context_length\":4096}]}"))
         (parsed (yason:parse json-text))
         (map (self-improving-agent-harness::store-model-metadata "openrouter" parsed)))
    (ensure-equal 128000 (gethash "alpha/model" map)
                  "stored alpha/model context length")
    (ensure-equal 4096 (gethash "beta/model" map)
                  "stored beta/model context length")
    (ensure-equal :fetched (gethash "" map)
                  "fetch sentinel recorded")
    (ensure-true (self-improving-agent-harness::model-metadata-fetched-p
                  (self-improving-agent-harness::make-openrouter-backend
                   :api-key "k"))
                 "fetched-p true after store"))

  ;; model-context-length: reads from cache without refetching.
  (let ((backend (self-improving-agent-harness::make-openrouter-backend :api-key "k")))
    (ensure-equal 128000 (self-improving-agent-harness::model-context-length backend "alpha/model")
                  "model-context-length returns cached value")
    (ensure-true (null (self-improving-agent-harness::model-context-length backend "unknown/model"))
                 "unknown model yields nil"))

  ;; Non-OpenAI-compatible backend (codex) is marked fetched-empty, no error.
  (let ((codex (self-improving-agent-harness::make-codex-app-server-backend)))
    (ensure-true (null (self-improving-agent-harness::model-context-length codex "any/model"))
                 "codex backend yields nil context length")
    (ensure-true (self-improving-agent-harness::model-metadata-fetched-p codex)
                 "codex backend marked fetched after lookup"))

  (self-improving-agent-harness::reset-model-metadata-cache)
  (format t "Model-metadata tests passed.~%")
  t)
