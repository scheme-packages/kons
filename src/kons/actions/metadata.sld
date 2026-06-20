(define-library (kons actions metadata)
  (export cmd-metadata)
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
          (kons library-discovery))

  (begin
(define (cmd-metadata cmd)
  (writeln (manifest-with-effective-libraries
            (parse-manifest (command-manifest-path cmd)))))

  ))
