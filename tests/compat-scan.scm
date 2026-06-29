(import (scheme base)
  (scheme process-context)
  (scheme file)
  (scheme write)
  (srfi 64)
  (kons util)
  (kons manifest)
  (kons actions activation translate)
  (kons actions compat-scan))

(test-begin "kons compat scan")

(define root "/tmp/kons-compat-scan-test")
(define dep-root (path-join root "deps/provider"))

(define (write-file path text)
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (read-text path)
  (call-with-input-file path
    (lambda (in)
      (let loop ((chars '()))
        (let ((ch (read-char in)))
          (if (eof-object? ch)
            (list->string (reverse chars))
            (loop (cons ch chars))))))))

(define (diagnostic-with-import diagnostics name)
  (let loop ((items diagnostics))
    (cond
      ((null? items) #f)
      ((equal? name (compat-diagnostic-import-name (car items))) (car items))
      (else (loop (cdr items))))))

(define (compat-diagnostic-import-name diagnostic)
  (compat-import-name (compat-diagnostic-import diagnostic)))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "mkdir -p "
              (shell-quote (path-join root "src/example"))
              " "
              (shell-quote (path-join dep-root "src/example"))))

(write-file
  (path-join root "kons.scm")
  "(package
  (name (example compat))
  (version \"0.1.0\")
  (source-path \"src\")
  (dialects r6rs))

(dependencies)
(dev-dependencies)
")

(write-file
  (path-join root "src/example/lib.sls")
  "(library (example lib)
  (export value)
  (import (rnrs))
  (begin (define value 1)))
")

(write-file
  (path-join root "src/example/app.sls")
  "(library (example app)
  (export run)
  (import (rnrs) (scheme base) (example lib) (missing lib))
  (begin (define (run) value)))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (report (compat-scan-report manifest '() 'chez))
       (diagnostics (compat-report-diagnostics report))
       (rnrs (diagnostic-with-import diagnostics '(rnrs)))
       (scheme-base (diagnostic-with-import diagnostics '(scheme base)))
       (example-lib (diagnostic-with-import diagnostics '(example lib)))
       (missing-lib (diagnostic-with-import diagnostics '(missing lib))))
  (test-equal
    "chez supports rnrs imports"
    'provided
    (compat-diagnostic-status rnrs))
  (test-equal
    "chez marks r7rs library unsupported"
    'implementation-unsupported
    (compat-diagnostic-status scheme-base))
  (test-equal
    "local provider is compatible"
    'provided
    (compat-diagnostic-status example-lib))
  (test-equal
    "unknown provider is missing"
    'missing
    (compat-diagnostic-status missing-lib))
  (test-assert
    "unsupported import advice suggests compatible implementation"
    (string-contains? (compat-diagnostic-advice scheme-base)
      "compatible Scheme implementation"))
  (test-assert
    "missing import advice suggests adding dependency"
    (string-contains? (compat-diagnostic-advice missing-lib)
      "add a dependency")))

(write-file
  (path-join dep-root "kons.scm")
  "(package
  (name (example dep))
  (version \"0.1.0\")
  (source-path \"src\")
  (dialects r6rs))

(dependencies)
(dev-dependencies)
")

(write-file
  (path-join dep-root "src/example/dep.sls")
  "(library (example dep)
  (export dep-value)
  (import (rnrs))
  (begin (define dep-value 1)))
")

(write-file
  (path-join root "kons.scm")
  "(package
  (name (example compat))
  (version \"0.1.0\")
  (source-path \"src\")
  (dialects r6rs))

(dependencies
  (path (name (example dep)) (path \"deps/provider\")))
(dev-dependencies)
")

(write-file
  (path-join root "src/example/app.sls")
  "(library (example app)
  (export run)
  (import (rnrs) (example dep) (missing lib))
  (begin (define (run) dep-value)))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (report (compat-scan-report manifest '() 'chez))
       (diagnostics (compat-report-diagnostics report))
       (example-dep (diagnostic-with-import diagnostics '(example dep)))
       (missing-lib (diagnostic-with-import diagnostics '(missing lib))))
  (test-equal
    "compat-scan reports unresolved dependency without activation"
    'missing
    (compat-diagnostic-status example-dep))
  (test-equal
    "compat-scan keeps missing dependency"
    'missing
    (compat-diagnostic-status missing-lib)))

(run-command
  (string-append "rm -f "
    (shell-quote (path-join root "src/example/app.sls"))
    " "
    (shell-quote (path-join root "src/example/lib.sls"))))

(write-file
  (path-join root "kons.scm")
  "(package
  (name (example compat))
  (version \"0.1.0\")
  (source-path \"src\")
  (dialects r7rs))

(dependencies)
(dev-dependencies)
")

(write-file
  (path-join root "src/example/app.sld")
  "(define-library (example app)
  (export run)
  (import (scheme base)
          (only (scheme lazy) delay force)
          (scheme lazy)
          (scheme time)
          (scheme load)
          (scheme repl))
  (unsupported-declaration value)
  (begin
    (define delayed-value (delay 'ok))
    (define (run) (force delayed-value))))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (report (compat-scan-report manifest '() 'mosh))
       (translation (compat-report-translations report))
       (library (car (translation-report-libraries translation)))
       (diagnostics (compat-report-diagnostics report))
       (scheme-base (diagnostic-with-import diagnostics '(scheme base)))
       (scheme-lazy (diagnostic-with-import diagnostics '(scheme lazy))))
  (test-assert
    "compat-scan translation report is active"
    (translation-report-active? translation))
  (test-equal
    "compat-scan translation report has unsupported declaration"
    1
    (length (translation-library-report-unsupported library)))
  (test-equal
    "compat-scan translated scheme base is provided"
    'provided
    (compat-diagnostic-status scheme-base))
  (test-equal
    "compat-scan translated scheme lazy is provided"
    'provided
    (compat-diagnostic-status scheme-lazy)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons compat scan")
  (exit (if (= failures 0) 0 1)))
