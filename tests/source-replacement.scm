(import (scheme base)
        (scheme file)
        (srfi 64)
        (kons util))

(test-begin "kons source replacement")

(define root "/tmp/kons-source-replacement-test")
(define home (path-join root "home"))
(define cache (path-join root "cache"))
(define app-root (path-join root "app"))
(define vendor-root (path-join root "vendor/kons"))
(define vendored-package-root (path-join vendor-root "local-example-dep-1-0-0"))
(define vendored-archive-path (path-join vendored-package-root ".kons-archive"))
(define tree-json-path (path-join root "tree.json"))
(define status-json-path (path-join root "status.json"))
(define check-output-path (path-join root "check.out"))
(define build-output-path (path-join root "build.out"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (file-sha256 path)
  (capture-first-line
   (string-append "sha256sum " (shell-quote path) " | awk '{print $1}'")))

(define (vendor-source-content-hash path)
  (capture-first-line
   (string-append
    "cd " (shell-quote path)
    " && find . -type f -not -path './.git/*' -print | LC_ALL=C sort | xargs cksum | cksum")))

(define (command-status command output-path)
  (shell-command-status
   (string-append
    "KONS_HOME="
    (shell-quote home)
    " XDG_CACHE_HOME="
    (shell-quote cache)
    " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join app-root "kons.scm"))
    " "
    command
    " >"
    (shell-quote output-path))))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
 (path-join app-root "kons.scm")
 "(package
  (name (example source-replacement-app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (registry (name (example dep))
            (version \"^1.0\")
            (registry \"local\")))
(dev-dependencies)
")

(write-file
 (path-join app-root "src/example/source-replacement-app.sld")
 "(define-library (example source-replacement-app)
  (export value)
  (import (scheme base) (example dep))
  (begin (define value dep-value)))
")

(write-file
 (path-join app-root "src/main.scm")
 "(import (scheme base) (example source-replacement-app))
(unless (= value 1)
  (error \"unexpected vendored value\" value))
")

(write-file
 (path-join vendored-package-root "kons.scm")
 "(package
  (name (example dep))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join vendored-package-root "src/example/dep.sld")
 "(define-library (example dep)
  (export dep-value)
  (import (scheme base))
  (begin (define dep-value 1)))
")

(write-file vendored-archive-path "archive bytes\n")

(let* ((archive-checksum (file-sha256 vendored-archive-path))
       (source-hash (vendor-source-content-hash vendored-package-root)))
  (write-expr-file
   (path-join app-root "kons.lock")
   `(lockfile
     (version 2)
     (root
      (name (example source-replacement-app))
      (version "0.1.0")
      (scheme capy)
      (dialect r7rs)
      (target #f)
      (profile debug)
      (compile-mode fresh-auto)
      (features default))
     (packages
      (package
       (id "registry:local:example/dep:1.0.0")
       (scope runtime)
       (type registry)
       (name (example dep))
       (req "^1.0")
       (version "1.0.0")
       (registry "local")
       (checksum ,archive-checksum)
       (download "http://127.0.0.1:9/api/v1/packages/example/dep/1.0.0/download")
       (features)))
     (edges
      (edge
       (from root)
       (to "registry:local:example/dep:1.0.0")
       (name (example dep))
       (req "^1.0")
       (kind runtime)
       (features)
       (optional #f)))
     (overrides)))
  (write-expr-file
   (path-join vendor-root "kons-vendor.scm")
   `(vendor
     (version 1)
     (directory ".")
     (source-replacement
      (kind registry)
      (directory "."))
     (packages
      (package
       (name (example dep))
       (version "1.0.0")
       (registry "local")
       (checksum ,archive-checksum)
       (archive ".kons-archive")
       (path "local-example-dep-1-0-0")
       (source-hash ,source-hash))))))

(run-command (string-append "mkdir -p " (shell-quote (path-join home "config"))))
(write-expr-file
 (path-join home "config/source-replacements.scm")
 `(source-replacements
   (replace
    (registry "local")
    (directory ,vendor-root))))

(test-assert
 "project source replacement pointer is absent"
 (not (file-exists? (path-join app-root "kons-vendor.scm"))))

(test-equal
 "tree uses configured source replacement"
 0
 (command-status "tree --locked --offline --format json" tree-json-path))

(test-equal
 "tree json reports vendored source"
 0
 (shell-command-status
  (string-append
   "node -e 'const fs=require(\"fs\");"
   "const data=JSON.parse(fs.readFileSync("
   (call-with-output-string (lambda (out) (write tree-json-path out)))
   ",\"utf8\"));"
   "const dep=data.dependencies.find((item)=>item.name && item.name.join(\"/\")===\"example/dep\");"
   "if (!dep || dep.source !== \"vendored\" || !/vendor\\/kons\\/local-example-dep-1-0-0$/.test(dep[\"source-path\"])) process.exit(1);"
   "'")))

(test-equal
 "status uses configured source replacement"
 0
 (command-status "status --offline --format json" status-json-path))

(test-equal
 "status json reports vendored source"
 0
 (shell-command-status
  (string-append
   "node -e 'const fs=require(\"fs\");"
   "const data=JSON.parse(fs.readFileSync("
   (call-with-output-string (lambda (out) (write status-json-path out)))
   ",\"utf8\"));"
   "const dep=data[\"locked-dependencies\"].find((item)=>item.name && item.name.join(\"/\")===\"example/dep\");"
   "if (!dep || dep.source !== \"vendored\" || !/vendor\\/kons\\/local-example-dep-1-0-0$/.test(dep[\"source-path\"])) process.exit(1);"
   "'")))

(test-equal
 "check frozen uses configured source replacement"
 0
 (command-status "check --frozen" check-output-path))

(test-equal
 "build frozen uses configured source replacement"
 0
 (command-status "build --frozen" build-output-path))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons source replacement")
  (exit (if (= failures 0) 0 1)))
