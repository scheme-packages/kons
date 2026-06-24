(define-library (kons commands clean)
  (export make-clean-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions clean))

  (begin
    (define (make-clean-command runner)
      (make-kons-command
       runner
       (kons-command-spec "clean" cmd-clean "Remove generated build and store artifacts." #t #t #t #f #f)
       (make-command-grammar
        (list 'flag "plan"
          'help: "Print the planned action without executing.")
        (list 'flag "all"
          'help: "Apply to all workspace members.")
        (list 'flag "gc"
          'help: "Garbage-collect store artifacts.")
        (list 'flag "store"
          'help: "Clean store artifacts."))))))
