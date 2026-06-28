(define-library (kons snow format)
  (export read-snow-repository
    make-snow-package
    snow-package?
    snow-package-name
    snow-package-version
    snow-package-url
    snow-package-sha256
    snow-package-size
    snow-package-description
    snow-package-libraries
    make-snow-library
    snow-library?
    snow-library-name
    snow-library-path
    snow-library-depends)
  (import (scheme base)
    (kons util)
    (kons snow records))

  (begin
    (define (field-one fields key default)
      (let ((found (assq key fields)))
        (if (and found (pair? (cdr found)))
          (cadr found)
          default)))

    (define (field-rest fields key default)
      (let ((found (assq key fields)))
        (if found (cdr found) default)))

    (define (snow-name-component? value)
      (or (symbol? value) (number? value)))

    (define (valid-snow-name? value)
      (and (list? value)
        (not (null? value))
        (let loop ((items value))
          (or (null? items)
            (and (snow-name-component? (car items))
              (loop (cdr items)))))))

    (define (signature-sha256 signatures)
      (let loop ((items signatures))
        (cond
          ((null? items) #f)
          ((and (pair? (car items)) (eq? (caar items) 'signature))
            (or (field-one (cdar items) 'sha-256 #f)
              (loop (cdr items))))
          (else (loop (cdr items))))))

    (define (parse-library form)
      (let* ((fields (cdr form))
             (name (field-one fields 'name #f))
             (path (field-one fields 'path ""))
             (depends (field-rest fields 'depends '())))
        (unless (valid-snow-name? name)
          (dependency-error "malformed Snow library name" name))
        (unless (string? path)
          (dependency-error "malformed Snow library path" path))
        (make-snow-library
          name
          path
          (filter valid-snow-name? depends))))

    (define (parse-package form)
      (let* ((fields (cdr form))
             (libraries (map parse-library
                          (filter (lambda (item)
                                    (and (pair? item) (eq? (car item) 'library)))
                            fields)))
             (package-name (field-one fields 'name #f))
             (fallback-name (and (pair? libraries)
                              (snow-library-name (car libraries))))
             (name (or package-name fallback-name))
             (version (field-one fields 'version "0.0.0"))
             (url (field-one fields 'url ""))
             (sha256 (signature-sha256 fields))
             (size (field-one fields 'size #f))
             (description (field-one fields 'description "")))
        (unless (valid-snow-name? name)
          (dependency-error "malformed Snow package name" name))
        (unless (string? version)
          (dependency-error "malformed Snow package version" name version))
        (unless (string? url)
          (dependency-error "malformed Snow package URL" name url))
        (make-snow-package name version url sha256 size description libraries)))

    (define (repository-packages form)
      (unless (and (pair? form) (eq? (car form) 'repository))
        (dependency-error "expected Snow repository form"))
      (map parse-package
        (filter (lambda (item)
                  (and (pair? item) (eq? (car item) 'package)))
          (cdr form))))

    (define (read-snow-repository path)
      (let ((exprs (read-all-exprs path)))
        (unless (= (length exprs) 1)
          (dependency-error "Snow repository requires exactly one repository form" path))
        (repository-packages (car exprs))))))
