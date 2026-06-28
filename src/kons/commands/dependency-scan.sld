(define-library (kons commands dependency-scan)
  (export make-dependency-scan-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions dependency-scan))

  (begin
    (define (make-dependency-scan-command runner)
      (make-kons-command
        runner
        (kons-command-spec "dependency-scan" cmd-dependency-scan "Scan source imports." #t #t #t #f #f)
        (make-command-grammar
          (list 'option "format"
            'help:
            "Output format: sexp or json."
            'value-help:
            "FORMAT"))))))
