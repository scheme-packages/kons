(define-library (kons commands compat-scan)
  (export make-compat-scan-command)
  (import (scheme base)
          (args runner)
          (kons options)
          (kons commands framework)
          (kons actions compat-scan))

  (begin
    (define (make-compat-scan-command runner)
      (make-kons-command
       runner
       (kons-command-spec "compat-scan" cmd-compat-scan "Report likely Scheme portability gaps." #t #t #t #f #f)
       (make-command-grammar
        (list 'option "format"
          'help: "Output format: sexp or json."
          'value-help: "FORMAT"))))))
