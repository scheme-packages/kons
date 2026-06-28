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
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
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

(write-file
  (path-join root "src/example/variant.sls")
  "(library (example variant)
  (export generic)
  (import (rnrs))
  (define (generic) 'ok))
")

(write-file
  (path-join root "src/example/variant.chez.sls")
  "(library (example variant)
  (export chez-only)
  (import (rnrs))
  (define (chez-only) 'ok))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (libraries (effective-package-libraries manifest))
       (variants (filter
                  (lambda (entry)
                    (and (eq? (car entry) 'r6rs)
                      (equal? (cadr entry) '(example variant))))
                  libraries))
       (r6rs-library-available? (lambda (name) (equal? name '(rnrs))))
       (chez-context (make-library-discovery-context '(chez r6rs) r6rs-library-available?))
       (capy-context (make-library-discovery-context '(capy r6rs) r6rs-library-available?))
       (chez-libraries (effective-package-libraries/context manifest chez-context))
       (capy-libraries (effective-package-libraries/context manifest capy-context))
       (chez-entry (library-key-entry (cons 'r6rs '(example variant)) chez-libraries))
       (capy-entry (library-key-entry (cons 'r6rs '(example variant)) capy-libraries)))
  (test-equal "discovers generic and implementation-specific variants" 2 (length variants))
  (test-equal "implementation-specific variant records implementation"
    'chez
    (library-entry-implementation
      (library-key-entry
        (cons 'r6rs '(example variant))
        (filter (lambda (entry) (library-entry-implementation entry)) variants))))
  (test-equal "Chez context selects implementation-specific variant"
    "/tmp/kons-library-discovery-test/src/example/variant.chez.sls"
    (library-entry-path "" chez-entry))
  (test-equal "non-Chez context selects generic variant"
    "/tmp/kons-library-discovery-test/src/example/variant.sls"
    (library-entry-path "" capy-entry))
  (test-assert "public libraries expose implementation metadata"
    (library-key-entry
      (cons 'r6rs '(example variant))
      (filter (lambda (entry)
                (eq? (library-entry-implementation entry) 'chez))
        (effective-public-package-libraries manifest)))))

(write-file
  (path-join root "src/example/import-inferred.sls")
  "(library (example import-inferred)
  (export value)
  (import (rnrs) (chezscheme))
  (define value 1))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (entry (library-key-entry
               (cons 'r6rs '(example import-inferred))
               (effective-package-libraries manifest))))
  (test-equal "infers implementation from implementation-specific imports"
    'chez
    (library-entry-implementation entry)))

(write-file
  (path-join root "src/example/capy-import-inferred.sld")
  "(define-library (example capy-import-inferred)
  (export value)
  (import (scheme base) (capy internals))
  (begin (define value 1)))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (entry (library-key-entry
               (cons 'r7rs '(example capy-import-inferred))
               (effective-package-libraries manifest))))
  (test-equal "infers Capy implementation from implementation-specific imports"
    'capy
    (library-entry-implementation entry)))

(for-each
  (lambda (item)
    (let ((impl (car item))
          (prefix (cadr item))
          (name (list 'example (string->symbol
                                (string-append
                                  (symbol->string (car item))
                                  "-prefix-inferred")))))
      (write-file
        (path-join root
          (string-append
            "src/example/"
            (symbol->string impl)
            "-prefix-inferred.sld"))
        (string-append
          "(define-library "
          (call-with-output-string (lambda (out) (write name out)))
          "\n"
          "  (export value)\n"
          "  (import (scheme base) ("
          (symbol->string prefix)
          " internals))\n"
          "  (begin (define value 1)))\n"))))
  '((chibi chibi)
    (cyclone cyclone)
    (gauche gauche)
    (guile guile)
    (ironscheme ironscheme)
    (kawa kawa)
    (loko loko)
    (mit mit)
    (mosh mosh)
    (sagittarius sagittarius)
    (skint skint)
    (stklos stklos)))

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (libraries (effective-package-libraries manifest)))
  (for-each
    (lambda (impl)
      (let ((name (list 'example (string->symbol
                                  (string-append
                                    (symbol->string impl)
                                    "-prefix-inferred")))))
        (test-equal
          (string-append
            "infers "
            (symbol->string impl)
            " implementation from implementation-specific imports")
          impl
          (library-entry-implementation
            (library-key-entry (cons 'r7rs name) libraries)))))
    '(chibi cyclone gauche guile ironscheme kawa loko mit mosh sagittarius skint stklos)))

(define multi-root "/tmp/kons-library-discovery-multi-test")
(run-command (string-append "rm -rf " (shell-quote multi-root)))

(write-file
  (path-join multi-root "kons.scm")
  "(package
  (name (example multi))
  (version \"0.1.0\")
  (source-path \"src\")
  (main \"main.scm\"))

(dependencies)
(dev-dependencies)
")

(write-file
  (path-join multi-root "src/example/bundle.sld")
  "(define-library (example one)
  (export one)
  (import (scheme base))
  (begin (define (one) \"one\")))

(define-library (example two)
  (export two)
  (import (scheme base))
  (begin (define (two) \"two\")))
")

(write-file
  (path-join multi-root "src/main.scm")
  "(import (scheme base)
          (scheme write)
          (example one)
          (example two))
(display (one))
(display \"/\")
(display (two))
(newline)
")

(let* ((manifest (parse-manifest (path-join multi-root "kons.scm")))
       (libraries (effective-package-libraries manifest)))
  (test-assert "discovers first library from multi-library file"
    (library-key-entry (cons 'r7rs '(example one)) libraries))
  (test-assert "discovers second library from multi-library file"
    (library-key-entry (cons 'r7rs '(example two)) libraries)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons library discovery")
  (exit (if (= failures 0) 0 1)))
