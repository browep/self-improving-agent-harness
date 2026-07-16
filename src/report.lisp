(in-package #:self-improving-agent-harness)

(defparameter +run-report-schema-version+ "1"
  "Version of the persisted run trace/report schema.")

(defun report-key-name (key)
  (string-downcase (substitute #\_ #\- (string key))))

(defun report-accounting-key-p (name)
  (member name '("INPUT-TOKENS" "OUTPUT-TOKENS" "TOTAL-TOKENS" "COST-USD")
          :test #'string=))

(defun report-budget-cap-key-p (name)
  "Recognize explicit non-sensitive evaluator budget fields, not arbitrary token keys."
  (member name '("MAX-WALL-SECONDS" "MAX-PROVIDER-CALLS" "MAX-TOTAL-TOKENS" "MAX-COST-USD")
          :test #'string=))

(defun sensitive-report-key-p (key)
  (let ((name (string-upcase (string key))))
    (unless (or (report-accounting-key-p name)
                (report-budget-cap-key-p name))
      (or (search "API_KEY" name)
          (search "API-KEY" name)
          (search "AUTHORIZATION" name)
          (search "CREDENTIAL" name)
          (search "PASSWORD" name)
          (search "SECRET" name)
          (search "TOKEN" name)
          (search "RAW" name)
          (search "OUTPUT" name)
          (search "RESPONSE" name)
          (search "CONTENT" name)
          (search "BODY" name)))))

(defun sensitive-report-string-p (value)
  "Recognize credential markers that might be embedded in otherwise free-form data."
  (and (stringp value)
       (let ((text (string-upcase value)))
         (or (search "OPENROUTER_API_KEY" text)
             (search "API_KEY=" text)
             (search "API-KEY=" text)
             (search "AUTHORIZATION:" text)
             (search "BEARER " text)
             (search "PASSWORD=" text)
             (search "CREDENTIAL=" text)
             (search "SECRET=" text)
             (and (search "RAW" text)
                  (or (search "TOOL" text) (search "PROVIDER" text))
                  (search "OUTPUT" text))))))

(defun redact-report-data (value)
  "Return VALUE without credentials or raw tool/provider output.

Accounting fields remain unchanged. Sensitive fields are removed, and a
free-form string containing a credential marker is replaced, so neither a
credential nor raw output can enter JSON, HTML, or console summaries."
  (cond
    ((and (listp value) (keywordp (first value)))
     (loop for (key item) on value by #'cddr
           unless (sensitive-report-key-p key)
             append (list key (redact-report-data item))))
    ((listp value) (mapcar #'redact-report-data value))
    ((and (vectorp value) (not (stringp value)))
     (map 'list #'redact-report-data value))
    ((hash-table-p value)
     (let ((result (make-hash-table :test (hash-table-test value))))
       (maphash (lambda (key item)
                  (unless (sensitive-report-key-p key)
                    (setf (gethash key result) (redact-report-data item))))
                value)
       result))
    ((sensitive-report-string-p value) "[redacted]")
    (t value)))

(defun report-json-value (value)
  (cond
    ((and (listp value) (keywordp (first value)))
     (let ((object (make-hash-table :test #'equal)))
       (loop for (key item) on value by #'cddr
             do (setf (gethash (report-key-name key) object)
                      (report-json-value item)))
       object))
    ((listp value) (mapcar #'report-json-value value))
    ((and (vectorp value) (not (stringp value)))
     (map 'list #'report-json-value value))
    ((hash-table-p value)
     (let ((object (make-hash-table :test #'equal)))
       (maphash (lambda (key item)
                  (setf (gethash (report-key-name key) object)
                        (report-json-value item)))
                value)
       object))
    ((symbolp value) (string-downcase (symbol-name value)))
    (t value)))

(defun report-json-string (report)
  (with-output-to-string (stream)
    (yason:encode (report-json-value report) stream)))

(defun html-escape (value)
  (with-output-to-string (stream)
    (loop for character across (princ-to-string value)
          do (write-string (case character
                             (#\& "&amp;")
                             (#\< "&lt;")
                             (#\> "&gt;")
                             (#\" "&quot;")
                             (#\' "&#39;")
                             (t (string character)))
                           stream))))

(defun report-value (value)
  (if (stringp value) value (prin1-to-string value)))

(defun render-report-list (items)
  (with-output-to-string (stream)
    (write-string "<ul>" stream)
    (dolist (item items)
      (format stream "<li><code>~A</code></li>" (html-escape (report-value item))))
    (write-string "</ul>" stream)))

(defun render-invoked-model-history (history)
  (with-output-to-string (stream)
    (write-string "<table><thead><tr><th>Model</th><th>Provider</th><th>Role</th><th>Input tokens</th><th>Output tokens</th><th>Actual cost (USD)</th><th>Outcome</th></tr></thead><tbody>" stream)
    (dolist (invocation history)
      (format stream "<tr><td>~A</td><td>~A</td><td>~A</td><td>~A</td><td>~A</td><td>~A</td><td>~A</td></tr>"
              (html-escape (getf invocation :model))
              (html-escape (getf invocation :provider))
              (html-escape (getf invocation :role))
              (html-escape (getf invocation :input-tokens))
              (html-escape (getf invocation :output-tokens))
              (html-escape (getf invocation :cost-usd))
              (html-escape (getf invocation :outcome))))
    (write-string "</tbody></table>" stream)))

(defun render-run-report-html (report)
  "Render REPORT as a self-contained, escaped HTML document."
  (let* ((task (getf report :task))
         (candidate (getf report :candidate))
         (models (getf report :model-history))
         (evaluation (getf report :evaluation))
         (decision (getf report :decision)))
    (with-output-to-string (stream)
      (write-string "<!doctype html><html><head><meta charset=\"utf-8\"><title>Harness run report</title><style>body{font-family:system-ui,sans-serif;max-width:1000px;margin:2rem auto;padding:0 1rem;color:#18212f}table{border-collapse:collapse;width:100%}th,td{border:1px solid #bcc7d6;padding:.45rem;text-align:left}th{background:#eef3f8}code{white-space:pre-wrap}section{margin:1.5rem 0}</style></head><body>" stream)
      (format stream "<h1>Harness run report</h1><p>Schema version: <strong>~A</strong></p>"
              (html-escape (getf report :schema-version)))
      (format stream "<section><h2>Task</h2><p>~A</p><h3>Acceptance criteria</h3>~A</section>"
              (html-escape (getf task :prompt))
              (render-report-list (getf task :criteria)))
      (format stream "<section><h2>Candidate lineage</h2><p>Candidate: <code>~A</code></p><p>Parent: <code>~A</code></p><p>Configuration: <code>~A</code></p></section>"
              (html-escape (getf candidate :id))
              (html-escape (getf candidate :parent-id))
              (html-escape (report-value (getf candidate :configuration))))
      ;; Selection is intentionally presented before attempts/invocations.
      (format stream "<section><h2>Available model history</h2>~A</section>"
              (render-report-list (getf models :available)))
      (format stream "<section><h2>Invoked model history</h2>~A</section>"
              (render-invoked-model-history (getf models :invoked)))
      (format stream "<section><h2>Tool metadata</h2>~A</section>"
              (render-report-list (getf report :tool-metadata)))
      (format stream "<section><h2>Outcome</h2><p><strong>~A</strong></p><h3>Evaluator evidence</h3>~A</section>"
              (html-escape (getf report :outcome))
              (render-report-list (getf evaluation :evidence)))
      (format stream "<section><h2>Final decision</h2><p>Action: <strong>~A</strong></p><p>~A</p></section>"
              (html-escape (getf decision :action))
              (html-escape (getf decision :rationale)))
      (write-string "</body></html>" stream))))

(defun render-configuration-comparison-html (report)
  "Render persisted evaluator evidence for a baseline and configuration candidates."
  (with-output-to-string (stream)
    (write-string "<!doctype html><html><head><meta charset=\"utf-8\"><title>Configuration comparison</title><style>body{font-family:system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#18212f}table{border-collapse:collapse;width:100%}th,td{border:1px solid #bcc7d6;padding:.45rem;text-align:left;vertical-align:top}th{background:#eef3f8}code{white-space:pre-wrap}</style></head><body>" stream)
    (format stream "<h1>Baseline vs candidate comparison</h1><p>Experiment: <code>~A</code></p><p>Equal explicit budget caps: <code>~A</code></p>"
            (html-escape (getf report :experiment-id))
            (html-escape (report-value (getf report :budget))))
    (write-string "<table><thead><tr><th>Role</th><th>Candidate / configuration hash</th><th>Parent</th><th>Outcome</th><th>Evaluator evidence</th><th>Actual accounting</th><th>Retention</th></tr></thead><tbody>" stream)
    (let ((baseline (getf report :baseline)))
      (format stream "<tr><td>Baseline</td><td><code>~A<br>~A</code></td><td><code>~A</code></td><td>~A</td><td><code>~A</code></td><td><code>~A</code></td><td>Control</td></tr>"
              (html-escape (getf baseline :id))
              (html-escape (getf baseline :configuration-hash))
              (html-escape (getf baseline :parent-id))
              (html-escape (getf report :baseline-outcome))
              (html-escape (report-value (getf report :baseline-evaluation)))
              (html-escape (report-value (getf report :baseline-accounting)))))
    (dolist (entry (getf report :comparisons))
      (let ((candidate (getf entry :candidate))
            (decision (getf entry :decision)))
        (format stream "<tr><td>Candidate</td><td><code>~A<br>~A<br>~A</code></td><td><code>~A</code></td><td>~A</td><td><code>~A</code></td><td><code>~A</code></td><td><strong>~A</strong><br>~A</td></tr>"
                (html-escape (getf candidate :id))
                (html-escape (getf candidate :configuration-hash))
                (html-escape (report-value (getf candidate :configuration)))
                (html-escape (getf candidate :parent-id))
                (html-escape (getf entry :outcome))
                (html-escape (report-value (getf entry :evaluation)))
                (html-escape (report-value (getf entry :accounting)))
                (html-escape (getf decision :action))
                (html-escape (getf decision :rationale)))))
    (write-string "</tbody></table><p>Retention is derived solely from the persisted deterministic evaluator results above; candidates do not self-evaluate or self-promote.</p></body></html>" stream)))

(defun scripted-baseline-run-report (result)
  "Build one complete, versioned trace record from the offline scripted run."
  (list :schema-version +run-report-schema-version+
        :report-type "run-trace"
        :run-id "baseline-answer-v1/scripted-run"
        :task (list :prompt "Submit the exact answer baseline-ok through submit_candidate."
                    :criteria '((:name "answer-is-baseline-ok" :kind :deterministic-command)))
        :candidate (list :id "baseline-answer-v1/candidate-1"
                         :parent-id "baseline-answer-v1/root"
                         :configuration '(:backend "scripted" :model "offline/baseline-v1"
                                          :api-key "credential-value"))
        :model-history
        (list :available '((:model "offline/baseline-v1" :provider "scripted" :selected t))
              :invoked '((:model "offline/baseline-v1" :provider "scripted" :role "worker"
                          :input-tokens 7 :output-tokens 3 :cost-usd 0.0025 :outcome "completed")
                         (:model "offline/baseline-v1" :provider "scripted" :role "worker"
                          :input-tokens 2 :output-tokens 1 :cost-usd 0.0005 :outcome "completed")))
        :tool-metadata '((:name "submit_candidate" :kind "function" :call-id "submit-baseline-v1"
                          :raw-output "raw sensitive tool output"))
        :usage (list :input-tokens 9 :output-tokens 4 :cost-usd 0.003)
        :evaluation (list :evaluator "deterministic-command"
                          :evidence (getf result :evidence))
        :outcome (string-downcase (symbol-name (getf result :outcome)))
        :decision (list :action (if (eq :success (getf result :outcome)) "retain" "reject")
                        :rationale "offline scripted baseline evaluation")))

(defun write-run-report-artifacts (report directory)
  "Write JSON and HTML from the exact same sanitized in-memory REPORT object."
  (let* ((safe-report (redact-report-data report))
         (output-directory (uiop:ensure-directory-pathname directory))
         (json-path (merge-pathnames "run.json" output-directory))
         (html-path (merge-pathnames "run.html" output-directory)))
    (ensure-directories-exist json-path)
    (with-open-file (stream json-path :direction :output :if-exists :supersede
                                      :if-does-not-exist :create :external-format :utf-8)
      (write-string (report-json-string safe-report) stream))
    (with-open-file (stream html-path :direction :output :if-exists :supersede
                                      :if-does-not-exist :create :external-format :utf-8)
      (write-string (if (string= (getf safe-report :report-type) "configuration-comparison")
                        (render-configuration-comparison-html safe-report)
                        (render-run-report-html safe-report)) stream))
    (list :json-path json-path :html-path html-path)))

(defun write-scripted-baseline-report (&optional (directory "reports/baseline-answer-v1/"))
  "Run the deterministic no-provider fixture and persist its auditable reports."
  (load "fixtures/baseline-answer-v1.lisp")
  (let* ((backend
           (make-instance
            'fixed-baseline-backend :name "fixed-scripted-baseline"
            :responses
            (list
             (make-completion-response
              :model "offline/baseline-v1" :usage '(:total-tokens 10 :cost-usd 0.0025)
              :tool-calls '((:id "submit-baseline-v1" :type "function"
                             :name "submit_candidate" :arguments "{\"answer\":\"baseline-ok\"}")))
             (make-completion-response :model "offline/baseline-v1" :text "submitted"
                                       :usage '(:total-tokens 3 :cost-usd 0.0005)))))
         (result
           (run-baseline-fixture
            *fixed-baseline-fixture* backend
            '(:max-wall-seconds 5 :max-provider-calls 2
              :max-total-tokens 32 :max-cost-usd 1))))
    (unless (eq :success (getf result :outcome))
      (error "Scripted baseline report requires a completed run."))
    (write-run-report-artifacts (scripted-baseline-run-report result) directory)))

(defun write-configuration-comparison-report (record directory)
  "Persist paired redacted JSON and HTML from one configuration comparison record."
  (unless (string= (getf record :report-type) "configuration-comparison")
    (error "Configuration comparison reports require a comparison record."))
  (write-run-report-artifacts record directory))
