(define-library (kons commands add)
  (export make-add-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions add))

  (begin
    (define (make-add-command runner)
      (make-kons-command
       runner
       (kons-command-spec "add" cmd-add "Add a dependency to the manifest." #t #t #t #t #f)
       (make-command-grammar
        (list 'option "git"
          'help: "Git repository URL for git dependencies."
          'value-help: "URL")
        (list 'option "rev"
          'help: "Git revision for path dependencies."
          'value-help: "REV")
        (list 'option "subpath"
          'help: "Subpath within a git dependency."
          'value-help: "PATH")
        (list 'option "version"
          'help: "Dependency version constraint. With --path or --git, records the registry requirement used for publish."
          'value-help: "VERSION")
        (list 'option "registry"
          'help: "Registry alias or URL for registry dependencies, or the publish registry for versioned local dependencies."
          'value-help: "REGISTRY")
        (list 'option "akku"
          'help: "Add an Akku package by flat name or exact list syntax, for example '(chibi match)'."
          'value-help: "NAME")
        (list 'flag "workspace"
          'help: "Operate on workspace members.")
        (list 'flag "plan"
          'help: "Print the planned action without executing.")
        (list 'flag "all"
          'help: "Apply to all workspace members.")
        (list 'flag "dev"
          'help: "Use dev-dependencies scope.")
        (list 'flag "system"
          'help: "Add or remove a system dependency.")
        (list 'flag "raw"
          'help: "Add a raw dependency expression."))))))
