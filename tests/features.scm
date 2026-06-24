(import (scheme base)
        (scheme file)
        (scheme process-context)
        (srfi 64)
        (kons compat json)
        (kons util)
        (kons names)
        (kons lock))

(test-begin "kons features")

(define root "/tmp/kf")
(define output-path (path-join root "out.txt"))
(define error-path (path-join root "err.txt"))
(define registry-root (path-join root "registry-command"))
(define registry-home (path-join registry-root "home"))
(define registry-url "http://r.test")
(define shared-capy-cache-home
  (or (get-environment-variable "KONS_TEST_CAPY_CACHE_HOME")
      (get-environment-variable "XDG_CACHE_HOME")))

(define (capy-cache-home fallback)
  (or shared-capy-cache-home fallback))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (json-field object key default)
  (let ((entry (assoc key object)))
    (if entry (cdr entry) default)))

(define (json-vector->list value)
  (if (vector? value) (vector->list value) '()))

(define (diagnostic-details diagnostic)
  (json-vector->list (json-field diagnostic 'details '#())))

(define (diagnostic-detail-with-field details field-name)
  (let loop ((items details))
    (cond
     ((null? items) #f)
     ((string=? (json-field (car items) 'field "") field-name) (car items))
     (else (loop (cdr items))))))

(define (command-status args)
  (shell-command-status
   (string-append
    "KONS_HOME="
    (shell-quote (path-join root "home"))
    " XDG_CACHE_HOME="
    (shell-quote (capy-cache-home (path-join root "cache")))
    " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join root "kons.scm"))
    " "
    args
    " >"
    (shell-quote output-path)
    " 2>"
    (shell-quote error-path))))

(define (registry-output-path)
  (path-join registry-root "out.txt"))

(define (registry-error-path)
  (path-join registry-root "err.txt"))

(define (registry-command-status args)
  (shell-command-status
   (string-append
    "KONS_HOME="
    (shell-quote registry-home)
    " XDG_CACHE_HOME="
    (shell-quote (capy-cache-home (path-join registry-root "cache")))
    " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join registry-root "kons.scm"))
    " "
    args
    " >"
    (shell-quote (registry-output-path))
    " 2>"
    (shell-quote (registry-error-path)))))

(define (cached-versions-metadata-path home package-name)
  (path-join
   (path-join
    (path-join home "store/registry/metadata")
    (safe-store-token registry-url))
   (string-append (safe-store-token package-name) "-versions.json")))

(define (write-registry-config! home)
  (write-file
   (path-join home "config/registries.scm")
   (string-append
    "(registries
  (registry
    (name \"default\")
    (url \"" registry-url "\")
    (default #t)))
")))

(define (write-cached-versions! home package-name json-body)
  (write-file
   (cached-versions-metadata-path home package-name)
   json-body))

(define (cached-registry-package-root home name version checksum)
  (path-join
   (path-join
    (path-join home "store/registry/sources")
    (safe-store-token registry-url))
   (string-append
    (safe-store-token name)
    "-"
    (safe-store-token version)
    "-"
    (safe-store-token checksum))))

(define (materialize-cached-registry-package! home lock name body-files)
  (let* ((entry (lock-entry-by-name lock name))
         (name-text (name->string name))
         (version (lock-entry-ref entry 'version ""))
         (checksum (lock-entry-ref entry 'checksum ""))
         (root (cached-registry-package-root home name-text version checksum)))
    (write-file
     (path-join root "kons.scm")
     (string-append
      "(package\n"
      "  (name " (call-with-output-string (lambda (out) (write name out))) ")\n"
      "  (version \"" version "\")\n"
      "  (source-path \"src\")\n"
      "  (features\n"
      "    (alpha)\n"
      "    (beta)\n"
      "    (tls)\n"
      "    (optional-leaf)))\n"
      "\n"
      "(dependencies)\n"
      "(dev-dependencies)\n"))
    (for-each
     (lambda (file)
       (write-file (path-join root (car file)) (cdr file)))
     body-files)
    root))

(define (materialize-registry-feature-sources! home lock)
  (for-each
   (lambda (name)
     (materialize-cached-registry-package!
      home
      lock
      name
      (list
       (cons
        (string-append "src/" (name->string name) ".sld")
        (string-append
         "(define-library "
         (call-with-output-string (lambda (out) (write name out)))
         "\n"
         "  (export value)\n"
         "  (import (scheme base))\n"
         "  (begin (define value 1)))\n")))))
   '((example feature-left)
     (example feature-right)
     (example optional-activator)
     (example optional-leaf)
     (example forwarder)
     (example forwarded-leaf)))
  (materialize-cached-registry-package!
   home
   lock
   '(example feature-target)
   (list
    (cons
     "build.scm"
     "(import (scheme base) (kons build))
(when (and (feature-enabled? 'alpha) (feature-enabled? 'beta))
  (write-library
   '(example feature-target generated)
   '(define-library (example feature-target generated)
      (export value)
      (import (scheme base))
      (begin (define value 'resolved-features)))))
")
    (cons
     "src/example/feature-target.sld"
     "(define-library (example feature-target)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
"))))

(define (write-registry-feature-sample!)
  (write-file
   (path-join registry-root "kons.scm")
   "(package
  (name (example registry-features))
  (version \"0.1.0\")
  (source-path \"src\")
  (main \"main.scm\"))

(dependencies
  (registry (name (example feature-left))
            (version \"^1.0\")
            (registry \"default\"))
  (registry (name (example feature-right))
            (version \"^1.0\")
            (registry \"default\"))
  (registry (name (example optional-activator))
            (version \"^1.0\")
            (registry \"default\")
            (features optional-leaf))
  (registry (name (example forwarder))
            (version \"^1.0\")
            (registry \"default\")
            (features tls)))
(dev-dependencies)
")
  (write-file
   (path-join registry-root "src/main.scm")
   "(import (scheme base) (example feature-target generated))
(unless (eq? value 'resolved-features)
  (exit 1))
")
  (write-file
   (path-join registry-root "src/example/registry-features.sld")
   "(define-library (example registry-features)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")
  (write-registry-config! registry-home)
  (write-cached-versions!
   registry-home
   "example/feature-left"
   "{\"package\":\"example/feature-left\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"a1\",\"dependencies\":[{\"name\":\"example/feature-target\",\"version\":\"^1.0\",\"registry\":\"default\",\"kind\":\"runtime\",\"features\":[\"alpha\"]}],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   registry-home
   "example/feature-right"
   "{\"package\":\"example/feature-right\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"b2\",\"dependencies\":[{\"name\":\"example/feature-target\",\"version\":\"^1.0\",\"registry\":\"default\",\"kind\":\"runtime\",\"features\":[\"beta\"]}],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   registry-home
   "example/feature-target"
   "{\"package\":\"example/feature-target\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"c3\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   registry-home
   "example/optional-activator"
   "{\"package\":\"example/optional-activator\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"d4\",\"dependencies\":[{\"name\":\"example/optional-leaf\",\"version\":\"^1.0\",\"registry\":\"default\",\"kind\":\"runtime\",\"optional\":true}],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   registry-home
   "example/optional-leaf"
   "{\"package\":\"example/optional-leaf\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"e5\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   registry-home
   "example/forwarder"
   "{\"package\":\"example/forwarder\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"f6\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[{\"feature\":\"tls\",\"dependencies\":[{\"name\":\"example/forwarded-leaf\",\"version\":\"^1.0\",\"registry\":\"default\",\"kind\":\"runtime\",\"features\":[\"tls\"]}]}]}]}\n")
  (write-cached-versions!
   registry-home
   "example/forwarded-leaf"
   "{\"package\":\"example/forwarded-leaf\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"g7\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]}]}\n"))

(define (lock-entry-by-name lock name)
  (let loop ((items (lock-package-entries lock)))
    (cond
     ((null? items) #f)
     ((equal? (lock-entry-ref (car items) 'name '()) name) (car items))
     (else (loop (cdr items))))))

(define (lock-edge-by-name lock name)
  (let loop ((items (lock-edge-entries lock)))
    (cond
     ((null? items) #f)
     ((equal? (lock-entry-ref (car items) 'name '()) name) (car items))
     (else (loop (cdr items))))))

(define (lock-entry-rest entry key)
  (let ((field (and (pair? entry) (assq key (cdr entry)))))
    (if field (cdr field) '())))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example features))
  (version \"0.1.0\")
  (source-path \"src\")
  (features
    (tls)))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join root "src/example/features.sld")
 "(define-library (example features)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")

(test-equal "default feature lock updates" 0 (command-status "update"))

(test-equal
 "feature-changed locked verify exits with diagnostic"
 1
 (command-status "--quiet --features tls --message-format json verify --locked"))

(let* ((diagnostic (call-with-input-file error-path json-read))
       (details (diagnostic-details diagnostic))
       (feature-detail (diagnostic-detail-with-field details "features")))
  (test-equal
   "feature stale diagnostic code"
   "stale-lockfile"
   (json-field diagnostic 'code ""))
  (test-assert "feature stale diagnostic names field" feature-detail)
  (test-equal
   "feature stale diagnostic expected features"
   '#("default" "tls")
   (json-field feature-detail 'expected '#()))
  (test-equal
   "feature stale diagnostic actual features"
   '#("default")
   (json-field feature-detail 'actual '#())))

(test-equal
 "context-changed frozen build exits with diagnostic"
 0
 (command-status "--target linux-x86_64 --scheme capy update"))

(test-equal
 "frozen build stale context exits with diagnostic"
 1
 (command-status "--quiet --target darwin-aarch64 --scheme guile --message-format json build --frozen"))

(let* ((diagnostic (call-with-input-file error-path json-read))
       (details (diagnostic-details diagnostic))
       (scheme-detail (diagnostic-detail-with-field details "scheme"))
       (target-detail (diagnostic-detail-with-field details "target")))
  (test-equal
   "frozen context stale diagnostic code"
   "stale-lockfile"
   (json-field diagnostic 'code ""))
  (test-assert "frozen context stale diagnostic names scheme" scheme-detail)
  (test-equal
   "frozen context stale diagnostic expected scheme"
   "guile"
   (json-field scheme-detail 'expected ""))
  (test-equal
   "frozen context stale diagnostic actual scheme"
   "capy"
   (json-field scheme-detail 'actual ""))
  (test-assert "frozen context stale diagnostic names target" target-detail)
  (test-equal
   "frozen context stale diagnostic expected target"
   "darwin-aarch64"
   (json-field target-detail 'expected ""))
  (test-equal
   "frozen context stale diagnostic actual target"
   "linux-x86_64"
   (json-field target-detail 'actual "")))

(test-equal
 "profile and compile-mode lock updates"
 0
 (command-status "--profile release --compile-mode compiled update"))

(test-equal
 "profile and compile-mode stale verify exits with diagnostic"
 1
 (command-status "--quiet --profile debug --compile-mode fresh-auto --message-format json verify --locked"))

(let* ((diagnostic (call-with-input-file error-path json-read))
       (details (diagnostic-details diagnostic))
       (profile-detail (diagnostic-detail-with-field details "profile"))
       (compile-mode-detail (diagnostic-detail-with-field details "compile-mode")))
  (test-equal
   "profile compile-mode stale diagnostic code"
   "stale-lockfile"
   (json-field diagnostic 'code ""))
  (test-assert "profile stale diagnostic names field" profile-detail)
  (test-equal
   "profile stale diagnostic expected"
   "debug"
   (json-field profile-detail 'expected ""))
  (test-equal
   "profile stale diagnostic actual"
   "release"
   (json-field profile-detail 'actual ""))
  (test-assert "compile-mode stale diagnostic names field" compile-mode-detail)
  (test-equal
   "compile-mode stale diagnostic expected"
   "fresh-auto"
   (json-field compile-mode-detail 'expected ""))
  (test-equal
   "compile-mode stale diagnostic actual"
   "compiled"
   (json-field compile-mode-detail 'actual "")))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example features))
  (version \"0.1.0\")
  (source-path \"src\")
  (dialects r6rs r7rs)
  (features
    (tls)))

(dependencies)
(dev-dependencies)
")

(test-equal
 "dialect context lock updates"
 0
 (command-status "--scheme capy update"))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example features))
  (version \"0.1.0\")
  (source-path \"src\")
  (dialects r7rs r6rs)
  (features
    (tls)))

(dependencies)
(dev-dependencies)
")

(test-equal
 "dialect stale verify exits with diagnostic"
 1
 (command-status "--quiet --scheme capy --message-format json verify --locked"))

(let* ((diagnostic (call-with-input-file error-path json-read))
       (details (diagnostic-details diagnostic))
       (dialect-detail (diagnostic-detail-with-field details "dialect")))
  (test-equal
   "dialect stale diagnostic code"
   "stale-lockfile"
   (json-field diagnostic 'code ""))
  (test-assert "dialect stale diagnostic names field" dialect-detail)
  (test-equal
   "dialect stale diagnostic expected"
   "r7rs"
   (json-field dialect-detail 'expected ""))
  (test-equal
   "dialect stale diagnostic actual"
   "r6rs"
   (json-field dialect-detail 'actual "")))

(write-registry-feature-sample!)

(test-equal
 "registry feature lock updates offline"
 0
 (registry-command-status "update --offline"))

(let* ((lock (read-lockfile (path-join registry-root "kons.lock")))
       (target (lock-entry-by-name lock '(example feature-target)))
       (optional-activator (lock-entry-by-name lock '(example optional-activator)))
       (optional-leaf (lock-entry-by-name lock '(example optional-leaf)))
       (forwarder (lock-entry-by-name lock '(example forwarder)))
       (forwarded-leaf (lock-entry-by-name lock '(example forwarded-leaf)))
       (target-edge (lock-edge-by-name lock '(example feature-target)))
       (forwarded-edge (lock-edge-by-name lock '(example forwarded-leaf))))
  (test-equal
   "registry feature union recorded in lock"
   '(alpha beta)
   (lock-entry-rest target 'features))
  (test-equal
   "registry feature union edge keeps first request"
   '(alpha)
   (lock-entry-rest target-edge 'features))
  (test-equal
   "registry selected optional activator feature"
   '(optional-leaf)
   (lock-entry-rest optional-activator 'features))
  (test-assert
   "registry optional dependency activated"
   optional-leaf)
  (test-equal
   "registry selected forwarding feature"
   '(tls)
   (lock-entry-rest forwarder 'features))
  (test-equal
   "registry forwarded dependency feature recorded"
   '(tls)
   (lock-entry-rest forwarded-leaf 'features))
  (test-equal
   "registry forwarded edge feature recorded"
   '(tls)
   (lock-entry-rest forwarded-edge 'features)))

(let ((lock (read-lockfile (path-join registry-root "kons.lock"))))
  (materialize-registry-feature-sources! registry-home lock))

(test-equal
 "locked dependency activation uses resolved features"
 0
 (registry-command-status "run --locked --offline"))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons features")
  (exit (if (= failures 0) 0 1)))
