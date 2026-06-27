(import (scheme base)
        (scheme file)
        (scheme process-context)
        (srfi 64)
        (kons akku config)
        (kons registry)
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
(delete-file-if-exists (registries-path))

(test-equal "default Akku source alias" "akku" default-akku-source-alias)
(test-equal
 "default Akku source URL"
 "https://archive.akkuscm.org/archive/"
 (akku-source-url default-akku-source-alias))
(test-equal
 "Kons default registry URL remains unchanged"
 default-registry-url
 (registry-name->url default-registry-alias))
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
    (url \"https://mirror.example.invalid/archive\")))
")

(write-file
 (registries-path)
 "(registries
  (registry
    (name \"default\")
    (url \"https://registry.example.invalid\")
    (default #t)))
")

(test-equal
 "Akku source override keeps trailing slash"
 "https://mirror.example.invalid/archive/"
 (akku-source-url default-akku-source-alias))
(test-equal
 "Akku override does not affect Kons default registry"
 "https://registry.example.invalid"
 (registry-name->url default-registry-alias))

(write-file
 (akku-sources-path)
 "(not-akku-sources
  (source
    (name \"akku\")
    (url \"https://bad.example.invalid/archive/\")))
")

(test-equal
 "malformed Akku source config keeps default source"
 "https://archive.akkuscm.org/archive/"
 (akku-source-url default-akku-source-alias))

(delete-file-if-exists (akku-sources-path))
(delete-file-if-exists (registries-path))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku config")
  (unless (= failures 0)
    (exit #f)))
