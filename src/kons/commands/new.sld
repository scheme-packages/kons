(define-library (kons commands new)
  (export make-new-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions new))

  (begin
    (define (make-new-command runner)
      (make-kons-command
       runner
       (kons-command-spec "new" cmd-new "Create a starter package in a directory." #f #f #f #f #f)
       (make-command-grammar
        (list 'option "directory"
          'help: "Directory path for scoped operations."
          'value-help: "DIR")
        (list 'option "name"
          'help: "Package, dependency, or install name."
          'value-help: "NAME")
        (list 'flag "plan"
          'help: "Print the planned action without executing.")
        (list 'flag "lib"
          'help: "Create a library package starter."))))))
