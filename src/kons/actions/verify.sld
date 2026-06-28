(define-library (kons actions verify)
  (export cmd-verify)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons util)
    (kons names)
    (kons manifest)
    (kons features)
    (kons lock)
    (kons registry)
    (kons runner)
    (kons options)
    (kons compat json)
    (kons actions paths)
    (kons actions lock-shared))

  (begin
    (define-record-type <verification-summary>
      (make-verification-summary lockfile package-count registry-archive-count registry-metadata-count)
      verification-summary?
      (lockfile verification-summary-lockfile)
      (package-count verification-summary-package-count)
      (registry-archive-count verification-summary-registry-archive-count)
      (registry-metadata-count verification-summary-registry-metadata-count))

    (define (cached-registry-archive-path entry)
      (registry-archive-path
        (lock-entry-ref entry 'registry "default")
        (name->string (lock-entry-ref entry 'name '()))
        (lock-entry-ref entry 'version "")
        (lock-entry-ref entry 'checksum "")))

    (define (verify-registry-archive! entry)
      (let ((archive (cached-registry-archive-path entry))
            (expected (lock-entry-ref entry 'checksum "")))
        (if (file-exists? archive)
          (let ((actual
                  (capture-first-line
                    (string-append
                      "sha256sum "
                      (shell-quote archive)
                      " | awk '{print $1}'"))))
            (unless (string=? actual expected)
              (dependency-error "registry archive checksum mismatch"
                (lock-entry-ref entry 'name '())
                (lock-entry-ref entry 'version "")
                expected
                actual
                '(diagnostic-code . "checksum-mismatch")))
            #t)
          #f)))

    (define (verify-registry-archives! lock)
      (let loop ((entries (lock-package-entries lock)) (count 0))
        (cond
          ((null? entries) count)
          ((eq? (lock-entry-type (car entries)) 'registry)
            (loop (cdr entries)
              (if (verify-registry-archive! (car entries))
                (+ count 1)
                count)))
          (else (loop (cdr entries) count)))))

    (define (verify-registry-metadata! lock)
      (let loop ((entries (lock-package-entries lock)) (count 0))
        (cond
          ((null? entries) count)
          ((eq? (lock-entry-type (car entries)) 'registry)
            (registry-package-candidates
              (lock-entry-ref (car entries) 'registry "default")
              (lock-entry-ref (car entries) 'name '())
              #t)
            (loop (cdr entries) (+ count 1)))
          (else (loop (cdr entries) count)))))

    (define (verify-current-lock! manifest features cmd lock)
      (unless (lock-resolution-current? manifest features cmd lock)
        (stale-lockfile-error manifest features cmd lock #t)))

    (define (verify-materialized-lock! manifest lock)
      (let ((missing (lock-missing-materializations lock #t manifest)))
        (unless (null? missing)
          (apply dependency-error
            "locked dependency is not materialized; run `kons fetch` first"
            (map missing-materialization-details missing))))
      (locked-activation-source-roots manifest lock #t))

    (define (verification-summary-sexp summary)
      `(verification
        (lockfile ,(verification-summary-lockfile summary))
        (packages ,(verification-summary-package-count summary))
        (registry-archives ,(verification-summary-registry-archive-count summary))
        (registry-metadata ,(verification-summary-registry-metadata-count summary))
        (status ok)))

    (define (verification-summary-json summary)
      `((formatVersion . 1)
        (kind . "verification")
        (lockfile . ,(verification-summary-lockfile summary))
        (packages . ,(verification-summary-package-count summary))
        (registryArchives . ,(verification-summary-registry-archive-count summary))
        (registryMetadata . ,(verification-summary-registry-metadata-count summary))
        (status . "ok")))

    (define (display-verification-summary cmd summary)
      (display "verified ")
      (displayln (verification-summary-lockfile summary))
      (writeln (verification-summary-sexp summary)))

    (define (cmd-verify cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (features (active-features manifest cmd))
             (lock-path (command-lock-path manifest cmd))
             (lock (stored-lockfile lock-path)))
        (ensure-supported-active-features manifest features cmd)
        (unless lock
          (lockfile-error "kons.lock missing; run `kons update` first"))
        (verify-current-lock! manifest features cmd lock)
        (verify-materialized-lock! manifest lock)
        (let ((archive-count (verify-registry-archives! lock))
              (metadata-count (verify-registry-metadata! lock)))
          (display-verification-summary
            cmd
            (make-verification-summary
              lock-path
              (length (lock-package-entries lock))
              archive-count
              metadata-count)))))))
