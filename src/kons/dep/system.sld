(define-library (kons dep system)
  (export system-lock-entry)
  (import (scheme base)
    (kons manifest)
    (kons dep shared))

  (begin
    (define (system-lock-entry manifest dep)
      (append
        `(system
          (scope ,(alist-ref dep 'scope 'runtime))
          (names ,@(alist-ref dep 'names '())))
        (dependency-selector-fields dep)))))
