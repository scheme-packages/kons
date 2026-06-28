(define-library (kons names)
  (export name->string)
  (import (scheme base))

  (begin
    (define (name->string name)
      (define (part->string part)
        (cond
          ((symbol? part) (symbol->string part))
          ((string? part) part)
          ((number? part) (number->string part))
          (else "")))
      (let loop ((xs name) (out ""))
        (cond
          ((null? xs) out)
          ((string=? out "")
            (loop (cdr xs) (part->string (car xs))))
          (else
            (loop (cdr xs) (string-append out "/" (part->string (car xs))))))))))
