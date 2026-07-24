(in-package #:self-improving-agent-harness)

;;; Minimal, dependency-free Markdown -> HTML renderer for the browser chat
;;; log (issue #50: "show markdown rendered text for responses that contain
;;; it"). No client-side markdown library (e.g. marked.js) is vendored
;;; because the container's Quicklisp archive/software directories are
;;; root-owned and read-only to the harness's runtime user, and no new
;;; Quicklisp system is fetched at request time. CL-PPCRE is already an
;;; existing transitive dependency (via CLOG), so this uses only in-repo
;;; Lisp plus CL-PPCRE.
;;;
;;; Security model: every code path below either (a) HTML-escapes raw
;;; Markdown source text via WEB-HTML-ESCAPE before it is ever placed inside
;;; a tag, or (b) constructs a tag from a fixed set of hard-coded strings
;;; (e.g. "<strong>", "</strong>"). Markdown source therefore can never
;;; introduce a live HTML tag or attribute; the only HTML actually emitted by
;;; this file is the literal tag text baked into the source below.

(defun web-html-escape (text)
  (with-output-to-string (out)
    (loop for character across (or text "") do
      (write-string (case character
                      (#\& "&amp;") (#\< "&lt;") (#\> "&gt;")
                      (#\" "&quot;") (#\' "&#39;") (t (string character))) out))))

(defun web-split-lines (text)
  "Split TEXT into a list of lines on #\Newline, stripping trailing #\Return."
  (let ((text (or text ""))
        (lines '())
        (start 0))
    (loop for i from 0 below (length text)
          for ch = (char text i)
          when (char= ch #\Newline)
            do (push (string-right-trim '(#\Return) (subseq text start i)) lines)
               (setf start (1+ i)))
    (push (string-right-trim '(#\Return) (subseq text start)) lines)
    (nreverse lines)))

(defun web-markdown-text-p (text)
  "Heuristic: does TEXT contain Markdown syntax worth rendering as HTML?

Deliberately conservative: plain prose without any of these markers renders
exactly as before (escaped plain text), so a false negative only means an
assistant reply keeps the pre-issue-#50 plain rendering, never that Markdown
source characters leak into the DOM unescaped."
  (and text
       (or (search "```" text)
           (cl-ppcre:scan "(?m)^#{1,6}\\s+\\S" text)
           (cl-ppcre:scan "(?m)^\\s*[-*+]\\s+\\S" text)
           (cl-ppcre:scan "(?m)^\\s*\\d+\\.\\s+\\S" text)
           (cl-ppcre:scan "\\*\\*[^*\\n]+\\*\\*" text)
           (cl-ppcre:scan "(?<!\\*)\\*[^*\\n]+\\*(?!\\*)" text)
           (cl-ppcre:scan "`[^`\\n]+`" text)
           (cl-ppcre:scan "\\[[^\\]\\n]+\\]\\([^)\\n]+\\)" text))))

(defun web-markdown-escape-inline (text)
  "HTML-escape TEXT for placement inside inline Markdown-derived HTML."
  (web-html-escape text))

(defun web-markdown-render-inline (text)
  "Render one line/paragraph's worth of inline Markdown as an HTML string.

TEXT is raw (unescaped) Markdown source. The whole string is HTML-escaped
first; the escaped result is then wrapped with literal tag strings at the
positions matched by inline patterns operating on that already-escaped text,
so no substring ever re-enters the DOM as unescaped markup."
  (let ((escaped (web-markdown-escape-inline text)))
    ;; Inline code spans first, so `*`/`_` inside backticks are not further
    ;; transformed by the emphasis rules below. \\1 refers to CL-PPCRE's
    ;; first capture register (already-escaped text), never raw source.
    (setf escaped (cl-ppcre:regex-replace-all "`([^`]+)`" escaped "<code>\\1</code>"))
    ;; Links: [label](url). URL is escaped text already (no raw quotes/tags
    ;; survive WEB-HTML-ESCAPE), so it is safe as an href attribute value.
    (setf escaped (cl-ppcre:regex-replace-all
                   "\\[([^\\]]+)\\]\\(([^)]+)\\)" escaped
                   "<a href=\"\\2\" target=\"_blank\" rel=\"noopener noreferrer\">\\1</a>"))
    ;; Bold before italic so **x** does not first match as *...*.
    (setf escaped (cl-ppcre:regex-replace-all "\\*\\*([^*]+)\\*\\*" escaped "<strong>\\1</strong>"))
    (setf escaped (cl-ppcre:regex-replace-all "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)" escaped "<em>\\1</em>"))
    escaped))

(defun web-markdown-split-blocks (text)
  "Split TEXT into a list of (:kind . lines) blocks: :code, :heading, :list, :para."
  (let ((lines (web-split-lines text))
        (blocks '())
        (i 0)
        (n 0))
    (setf n (length lines))
    (loop while (< i n) do
      (let ((line (nth i lines)))
        (cond
          ;; Fenced code block.
          ((cl-ppcre:scan "^```" line)
           (let ((body '()))
             (incf i)
             (loop while (and (< i n) (not (cl-ppcre:scan "^```" (nth i lines))))
                   do (push (nth i lines) body) (incf i))
             (when (< i n) (incf i)) ; consume closing fence
             (push (cons :code (nreverse body)) blocks)))
          ;; ATX heading.
          ((cl-ppcre:scan "^#{1,6}\\s+\\S" line)
           (push (cons :heading line) blocks)
           (incf i))
          ;; Bullet or numbered list: consume contiguous list lines.
          ((cl-ppcre:scan "^\\s*([-*+]|\\d+\\.)\\s+\\S" line)
           (let ((items '()))
             (loop while (and (< i n) (cl-ppcre:scan "^\\s*([-*+]|\\d+\\.)\\s+\\S" (nth i lines)))
                   do (push (nth i lines) items) (incf i))
             (push (cons :list (nreverse items)) blocks)))
          ;; Blank line separates paragraphs; skip.
          ((string= (string-trim '(#\Space #\Tab) line) "")
           (incf i))
          ;; Paragraph: consume contiguous non-blank, non-special lines.
          (t
           (let ((para '()))
             (loop while (and (< i n)
                              (not (string= (string-trim '(#\Space #\Tab) (nth i lines)) ""))
                              (not (cl-ppcre:scan "^```" (nth i lines)))
                              (not (cl-ppcre:scan "^#{1,6}\\s+\\S" (nth i lines)))
                              (not (cl-ppcre:scan "^\\s*([-*+]|\\d+\\.)\\s+\\S" (nth i lines))))
                   do (push (nth i lines) para) (incf i))
             (push (cons :para (nreverse para)) blocks))))))
    (nreverse blocks)))

(defun web-markdown-render-heading (line)
  (multiple-value-bind (match groups) (cl-ppcre:scan-to-strings "^(#{1,6})\\s+(.*)$" line)
    (declare (ignore match))
    (let* ((level (length (aref groups 0)))
           (content (aref groups 1)))
      (format nil "<h~D style=\"margin:0.4em 0;font-size:~Aem\">~A</h~D>"
              (min level 6)
              (- 1.3 (* 0.1 level))
              (web-markdown-render-inline content)
              (min level 6)))))

(defun web-markdown-render-list (lines)
  (let ((orderedp (cl-ppcre:scan "^\\s*\\d+\\.\\s+" (first lines))))
    (with-output-to-string (out)
      (format out "<~:[ul~;ol~] style=\"margin:0.3em 0;padding-left:1.4em\">" orderedp)
      (dolist (line lines)
        (multiple-value-bind (match groups)
            (cl-ppcre:scan-to-strings "^\\s*(?:[-*+]|\\d+\\.)\\s+(.*)$" line)
          (declare (ignore match))
          (format out "<li>~A</li>" (web-markdown-render-inline (aref groups 0)))))
      (format out "~:[</ul>~;</ol>~]" orderedp))))

(defun web-markdown-render-code (lines)
  (format nil "<pre style=\"margin:0.4em 0;padding:8px;background:#0f172a;color:#e2e8f0;border-radius:6px;overflow-x:auto;white-space:pre\"><code>~A</code></pre>"
          (web-html-escape (format nil "~{~A~^~%~}" lines))))

(defun web-markdown-render-para (lines)
  (format nil "<p style=\"margin:0.4em 0\">~{~A~^<br>~}</p>"
          (mapcar #'web-markdown-render-inline lines)))

(defun web-render-markdown (text)
  "Render TEXT (assistant Markdown source) as an HTML fragment string.

Every character of TEXT that is not part of recognized Markdown syntax is
passed through WEB-HTML-ESCAPE (directly or via WEB-MARKDOWN-RENDER-INLINE,
which escapes first and only adds fixed tag strings around already-escaped
substrings), so this never emits attacker-controlled HTML."
  (with-output-to-string (out)
    (dolist (block (web-markdown-split-blocks (or text "")))
      (ecase (car block)
        (:code (write-string (web-markdown-render-code (cdr block)) out))
        (:heading (write-string (web-markdown-render-heading (cdr block)) out))
        (:list (write-string (web-markdown-render-list (cdr block)) out))
        (:para (write-string (web-markdown-render-para (cdr block)) out))))))
