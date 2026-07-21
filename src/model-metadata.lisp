(in-package #:self-improving-agent-harness)

;;; Model metadata — context-length lookup for the context-window fill display.
;;;
;;; OpenRouter (and Synthetic, which is OpenAI-compatible) expose a public
;;; GET /models endpoint returning per-model context_length and
;;; top_provider.context_length. We fetch it once per backend per process and
;;; cache a model-id -> context-length map so the per-turn outcome line can show
;;; how full the context window is without re-fetching on every turn.
;;;
;;; Failures are graceful: a fetch error or an unknown model yields NIL, and the
;;; outcome line degrades to showing token counts without a context percentage.
;;; The cache records a "fetched" sentinel (including failed fetches) so a
;;; broken endpoint is not retried on every turn.

(defparameter *model-metadata-fetch-timeout-seconds* 20
  "Wall-clock timeout for a single /models metadata fetch.")

(defparameter *model-metadata-connection-timeout-seconds* 10
  "Drakma connection timeout for /models metadata fetch.")

(defparameter *model-metadata-cache* (make-hash-table :test #'equal)
  "Cache of backend-name -> metadata map.

Each value is a hash-table mapping model-id (string) to context-length (integer)
or NIL when the model was absent from the listing. A second value, the symbol
:fetched, is stored under the key \"\" (empty string) as a sentinel meaning the
endpoint has been queried (successfully or not) so we do not retry every turn.")

(defun model-metadata-fetched-p (backend)
  "True when metadata for BACKEND's provider has already been queried."
  (let ((map (gethash (backend-name backend) *model-metadata-cache*)))
    (and (hash-table-p map)
         (gethash "" map))))

(defun model-metadata-url (backend)
  "Return the /models endpoint URL for BACKEND's base URL."
  (format nil "~A/models"
          (string-right-trim "/" (openrouter-backend-base-url backend))))

(defun model-context-length-from-entry (entry)
  "Extract the context length from one parsed /models entry.

Prefers top_provider.context_length (the effective limit for the best provider)
and falls back to the top-level context_length field. Returns an integer or NIL."
  (let ((top-provider (openrouter-json-field entry "top_provider"))
        (top-level (openrouter-json-field entry "context_length")))
    (let ((from-provider (and top-provider
                              (openrouter-json-field top-provider
                                                     "context_length")))
          (from-top (and top-level (openrouter-json-field entry "context_length"))))
      (let ((value (or (and (integerp from-provider) from-provider)
                       (and (integerp from-top) from-top))))
        (and (integerp value) (plusp value) value)))))

(defun store-model-metadata (backend-name parsed)
  "Populate the cache for BACKEND-NAME from a parsed /models response.

PARSED is a Yason hash-table with a \"data\" array of model entries. Each entry
has an \"id\" and a context_length / top_provider.context_length. Unknown or
missing context lengths are stored as NIL so a later lookup does not refetch."
  (let ((map (make-hash-table :test #'equal))
        (entries (openrouter-list (openrouter-json-field parsed "data"))))
    (dolist (entry entries)
      (let ((id (openrouter-json-field entry "id")))
        (when (stringp id)
          (setf (gethash id map) (model-context-length-from-entry entry)))))
    ;; Sentinel: this backend's endpoint has been queried.
    (setf (gethash "" map) :fetched)
    (setf (gethash backend-name *model-metadata-cache*) map)
    map))

(defun mark-model-metadata-fetch-failed (backend-name)
  "Record that BACKEND-NAME's /models endpoint was queried but unusable.

Prevents per-turn retries when the endpoint is absent or returns garbage."
  (let ((map (make-hash-table :test #'equal)))
    (setf (gethash "" map) :fetched)
    (setf (gethash backend-name *model-metadata-cache*) map)
    map))

(defun fetch-model-metadata (backend)
  "Fetch and cache /models metadata for BACKEND. Returns the cache map.

Only OpenAI-compatible backends (openrouter-backend and its synthetic subclass)
have a base URL; other backends (codex) are marked fetched-with-empty so the
context display degrades to unavailable without errors."
  (let ((backend-name (backend-name backend)))
    (cond
      ((not (typep backend 'openrouter-backend))
       ;; Codex and other non-OpenAI-compatible backends have no /models URL.
       (mark-model-metadata-fetch-failed backend-name))
      (t
       (handler-case
           (let* ((url (model-metadata-url backend))
                  (api-key (openrouter-backend-api-key backend))
                  (octets-payload nil))
             (declare (ignore octets-payload))
             (multiple-value-bind (body status-code)
                 (drakma:http-request
                  url
                  :method :get
                  :connection-timeout *model-metadata-connection-timeout-seconds*
                  :additional-headers
                  (if (and (stringp api-key) (plusp (length api-key)))
                      `(("Authorization" . ,(format nil "Bearer ~A" api-key)))
                      '()))
               (let ((body-text (openrouter-response-body-string body)))
                 (if (<= 200 status-code 299)
                     (store-model-metadata backend-name (yason:parse body-text))
                     (progn
                       (log-interaction :warn "model-metadata-fetch-failed"
                                        :backend backend-name
                                        :status-code status-code)
                       (mark-model-metadata-fetch-failed backend-name))))))
         (error (condition)
           (log-interaction :warn "model-metadata-fetch-error"
                            :backend backend-name
                            :message (princ-to-string condition))
           (mark-model-metadata-fetch-failed backend-name)))))))

(defun ensure-model-metadata (backend)
  "Return the metadata cache map for BACKEND, fetching it once if needed."
  (or (gethash (backend-name backend) *model-metadata-cache*)
      (fetch-model-metadata backend)))

(defun model-context-length (backend model)
  "Return the cached context length for MODEL on BACKEND, or NIL.

Fetches /models once per backend per process. Returns NIL when the model is
unknown, the endpoint is unavailable, or BACKEND is not OpenAI-compatible."
  (when (and backend (stringp model) (plusp (length model)))
    (let ((map (ensure-model-metadata backend)))
      (gethash model map))))

(defun context-fill-percentage (used-tokens context-length)
  "Return the integer percentage of context used, or NIL when not computable."
  (when (and (integerp used-tokens)
             (integerp context-length)
             (plusp context-length))
    (min 100 (max 0 (floor (* 100 used-tokens) context-length)))))

(defun reset-model-metadata-cache ()
  "Clear the in-process model metadata cache (mainly for tests)."
  (clrhash *model-metadata-cache*))
