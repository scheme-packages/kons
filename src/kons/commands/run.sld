(define-library (kons commands run)
  (export make-run-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions run))

  (begin
    (define (make-run-command runner)
      (make-kons-command
        runner
        (kons-command-spec "run" cmd-run "Run a package script or binary target." #t #t #t #t #f)
        (make-command-grammar
          (list 'option "script"
            'help:
            "Manifest script target name."
            'value-help:
            "NAME")
          (list 'option "bin"
            'help:
            "Binary target name."
            'value-help:
            "NAME")
          (list 'option "example"
            'help:
            "Example target name."
            'value-help:
            "NAME")
          (list 'flag "workspace"
            'help:
            "Operate on workspace members.")
          (list 'flag "list"
            'help:
            "List available targets instead of running.")
          (list 'flag "plan"
            'help:
            "Print the planned action without executing."))))))
