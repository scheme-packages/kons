(define-library (kons commands status)
  (export make-status-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions status))

  (begin
    (define (make-status-command runner)
      (make-kons-command
        runner
        (kons-command-spec "status" cmd-status "Print project readiness and next actions." #t #t #t #f #f)
        (make-command-grammar)))))
