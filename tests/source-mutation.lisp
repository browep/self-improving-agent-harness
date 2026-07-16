(in-package #:self-improving-agent-harness/tests)

(defun run-source-mutation-tests ()
  (let ((mutation (parse-source-mutation
                   "(:operation :replace-function-body :target \"fixture-score\" :body (+ value 2))")))
    (ensure-true (and (eq :replace-function-body (getf mutation :operation))
                      (string= "fixture-score" (getf mutation :target))
                      (equal '((:symbol "+") (:symbol "VALUE") (:integer 2))
                             (mapcar (lambda (item)
                                       (cond ((symbolp item) (list :symbol (symbol-name item)))
                                             ((integerp item) (list :integer item))
                                             (t item)))
                                     (getf mutation :body))))
                 "the structured mutation reader parses a named-definition transformation"))
  (let* ((mutation (parse-source-mutation
                    "(:operation :replace-function-body :target \"fixture-score\" :body (+ value 2))"))
         (candidate-source
           (apply-source-mutation
            "(defun fixture-score (value) (+ value 1))" mutation)))
    (ensure-true (search "2)" candidate-source)
                 "a structured named-function mutation replaces only the fixture body")
    (ensure-true (not (search "(+ VALUE 1)" candidate-source))
                 "the original fixture body is absent after application"))
  (let ((rejected nil))
    (handler-case
        (validate-source-mutation
         '(:operation :replace-function-body :target "fixture-score" :body "not-a-form"))
      (error () (setf rejected t)))
    (ensure-true rejected
                 "invalid structured transformations reject before execution"))
  (let* ((directory (merge-pathnames "source-mutation-test/" (uiop:temporary-directory)))
         (result (run-source-mutation-prototype directory)))
    (unwind-protect
         (progn
           (ensure-true (eq :pass (getf result :outcome))
                        "the isolated candidate compiles and passes the held-out evaluator")
           (ensure-true (and (probe-file (getf result :diff-path))
                             (probe-file (getf result :json-path))
                             (probe-file (getf result :html-path)))
                        "the prototype writes reviewable diff and paired evidence artifacts"))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))
