(in-package #:self-improving-agent-harness/tests)

;;; Unit tests for the Lisp-only Markdown -> HTML renderer added for issue
;;; #50 ("web-ui: show markdown rendered text for responses that contain
;;; it"). See src/web-markdown.lisp for the security model this relies on:
;;; raw Markdown source is always HTML-escaped before any tag is added
;;; around it, so these tests also assert that escaping survives rendering.

(defun run-web-markdown-tests ()
  ;; --- web-markdown-text-p: detection heuristic --------------------------
  (ensure-true (not (self-improving-agent-harness::web-markdown-text-p "plain prose, nothing special."))
               "plain prose is not detected as Markdown")
  (ensure-true (not (self-improving-agent-harness::web-markdown-text-p nil))
               "nil text is not detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p "before **bold** after")
               "bold emphasis is detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p "a *single* star italic")
               "single-star italic is detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p "inline `code` span")
               "inline code span is detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p (format nil "# Heading~%text"))
               "an ATX heading is detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p (format nil "- one~%- two"))
               "a bullet list is detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p (format nil "1. one~%2. two"))
               "a numbered list is detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p (format nil "```~%code~%```"))
               "a fenced code block is detected as Markdown")
  (ensure-true (self-improving-agent-harness::web-markdown-text-p "see [a link](https://example.com)")
               "a Markdown link is detected as Markdown")

  ;; --- web-render-markdown: structural conversion -------------------------
  (ensure-true (search "<strong>bold</strong>"
                       (self-improving-agent-harness::web-render-markdown "before **bold** after"))
               "bold emphasis renders as <strong>")
  (ensure-true (search "<em>italic</em>"
                       (self-improving-agent-harness::web-render-markdown "a *italic* word"))
               "single-star emphasis renders as <em>")
  (ensure-true (search "<code>x = 1</code>"
                       (self-improving-agent-harness::web-render-markdown "set `x = 1` please"))
               "inline code renders as <code>")
  (let ((html (self-improving-agent-harness::web-render-markdown (format nil "# Title~%body text"))))
    (ensure-true (search "<h1" html) "an ATX H1 heading renders as an <h1> tag")
    (ensure-true (search "Title" html) "heading text is preserved"))
  (let ((html (self-improving-agent-harness::web-render-markdown (format nil "- one~%- two~%- three"))))
    (ensure-true (search "<ul" html) "a bullet list renders as a <ul>")
    (ensure-true (search "<li>one</li>" html) "each bullet item renders as an <li>")
    (ensure-true (search "<li>two</li>" html) "list order is preserved (item 2)")
    (ensure-true (search "<li>three</li>" html) "list order is preserved (item 3)"))
  (let ((html (self-improving-agent-harness::web-render-markdown (format nil "1. first~%2. second"))))
    (ensure-true (search "<ol" html) "a numbered list renders as an <ol>")
    (ensure-true (search "<li>first</li>" html) "numbered list item text renders correctly"))
  (let ((html (self-improving-agent-harness::web-render-markdown
               (format nil "before~%```~%line one~%line two~%```~%after"))))
    (ensure-true (search "<pre" html) "a fenced code block renders as <pre>")
    (ensure-true (search "line one" html) "fenced code block content line 1 is preserved")
    (ensure-true (search "line two" html) "fenced code block content line 2 is preserved"))
  (let ((html (self-improving-agent-harness::web-render-markdown "see [a link](https://example.com/x)")))
    (ensure-true (search "<a href=\"https://example.com/x\"" html)
                 "a Markdown link renders as an <a href=...> tag")
    (ensure-true (search ">a link</a>" html) "link label text is preserved"))

  ;; --- Security: raw Markdown source is always HTML-escaped --------------
  (let ((html (self-improving-agent-harness::web-render-markdown
               "before **<script>alert(1)</script>** after")))
    (ensure-true (not (search "<script>" html))
                 "a literal <script> tag inside Markdown source is never emitted unescaped")
    (ensure-true (search "&lt;script&gt;" html)
                 "the escaped form of the injected tag text is present instead"))
  (let ((html (self-improving-agent-harness::web-render-markdown
               "click [x](javascript:alert(1)\"onmouseover=\"alert(2))")))
    (ensure-true (not (search "\"onmouseover=\"alert" html))
                 "a raw double-quote inside a link URL cannot break out of the href attribute"))
  (let ((html (self-improving-agent-harness::web-render-markdown "line with <b>raw html</b> in prose")))
    (ensure-true (not (search "<b>raw html</b>" html))
                 "raw HTML embedded in a plain paragraph is escaped, not passed through")
    (ensure-true (search "&lt;b&gt;raw html&lt;/b&gt;" html)
                 "the escaped form of the embedded raw HTML is present instead"))

  ;; --- Plain-prose fallback: unaffected by non-Markdown-looking input -----
  (let ((html (self-improving-agent-harness::web-render-markdown "just some plain text, nothing fancy")))
    (ensure-true (search "just some plain text, nothing fancy" html)
                 "plain prose without Markdown markers still renders (as an escaped paragraph)"))

  (format t "Web-markdown tests passed.~%")
  t)
