(import (scheme base)
        (scheme file)
        (scheme process-context)
        (srfi 64)
        (kons util))

(test-begin "kons metadata")

(define root "/tmp/kons-metadata-test")
(define output-path (path-join root "metadata.json"))

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

(let ((command (string-append
                "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
                (shell-quote (path-join root "kons.scm"))
                " metadata --format json >"
                (shell-quote output-path))))
  (test-equal "metadata json command exits" 0 (shell-command-status command)))

(test-equal
 "metadata json includes discovered library exports"
 0
 (shell-command-status
  (string-append
   "node -e 'const fs=require(\"fs\");"
   "const data=JSON.parse(fs.readFileSync(\""
   output-path
   "\",\"utf8\"));"
   "const libs=data.package && data.package.libraries;"
   "const r7rs=libs && libs.r7rs;"
   "if (data.formatVersion !== 1) process.exit(1);"
   "if (!r7rs) process.exit(2);"
   "if (!Array.isArray(r7rs.example) || r7rs.example.join(\"/\") !== \"metadata\") process.exit(3);"
   "if (!Array.isArray(r7rs.exports) || !r7rs.exports.includes(\"run\")) process.exit(4);"
   "if (!r7rs.exports.includes(\"public-hidden\")) process.exit(5);"
   "if (!r7rs.imports || !Array.isArray(r7rs.imports.scheme) || !r7rs.imports.scheme.includes(\"base\")) process.exit(6);"
   "'")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons metadata")
  (exit (if (= failures 0) 0 1)))
