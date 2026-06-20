(define-library (kons commands bench)
  (export make-bench-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions bench))

  (begin
    (define (make-bench-command runner)
      (make-kons-command
       runner
       (kons-command-spec "bench" cmd-bench "Run package benchmarks." #t #t #t #f #f)
       (make-command-grammar
        (list 'flag "workspace"
          'help: "Operate on workspace members.")
        (list 'flag "list"
          'help: "List available targets instead of running.")
        (list 'flag "plan"
          'help: "Print the planned action without executing."))))))
