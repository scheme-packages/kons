(define-library (kons actions clean)
  (export cmd-clean)
  (import (scheme base)
    (scheme file)
    (scheme process-context)
    (scheme write)
    (kons util)
    (kons implementation)
    (kons manifest)
    (kons features)
    (kons lock)
    (kons runner)
    (kons options)
    (kons actions paths)
    (kons actions tree-clean))

  (begin
    (define (cmd-clean cmd)
      (if (and (command-flag? cmd "store")
           (not (command-flag? cmd "plan")))
        (begin
          (run-command (string-append "rm -rf " (shell-quote (kons-store-root))))
          (displayln "cleaned materialized store artifacts"))
        (let* ((manifest (parse-manifest (command-manifest-path cmd)))
               (kons-dir (project-kons-path manifest ""))
               (builds-dir (project-kons-path manifest "builds"))
               (compiled-dir (project-kons-path manifest "compiled")))
          (if (command-flag? cmd "plan")
            (writeln
              `(clean-plan
                (default-removes ,builds-dir ,compiled-dir)
                (store-removes ,(kons-store-root))
                (gc-removes "unreferenced store/sources entries" "unreferenced store/metadata entries")
                (all-removes ,kons-dir)))
            (begin
              (cond
                ((command-flag? cmd "all")
                  (run-command (string-append "rm -rf " (shell-quote kons-dir)))
                  (displayln "cleaned all kons artifacts"))
                ((command-flag? cmd "store")
                  (run-command (string-append "rm -rf " (shell-quote (kons-store-root))))
                  (displayln "cleaned materialized store artifacts"))
                ((command-flag? cmd "gc")
                  (clean-store-gc manifest cmd))
                (else
                  (run-command
                    (string-append "rm -rf "
                      (shell-quote builds-dir)
                      " "
                      (shell-quote compiled-dir)))
                  (displayln "cleaned generated build artifacts"))))))))))
