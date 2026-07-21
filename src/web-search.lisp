(in-package #:self-improving-agent-harness)

;;; web_search tool — Tavily Search API integration.
;;;
;;; Provides real-time web search via Tavily (https://docs.tavily.com). The API
;;; key is read from the TAVILY_API_KEY environment variable, which the chat
;;; startup loads from the workspace .env file (see LOAD-WORKSPACE-ENV-FILE).
;;; The key is never logged; only its presence/absence is reported.
;;;
;;; Design follows the existing tool conventions:
;;;   - WEB-SEARCH-TOOL is the handler symbol (re-resolved after reload_harness).
;;;   - The handler returns a plain string result for the tool loop.
;;;   - HTTP uses Drakma + Yason, matching the backend transport conventions.
;;;   - Errors are signaled as clear strings so the tool loop reports them.

(defparameter *tavily-search-url* "https://api.tavily.com/search"
  "Tavily Search REST endpoint.")

(defparameter *tavily-default-search-depth* "basic"
  "Default search_depth. \"basic\" costs 1 credit; \"advanced\" costs 2.")

(defparameter *tavily-default-max-results* 5
  "Default max_results. Tavily allows 0..20.")

(defparameter *tavily-request-timeout-seconds* 40
  "Wall-clock timeout for a single Tavily Search HTTP request.")

(defparameter *tavily-connection-timeout-seconds* 10
  "Drakma connection timeout for Tavily requests.")

(defun tavily-api-key ()
  "Return the Tavily API key from the environment, or NIL if unset.

Reads TAVILY_API_KEY, which LOAD-WORKSPACE-ENV-FILE sets into the process
environment at chat startup. The value is never logged."
  (let ((key (uiop:getenv "TAVILY_API_KEY")))
    (and (stringp key) (plusp (length key)) key)))

(defun tavily-api-key-configured-p ()
  "True when a non-empty TAVILY_API_KEY is present in the environment."
  (and (tavily-api-key) t))

(defun tavily-search-payload (query &key search-depth max-results topic
                                     include-answer time-range)
  "Build the JSON request body string for a Tavily Search request.

QUERY is required. SEARCH-DEPTH defaults to *TAVILY-DEFAULT-SEARCH-DEPTH*.
MAX-RESULTS defaults to *TAVILY-DEFAULT-MAX-RESULTS*. Optional TOPIC is one of
\"general\", \"news\", \"finance\". INCLUDE-ANSWER may be T, NIL, \"basic\", or
\"advanced\". TIME-RANGE may be one of \"day\",\"week\",\"month\",\"year\"."
  (unless (and (stringp query) (plusp (length query)))
    (error "web_search requires a non-empty query."))
  (let ((depth (or search-depth *tavily-default-search-depth*))
        (results (or max-results *tavily-default-max-results*)))
    (yason:with-output-to-string* ()
      (yason:with-object ()
        (yason:encode-object-element "query" query)
        (yason:encode-object-element "search_depth" depth)
        (yason:encode-object-element "max_results" results)
        (when topic
          (yason:encode-object-element "topic" topic))
        (when include-answer
          (yason:encode-object-element
           "include_answer"
           (cond ((eq include-answer t) t)
                 ((stringp include-answer) include-answer)
                 (t t))))
        (when time-range
          (yason:encode-object-element "time_range" time-range))))))

(defun tavily-format-results (parsed)
  "Format a parsed Tavily Search JSON response into a compact text string.

Returns a human/LLM-readable summary: the answer (if present), then each result
as title, url, score, and content. The raw JSON object is a Yason hash-table."
  (let ((answer (openrouter-json-field parsed "answer"))
        (results (openrouter-list (openrouter-json-field parsed "results")))
        (response-time (openrouter-json-field parsed "response_time")))
    (with-output-to-string (stream)
      (when (and answer (stringp answer) (plusp (length answer)))
        (format stream "Answer: ~A~%~%" answer))
      (format stream "~D result~:P~@[ (response_time=~As)~]:~%"
              (length results) response-time)
      (loop for r in results
            for i from 1
            do (let ((title (openrouter-json-field r "title"))
                     (url (openrouter-json-field r "url"))
                     (score (openrouter-json-field r "score"))
                     (content (openrouter-json-field r "content")))
                 (format stream "~%[~D] ~A~%" i (or title "(untitled)"))
                 (when url
                   (format stream "    URL: ~A~%" url))
                 (when score
                   (format stream "    Score: ~A~%" score))
                 (when content
                   (format stream "    Content: ~A~%" content)))))))

(defun tavily-http-error-message (status-code body-text)
  "Build a clear error string for a non-2xx Tavily response."
  (let ((snippet (if (and (stringp body-text) (> (length body-text) 500))
                     (subseq body-text 0 500)
                     body-text)))
    (format nil "Tavily Search failed (HTTP ~D): ~A"
            status-code (or snippet "(empty body)"))))

(defun tavily-search (query &key search-depth max-results topic
                            include-answer time-range)
  "Execute a Tavily Search and return a formatted text result string.

Signals an error if the API key is missing, the HTTP request fails, or Tavily
returns a non-2xx status. Keyword arguments are forwarded to
TAVILY-SEARCH-PAYLOAD."
  (let ((api-key (tavily-api-key)))
    (unless api-key
      (error "web_search is unavailable: TAVILY_API_KEY is not set in the environment."))
    (let* ((payload (tavily-search-payload query
                                           :search-depth search-depth
                                           :max-results max-results
                                           :topic topic
                                           :include-answer include-answer
                                           :time-range time-range))
           (octets (sb-ext:string-to-octets payload :external-format :utf-8)))
      (multiple-value-bind (body status-code)
          (drakma:http-request
           *tavily-search-url*
           :method :post
           :content octets
           :content-type "application/json; charset=utf-8"
           :connection-timeout *tavily-connection-timeout-seconds*
           :additional-headers
           `(("Authorization" . ,(format nil "Bearer ~A" api-key))))
        (let ((body-text (openrouter-response-body-string body)))
          (unless (<= 200 status-code 299)
            (error "~A" (tavily-http-error-message status-code body-text)))
          (tavily-format-results (yason:parse body-text)))))))

(defun web-search-tool (arguments)
  "web_search tool handler. Performs a Tavily web search.

ARGUMENTS is a decoded JSON object (Yason hash-table) with keys:
  query (string, required), search_depth (string, optional),
  max_results (integer, optional), topic (string, optional),
  include_answer (boolean, optional), time_range (string, optional).

Returns a formatted text summary of the search results. If TAVILY_API_KEY is
not configured, signals a clear error so the tool loop reports the missing
configuration rather than hanging."
  (let ((query (gethash "query" arguments))
        (search-depth (gethash "search_depth" arguments))
        (max-results (gethash "max_results" arguments))
        (topic (gethash "topic" arguments))
        (include-answer (gethash "include_answer" arguments))
        (time-range (gethash "time_range" arguments)))
    (log-interaction :info "tool-call" :tool "web_search"
                     :query query
                     :search-depth (or search-depth *tavily-default-search-depth*)
                     :max-results (or max-results *tavily-default-max-results*))
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (result err)
          (handler-case
              (tavily-search query
                             :search-depth search-depth
                             :max-results max-results
                             :topic topic
                             :include-answer include-answer
                             :time-range time-range)
            (error (condition) (values nil condition)))
        (let ((duration (/ (float (- (get-internal-real-time) start) 0d0)
                           internal-time-units-per-second)))
          (cond
            (err
             (log-interaction :error "tool-failed" :tool "web_search"
                              :query query
                              :duration-seconds duration
                              :message (princ-to-string err))
             (error "~A" err))
            (t
             (log-interaction :info "tool-completed" :tool "web_search"
                              :query query
                              :duration-seconds duration
                              :output-length (length result))
             result)))))))
