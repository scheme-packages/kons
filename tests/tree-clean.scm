(import (scheme base)
  (scheme process-context)
  (srfi 64)
  (kons actions tree-clean))

(test-begin "kons tree clean")

(define selected-path-entry
  '(package
    (scope dev)
    (type path)
    (name (example dep))
    (path "vendor/dep")
    (raw #f)
    (source-hash "abc123")
    (schemes capy guile)
    (targets "linux-x86_64")
    (profiles release)
    (compile-modes compiled)))

(test-equal
  "locked path dependency keeps selector fields"
  '(dependency
    (scope dev)
    (type path)
    (name (example dep))
    (path "vendor/dep")
    (raw #f)
    (source-hash "abc123")
    (schemes capy guile)
    (targets "linux-x86_64")
    (profiles release)
    (compile-modes compiled))
  (tree-dependency-from-lock-entry selected-path-entry))

(define selected-system-entry
  '(system
    (scope runtime)
    (names (scheme file) (scheme write))
    (schemes capy)
    (profiles debug)))

(test-equal
  "locked system dependency keeps selector fields"
  '(dependency
    (scope runtime)
    (type system)
    (names (scheme file) (scheme write))
    (schemes capy)
    (profiles debug))
  (tree-dependency-from-lock-entry selected-system-entry))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons tree clean")
  (exit (if (= failures 0) 0 1)))
