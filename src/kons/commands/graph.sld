(define-library (kons commands graph)
  (export make-graph-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions graph))

  (begin
    (define (make-graph-command runner)
      (make-kons-command
       runner
       (kons-command-spec "graph" cmd-graph "Print the dependency graph." #t #t #t #f #f)
       (make-command-grammar
        (list 'option "format"
          'help: "Output format: sexp, dot, or json."
          'value-help: "FORMAT"))))))
