(define-library (kons actions registry route)
  (export string-join
          string-index
          library-route-key)
  (import (scheme base)
          (scheme char))

  (begin
(define (string-join xs sep)
  (let loop ((rest xs) (out ""))
    (cond
     ((null? rest) out)
     ((string=? out "") (loop (cdr rest) (car rest)))
     (else (loop (cdr rest) (string-append out sep (car rest)))))))

(define (string-index s ch)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (cond
       ((= i len) #f)
       ((char=? (string-ref s i) ch) i)
       (else (loop (+ i 1)))))))

(define (string-trim-spaces text)
  (let ((len (string-length text)))
    (let find-start ((start 0))
      (if (and (< start len) (char-whitespace? (string-ref text start)))
          (find-start (+ start 1))
          (let find-end ((end len))
            (if (and (> end start)
                     (char-whitespace? (string-ref text (- end 1))))
                (find-end (- end 1))
                (substring text start end)))))))

(define (string-starts-with? text ch)
  (and (> (string-length text) 0)
       (char=? (string-ref text 0) ch)))

(define (string-ends-with? text ch)
  (let ((len (string-length text)))
    (and (> len 0)
         (char=? (string-ref text (- len 1)) ch))))

(define (string-contains-char? text ch)
  (let ((len (string-length text)))
    (let loop ((index 0))
      (cond
       ((= index len) #f)
       ((char=? (string-ref text index) ch) #t)
       (else (loop (+ index 1)))))))

(define (split-whitespace text)
  (let ((len (string-length text)))
    (let loop ((index 0) (start #f) (parts '()))
      (cond
       ((= index len)
        (reverse
         (if start
             (cons (substring text start index) parts)
             parts)))
       ((char-whitespace? (string-ref text index))
        (loop (+ index 1)
              #f
              (if start
                  (cons (substring text start index) parts)
                  parts)))
       (start
        (loop (+ index 1) start parts))
       (else
        (loop (+ index 1) index parts))))))

(define (display-library-name? text)
  (and (string-starts-with? text #\()
       (string-ends-with? text #\))))

(define (library-route-key text)
  (let ((trimmed (string-trim-spaces text)))
    (cond
     ((display-library-name? trimmed)
      (let ((inner (substring trimmed 1 (- (string-length trimmed) 1))))
        (string-join (split-whitespace inner) "/")))
     ((not (string-contains-char? trimmed #\/))
      (let ((parts (split-whitespace trimmed)))
        (cond
         ((null? parts) trimmed)
         ((null? (cdr parts)) trimmed)
         (else (string-join parts "/")))))
     (else trimmed))))

))
