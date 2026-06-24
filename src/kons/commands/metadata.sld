(define-library (kons commands metadata)
  (export make-metadata-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions metadata))

  (begin
    (define (make-metadata-command runner)
      (make-kons-command
       runner
       (kons-command-spec "metadata" cmd-metadata "Print normalized manifest data." #f #f #f #f #f)
       (make-command-grammar
        (list 'option "format"
          'help: "Output format: sexp or json."
          'value-help: "FORMAT"))))))
