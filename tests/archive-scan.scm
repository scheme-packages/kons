(import (scheme base)
        (scheme process-context)
        (scheme file)
        (scheme write)
        (srfi 64)
        (kons util)
        (kons manifest)
        (kons actions archive-scan))

(test-begin "kons archive scan")

(define root "/tmp/kons-archive-scan-test")
(define archive "/tmp/kons-archive-scan-test.kons")

(define (write-file path text)
  (call-with-output-file path
    (lambda (out) (display text out))))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "rm -f " (shell-quote archive)))
(run-command (string-append "mkdir -p " (shell-quote (path-join root "src/example"))))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example archive))
  (version \"0.1.0\")
  (license \"MIT\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join root "src/example/archive.sld")
 "(define-library (example archive)
  (export run value)
  (import (scheme base))
  (begin
    (define value 1)
    (define (run) value)))
")

(let* ((manifest (parse-manifest (path-join root "kons.scm")))
       (report (archive-scan-report manifest 'checkout #f)))
  (test-equal "checkout library count" 1 (length (archive-scan-report-libraries report)))
  (test-equal "checkout identifier count" 2 (length (archive-scan-report-identifiers report))))

(run-command
 (string-append
  "cd " (shell-quote root)
  " && tar -czf " (shell-quote archive) " ."))

(let* ((tmp (temporary-file-path "kons-archive-scan-test-out"))
       (command (string-append
                 "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- archive-scan --archive "
                 (shell-quote archive)
                 " --format json >"
                 (shell-quote tmp))))
  (test-equal "archive-scan command exits" 0 (shell-command-status command))
  (test-equal
   "archive-scan json shape"
   0
   (shell-command-status
    (string-append
     "node -e 'const fs=require(\"fs\"); const data=JSON.parse(fs.readFileSync(\""
     tmp
     "\",\"utf8\")); if (data.formatVersion !== 1 || data.root.license !== \"MIT\" || data.libraries.length !== 1 || data.identifiers.length !== 2) process.exit(1)'"))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons archive scan")
  (exit (if (= failures 0) 0 1)))
