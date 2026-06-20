(define-library (kons commands fetch)
  (export make-fetch-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions fetch))

  (begin
    (define (make-fetch-command runner)
      (make-kons-command
       runner
       (kons-command-spec "fetch" cmd-fetch "Materialize the dependency graph." #t #t #t #f #f)
       (make-command-grammar
        (list 'flag "plan"
          'help: "Print the planned action without executing."))))))
