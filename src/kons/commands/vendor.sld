(define-library (kons commands vendor)
  (export make-vendor-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions vendor))

  (begin
    (define (make-vendor-command runner)
      (make-kons-command
        runner
        (kons-command-spec "vendor" cmd-vendor "Vendor locked registry dependencies." #t #t #t #f #f)
        (make-command-grammar
          (list 'option "directory"
            'help:
            "Directory to write vendored registry packages."
            'value-help:
            "DIR")
          (list 'flag "sync"
            'help:
            "Remove stale vendored packages before writing.")
          (list 'flag "plan"
            'help:
            "Print the planned action without executing."))))))
