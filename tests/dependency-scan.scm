(import (scheme base)
        (scheme process-context)
        (scheme file)
        (scheme write)
        (srfi 64)
        (kons util)
        (kons manifest)
        (kons actions dependency-scan))

(test-begin "kons dependency scan")

(define root "/tmp/kons-dependency-scan-test")
(define dep-root (path-join root "deps/provider"))

(define (write-file path text)
  (call-with-output-file path
    (lambda (out) (display text out))))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "mkdir -p "
                            (shell-quote (path-join root "src/example"))
                            " "
                            (shell-quote (path-join dep-root "src/example"))))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join root "src/example/lib.sld")
 "(define-library (example lib)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")

(write-file
 (path-join root "src/example/app.sld")
 "(define-library (example app)
  (export run)
  (import (scheme base) (example lib) (missing lib))
  (begin (define (run) value)))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (report (dependency-scan-report manifest '()))
       (missing (scan-report-missing report)))
  (test-equal "discovered provider count" 2 (length (scan-report-libraries report)))
  (test-equal "missing import count" 1 (length missing))
  (test-equal "missing import name" '(missing lib) (scan-import-name (car missing))))

(write-file
 (path-join dep-root "kons.scm")
 "(package
  (name (example dep))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join dep-root "src/example/dep.sld")
 "(define-library (example dep)
  (export dep-value)
  (import (scheme base))
  (begin (define dep-value 1)))
")

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (path (name (example dep)) (path \"deps/provider\")))
(dev-dependencies)
")

(write-file
 (path-join root "src/example/app.sld")
 "(define-library (example app)
  (export run)
  (import (scheme base) (example dep) (missing lib))
  (begin (define (run) dep-value)))
")

(let* ((tmp (temporary-file-path "kons-dependency-scan-test-out"))
       (command (string-append
                 "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
                 (shell-quote (path-join root "kons.scm"))
                 " dependency-scan --format json >"
                 (shell-quote tmp))))
  (test-equal "dependency-scan command sees dependency providers"
              0
              (shell-command-status command))
  (test-equal
   "dependency-scan json omits dependency-provided import from missing"
   0
   (shell-command-status
    (string-append
     "node -e 'const fs=require(\"fs\"); const data=JSON.parse(fs.readFileSync(\""
     tmp
     "\",\"utf8\")); const names=(xs)=>xs.map((x)=>x.name.join(\"/\")); if (!names(data.libraries).includes(\"example/dep\")) process.exit(1); const missing=names(data.missing); if (missing.includes(\"example/dep\") || !missing.includes(\"missing/lib\")) process.exit(1)'"))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons dependency scan")
  (exit (if (= failures 0) 0 1)))
