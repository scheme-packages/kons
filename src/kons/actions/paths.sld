(define-library (kons actions paths)
  (export project-artifact-path
    project-lock-path
    command-lock-path
    project-kons-path
    read-existing-lock
    read-existing-command-lock
    same-path?
    parent-path
    find-package-root-for-source-root
    manifest-root-path
    manifest-source-path
    last-symbol
    default-binary-name
    string-contains?
    string-prefix?
    package-field-rest
    package-field-value
    maybe-rest-field
    third)
  (import (scheme base)
    (scheme file)
    (kons util)
    (kons manifest)
    (kons options)
    (kons lock))

  (begin
    (define (third xs)
      (cadr (cdr xs)))

    (define (project-artifact-path manifest path)
      (path-join (manifest-root manifest) path))

    (define (project-lock-path manifest)
      (project-artifact-path manifest "kons.lock"))

    (define (command-lock-path manifest cmd)
      (let ((workspace-root (command-option cmd "workspace-root" #f)))
        (if workspace-root
          (path-join (dirname workspace-root) "kons.lock")
          (project-lock-path manifest))))

    (define (project-kons-path manifest path)
      (project-artifact-path manifest (path-join ".kons" path)))

    (define (read-existing-lock manifest)
      (let ((path (project-lock-path manifest)))
        (and (file-exists? path)
          (read-lockfile path))))

    (define (read-existing-command-lock manifest cmd)
      (let ((path (command-lock-path manifest cmd)))
        (and (file-exists? path)
          (read-lockfile path))))

    (define (same-path? a b)
      (string=? (absolute-path a) (absolute-path b)))

    (define (parent-path path)
      (let ((parent (dirname path)))
        (if (string=? parent path) #f parent)))

    (define (path-last-segment path)
      (let ((parts (filter non-empty-string? (string-split path #\/))))
        (if (null? parts) path (car (reverse parts)))))

    (define (find-package-root-for-source-root source-root)
      (let loop ((dir source-root))
        (let ((manifest-path (path-join dir "kons.scm")))
          (cond
            ((file-exists? manifest-path) dir)
            ((string=? (path-last-segment dir) ".kons") #f)
            ((or (string=? dir ".") (string=? dir "/")) #f)
            ((parent-path dir) => loop)
            (else #f)))))

    (define (manifest-root-path manifest path)
      (if (absolute-path? path) path (path-join (manifest-root manifest) path)))

    (define (manifest-source-path manifest path)
      (if (absolute-path? path) path (path-join (manifest-source-root manifest) path)))

    (define (last-symbol xs fallback)
      (cond
        ((null? xs) fallback)
        ((null? (cdr xs)) (car xs))
        (else (last-symbol (cdr xs) fallback))))

    (define (default-binary-name manifest)
      (symbol->string (last-symbol (package-name manifest) 'main)))

    (define (package-field-rest package key)
      (let ((field (assq key package)))
        (if field (cdr field) '())))

    (define (package-field-value package key default)
      (let ((field (assq key package)))
        (if field (cadr field) default)))

    (define (maybe-rest-field key values)
      (if (null? values) '() (list (cons key values))))))
