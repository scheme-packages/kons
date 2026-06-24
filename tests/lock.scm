(import (scheme base)
        (scheme process-context)
        (srfi 64)
        (kons util)
        (kons lock))

(test-begin "kons lock")

(define root "/tmp/kons-lock-test")
(define legacy-path (path-join root "legacy.lock"))
(define graph-path (path-join root "graph.lock"))
(define context-path (path-join root "context.lock"))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "mkdir -p " (shell-quote root)))

(write-expr-file
 legacy-path
 '(lockfile
   (version 1)
   (root
    (name (example app))
    (version "0.1.0")
    (features default))
   (packages
    (package
     (type registry)
     (name (example dep))
     (req "^1.0")
     (version "1.0.0")
     (registry "default")
     (checksum "abc")
     (download "https://registry.test/example/dep/1.0.0/download")))))

(write-expr-file
 graph-path
 '(lockfile
   (version 2)
   (root
    (name (example app))
    (version "0.1.0")
    (features default))
   (packages
    (package
     (id "registry:default:example/dep:1.0.0")
     (scope runtime)
     (type registry)
     (name (example dep))
     (req "^1.0")
     (version "1.0.0")
     (registry "default")
     (checksum "abc")
     (download "https://registry.test/example/dep/1.0.0/download")
     (features)))
   (edges
    (edge
     (from root)
     (to "registry:default:example/dep:1.0.0")
     (name (example dep))
     (req "^1.0")
     (kind runtime)))))

(write-expr-file
 context-path
 '(lockfile
   (version 2)
   (root
    (name (example app))
    (version "0.1.0")
    (scheme capy)
    (dialect r7rs)
    (target "linux-x86_64")
    (profile release)
    (compile-mode compiled)
    (features default tls))
   (packages)
   (edges)))

(let ((legacy (read-lockfile legacy-path)))
  (test-equal "legacy root name" '(example app) (lock-root-name legacy))
  (test-equal "legacy root features" '(default) (lock-root-features legacy))
  (test-equal "legacy root scheme missing" #f (lock-root-scheme legacy))
  (test-equal "legacy root dialect missing" #f (lock-root-dialect legacy))
  (test-equal "legacy root target missing" #f (lock-root-target legacy))
  (test-equal "legacy root profile default" 'debug (lock-root-profile legacy))
  (test-equal "legacy root compile mode missing" #f (lock-root-compile-mode legacy))
  (test-equal "legacy package count" 1 (length (lock-package-entries legacy)))
  (test-equal "legacy package type" 'registry (lock-entry-type (car (lock-package-entries legacy))))
  (test-equal "legacy package version" "1.0.0" (lock-entry-ref (car (lock-package-entries legacy)) 'version #f))
  (test-equal "legacy lock has no graph edges" '() (lock-edge-entries legacy)))

(let ((graph (read-lockfile graph-path)))
  (test-equal "graph package count" 1 (length (lock-package-entries graph)))
  (test-equal "graph edge count" 1 (length (lock-edge-entries graph)))
  (test-equal "graph edge target"
              "registry:default:example/dep:1.0.0"
              (lock-entry-ref (car (lock-edge-entries graph)) 'to #f)))

(let ((context (read-lockfile context-path)))
  (test-equal "context root scheme" 'capy (lock-root-scheme context))
  (test-equal "context root dialect" 'r7rs (lock-root-dialect context))
  (test-equal "context root target" "linux-x86_64" (lock-root-target context))
  (test-equal "context root profile" 'release (lock-root-profile context))
  (test-equal "context root compile mode" 'compiled (lock-root-compile-mode context))
  (test-equal "context root features" '(default tls) (lock-root-features context)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons lock")
  (exit (if (= failures 0) 0 1)))
