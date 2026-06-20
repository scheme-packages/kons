(define-library (kons compat process)
  (export system
          read-line)
  (cond-expand
    (capy
     (import (scheme base)
             (core io process)))
    (gauche
     (import (scheme base)
             (rename (gauche base)
                     (sys-system gauche-system)
                     (read-line gauche-read-line))))
    (guile
     (import (rename (scheme base)
                     (read-line guile-read-line))
             (rename (only (guile) system)
                     (system guile-system))))
    (chibi
     (import (scheme base)
             (rename (chibi process)
                     (system chibi-system))
             (rename (chibi io)
                     (read-line chibi-read-line))))
    (else
     (import (scheme base))))

  (cond-expand
    (capy
     (begin))
    (else
     (begin
       (define (process-status result)
         (cond
          ((number? result) result)
          ((and (pair? result) (pair? (cdr result)) (number? (cadr result)))
           (cadr result))
          (else 1)))

       (define (system command)
         (cond-expand
           (gauche (process-status (gauche-system command)))
           (guile (process-status (guile-system command)))
           (chibi (process-status (chibi-system "/bin/sh" "-c" command)))
           (else 1)))

       (define (read-line . maybe-port)
         (cond-expand
           (gauche
            (if (null? maybe-port)
                (gauche-read-line)
                (gauche-read-line (car maybe-port))))
           (guile
            (if (null? maybe-port)
                (guile-read-line)
                (guile-read-line (car maybe-port))))
           (chibi
            (if (null? maybe-port)
                (chibi-read-line)
                (chibi-read-line (car maybe-port))))
           (else (read (open-input-string "")))))))))
