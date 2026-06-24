(import (scheme base)
        (scheme file)
        (scheme process-context)
        (srfi 64)
        (kons util))

(test-begin "kons license scan")

(define root "/tmp/kons-license-scan-test")
(define dep-root (path-join root "deps/helper"))
(define output-path (path-join root "license-scan.json"))
(define notices-dir (path-join root "notices"))
(define notices-path (path-join notices-dir "THIRD_PARTY_NOTICES.txt"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example license-app))
  (version \"0.1.0\")
  (license \"Apache-2.0\")
  (source-path \"src\"))

(dependencies
  (path (name (example license-helper)) (path \"deps/helper\"))
  (system (scheme base)))
(dev-dependencies)
")

(write-file
 (path-join root "src/example/license-app.sld")
 "(define-library (example license-app)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")

(write-file
 (path-join dep-root "kons.scm")
 "(package
  (name (example license-helper))
  (version \"1.2.3\")
  (license \"MIT\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join dep-root "src/example/license-helper.sld")
 "(define-library (example license-helper)
  (export helper)
  (import (scheme base))
  (begin (define helper 1)))
")

(let ((command (string-append
                "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
                (shell-quote (path-join root "kons.scm"))
                " license-scan --format json --directory "
                (shell-quote notices-dir)
                " >"
                (shell-quote output-path))))
  (test-equal "license-scan command exits" 0 (shell-command-status command)))

(test-assert "license-scan writes notices file" (file-exists? notices-path))

(test-equal
 "license-scan json and notices content"
 0
 (shell-command-status
  (string-append
   "node -e 'const fs=require(\"fs\");"
   "const data=JSON.parse(fs.readFileSync(\""
   output-path
   "\",\"utf8\"));"
   "const notices=fs.readFileSync(\""
   notices-path
   "\",\"utf8\");"
   "const nameText=(name)=>name.map((part)=>Array.isArray(part) ? part.join(\"/\") : part).join(\"/\");"
   "const names=data.packages.map((item)=>nameText(item.name));"
   "if (data.formatVersion !== 1) process.exit(1);"
   "if (!names.includes(\"example/license-app\")) process.exit(2);"
   "if (!names.includes(\"example/license-helper\")) process.exit(3);"
   "if (!names.includes(\"scheme/base\")) process.exit(4);"
   "const helper=data.packages.find((item)=>nameText(item.name)===\"example/license-helper\");"
   "if (!helper || helper.license !== \"MIT\" || helper.status !== \"known\") process.exit(5);"
   "if (!/Third Party Notices/.test(notices)) process.exit(6);"
   "if (!/example\\/license-app 0\\.1\\.0 - Apache-2\\.0 \\(known\\)/.test(notices)) process.exit(7);"
   "if (!/example\\/license-helper 1\\.2\\.3 - MIT \\(known\\)/.test(notices)) process.exit(8);"
   "if (!/scheme\\/base - system \\(system\\)/.test(notices)) process.exit(9);"
   "'")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons license scan")
  (exit (if (= failures 0) 0 1)))
