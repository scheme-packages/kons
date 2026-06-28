(define-library (kons commands update)
  (export make-update-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions update))

  (begin
    (define (make-update-command runner)
      (make-kons-command
        runner
        (kons-command-spec "update" cmd-update "Resolve dependencies and write kons.lock." #t #t #t #f #f)
        (make-command-grammar
          (list 'flag "upgrade"
            'help:
            "Upgrade compatible registry dependencies instead of preserving locked versions."))))))
