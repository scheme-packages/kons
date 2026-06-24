(import (scheme base)
        (scheme process-context)
        (scheme file)
        (scheme write)
        (srfi 64)
        (kons util)
        (kons manifest)
        (kons actions compat-scan))

(test-begin "kons compat scan")

(define root "/tmp/kons-compat-scan-test")
(define dep-root (path-join root "deps/provider"))

(define (write-file path text)
  (call-with-output-file path
    (lambda (out) (display text out))))

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

(let* ((tmp (temporary-file-path "kons-compat-scan-test-out"))
       (command (string-append
                 "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --scheme chez --manifest "
                 (shell-quote (path-join root "kons.scm"))
                 " compat-scan --format json >"
                 (shell-quote tmp))))
  (test-equal "compat-scan command exits" 0 (shell-command-status command))
  (test-equal
   "compat-scan json shape"
   0
   (shell-command-status
    (string-append
     "node -e 'const fs=require(\"fs\"); const data=JSON.parse(fs.readFileSync(\""
     tmp
     "\",\"utf8\")); if (data.formatVersion !== 1 || data.implementation.scheme !== \"chez\" || !Array.isArray(data.diagnostics) || !data.diagnostics.some((item) => item.advice && item.advice.includes(\"compatible Scheme implementation\"))) process.exit(1)'"))))

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

(let* ((tmp (temporary-file-path "kons-compat-scan-dep-out"))
       (command (string-append
                 "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --scheme chez --manifest "
                 (shell-quote (path-join root "kons.scm"))
                 " compat-scan --format json >"
                 (shell-quote tmp))))
  (test-equal "compat-scan command sees dependency providers"
              0
              (shell-command-status command))
  (test-equal
   "compat-scan marks dependency-provided import as provided"
   0
   (shell-command-status
    (string-append
     "node -e 'const fs=require(\"fs\"); const data=JSON.parse(fs.readFileSync(\""
     tmp
     "\",\"utf8\")); const dep=data.diagnostics.find((item)=>item.import.name.join(\"/\")===\"example/dep\"); const missing=data.diagnostics.find((item)=>item.import.name.join(\"/\")===\"missing/lib\"); if (!dep || dep.status !== \"provided\" || !missing || missing.status !== \"missing\") process.exit(1)'"))))

(let* ((update-command (string-append
                        "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --quiet --scheme chez --manifest "
                        (shell-quote (path-join root "kons.scm"))
                        " update"))
       (fetch-command (string-append
                       "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --quiet --scheme chez --manifest "
                       (shell-quote (path-join root "kons.scm"))
                       " fetch --locked"))
       (tmp (temporary-file-path "kons-compat-scan-locked-dep-out"))
       (scan-command (string-append
                      "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --scheme chez --manifest "
                      (shell-quote (path-join root "kons.scm"))
                      " compat-scan --locked --format json >"
                      (shell-quote tmp))))
  (test-equal "compat-scan locked dependency setup"
              0
              (shell-command-status update-command))
  (test-equal "compat-scan locked dependency materialization"
              0
              (shell-command-status fetch-command))
  (test-equal "compat-scan locked sees dependency providers"
              0
              (shell-command-status scan-command))
  (test-equal
   "compat-scan locked marks locked dependency import as provided"
   0
   (shell-command-status
    (string-append
     "node -e 'const fs=require(\"fs\"); const data=JSON.parse(fs.readFileSync(\""
     tmp
     "\",\"utf8\")); const dep=data.diagnostics.find((item)=>item.import.name.join(\"/\")===\"example/dep\"); if (!dep || dep.status !== \"provided\" || dep.reason !== \"local-library\") process.exit(1)'"))))

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

(let* ((tmp (temporary-file-path "kons-compat-scan-translation-out"))
       (command (string-append
                 "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --scheme mosh --manifest "
                 (shell-quote (path-join root "kons.scm"))
                 " compat-scan --format json >"
                 (shell-quote tmp))))
  (test-equal "compat-scan reports R7RS translation for R6RS scheme"
              0
              (shell-command-status command))
  (test-equal
   "compat-scan json includes translation and unsupported forms"
   0
   (shell-command-status
    (string-append
     "node -e 'const fs=require(\"fs\"); const data=JSON.parse(fs.readFileSync(\""
     tmp
     "\",\"utf8\")); const t=data.translations; const lib=t && t.libraries && t.libraries[0]; const schemeBase=data.diagnostics.find((item)=>item.import.name.join(\"/\")===\"scheme/base\"); const lazyOnly=data.diagnostics.find((item)=>item.import.spec && item.import.spec[0]===\"only\" && item.import.spec[1].join(\"/\")===\"scheme/lazy\"); const unsupportedNames=[\"scheme/lazy\",\"scheme/time\",\"scheme/load\",\"scheme/repl\"]; const unsupportedOk=unsupportedNames.every((name)=>{ const item=data.diagnostics.find((diag)=>Array.isArray(diag.import.spec) && diag.import.spec.join(\"/\")===name); return item && item.status === \"implementation-unsupported\" && item.reason === \"translation-mapping\"; }); if (!t || t.active !== true || t.target !== \"r6rs\" || !lib || lib.status !== \"unsupported\" || lib.unsupported.length < 5 || !schemeBase || schemeBase.status !== \"provided\" || schemeBase.reason !== \"translated-standard-library\" || !lazyOnly || lazyOnly.status !== \"provided\" || lazyOnly.reason !== \"translated-standard-library\" || !unsupportedOk) process.exit(1)'"))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons compat scan")
  (exit (if (= failures 0) 0 1)))
