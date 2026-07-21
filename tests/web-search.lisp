(in-package #:self-improving-agent-harness/tests)

(defun make-web-search-arguments (&key query search-depth max-results topic
                                  include-answer time-range)
  "Build a Yason-style hash-table mimicking decoded tool arguments."
  (let ((arguments (make-hash-table :test #'equal)))
    (when query (setf (gethash "query" arguments) query))
    (when search-depth (setf (gethash "search_depth" arguments) search-depth))
    (when max-results (setf (gethash "max_results" arguments) max-results))
    (when topic (setf (gethash "topic" arguments) topic))
    (when include-answer (setf (gethash "include_answer" arguments) include-answer))
    (when time-range (setf (gethash "time_range" arguments) time-range))
    arguments))

(defun run-web-search-tests ()
  "Cover TAVILY-SEARCH-PAYLOAD, TAVILY-FORMAT-RESULTS, and the missing-key path.

These tests are offline-safe: they do not make HTTP requests. The live Tavily
API is exercised only by an operator-run smoke script."
  ;; Payload building: required query is included.
  (let ((payload (self-improving-agent-harness::tavily-search-payload "hello world")))
    (ensure-true (search "\"query\"" payload) "payload contains query key")
    (ensure-true (search "hello world" payload) "payload contains query value")
    (ensure-true (search "\"search_depth\"" payload)
                 "payload contains search_depth key")
    (ensure-true (search "\"max_results\"" payload)
                 "payload contains max_results key"))
  ;; Payload building: empty query is rejected.
  (handler-case
      (progn
        (self-improving-agent-harness::tavily-search-payload "")
        (error "Test failed: empty query must be rejected"))
    (error (condition)
      (ensure-true (search "non-empty query" (princ-to-string condition))
                   "empty query signals a clear error")))
  ;; Payload building: optional keys appear when supplied.
  (let ((payload (self-improving-agent-harness::tavily-search-payload
                  "test" :topic "news" :time-range "week" :include-answer t)))
    (ensure-true (search "\"topic\"" payload) "payload includes topic")
    (ensure-true (search "\"time_range\"" payload) "payload includes time_range")
    (ensure-true (search "\"include_answer\"" payload)
                 "payload includes include_answer"))
  ;; Format results: builds a readable summary from a parsed response.
  (let* ((parsed (yason:parse
                  "{\"answer\":\"Paris\",\"results\":[{\"title\":\"Eiffel Tower\",\"url\":\"https://example.com\",\"score\":0.9,\"content\":\"A tower in Paris.\"}],\"response_time\":1.5}"))
         (text (self-improving-agent-harness::tavily-format-results parsed)))
    (ensure-true (search "Answer: Paris" text)
                 "formatted results include the answer")
    (ensure-true (search "Eiffel Tower" text)
                 "formatted results include the title")
    (ensure-true (search "https://example.com" text)
                 "formatted results include the url")
    (ensure-true (search "A tower in Paris." text)
                 "formatted results include the content"))
  ;; Format results: empty results list is handled gracefully.
  (let* ((parsed (yason:parse "{\"results\":[],\"response_time\":0.5}"))
         (text (self-improving-agent-harness::tavily-format-results parsed)))
    (ensure-true (search "0 results" text)
                 "empty results list is reported"))
  ;; Missing API key: the tool signals a clear error (offline, no HTTP).
  ;; Only run this assertion when no key is present so it stays deterministic.
  (unless (self-improving-agent-harness::tavily-api-key-configured-p)
    (handler-case
        (progn
          (self-improving-agent-harness::web-search-tool
           (make-web-search-arguments :query "anything"))
          (error "Test failed: missing key must signal an error"))
      (error (condition)
        (ensure-true (search "TAVILY_API_KEY" (princ-to-string condition))
                     "missing key error mentions TAVILY_API_KEY"))))
  (format t "Web-search tests passed.~%")
  t)
