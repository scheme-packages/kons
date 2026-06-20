(define-library (kons commands doctor)
  (export make-doctor-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions doctor))

  (begin
    (define (make-doctor-command runner)
      (make-kons-command
       runner
       (kons-command-spec "doctor" cmd-doctor "Report Scheme implementations, tools, and paths." #f #f #f #f #f)
       (make-command-grammar)))))
