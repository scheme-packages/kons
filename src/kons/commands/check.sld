(define-library (kons commands check)
  (export make-check-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions check))

  (begin
    (define (make-check-command runner)
      (make-kons-command
        runner
        (kons-command-spec "check" cmd-check "Validate manifest and dependency preconditions." #t #t #t #f #f)
        (make-command-grammar
          (list 'flag "workspace"
            'help:
            "Operate on workspace members.")
          (list 'flag "plan"
            'help:
            "Print the planned action without executing."))))))
