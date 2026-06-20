(define-library (kons commands resolve)
  (export make-resolve-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions resolve))

  (begin
    (define (make-resolve-command runner)
      (make-kons-command
       runner
       (kons-command-spec "resolve" cmd-resolve "Print the resolved dependency graph shape." #f #t #f #f #f)
       (make-command-grammar)))))
