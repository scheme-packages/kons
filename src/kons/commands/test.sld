(define-library (kons commands test)
  (export make-test-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions test))

  (begin
    (define (make-test-command runner)
      (make-kons-command
        runner
        (kons-command-spec "test" cmd-test "Run package tests." #t #t #t #f #f)
        (make-command-grammar
          (list 'option "directory"
            'help:
            "Directory path for scoped operations."
            'value-help:
            "DIR")
          (list 'flag "workspace"
            'help:
            "Operate on workspace members.")
          (list 'flag "list"
            'help:
            "List available targets instead of running.")
          (list 'flag "plan"
            'help:
            "Print the planned action without executing."))))))
