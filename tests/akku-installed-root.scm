(import (scheme base)
  (scheme file)
  (scheme write)
  (srfi 64)
  (kons util)
  (kons dep akku))

(test-begin "kons Akku installed root")

(define root "/tmp/kons-akku-installed-root-test")
(define source-root (path-join root "source"))
(define installed-root (path-join root "installed"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (contains-symbol? expr needle)
  (cond
    ((symbol? expr) (eq? expr needle))
    ((pair? expr)
      (or (contains-symbol? (car expr) needle)
        (contains-symbol? (cdr expr) needle)))
    (else #f)))

(define (definition-value expr name)
  (cond
    ((not (pair? expr)) #f)
    ((and (eq? (car expr) 'define)
       (pair? (cdr expr))
       (eq? (cadr expr) name)
       (pair? (cddr expr)))
      (caddr expr))
    (else
      (or (definition-value (car expr) name)
        (definition-value (cdr expr) name)))))

(define (maybe-unquote expr)
  (if (and (pair? expr)
        (eq? (car expr) 'quote)
        (pair? (cdr expr)))
    (cadr expr)
    expr))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "mkdir -p " (shell-quote source-root)))

(write-file
  (path-join source-root "base.sls")
  "(library (akku-r7rs base)
  (export base-selected)
  (import (rnrs))
  (define base-selected #t))
")

(write-file
  (path-join source-root "scheme/base.sls")
  "(library (scheme base)
  (export generic-selected)
  (import (rnrs))
  (define generic-selected #t))
")

(write-file
  (path-join source-root "scheme/base.guile.sls")
  "(library (scheme base)
  (export guile-selected)
  (import (rnrs))
  (define guile-selected #t))
")

(write-file
  (path-join source-root "include.sls")
  "(library (sample include)
  (export included)
  (import (rnrs))
  (include \"body.scm\"))
")

(write-file
  (path-join source-root "body.scm")
  "(define included 'ok)
")

(prepare-akku-installed-root!
  installed-root
  `((package
     (type akku)
     (scope runtime)
     (name "fake-akku")
     (version "1.0.0")
     (source-cache-path ,source-root)))
  'chez)

(test-assert "materializes akku-r7rs library path"
  (file-exists? (path-join installed-root "akku-r7rs/base.sls")))

(test-assert "materializes scheme library path"
  (file-exists? (path-join installed-root "scheme/base.sls")))

(let ((scheme-base (car (read-all-exprs (path-join installed-root "scheme/base.sls")))))
  (test-assert "Chez installed root keeps generic variant"
    (contains-symbol? scheme-base 'generic-selected))
  (test-assert "Chez installed root ignores non-target variant"
    (not (contains-symbol? scheme-base 'guile-selected))))

(let* ((metadata (car (read-all-exprs (path-join installed-root "akku/metadata.sls"))))
       (libraries (maybe-unquote (definition-value metadata 'installed-libraries)))
       (assets (maybe-unquote (definition-value metadata 'installed-assets))))
  (test-assert "metadata lists akku-r7rs base"
    (member '(akku-r7rs base) libraries))
  (test-assert "metadata lists scheme base"
    (member '(scheme base) libraries))
  (test-equal "metadata records include asset"
    '(((include "body.scm") ("sample/body.scm")))
    assets)
  (test-assert "metadata does not export search-paths"
    (not (contains-symbol? metadata 'search-paths))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku installed root")
  (exit (if (= failures 0) 0 1)))
