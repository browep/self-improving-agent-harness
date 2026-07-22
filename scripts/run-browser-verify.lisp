;;;; Standalone runner for the CLOG web UI browser integration verification
;;;; (GitHub issue #42).
;;;;
;;;; This loads the self-improving-agent-harness system and the standalone
;;;; integration test, then runs the end-to-end verification flow against the
;;;; real CLOG web UI at http://localhost:18080/. It writes a verification
;;;; artifact bundle (screenshots, DOM snapshots, console log, manifest) under
;;;; /tmp/browser-verify/<run-id>/ and exits non-zero if any assertion failed.
;;;;
;;;; Usage:
;;;;   sbcl --noinform --non-interactive \
;;;;     --load /opt/quicklisp/setup.lisp \
;;;;     --load scripts/run-browser-verify.lisp
;;;;
;;;; Requirements:
;;;;   - The CLOG web UI must be running (scripts/web.lisp on :18080).
;;;;   - Node + Playwright + headless Chromium must be available (the
;;;;     playwright-bridge.js subprocess is spawned on demand).

(require :asdf)
(asdf:load-asd (merge-pathnames "self-improving-agent-harness.asd"
                               (uiop:getcwd)))
(asdf:load-system :self-improving-agent-harness)

;; Load the standalone integration test (it is intentionally NOT compiled into
;; the test system's normal RUN-TESTS path, because it needs a live browser +
;; CLOG server).
(load (merge-pathnames
       "tests/tooling/browser/harness-web-ui/harness-web-ui-integration.lisp"
       (uiop:getcwd)))

(let ((output-dir (or (uiop:getenv "BROWSER_VERIFY_OUTPUT_DIR")
                      "/tmp/browser-verify")))
  (ensure-directories-exist output-dir)
  (multiple-value-bind (passp bundle-dir)
      (self-improving-agent-harness/tests:run-browser-verification-test
       :output-dir output-dir)
    (format t "~&[run-browser-verify] pass=~A bundle=~A~%" passp bundle-dir)
    (unless passp
      (uiop:quit 1))))
