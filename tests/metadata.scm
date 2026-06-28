(import (scheme base)
  (scheme file)
  (scheme process-context)
  (srfi 64)
  (kons manifest)
  (kons library-discovery)
  (kons util))

(test-begin "kons metadata")

(define root "/tmp/kons-metadata-test")
(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
  (path-join root "kons.scm")
  "(package
  (name (example metadata))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
  (path-join root "src/example/metadata.sld")
  "(define-library (example metadata)
  (export run (rename hidden public-hidden))
  (import (scheme base))
  (begin
    (define hidden 1)
    (define (run) hidden)))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (entry (car (effective-package-libraries manifest))))
  (test-equal "metadata library name" '(example metadata) (cadr entry))
  (test-equal "metadata library imports" '((scheme base)) (library-entry-imports entry))
  (test-equal "metadata library exports" '(run public-hidden) (library-entry-exports entry)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons metadata")
  (exit (if (= failures 0) 0 1)))
