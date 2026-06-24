(define-library (kons commands archive-scan)
  (export make-archive-scan-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions archive-scan))

  (begin
    (define (make-archive-scan-command runner)
      (make-kons-command
       runner
       (kons-command-spec "archive-scan" cmd-archive-scan "Inspect package archive metadata." #f #f #f #f #f)
       (make-command-grammar
        (list 'option "archive"
          'help: "Archive file to inspect."
          'value-help: "FILE")
        (list 'option "format"
          'help: "Output format: sexp or json."
          'value-help: "FORMAT"))))))
