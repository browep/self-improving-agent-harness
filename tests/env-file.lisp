(in-package #:self-improving-agent-harness/tests)

(defun run-env-file-tests ()
  "Cover PARSE-ENV-FILE-LINE and LOAD-WORKSPACE-ENV-FILE."
  ;; Parsing: blank/comment lines are skipped.
  (ensure-true (null (parse-env-file-line ""))
               "blank line is skipped")
  (ensure-true (null (parse-env-file-line "   "))
               "whitespace-only line is skipped")
  (ensure-true (null (parse-env-file-line "# a comment"))
               "comment line is skipped")
  ;; Parsing: KEY=value, export prefix, and quote stripping.
  (multiple-value-bind (name value) (parse-env-file-line "GITHUB_TOKEN=ghp_abc")
    (ensure-equal "GITHUB_TOKEN" name "plain name parsed")
    (ensure-equal "ghp_abc" value "plain value parsed"))
  (multiple-value-bind (name value) (parse-env-file-line "export GH_HOST=example.com")
    (ensure-equal "GH_HOST" name "export prefix stripped")
    (ensure-equal "example.com" value "value after export parsed"))
  (multiple-value-bind (name value) (parse-env-file-line "Q=\"double quoted\"")
    (ensure-equal "Q" name "double-quoted name parsed")
    (ensure-equal "double quoted" value "double quotes stripped"))
  (multiple-value-bind (name value) (parse-env-file-line "S='single quoted'")
    (declare (ignore name))
    (ensure-equal "single quoted" value "single quotes stripped"))
  ;; Parsing: malformed lines are skipped.
  (ensure-true (null (parse-env-file-line "NO EQUALS HERE"))
               "line without = is skipped")
  (ensure-true (null (parse-env-file-line "=no-name"))
               "line without a name is skipped")
  (ensure-true (null (parse-env-file-line "9BAD=starts-with-digit"))
               "name starting with a digit is skipped")
  ;; Loader: missing file is not an error and sets nothing.
  (ensure-true (null (load-workspace-env-file "/nonexistent/env/file/xyz"))
               "missing env file returns NIL")
  ;; Loader: sets new vars, preserves pre-existing ones, inheritable by children.
  (let ((tmp (uiop:with-temporary-file (:pathname p :keep t :stream s :direction :output)
               (write-string "# header
UNIQUE_ENV_TOKEN_A=aaa
export UNIQUE_ENV_TOKEN_B='bbb'
PREEXISTING_ENV_VAR=from-file
" s)
               p)))
    (unwind-protect
         (progn
           (setf (uiop:getenv "PREEXISTING_ENV_VAR") "from-process")
           (let ((names (load-workspace-env-file tmp)))
             (ensure-true (member "UNIQUE_ENV_TOKEN_A" names :test #'string=)
                          "new var A reported as set")
             (ensure-true (member "UNIQUE_ENV_TOKEN_B" names :test #'string=)
                          "new var B reported as set")
             (ensure-true (not (member "PREEXISTING_ENV_VAR" names :test #'string=))
                          "pre-existing var not reported as set"))
           (ensure-equal "aaa" (uiop:getenv "UNIQUE_ENV_TOKEN_A")
                         "var A set into process env")
           (ensure-equal "bbb" (uiop:getenv "UNIQUE_ENV_TOKEN_B")
                         "var B set into process env")
           (ensure-equal "from-process" (uiop:getenv "PREEXISTING_ENV_VAR")
                         "pre-existing process value not overridden"))
      (ignore-errors (delete-file tmp)))))
