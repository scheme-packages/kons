(define-library (kons actions dependency-scan)
  (export cmd-dependency-scan
    dependency-scan-report
    scan-report-libraries
    scan-report-imports
    scan-report-missing
    scan-import-name)
  (import (scheme base)
    (scheme write)
    (kons util)
    (kons manifest)
    (kons features)
    (kons runner)
    (kons options)
    (kons actions paths)
    (kons compat json)
    (kons library-discovery))

  (begin
    (define-record-type <scan-library>
      (make-scan-library kind name path imports exports)
      scan-library?
      (kind scan-library-kind)
      (name scan-library-name)
      (path scan-library-path)
      (imports scan-library-imports)
      (exports scan-library-exports))

    (define-record-type <scan-import>
      (make-scan-import library path name)
      scan-import?
      (library scan-import-library)
      (path scan-import-path)
      (name scan-import-name))

    (define-record-type <scan-report>
      (make-scan-report name version features libraries imports missing)
      scan-report?
      (name scan-report-name)
      (version scan-report-version)
      (features scan-report-features)
      (libraries scan-report-libraries)
      (imports scan-report-imports)
      (missing scan-report-missing))

    (define (library-entry->scan-library source-root entry)
      (make-scan-library
        (car entry)
        (cadr entry)
        (library-entry-path source-root entry)
        (library-entry-imports entry)
        (library-entry-exports entry)))

    (define (source-root-manifest source-root)
      (let ((package-root (find-package-root-for-source-root source-root)))
        (and package-root
          (parse-manifest (path-join package-root "kons.scm")))))

    (define (source-root-libraries source-root)
      (let ((manifest (source-root-manifest source-root)))
        (if manifest
          (map (lambda (entry)
                (library-entry->scan-library source-root entry))
            (effective-package-libraries manifest))
          '())))

    (define (source-roots-libraries source-roots)
      (append-map source-root-libraries source-roots))

    (define (scan-library->imports library)
      (map (lambda (name)
            (make-scan-import
              (scan-library-name library)
              (scan-library-path library)
              name))
        (scan-library-imports library)))

    (define (same-name? left right)
      (equal? left right))

    (define (name-present? name names)
      (let loop ((items names))
        (cond
          ((null? items) #f)
          ((same-name? name (car items)) #t)
          (else (loop (cdr items))))))

    (define (symbol-name? value text)
      (and (symbol? value)
        (string=? (symbol->string value) text)))

    (define (standard-import-name? name)
      (and (pair? name)
        (let ((head (car name)))
          (or (symbol-name? head "scheme")
            (symbol-name? head "srfi")
            (symbol-name? head "rnrs")
            (symbol-name? head "ice-9")
            (symbol-name? head "gauche")
            (symbol-name? head "util")
            (symbol-name? head "rfc")
            (symbol-name? head "text")
            (symbol-name? head "data")))))

    (define (provided-import? import provided-names)
      (name-present? (scan-import-name import) provided-names))

    (define (missing-import? import provided-names)
      (and (not (provided-import? import provided-names))
        (not (standard-import-name? (scan-import-name import)))))

    (define (same-import? left right)
      (and (equal? (scan-import-library left) (scan-import-library right))
        (equal? (scan-import-path left) (scan-import-path right))
        (equal? (scan-import-name left) (scan-import-name right))))

    (define (import-present? import imports)
      (let loop ((items imports))
        (cond
          ((null? items) #f)
          ((same-import? import (car items)) #t)
          (else (loop (cdr items))))))

    (define (dedupe-imports imports)
      (let loop ((items imports) (out '()))
        (cond
          ((null? items) (reverse out))
          ((import-present? (car items) out) (loop (cdr items) out))
          (else (loop (cdr items) (cons (car items) out))))))

    (define (dependency-scan-report manifest features . maybe-cmd)
      (let* ((source-root (manifest-source-root manifest))
             (root-libraries (source-root-libraries source-root))
             (provider-libraries
               (if (null? maybe-cmd)
                 root-libraries
                 (source-roots-libraries
                   (effective-activation-source-roots
                     manifest
                     #f
                     features
                     (car maybe-cmd)))))
             (provided-names (map scan-library-name provider-libraries))
             (imports (dedupe-imports (append-map scan-library->imports root-libraries)))
             (missing (filter (lambda (import)
                               (missing-import? import provided-names))
                       imports)))
        (make-scan-report
          (package-name manifest)
          (package-version manifest)
          features
          provider-libraries
          imports
          missing)))

    (define (scan-library->sexp library)
      `(library
        (kind ,(scan-library-kind library))
        (name ,(scan-library-name library))
        (path ,(scan-library-path library))
        (imports ,@(scan-library-imports library))
        (exports ,@(scan-library-exports library))))

    (define (scan-import->sexp import)
      `(import
        (library ,(scan-import-library import))
        (path ,(scan-import-path import))
        (name ,(scan-import-name import))))

    (define (report->sexp report)
      `(dependency-scan
        (root
         (name ,(scan-report-name report))
         (version ,(scan-report-version report))
         (features ,@(scan-report-features report)))
        (libraries ,@(map scan-library->sexp (scan-report-libraries report)))
        (imports ,@(map scan-import->sexp (scan-report-imports report)))
        (missing ,@(map scan-import->sexp (scan-report-missing report)))))

    (define (scan-value->json value)
      (cond
        ((symbol? value) (symbol->string value))
        ((or (string? value) (number? value) (boolean? value)) value)
        ((null? value) '#())
        ((pair? value) (list->vector (map scan-value->json value)))
        (else #f)))

    (define (scan-library->json library)
      `((kind . ,(scan-value->json (scan-library-kind library)))
        (name . ,(scan-value->json (scan-library-name library)))
        (path . ,(scan-library-path library))
        (imports . ,(scan-value->json (scan-library-imports library)))
        (exports . ,(scan-value->json (scan-library-exports library)))))

    (define (scan-import->json import)
      `((library . ,(scan-value->json (scan-import-library import)))
        (path . ,(scan-import-path import))
        (name . ,(scan-value->json (scan-import-name import)))))

    (define (report->json report)
      `((formatVersion . 1)
        (root . ((name . ,(scan-value->json (scan-report-name report)))
                 (version . ,(scan-report-version report))
                 (features . ,(scan-value->json (scan-report-features report)))))
        (libraries . ,(list->vector
                       (map scan-library->json (scan-report-libraries report))))
        (imports . ,(list->vector
                     (map scan-import->json (scan-report-imports report))))
        (missing . ,(list->vector
                     (map scan-import->json (scan-report-missing report))))))

    (define (write-report-json report)
      (json-write (report->json report) (current-output-port))
      (newline))

    (define (write-dependency-scan-report cmd report)
      (writeln (report->sexp report)))

    (define (cmd-dependency-scan cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (features (active-features manifest cmd)))
        (ensure-supported-active-features manifest features cmd)
        (write-dependency-scan-report
          cmd
          (dependency-scan-report manifest features cmd))))))
