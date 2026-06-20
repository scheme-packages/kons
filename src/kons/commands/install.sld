(define-library (kons commands install)
  (export make-install-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions install))

  (begin
    (define (make-install-command runner)
      (make-kons-command
       runner
       (kons-command-spec "install" cmd-install "Install an executable launcher." #t #t #t #f #t)
       (make-command-grammar
        (list 'option "directory"
          'help: "Directory path for scoped operations."
          'value-help: "DIR")
        (list 'option "root"
          'help: "Installation root directory."
          'value-help: "DIR")
        (list 'option "name"
          'help: "Package, dependency, or install name."
          'value-help: "NAME")
        (list 'option "script"
          'help: "Manifest script target name."
          'value-help: "NAME")
        (list 'option "bin"
          'help: "Binary target name."
          'value-help: "NAME")
        (list 'flag "workspace"
          'help: "Operate on workspace members.")
        (list 'flag "plan"
          'help: "Print the planned action without executing.")
        (list 'flag "all"
          'help: "Apply to all workspace members."))))))

