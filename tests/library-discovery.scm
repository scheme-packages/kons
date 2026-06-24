(import (scheme base)
        (scheme process-context)
        (scheme file)
        (scheme write)
        (srfi 64)
        (kons util)
        (kons manifest)
        (kons library-discovery))

(test-begin "kons library discovery")

(define root "/tmp/kons-library-discovery-test")

(define (write-file path text)
  (call-with-output-file path
    (lambda (out) (display text out))))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "mkdir -p " (shell-quote (path-join root "src/example"))))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example lib))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join root "src/example/lib.sld")
 "(define-library (example lib)
  (export message (rename internal public-name))
  (import (scheme base) (scheme write))
  (include-ci \"case-imports.scm\")
  (begin
    (define (message) \"ok\")
    (define internal 1)))
")

(write-file
 (path-join root "src/example/case-imports.scm")
 "(IMPORT (ONLY (EXAMPLE DEP) RUN))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (libraries (effective-package-libraries manifest))
       (entry (car libraries)))
  (test-equal "discovered library kind" 'r7rs (car entry))
  (test-equal "discovered library name" '(example lib) (cadr entry))
  (test-equal "discovered imports" '((scheme base) (scheme write) (example dep)) (library-entry-imports entry))
  (test-equal
   "discovered import specs preserve include-ci folding"
   '((scheme base) (scheme write) (only (example dep) run))
   (library-entry-import-specs/context (manifest-source-root manifest) entry #f))
  (test-equal "discovered exports" '(message public-name) (library-entry-exports entry))
  (test-equal
   "public libraries include metadata"
   '((r7rs (example lib)
           (path "/tmp/kons-library-discovery-test/src/example/lib.sld")
           (imports (scheme base) (scheme write) (example dep))
           (exports message public-name)))
   (effective-public-package-libraries manifest)))

(write-file
 (path-join root "src/example/r6.sls")
 "(library (example r6)
  (export run (rename hidden public-hidden))
  (import (rnrs))
  (begin
    (define (run) 'ok)
    (define hidden 1)))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (libraries (effective-package-libraries manifest))
       (entry (library-key-entry (cons 'r6rs '(example r6)) libraries)))
  (test-assert "discovers R6RS libraries" entry)
  (test-equal "R6RS discovered path"
              "/tmp/kons-library-discovery-test/src/example/r6.sls"
              (library-entry-path "" entry))
  (test-equal "R6RS discovered imports" '((rnrs)) (library-entry-imports entry))
  (test-equal "R6RS discovered exports" '(run public-hidden) (library-entry-exports entry)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons library discovery")
  (exit (if (= failures 0) 0 1)))
