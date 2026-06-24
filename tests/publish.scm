(import (scheme base)
        (scheme file)
        (srfi 64)
        (kons util))

(test-begin "kons publish")

(define root "/tmp/kons-publish-test")
(define output-path (path-join root "publish.out"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (command-status command output)
  (shell-command-status
   (string-append
    "KONS_HOME="
    (shell-quote (path-join root "home"))
    " XDG_CACHE_HOME="
    (shell-quote (path-join root "cache"))
    " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join root "kons.scm"))
    " "
    command
    " >"
    (shell-quote output)
    " 2>"
    (shell-quote (string-append output ".err")))))

(define (json-check script)
  (shell-command-status
   (string-append
    "node -e "
    (shell-quote script))))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example publish-no-metadata))
  (version \"0.1.0\")
  (owner \"example-owner\")
  (description \"Publish no metadata sample\")
  (license \"MIT\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join root "src/example/publish-no-metadata.sld")
 "(define-library (example publish-no-metadata)
  (export value)
  (import (scheme base))
  (begin (define value 1))
")

(test-assert
 "publish dry-run fails when metadata discovery fails"
 (not (= 0 (command-status "publish --dry-run --registry http://127.0.0.1:9"
                           (path-join root "publish-with-metadata.out")))))

(test-equal
 "publish no-metadata dry-run skips rich metadata discovery"
 0
 (command-status "publish --dry-run --no-metadata --registry http://127.0.0.1:9"
                 output-path))

(test-equal
 "publish no-metadata payload omits discovered libraries"
 0
 (json-check
  (string-append
   "const fs=require('fs');"
   "const text=fs.readFileSync("
   (call-with-output-string (lambda (out) (write output-path out)))
   ",'utf8');"
   "const match=text.match(/\\(payload \"?([^\"\\n)]+)\"?\\)/);"
   "if(!match) process.exit(1);"
   "const data=JSON.parse(fs.readFileSync(match[1],'utf8'));"
   "if(!Array.isArray(data.libraries) || data.libraries.length !== 0) process.exit(2);")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons publish")
  (exit (if (= failures 0) 0 1)))
