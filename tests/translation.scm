(import (scheme base)
  (scheme file)
  (srfi 64)
  (kons util)
  (kons manifest)
  (kons runner)
  (kons library-discovery)
  (kons actions activation translate))

(test-begin "kons R7RS to R6RS translation")

(define root "/tmp/kons-translation-test")
(define source-root (path-join root "src"))
(define build-root (path-join root "build"))
(define runtime-root "/tmp/kons-translation-runtime-test")
(define runtime-source-root (path-join runtime-root "src"))
(define runtime-build-root (path-join runtime-root "build"))
(define install-root "/tmp/kons-translation-install-root")
(define bad-root "/tmp/kons-translation-bad-test")
(define bad-source-root (path-join bad-root "src"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (activation-source-roots metadata)
  (let ((entry (assoc 'source-roots (cdr metadata))))
    (if entry (cdr entry) '())))

(define (translated-library-installed? roots name)
  (let loop ((items roots))
    (and (pair? items)
      (or (file-exists? (r6rs-library-source-path (car items) name))
        (loop (cdr items))))))

(define (unsupported-message-member? unsupported text)
  (let loop ((items unsupported))
    (cond
      ((null? items) #f)
      ((string-contains? (unsupported-translation-form-message (car items)) text) #t)
      (else (loop (cdr items))))))

(define preserved-standard-imports
  '((scheme base)
    (scheme case-lambda)
    (scheme char)
    (scheme complex)
    (scheme cxr)
    (scheme eval)
    (scheme file)
    (scheme inexact)
    (scheme process-context)
    (scheme read)
    (scheme write)
    (scheme r5rs)
    (scheme lazy)
    (scheme time)
    (scheme load)
    (scheme repl)))

(define unmapped-standard-imports
  '((not-scheme base)))

(for-each
  (lambda (name)
    (test-equal
      (string-append
        "standard import preserved "
        (call-with-output-string
          (lambda (out) (write name out))))
      (list name)
      (r7rs-standard-library->r6rs-imports name)))
  preserved-standard-imports)

(for-each
  (lambda (name)
    (test-equal
      (string-append
        "standard import intentionally unmapped "
        (call-with-output-string
          (lambda (out) (write name out))))
      #f
      (r7rs-standard-library->r6rs-imports name)))
  unmapped-standard-imports)

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "rm -rf " (shell-quote runtime-root)))
(run-command (string-append "rm -rf " (shell-quote install-root)))
(run-command (string-append "rm -rf " (shell-quote bad-root)))

(write-file
  (path-join root "kons.scm")
  "(package
  (name (example translated))
  (version \"0.1.0\")
  (dialects r7rs)
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
  (path-join source-root "example/decls.scm")
  "(export extra)
(begin
  (define extra 'included-declaration))
")

(write-file
  (path-join source-root "example/body.scm")
  "(define body-value 'included-body)
")

(write-file
  (path-join source-root "example/case-body.scm")
  "(DEFINE CASE-FOLDED-VALUE 'INCLUDED-BODY)
")

(write-file
  (path-join source-root "example/translated.sld")
  "(define-library (example translated)
  (export main (rename hidden public-hidden))
  (import (scheme base)
          (only (scheme write) write)
          (except (scheme base) string?)
          (prefix (scheme write) out:)
          (rename (scheme base) (car first))
          (scheme read)
          (scheme file)
          (scheme process-context)
          (scheme cxr)
          (scheme complex)
          (scheme case-lambda)
          (srfi 1)
          (for fun)
          (library reserved)
          (only (scheme lazy) delay force)
          (example dep))
  (include-library-declarations \"decls.scm\")
  (cond-expand
    (r7rs (begin (define target 'wrong)))
    ((library (example missing-translation-branch))
     (begin (define target 'missing-library-branch)))
    ((library (scheme base))
     (begin (define target 'standard-library-branch)))
    (r6rs (begin (define target 'r6rs)))
    (else (begin (define target 'else))))
  (include \"body.scm\")
  (include-ci \"case-body.scm\")
  (begin
    (define hidden 'renamed-export)
    (define (main) target)))
")

(let ((manifest (parse-manifest (path-join root "kons.scm"))))
  (test-assert
    "R6RS-only implementation activates translation"
    (r7rs->r6rs-translation-active-for-scheme? manifest 'mosh))
  (test-equal
    "adapter falls back to R6RS implementation mode"
    'mosh
    (adapter-scheme manifest 'mosh))
  (let ((report (r7rs->r6rs-translation-report manifest '(default) 'mosh build-root)))
    (test-assert "translation report is active" (translation-report-active? report))
    (test-equal
      "translation report has one library"
      1
      (length (translation-report-libraries report)))
    (let ((library (car (translation-report-libraries report))))
      (test-equal
        "translation report source"
        (path-join source-root "example/translated.sld")
        (translation-library-report-source library))
      (test-equal
        "translation report output"
        (r6rs-library-source-path build-root '(example translated))
        (translation-library-report-output library))
      (test-equal
        "translation report has no unsupported forms"
        '()
        (translation-library-report-unsupported library))))
  (write-r7rs->r6rs-translations-for-scheme! manifest '(default) 'mosh build-root)
  (let* ((output (r6rs-library-source-path build-root '(example translated)))
         (forms (read-all-exprs output)))
    (test-assert "translated output exists" (file-exists? output))
    (test-equal
      "translated library form"
      '((library (example translated)
         (export main (rename (hidden public-hidden)) extra)
         (import (scheme base)
          (only (scheme write) write)
          (except (scheme base) string?)
          (prefix (scheme write) out:)
          (rename (scheme base) (car first))
          (scheme read)
          (scheme file)
          (scheme process-context)
          (scheme cxr)
          (scheme complex)
          (scheme case-lambda)
          (srfi :1)
          (library (for fun))
          (library (library reserved))
          (only (scheme lazy) delay force)
          (example dep))
         (define extra 'included-declaration)
         (define target 'standard-library-branch)
         (define body-value 'included-body)
         (define case-folded-value 'included-body)
         (define hidden 'renamed-export)
         (define (main) target)))
      forms)))

(write-file
  (path-join source-root "example/1/numeric.sld")
  "(define-library (example 1 numeric)
  (export value)
  (import (scheme base) (example 2 dep))
  (begin (define value 1)))
")

(let ((manifest (parse-manifest (path-join root "kons.scm"))))
  (write-r7rs->r6rs-translations-for-scheme! manifest '(default) 'mosh build-root)
  (let* ((output (r6rs-library-source-path build-root '(example :1 numeric)))
         (forms (read-all-exprs output)))
    (test-assert "translated numeric library output exists" (file-exists? output))
    (test-equal
      "translated numeric library name and import"
      '((library (example :1 numeric)
         (export value)
         (import (scheme base) (example :2 dep))
         (define value 1)))
      forms)))

(write-file
  (path-join bad-root "kons.scm")
  "(package
  (name (example bad-translation))
  (version \"0.1.0\")
  (dialects r7rs)
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
  (path-join bad-source-root "example/bad-translation.sld")
  "(define-library (example bad-translation)
  (export value (prefix value bad:))
  (import (scheme base) (scheme lazy) (scheme time) (scheme load) (scheme repl))
  (unsupported-declaration value)
  (begin (define value 1)))
")

(let* ((manifest (parse-manifest (path-join bad-root "kons.scm")))
       (report (r7rs->r6rs-translation-report manifest '(default) 'mosh (path-join bad-root "build")))
       (library (car (translation-report-libraries report)))
       (unsupported (translation-library-report-unsupported library)))
  (test-equal "unsupported translation report count" 2 (length unsupported))
  (test-assert
    "unsupported export report message"
    (unsupported-message-member?
      unsupported
      "unsupported R7RS export spec"))
  (test-assert
    "unsupported declaration report message"
    (unsupported-message-member?
      unsupported
      "unsupported R7RS library declaration")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons R7RS to R6RS translation")
  (exit (if (= failures 0) 0 1)))
