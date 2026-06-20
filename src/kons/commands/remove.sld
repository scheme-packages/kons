(define-library (kons commands remove)
  (export make-remove-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions remove))

  (begin
    (define (make-remove-command runner)
      (make-kons-command
       runner
       (kons-command-spec "remove" cmd-remove "Remove a dependency from the manifest." #t #t #t #t #f)
       (make-command-grammar
        (list 'flag "workspace"
          'help: "Operate on workspace members.")
        (list 'flag "plan"
          'help: "Print the planned action without executing.")
        (list 'flag "all"
          'help: "Apply to all workspace members.")
        (list 'flag "dev"
          'help: "Use dev-dependencies scope."))))))
