(import (scheme base)
  (scheme file)
  (scheme process-context)
  (srfi 64)
  (kons akku config)
  (kons util))

(test-begin "kons Akku config")

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (delete-file-if-exists path)
  (when (file-exists? path)
    (delete-file path)))

(delete-file-if-exists (akku-sources-path))

(test-equal "default Akku source alias" "akku" default-akku-source-alias)
(test-equal
  "Akku metadata cache root"
  (path-join (path-join (kons-store-root) "akku") "metadata")
  (akku-metadata-root))
(test-equal
  "Akku source cache root"
  (path-join (path-join (kons-store-root) "akku") "sources")
  (akku-sources-root))

(write-file
  (akku-sources-path)
  "(akku-sources
  (source
    (name \"akku\")
    (url \"file:///tmp/kons-akku-config-source\")))
")

(test-equal
  "Akku source override keeps trailing slash"
  "file:///tmp/kons-akku-config-source/"
  (akku-source-url default-akku-source-alias))

(delete-file-if-exists (akku-sources-path))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku config")
  (unless (= failures 0)
    (exit #f)))
