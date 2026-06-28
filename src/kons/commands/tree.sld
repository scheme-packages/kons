(define-library (kons commands tree)
  (export make-tree-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions tree))

  (begin
    (define (make-tree-command runner)
      (make-kons-command
        runner
        (kons-command-spec "tree" cmd-tree "Print the resolved dependency tree." #t #t #t #f #f)
        (make-command-grammar)))))
