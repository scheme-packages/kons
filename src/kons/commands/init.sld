(define-library (kons commands init)
  (export make-init-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions init))

  (begin
    (define (make-init-command runner)
      (make-kons-command
       runner
       (kons-command-spec "init" cmd-init "Create a starter package in an existing directory." #f #f #f #f #f)
       (make-command-grammar
        (list 'option "directory"
          'help: "Directory path for scoped operations."
          'value-help: "DIR")
        (list 'option "name"
          'help: "Package, dependency, or install name."
          'value-help: "NAME")
        (list 'option "dialect"
          'help: "Starter package dialect."
          'value-help: "NAME"
          'allowed: '("r7rs" "r6rs"))
        (list 'flag "plan"
          'help: "Print the planned action without executing.")
        (list 'flag "lib"
          'help: "Create a library package starter."))))))
