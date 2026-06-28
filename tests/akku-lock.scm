(import (scheme base)
  (srfi 64)
  (kons akku lock))

(test-begin "kons Akku lock")

(define lock
  '(kons-lock
    (root
      (name (sample app))
      (version "0.1.0")
      (scheme capy)
      (dialect r7rs)
      (target host)
      (profile debug))
    (packages
      (package
        (id "registry:akku:akku/string/flat-name:1.2.0")
        (scope runtime)
        (type akku)
        (name "flat-name")
        (resolver-name (akku string "flat-name"))
        (key "akku/string/flat-name")
        (req "^1.0")
        (version "1.2.0")
        (source "sample")
        (source-url "/tmp/source")
        (source-kind git)
        (remote "/tmp/flat.git")
        (tag "v1.2.0")
        (revision "abc123")
        (depends ((direct-leaf "^1.0")))
        (depends/dev ((dev-only "^1.0")))
        (conflicts ((old-flat "<1.0")))
        (source-cache-path "/tmp/source")
        (optional #f))
      (package
        (id "path:sample")
        (scope runtime)
        (type path)
        (name (local dep))
        (version "0.1.0")))))

(let ((refs (locked-akku-refs lock)))
  (test-equal "locked Akku refs count" 1 (length refs))
  (test-equal "locked Akku ref name"
    '(akku string "flat-name")
    (cdr (assoc 'name (car refs))))
  (test-equal "locked Akku ref version"
    "1.2.0"
    (cdr (assoc 'version (car refs))))
  (test-equal "locked Akku ref source"
    "sample"
    (cdr (assoc 'registry (car refs)))))

(test-equal "empty lock has no Akku refs" '() (locked-akku-refs #f))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku lock")
  (exit (if (= failures 0) 0 1)))
