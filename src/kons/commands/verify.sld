(define-library (kons commands verify)
  (export make-verify-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions verify))

  (begin
    (define (make-verify-command runner)
      (make-kons-command
       runner
       (kons-command-spec "verify" cmd-verify "Verify lockfile, materialized sources, and cached archives." #t #t #t #f #f)
       (make-command-grammar
        (list 'option "format"
          'help: "Output format: sexp or json."
          'value-help: "FORMAT"))))

  ))
