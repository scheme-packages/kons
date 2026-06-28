(define-library (kons dep store)
  (export store-metadata-root
    store-metadata-path
    write-store-metadata
    subpath-package-root)
  (import (scheme base)
    (scheme write)
    (kons util))

  (begin
    (define (store-metadata-root kind token)
      (path-join
        (path-join (path-join (kons-store-root) "metadata") (symbol->string kind))
        (safe-store-token token)))

    (define (store-metadata-path kind token name-token)
      (path-join (store-metadata-root kind token)
        (string-append name-token ".scm")))

    (define (write-store-metadata kind token name-token record)
      (let ((root (store-metadata-root kind token))
            (path (store-metadata-path kind token name-token)))
        (run-command (string-append "mkdir -p " (shell-quote root)))
        (write-expr-file path record)
        path))

    (define (subpath-package-root root subpath)
      (if subpath
        (path-join root subpath)
        root))))
