(define-library (kons actions doctor-shared)
  (export command-path
    command-report
    scheme-report
    doctor-ok?)
  (import (scheme base)
    (kons util))

  (begin
    (define (command-path command)
      (let* ((result
               (capture-command-lines/status
                 (string-append "command -v " (shell-quote command) " 2>/dev/null")))
             (status (car result))
             (lines (cadr result)))
        (if (and (= status 0) (pair? lines) (not (string=? (car lines) "")))
          (car lines)
          #f)))

    (define (command-report name command role required?)
      (let ((path (command-path command)))
        `(,name
          (command ,command)
          (role ,role)
          (required ,required?)
          (available ,(if path #t #f))
          ,@(if path `((path ,path)) '()))))

    (define (scheme-report scheme command selected?)
      (let ((path (command-path command)))
        `(,scheme
          (command ,command)
          (selected ,selected?)
          (available ,(if path #t #f))
          ,@(if path `((path ,path)) '()))))

    (define (doctor-ok? forms)
      (let loop ((items forms))
        (cond
          ((null? items) #t)
          ((and (pair? (car items))
              (equal? (field-ref (cdr (car items)) 'required #f) #t)
              (equal? (field-ref (cdr (car items)) 'available #f) #f))
            #f)
          (else (loop (cdr items))))))))
