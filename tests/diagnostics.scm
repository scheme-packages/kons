(import (scheme base)
        (scheme file)
        (scheme process-context)
        (srfi 64)
        (kons compat json)
        (kons util))

(test-begin "kons diagnostics")

(define root "/tmp/kons-diagnostics-test")
(define checksum-root (path-join root "checksum-command"))
(define checksum-home (path-join checksum-root "home"))
(define checksum-registry-url "http://127.0.0.1:9")
(define checksum-package-name '(example checksum-dep))
(define checksum-package-name-text "example/checksum-dep")
(define checksum-package-version "1.0.0")
(define expected-checksum
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
(define resolver-root (path-join root "resolver-command"))
(define resolver-home (path-join resolver-root "home"))
(define resolver-registry-url "http://127.0.0.1:9")
(define stale-root (path-join root "stale-lock-command"))
(define stale-home (path-join stale-root "home"))

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

(define (run-json-diagnostic-script message)
  (let* ((script (path-join root (string-append (safe-store-token message) ".scm")))
         (err (string-append script ".err")))
    (write-file
     script
     (string-append
      "(import (scheme base) (kons util))\n"
      "(set-message-format! 'json)\n"
      "(dependency-error "
      (call-with-output-string (lambda (out) (write message out)))
      ")\n"))
    (test-assert
     (string-append "diagnostic script fails for " message)
     (not (= 0
             (shell-command-status
              (string-append
               "capy -L vendor/scm-args/src,vendor/conduit/src,src -s "
               (shell-quote script)
               " >/dev/null 2>"
               (shell-quote err))))))
    (call-with-input-file err json-read)))

(define (run-command-json-error command err)
  (let ((raw-err (string-append err ".raw")))
    (test-assert
     (string-append "command fails: " command)
     (not (= 0
             (shell-command-status
              (string-append command " >/dev/null 2>" (shell-quote raw-err))))))
    (test-equal
     "extract final diagnostic line"
     0
     (shell-command-status
      (string-append "tail -n 1 " (shell-quote raw-err) " > " (shell-quote err)))))
  (call-with-input-file err json-read))

(define (cached-archive-path home registry-url package-name version checksum)
  (path-join
   (path-join
    (path-join home "store/registry/archives")
    (safe-store-token registry-url))
   (string-append
    (safe-store-token package-name)
    "-"
    (safe-store-token version)
    "-"
    (safe-store-token checksum)
    ".kons")))

(define (cached-versions-metadata-path home registry-url package-name)
  (path-join
   (path-join
    (path-join home "store/registry/metadata")
    (safe-store-token registry-url))
   (string-append (safe-store-token package-name) "-versions.json")))

(define (cached-source-root home registry-url package-name version checksum)
  (path-join
   (path-join
    (path-join home "store/registry/sources")
    (safe-store-token registry-url))
   (string-append
    (safe-store-token package-name)
    "-"
    (safe-store-token version)
    "-"
    (safe-store-token checksum))))

(define (write-checksum-command-sample!)
  (write-file
   (path-join checksum-root "kons.scm")
   "(package
  (name (example checksum-app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (registry (name (example checksum-dep))
            (version \"^1.0\")
            (registry \"default\")))
(dev-dependencies)
")
  (write-file (path-join checksum-root "src/example/checksum-app.sld")
              "(define-library (example checksum-app)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")
  (write-file
   (path-join checksum-home "config/registries.scm")
   "(registries
  (registry
    (name \"default\")
    (url \"http://127.0.0.1:9\")
    (default #t)))
")
  (write-expr-file
   (path-join checksum-root "kons.lock")
   `(lockfile
     (version 2)
     (root
      (name (example checksum-app))
      (version "0.1.0")
      (scheme capy)
      (dialect r7rs)
      (target #f)
      (profile debug)
      (compile-mode fresh-auto)
      (features default))
     (packages
      (package
       (id "registry:default:example/checksum-dep:1.0.0")
       (scope runtime)
       (type registry)
       (name ,checksum-package-name)
       (req "^1.0")
       (version ,checksum-package-version)
       (registry "default")
       (checksum ,expected-checksum)
       (download "http://127.0.0.1:9/api/v1/packages/example/checksum-dep/1.0.0/download")
       (optional #f)
       (features)))
     (edges
      (edge
       (from root)
       (to "registry:default:example/checksum-dep:1.0.0")
       (name ,checksum-package-name)
       (req "^1.0")
       (kind runtime)
       (features)
       (optional #f)))
     (overrides)))
  (write-file
   (cached-versions-metadata-path
    checksum-home
    checksum-registry-url
    checksum-package-name-text)
   "{\"package\":\"example/checksum-dep\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"download\":\"http://127.0.0.1:9/api/v1/packages/example/checksum-dep/1.0.0/download\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]}]}\n")
  (let ((package-root
         (cached-source-root
          checksum-home
          checksum-registry-url
          checksum-package-name-text
          checksum-package-version
          expected-checksum)))
    (write-file
     (path-join package-root "kons.scm")
     "(package
  (name (example checksum-dep))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")
    (write-file
     (path-join package-root "src/example/checksum-dep.sld")
     "(define-library (example checksum-dep)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
"))
  (write-file
   (cached-archive-path
    checksum-home
    checksum-registry-url
    checksum-package-name-text
    checksum-package-version
    expected-checksum)
   "corrupt archive\n"))

(define (write-registry-config! home)
  (write-file
   (path-join home "config/registries.scm")
   "(registries
  (registry
    (name \"default\")
    (url \"http://127.0.0.1:9\")
    (default #t)))
"))

(define (write-cached-versions! home package-name json-body)
  (write-file
   (cached-versions-metadata-path home resolver-registry-url package-name)
   json-body))

(define (write-resolver-conflict-command-sample!)
  (write-file
   (path-join resolver-root "kons.scm")
   "(package
  (name (example resolver-app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (registry (name (example impossible-left))
            (version \"^1.0\")
            (registry \"default\"))
  (registry (name (example impossible-right))
            (version \"^1.0\")
            (registry \"default\")))
(dev-dependencies)
")
  (write-file
   (path-join resolver-root "src/example/resolver-app.sld")
   "(define-library (example resolver-app)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")
  (write-registry-config! resolver-home)
  (write-cached-versions!
   resolver-home
   "example/impossible-left"
   "{\"package\":\"example/impossible-left\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"dependencies\":[{\"name\":\"example/shared\",\"version\":\">=2.0.0\",\"registry\":\"default\",\"kind\":\"runtime\"}],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   resolver-home
   "example/impossible-right"
   "{\"package\":\"example/impossible-right\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"dependencies\":[{\"name\":\"example/shared\",\"version\":\"<2.0.0\",\"registry\":\"default\",\"kind\":\"runtime\"}],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   resolver-home
   "example/shared"
   "{\"package\":\"example/shared\",\"versions\":[{\"version\":\"2.0.0\",\"checksum\":\"3333333333333333333333333333333333333333333333333333333333333333\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]},{\"version\":\"1.5.0\",\"checksum\":\"4444444444444444444444444444444444444444444444444444444444444444\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]}]}\n"))

(define (stale-command args out err)
  (shell-command-status
   (string-append
    "KONS_HOME="
    (shell-quote stale-home)
    " XDG_CACHE_HOME="
    (shell-quote (path-join stale-root "cache"))
    " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join stale-root "kons.scm"))
    " "
    args
    " >"
    (shell-quote out)
    " 2>"
    (shell-quote err))))

(define (write-stale-lock-command-sample!)
  (write-file
   (path-join stale-root "kons.scm")
   "(package
  (name (example stale-lock-app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (registry (name (example stale-root-dep))
            (version \"^1.0\")
            (registry \"default\")))
(dev-dependencies)
")
  (write-file
   (path-join stale-root "src/example/stale-lock-app.sld")
   "(define-library (example stale-lock-app)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")
  (write-registry-config! stale-home)
  (write-cached-versions!
   stale-home
   "example/stale-root-dep"
   "{\"package\":\"example/stale-root-dep\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"5555555555555555555555555555555555555555555555555555555555555555\",\"dependencies\":[{\"name\":\"example/stale-old-leaf\",\"version\":\"^1.0\",\"registry\":\"default\",\"kind\":\"runtime\"}],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   stale-home
   "example/stale-old-leaf"
   "{\"package\":\"example/stale-old-leaf\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"6666666666666666666666666666666666666666666666666666666666666666\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]}]}\n")
  (write-cached-versions!
   stale-home
   "example/stale-new-leaf"
   "{\"package\":\"example/stale-new-leaf\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"7777777777777777777777777777777777777777777777777777777777777777\",\"dependencies\":[],\"features\":[],\"featureDependencies\":[]}]}\n"))

(define (mutate-stale-transitive-metadata!)
  (write-cached-versions!
   stale-home
   "example/stale-root-dep"
   "{\"package\":\"example/stale-root-dep\",\"versions\":[{\"version\":\"1.0.0\",\"checksum\":\"5555555555555555555555555555555555555555555555555555555555555555\",\"dependencies\":[{\"name\":\"example/stale-new-leaf\",\"version\":\"^1.0\",\"registry\":\"default\",\"kind\":\"runtime\"}],\"features\":[],\"featureDependencies\":[]}]}\n"))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "mkdir -p " (shell-quote root)))

(let ((diagnostic (run-json-diagnostic-script "registry archive checksum mismatch")))
  (test-equal "checksum mismatch category" "dependency" (json-field diagnostic 'category ""))
  (test-equal "checksum mismatch code" "checksum-mismatch" (json-field diagnostic 'code "")))

(let ((diagnostic (run-json-diagnostic-script "dependency version conflict")))
  (test-equal "resolver conflict category" "dependency" (json-field diagnostic 'category ""))
  (test-equal "resolver conflict code" "resolver-conflict" (json-field diagnostic 'code "")))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example diagnostics))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (system (no such kons system library)))
(dev-dependencies)
")

(let ((diagnostic
       (run-command-json-error
        (string-append
         "KONS_HOME="
         (shell-quote (path-join root "home"))
         " XDG_CACHE_HOME="
         (shell-quote (path-join root "cache"))
         " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
         (shell-quote (path-join root "kons.scm"))
         " --message-format json check")
        (path-join root "missing-system.err"))))
  (test-equal "missing system category" "dependency" (json-field diagnostic 'category ""))
  (test-equal "missing system code" "missing-system-dependency" (json-field diagnostic 'code "")))

(write-checksum-command-sample!)

(let ((diagnostic
       (run-command-json-error
        (string-append
         "KONS_HOME="
         (shell-quote checksum-home)
         " XDG_CACHE_HOME="
         (shell-quote (path-join checksum-root "cache"))
         " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
         (shell-quote (path-join checksum-root "kons.scm"))
         " --message-format json verify --offline")
        (path-join checksum-root "checksum.err"))))
  (test-equal "command checksum category" "dependency" (json-field diagnostic 'category ""))
  (test-equal "command checksum code" "checksum-mismatch" (json-field diagnostic 'code "")))

(write-resolver-conflict-command-sample!)

(let* ((diagnostic
        (run-command-json-error
         (string-append
          "KONS_HOME="
          (shell-quote resolver-home)
          " XDG_CACHE_HOME="
          (shell-quote (path-join resolver-root "cache"))
          " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
          (shell-quote (path-join resolver-root "kons.scm"))
          " --message-format json update --offline")
         (path-join resolver-root "resolver.err")))
       (details (json-field diagnostic 'details '#()))
       (package (and (vector? details)
                     (> (vector-length details) 0)
                     (vector-ref details 0)))
       (detail (and (vector? details)
                    (> (vector-length details) 1)
                    (vector-ref details 1)))
       (conflict (and (pair? detail) (assoc 'reason detail))))
  (test-equal "command resolver conflict category" "dependency" (json-field diagnostic 'category ""))
  (test-equal "command resolver conflict code" "resolver-conflict" (json-field diagnostic 'code ""))
  (test-equal "command resolver conflict message" "dependency version conflict" (json-field diagnostic 'message ""))
  (test-equal "command resolver conflict package" "example/shared" package)
  (test-equal "command resolver conflict detail reason" "resolver-conflict" (and conflict (cdr conflict))))

(write-stale-lock-command-sample!)

(test-equal
 "transitive metadata lock updates offline"
 0
 (stale-command
  "update --offline"
  (path-join stale-root "update.out")
  (path-join stale-root "update.err")))

(mutate-stale-transitive-metadata!)

(let* ((diagnostic
        (run-command-json-error
         (string-append
          "KONS_HOME="
          (shell-quote stale-home)
          " XDG_CACHE_HOME="
          (shell-quote (path-join stale-root "cache"))
          " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
          (shell-quote (path-join stale-root "kons.scm"))
          " --message-format json verify --locked --offline")
         (path-join stale-root "verify.err")))
       (details (diagnostic-details diagnostic))
       (packages-detail (diagnostic-detail-with-field details "packages"))
       (edges-detail (diagnostic-detail-with-field details "edges")))
  (test-equal
   "transitive metadata stale verify code"
   "stale-lockfile"
   (json-field diagnostic 'code ""))
  (test-assert "transitive metadata stale verify reports packages" packages-detail)
  (test-assert "transitive metadata stale verify reports edges" edges-detail))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons diagnostics")
  (exit (if (= failures 0) 0 1)))
