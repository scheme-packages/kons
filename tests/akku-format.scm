(import (scheme base)
  (scheme file)
  (srfi 64)
  (kons akku format))

(test-begin "kons akku format")

(define root "/tmp/kons-akku-format-test")

(define (ensure-directory path)
  (unless (file-exists? path)
    (create-directory path)))

(define (write-file path text)
  (when (file-exists? path)
    (delete-file path))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (path-join a b)
  (string-append a "/" b))

(define (raises? thunk)
  (guard (exn (else #t))
    (thunk)
    #f))

(ensure-directory root)

(define manifest-path (path-join root "Akku.manifest"))
(define lock-path (path-join root "Akku.lock"))
(define index-path (path-join root "Akku-index.scm"))

(write-file
  manifest-path
  "(import (akku format manifest))

(akku-package (\"flat-name\" \"1.2.3\")
  (synopsis \"Flat package\")
  (description \"One\" \"Two\")
  (authors \"Ada\" \"Bea\")
  (homepage \"local-flat\")
  (license \"MIT\")
  (scripts (test \"tests/run.scm\"))
  (install (load-paths \"src\" \"lib\"))
  (depends (scheme-bytestructures \">=1.0.0\"))
  (depends/dev ((chibi test) \"0.1.0\"))
  (conflicts (old-flat \"<1.0.0\")))

(akku-package ((chibi match) \"0.7.0\")
  (synopsis \"List package\")
  (license \"BSD-3-Clause\")
  (source (git \"/tmp/chibi-match.git\") (tag \"v0.7.0\")))
")

(write-file
  lock-path
  "(import (akku format lockfile))

(projects
  ((name \"flat-name\")
   (location (git \"/tmp/flat.git\"))
   (tag \"v1.2.3\")
   (revision \"abc123\"))
  ((name \"list-name\")
   (location (directory \"vendor/list-name\"))))
")

(write-file
  index-path
  "(import (akku format index))

(package (name \"flat-name\")
  (versions
    ((version \"1.2.3\")
     (synopsis \"Flat package\")
     (authors \"Ada\")
     (homepage \"local-flat\")
     (license \"MIT\")
     (install (load-paths \"src\"))
     (lock (location (git \"/tmp/flat.git\")) (tag \"v1.2.3\"))
     (depends (scheme-bytestructures \">=1.0.0\"))
     (depends/dev)
     (conflicts))))

(package (name (chibi match))
  (versions
    ((version \"0.7.0\")
     (synopsis \"List package\")
     (license \"BSD-3-Clause\")
     (lock (location (directory \"vendor/chibi-match\")))
     (depends)
     (depends/dev)
     (conflicts))))
")

(let ((packages (read-akku-manifest manifest-path)))
  (test-equal "manifest package count" 2 (length packages))
  (test-assert "manifest package record" (akku-package? (car packages)))
  (test-equal "manifest preserves string name"
    "flat-name"
    (akku-package-name (car packages)))
  (test-equal "manifest preserves list name"
    '(chibi match)
    (akku-package-name (cadr packages)))
  (test-equal "manifest version"
    "1.2.3"
    (akku-version-number (car (akku-package-versions (car packages)))))
  (test-equal "manifest dependencies preserved"
    '((scheme-bytestructures ">=1.0.0"))
    (akku-version-depends (car (akku-package-versions (car packages)))))
  (test-equal "manifest install metadata preserved"
    '((load-paths "src" "lib"))
    (let ((version (car (akku-package-versions (car packages)))))
      (let ((field (assq 'install (akku-version-properties version))))
        (if field (cdr field) '())))))

(let ((projects (read-akku-lock lock-path)))
  (test-equal "lock project count" 2 (length projects))
  (test-assert "lock project record" (akku-lock-project? (car projects)))
  (test-equal "lock project name" "flat-name" (akku-lock-project-name (car projects)))
  (test-equal "lock project location"
    '(git "/tmp/flat.git")
    (akku-lock-project-location (car projects)))
  (test-equal "lock project revision" "abc123" (akku-lock-project-revision (car projects))))

(let ((packages (read-akku-index index-path)))
  (test-equal "index package count" 2 (length packages))
  (test-equal "index preserves string name"
    "flat-name"
    (akku-package-name (car packages)))
  (test-equal "index preserves list name"
    '(chibi match)
    (akku-package-name (cadr packages)))
  (test-equal "index lock data preserved"
    '((location (git "/tmp/flat.git")) (tag "v1.2.3"))
    (akku-version-lock (car (akku-package-versions (car packages)))))
  (test-equal "index install metadata preserved"
    '((load-paths "src"))
    (let ((version (car (akku-package-versions (car packages)))))
      (let ((field (assq 'install (akku-version-properties version))))
        (if field (cdr field) '())))))

(define directive-index-path (path-join root "directive-index.scm"))
(write-file
  directive-index-path
  "#!r6rs ; -*- mode: scheme; coding: utf-8 -*-
;; SPDX-License-Identifier: CC0-1.0
(import (akku format index))

(package (name \"directive\")
  (versions
    ((version \"1.0.0\")
     (license \"MIT\"))))
")
(test-equal "index reader skips leading reader directive"
  "directive"
  (akku-package-name (car (read-akku-index directive-index-path))))

(define bad-import-path (path-join root "bad-import.scm"))
(write-file bad-import-path "(import (akku format manifest))\n(package (name \"x\"))\n")
(test-assert "wrong package form rejected"
  (raises? (lambda () (read-akku-index bad-import-path))))

(define bad-header-path (path-join root "bad-header.scm"))
(write-file bad-header-path "(import (akku format index))\n")
(test-assert "wrong import header rejected"
  (raises? (lambda () (read-akku-manifest bad-header-path))))

(define bad-version-path (path-join root "bad-version.scm"))
(write-file
  bad-version-path
  "(import (akku format index))
(package (name \"bad\")
  (versions
    ((version 1)
     (license \"MIT\"))))
")
(test-assert "malformed version records rejected"
  (raises? (lambda () (read-akku-index bad-version-path))))

(define executable-looking-path (path-join root "executable-looking.scm"))
(write-file
  executable-looking-path
  "(import (akku format manifest))
(define (run) (display \"must not evaluate\"))
")
(test-assert "executable-looking unexpected forms rejected"
  (raises? (lambda () (read-akku-manifest executable-looking-path))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons akku format")
  (exit (if (= failures 0) 0 1)))
