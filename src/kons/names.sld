(define-library (kons names)
  (export name->string)
  (import (scheme base))

  (begin
(define (name->string name)
  (let loop ((xs name) (out ""))
    (cond
     ((null? xs) out)
     ((string=? out "")
      (loop (cdr xs) (symbol->string (car xs))))
     (else
      (loop (cdr xs) (string-append out "/" (symbol->string (car xs))))))))

  ))
