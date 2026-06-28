(define-library (kons commands build)
  (export make-build-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions build))

  (begin
    (define (make-build-command runner)
      (make-kons-command
        runner
        (kons-command-spec "build" cmd-build "Run build hooks and implementation compilation." #t #t #t #f #f)
        (make-command-grammar
          (list 'flag "workspace"
            'help:
            "Operate on workspace members.")
          (list 'flag "plan"
            'help:
            "Print the planned action without executing."))))))
