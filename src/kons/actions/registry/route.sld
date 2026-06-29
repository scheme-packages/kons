(define-library (kons actions registry route)
  (export library-route-key)
  (import (scheme base)
          (kons util))

  (begin
(define (display-library-name? text)
  (and (string-prefix? "(" text)
       (string-suffix? ")" text)))

(define (library-route-key text)
  (let ((trimmed (trim-space text)))
    (cond
     ((display-library-name? trimmed)
      (let ((inner (substring trimmed 1 (- (string-length trimmed) 1))))
        (string-join (split-whitespace inner) "/")))
     ((not (string-contains? trimmed "/"))
      (let ((parts (split-whitespace trimmed)))
        (cond
         ((null? parts) trimmed)
         ((null? (cdr parts)) trimmed)
         (else (string-join parts "/")))))
     (else trimmed))))

))
