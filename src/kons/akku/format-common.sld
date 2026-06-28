(define-library (kons akku format-common)
  (export manifest-import
          lockfile-import
          index-import
          manifest-version-fields
          index-version-fields
          lock-project-fields
          akku-format-error
          read-akku-file
          valid-package-name?
          valid-version-string?
          top-form-kind
          ensure-known-fields
          field-rest
          field-one
          require-field-one
          validate-string-list-field
          validate-script-list
          validate-dependency-list)
  (import (scheme base)
          (scheme file)
          (scheme read))

  (begin
(define manifest-import '(import (akku format manifest)))
(define lockfile-import '(import (akku format lockfile)))
(define index-import '(import (akku format index)))

(define manifest-version-fields
  '(synopsis description authors homepage license scripts lock source
             install notice-files extra-files depends depends/dev conflicts))

(define index-version-fields
  '(version synopsis description authors homepage license scripts lock source
            install notice-files extra-files depends depends/dev conflicts))

(define lock-project-fields
  '(name location install installer scripts tag revision content))

(define (akku-format-error path message . details)
  (apply error (string-append "Akku format parse error: " message) path details))

(define (read-all-exprs path)
  (call-with-input-file path
    (lambda (in)
      (let loop ((expr (read in)) (out '()))
        (if (eof-object? expr)
            (reverse out)
            (loop (read in) (cons expr out)))))))

(define (read-akku-file path expected-import)
  (let ((exprs (read-all-exprs path)))
    (cond
     ((null? exprs)
      (akku-format-error path "file is empty"))
     ((not (equal? (car exprs) expected-import))
      (akku-format-error path "wrong import header" (car exprs)))
     (else (cdr exprs)))))

(define (symbol-or-number? value)
  (or (symbol? value) (number? value)))

(define (valid-package-name? value)
  (or (string? value)
      (and (list? value)
           (not (null? value))
           (let loop ((items value))
             (or (null? items)
                 (and (symbol-or-number? (car items))
                      (loop (cdr items))))))))

(define (valid-dependency-name? value)
  (or (symbol? value) (valid-package-name? value)))

(define (valid-version-string? value)
  (and (string? value)
       (> (string-length value) 0)))

(define (top-form-kind path form)
  (if (and (pair? form) (symbol? (car form)))
      (car form)
      (akku-format-error path "expected top-level form" form)))

(define (field-key path context field)
  (if (and (pair? field) (symbol? (car field)) (list? field))
      (car field)
      (akku-format-error path "expected field form" context field)))

(define (ensure-known-fields path context fields allowed)
  (let loop ((rest fields) (seen '()))
    (unless (null? rest)
      (let ((key (field-key path context (car rest))))
        (unless (memq key allowed)
          (akku-format-error path "unknown field" context key))
        (when (memq key seen)
          (akku-format-error path "duplicate field" context key))
        (loop (cdr rest) (cons key seen))))))

(define (field-rest fields key default)
  (let loop ((rest fields))
    (cond
     ((null? rest) default)
     ((eq? (caar rest) key) (cdar rest))
     (else (loop (cdr rest))))))

(define (field-one path context fields key default)
  (let loop ((rest fields))
    (cond
     ((null? rest) default)
     ((eq? (caar rest) key)
      (let ((values (cdar rest)))
        (if (and (pair? values) (null? (cdr values)))
            (car values)
            (akku-format-error path "expected a single field value" context key))))
     (else (loop (cdr rest))))))

(define (require-field-one path context fields key)
  (let ((value (field-one path context fields key #f)))
    (if value
        value
        (akku-format-error path "missing required field" context key))))

(define (all-strings? values)
  (let loop ((items values))
    (or (null? items)
        (and (string? (car items))
             (loop (cdr items))))))

(define (validate-string-list-field path context fields key)
  (let ((values (field-rest fields key '())))
    (unless (all-strings? values)
      (akku-format-error path "field values must be strings" context key))
    values))

(define (validate-script-list path context values)
  (for-each
   (lambda (script)
     (unless (and (list? script)
                  (pair? script)
                  (symbol? (car script)))
       (akku-format-error path "malformed scripts field" context script)))
   values)
  values)

(define (validate-dependency-list path context key values)
  (for-each
   (lambda (dep)
     (unless (and (list? dep)
                  (pair? dep)
                  (valid-dependency-name? (car dep)))
       (akku-format-error path "malformed dependency field" context key dep)))
   values)
  values)

))
