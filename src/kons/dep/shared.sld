(define-library (kons dep shared)
  (export lock-package-entries
          lock-entry-type
          lock-entry-ref
          dependency-selector-fields)
  (import (scheme base)
          (scheme write)
          (kons util)
          (kons manifest))

  (begin
(define (lock-package-entries lock)
  (let ((packages-form (assq 'packages (cdr lock))))
    (if packages-form (cdr packages-form) '())))

(define (lock-entry-type entry)
  (and (pair? entry)
       (eq? (car entry) 'package)
       (let ((type-field (assq 'type (cdr entry))))
         (and type-field (cadr type-field)))))

(define (lock-entry-ref entry key default)
  (let ((field (and (pair? entry) (assq key (cdr entry)))))
    (if field (cadr field) default)))

(define (dependency-selector-fields dep)
  (append
   (let ((schemes (alist-ref dep 'schemes '())))
     (if (null? schemes) '() `((schemes ,@schemes))))
   (let ((dialects (alist-ref dep 'dialects '())))
     (if (null? dialects) '() `((dialects ,@dialects))))
   (let ((targets (alist-ref dep 'targets '())))
     (if (null? targets) '() `((targets ,@targets))))
   (let ((profiles (alist-ref dep 'profiles '())))
     (if (null? profiles) '() `((profiles ,@profiles))))
   (let ((compile-modes (alist-ref dep 'compile-modes '())))
     (if (null? compile-modes) '() `((compile-modes ,@compile-modes))))))

  ))
