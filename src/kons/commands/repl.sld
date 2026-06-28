(define-library (kons commands repl)
  (export make-repl-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions repl))

  (begin
    (define (make-repl-command runner)
      (make-kons-command
        runner
        (kons-command-spec "repl" cmd-repl "Start a Scheme REPL with package load paths." #t #t #t #t #f)
        (make-command-grammar
          (list 'flag "workspace"
            'help:
            "Operate on workspace members.")
          (list 'flag "plan"
            'help:
            "Print the planned action without executing."))))))
