(define-library (kons commands license-scan)
  (export make-license-scan-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions license-scan))

  (begin
    (define (make-license-scan-command runner)
      (make-kons-command
        runner
        (kons-command-spec "license-scan" cmd-license-scan "Report package licenses." #t #t #t #f #f)
        (make-command-grammar
          (list 'option "directory"
            'help:
            "Write THIRD_PARTY_NOTICES.txt into DIR."
            'value-help:
            "DIR"))))))
