(define-library (kons lock)
  (export dependency-lock-entry
          read-lockfile
          lock-root-name
          lock-root-version
          lock-root-scheme
          lock-root-target
          lock-root-profile
          lock-root-compile-mode
          lock-root-source-hash
          lock-root-features
          lock-package-entries
          lock-entry-type
          lock-entry-ref
          make-lock)
  (import (scheme base)
          (kons util)
          (kons names)
          (kons implementation)
          (kons manifest)
          (kons features)
          (kons options)
          (kons dep shared)
          (kons dep git)
          (kons dep path)
          (kons dep registry)
          (kons dep workspace)
          (kons dep system))

  (begin
(define (dependency-lock-entry manifest dep)
  (let ((type (alist-ref dep 'type #f)))
    (case type
      ((path) (path-lock-entry manifest dep))
      ((workspace) (workspace-lock-entry manifest dep))
      ((git) (git-lock-entry manifest dep))
      ((registry) (registry-lock-entry manifest dep))
      ((system) (system-lock-entry manifest dep))
      (else (dependency-error "cannot lock unknown dependency type" type)))))

(define (read-lockfile path)
  (let ((exprs (read-all-exprs path)))
    (if (null? exprs)
        (lockfile-error "lockfile is empty" path)
        (car exprs))))

(define (lock-root-name lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (name-form (and root-form (assq 'name (cdr root-form)))))
    (if name-form (cadr name-form) '())))

(define (lock-root-version lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (version-form (and root-form (assq 'version (cdr root-form)))))
    (and version-form (cadr version-form))))

(define (lock-root-scheme lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (scheme-form (and root-form (assq 'scheme (cdr root-form)))))
    (and scheme-form (cadr scheme-form))))

(define (lock-root-target lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (target-form (and root-form (assq 'target (cdr root-form)))))
    (and target-form (cadr target-form))))

(define (lock-root-profile lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (profile-form (and root-form (assq 'profile (cdr root-form)))))
    (if profile-form (cadr profile-form) 'debug)))

(define (lock-root-compile-mode lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (mode-form (and root-form (assq 'compile-mode (cdr root-form)))))
    (and mode-form (cadr mode-form))))

(define (lock-root-source-hash lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (hash-form (and root-form (assq 'source-hash (cdr root-form)))))
    (and hash-form (cadr hash-form))))

(define (lock-root-features lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (features-form (and root-form (assq 'features (cdr root-form)))))
    (if features-form (cdr features-form) '())))

(define (lock-value-key value)
  (cond
   ((symbol? value) (symbol->string value))
   ((string? value) value)
   ((number? value) (number->string value))
   ((null? value) "")
   ((pair? value)
    (let loop ((items value) (out ""))
      (cond
       ((null? items) out)
       ((string=? out "") (loop (cdr items) (lock-value-key (car items))))
       (else
        (loop (cdr items)
              (string-append out "/" (lock-value-key (car items))))))))
   (else "value")))

(define (lock-entry-sort-key entry)
  (cond
   ((and (pair? entry) (eq? (car entry) 'package))
    (string-append
     "package:"
     (lock-value-key (lock-entry-ref entry 'type 'unknown))
     ":"
     (lock-value-key (lock-entry-ref entry 'name '()))))
   ((and (pair? entry) (eq? (car entry) 'system))
    (let ((names-form (assq 'names (cdr entry))))
      (string-append
       "system:"
       (lock-value-key (if names-form (cdr names-form) '())))))
   (else (lock-value-key entry))))

(define (lock-entry<? a b)
  (string<? (lock-entry-sort-key a) (lock-entry-sort-key b)))

(define (insert-lock-entry entry sorted)
  (cond
   ((null? sorted) (list entry))
   ((lock-entry<? entry (car sorted)) (cons entry sorted))
   (else (cons (car sorted) (insert-lock-entry entry (cdr sorted))))))

(define (sort-lock-entries entries)
  (let loop ((rest entries) (out '()))
    (if (null? rest)
        out
        (loop (cdr rest) (insert-lock-entry (car rest) out)))))

(define (make-lock manifest features cmd . maybe-include-dev?)
  (let* ((include-dev? (if (null? maybe-include-dev?) #t (car maybe-include-dev?)))
         (package-entries
         (sort-lock-entries
          (map (lambda (dep) (dependency-lock-entry manifest dep))
               (all-dependencies-for manifest include-dev? features cmd))))
        (override-entries
         (sort-lock-entries
          (map (lambda (dep) (dependency-lock-entry manifest dep))
               (alist-ref manifest 'overrides '())))))
    `(lockfile
      (version ,kons-version)
      (root
       (name ,(package-name manifest))
       (version ,(package-version manifest))
       (features ,@features))
      (packages
       ,@package-entries)
      (overrides
       ,@override-entries))))
  ))
