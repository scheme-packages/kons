(define-library (kons actions resolve)
  (export cmd-resolve)
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
          (kons options))

  (begin
(define (cmd-resolve cmd)
  (let* ((manifest (parse-manifest (command-manifest-path cmd)))
         (features (active-features manifest cmd)))
    (ensure-supported-active-features manifest features cmd)
    (writeln
     `(resolution
       (root ,(package-name manifest))
       (features ,@features)
       (runtime-dependencies ,@(all-dependencies-for manifest #f features cmd))
       (dev-dependencies ,@(alist-ref manifest 'dev-dependencies '()))
       (overrides ,@(alist-ref manifest 'overrides '()))))))

  ))
