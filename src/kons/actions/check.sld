(define-library (kons actions check)
  (export cmd-check)
  (import (scheme base)
          (scheme file)
          (scheme process-context)
          (scheme write)
          (kons util)
          (kons names)
          (kons implementation)
          (kons manifest)
          (kons features)
          (kons lock)
          (kons runner)
          (kons options)
          (kons library-discovery)
          (kons actions paths)
          (kons actions activation)
          (kons actions activation translate)
          (kons actions targets))

  (begin
(define (translation-library-unsupported-count library)
  (length (translation-library-report-unsupported library)))

(define (translation-report-unsupported-count report)
  (let loop ((items (translation-report-libraries report)) (count 0))
    (if (null? items)
        count
        (loop (cdr items)
              (+ count
                 (translation-library-unsupported-count (car items)))))))

(define (unsupported-translation-form-detail item)
  `((source . ,(unsupported-translation-form-source item))
    (message . ,(unsupported-translation-form-message item))
    (form . ,(unsupported-translation-form-form item))))

(define (translation-library-unsupported-detail library)
  `((name . ,(translation-library-report-name library))
    (source . ,(translation-library-report-source library))
    (output . ,(translation-library-report-output library))
    (unsupported . ,(list->vector
                     (map unsupported-translation-form-detail
                          (translation-library-report-unsupported library))))))

(define (translation-report-unsupported-detail report unsupported-count)
  `((active . ,(translation-report-active? report))
    (scheme . ,(translation-report-scheme report))
    (target . ,(translation-report-target report))
    (unsupported-count . ,unsupported-count)
    (libraries . ,(list->vector
                   (map translation-library-unsupported-detail
                        (translation-report-libraries report))))))

(define (display-translation-library-report library)
  (display "translated: ")
  (display (translation-library-report-source library))
  (display " -> ")
  (displayln (translation-library-report-output library))
  (for-each
   (lambda (item)
     (display "unsupported translation form: ")
     (display (unsupported-translation-form-source item))
     (display ": ")
     (display (unsupported-translation-form-message item))
     (display " ")
     (write (unsupported-translation-form-form item))
     (newline))
   (translation-library-report-unsupported library)))

(define (display-translation-report report)
  (when (translation-report-active? report)
    (for-each display-translation-library-report
              (translation-report-libraries report))))

(define (ensure-translation-report-supported! report)
  (let ((unsupported-count (translation-report-unsupported-count report)))
    (when (> unsupported-count 0)
      (if (message-format-json?)
          (manifest-error
           "unsupported R7RS forms for R6RS translation"
           unsupported-count
           `((translation . ,(translation-report-unsupported-detail
                              report
                              unsupported-count)))
           '(diagnostic-code . "unsupported-translation"))
          (manifest-error
           "unsupported R7RS forms for R6RS translation"
           unsupported-count)))))

(define (cmd-check cmd)
  (let* ((manifest (parse-manifest (command-manifest-path cmd)))
         (features (active-features manifest cmd))
         (translation-report
          (r7rs->r6rs-translation-report
           manifest
           features
           (command-selected-scheme cmd)
           (build-output-dir manifest features cmd))))
    (ensure-supported-active-features manifest features cmd)
    (unless (command-flag? cmd "plan")
      (display-translation-report translation-report)
      (ensure-translation-report-supported! translation-report))
    (unless (command-flag? cmd "plan")
      (begin
        (implementation-probe (adapter-scheme manifest (command-selected-scheme cmd)))
        (ensure-dev-activation-ready! manifest features cmd)
        (ensure-implementation-compiled! manifest features cmd)))
    (let ((srcs (activation-source-roots-with-build manifest #t features cmd)))
      (check-system-dependencies manifest cmd #t features srcs)
      (if (command-flag? cmd "plan")
          (writeln
           `(check-plan
             (root ,(package-name manifest))
             (features ,@features)
             (profile ,(command-selected-profile cmd))
             (main ,(or (package-main-path manifest) #f))
             (tests ,@(package-test-files manifest))
             (benches ,@(package-bench-files manifest))
             (examples ,@(map (lambda (example)
                                 `(,(car example) ,(cdr example)))
                               (package-example-files manifest)))
             (bins ,@(map (lambda (bin)
                            `(,(car bin) ,(manifest-source-path manifest (cdr bin))))
                          (package-bins manifest)))
             (scripts ,@(map (lambda (script)
                               `(,(car script) ,(manifest-root-path manifest (cdr script))))
                             (package-scripts manifest)))
             (libraries ,@(library-entry-files manifest))
             ,(translation-report->sexp translation-report)
             (source-roots ,@srcs)
             (load-paths ,@srcs)
             (dependencies ,@(all-dependencies-for manifest #t features cmd))))
          (begin
            (validate-declared-libraries manifest)
            (validate-entrypoints manifest)
            (display "checked ")
            (displayln (name->string (package-name manifest))))))))

  ))
