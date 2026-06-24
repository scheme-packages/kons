(define-library (kons actions archive-scan)
  (export cmd-archive-scan
          archive-scan-report
          archive-scan-report-libraries
          archive-scan-report-identifiers)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons util)
          (kons manifest)
          (kons options)
          (kons compat json)
          (kons library-discovery))

  (begin
(define-record-type <archive-library>
  (make-archive-library kind name path imports exports)
  archive-library?
  (kind archive-library-kind)
  (name archive-library-name)
  (path archive-library-path)
  (imports archive-library-imports)
  (exports archive-library-exports))

(define-record-type <archive-identifier>
  (make-archive-identifier library path name)
  archive-identifier?
  (library archive-identifier-library)
  (path archive-identifier-path)
  (name archive-identifier-name))

(define-record-type <archive-scan-report>
  (make-archive-scan-report source archive root name version license license-status libraries identifiers)
  archive-scan-report?
  (source archive-scan-report-source)
  (archive archive-scan-report-archive)
  (root archive-scan-report-root)
  (name archive-scan-report-name)
  (version archive-scan-report-version)
  (license archive-scan-report-license)
  (license-status archive-scan-report-license-status)
  (libraries archive-scan-report-libraries)
  (identifiers archive-scan-report-identifiers))

(define (json-format? value)
  (and value (string=? value "json")))

(define (license-status license)
  (if (and (string? license)
           (not (string=? license "")))
      'known
      'missing))

(define (relative-path root path)
  (let ((prefix (string-append root "/")))
    (if (and (>= (string-length path) (string-length prefix))
             (string=? (substring path 0 (string-length prefix)) prefix))
        (substring path (string-length prefix) (string-length path))
        path)))

(define (library-entry->archive-library source-root entry)
  (make-archive-library
   (car entry)
   (cadr entry)
   (relative-path source-root (library-entry-path source-root entry))
   (library-entry-imports entry)
   (library-entry-exports entry)))

(define (archive-library->identifiers library)
  (map (lambda (identifier)
         (make-archive-identifier
          (archive-library-name library)
          (archive-library-path library)
          identifier))
       (filter symbol? (archive-library-exports library))))

(define (libraries-for-manifest manifest)
  (map (lambda (entry)
         (library-entry->archive-library
          (manifest-source-root manifest)
          entry))
       (effective-package-libraries manifest)))

(define (archive-scan-report manifest source archive)
  (let ((libraries (libraries-for-manifest manifest)))
    (make-archive-scan-report
     source
     archive
     (manifest-root manifest)
     (package-name manifest)
     (package-version manifest)
     (package-license manifest)
     (license-status (package-license manifest))
     libraries
     (append-map archive-library->identifiers libraries))))

(define (archive-library->sexp library)
  `(library
    (kind ,(archive-library-kind library))
    (name ,(archive-library-name library))
    (path ,(archive-library-path library))
    (imports ,@(archive-library-imports library))
    (exports ,@(archive-library-exports library))))

(define (archive-identifier->sexp identifier)
  `(identifier
    (library ,(archive-identifier-library identifier))
    (path ,(archive-identifier-path identifier))
    (name ,(archive-identifier-name identifier))))

(define (report->sexp report)
  `(archive-scan
    (source ,(archive-scan-report-source report))
    (archive ,(archive-scan-report-archive report))
    (root
     (path ,(archive-scan-report-root report))
     (name ,(archive-scan-report-name report))
     (version ,(archive-scan-report-version report))
     (license ,(archive-scan-report-license report))
     (license-status ,(archive-scan-report-license-status report)))
    (libraries ,@(map archive-library->sexp
                      (archive-scan-report-libraries report)))
    (identifiers ,@(map archive-identifier->sexp
                        (archive-scan-report-identifiers report)))))

(define (scan-value->json value)
  (cond
   ((symbol? value) (symbol->string value))
   ((or (string? value) (number? value) (boolean? value)) value)
   ((null? value) '#())
   ((pair? value) (list->vector (map scan-value->json value)))
   (else #f)))

(define (archive-library->json library)
  `((kind . ,(scan-value->json (archive-library-kind library)))
    (name . ,(scan-value->json (archive-library-name library)))
    (path . ,(archive-library-path library))
    (imports . ,(scan-value->json (archive-library-imports library)))
    (exports . ,(scan-value->json (archive-library-exports library)))))

(define (archive-identifier->json identifier)
  `((library . ,(scan-value->json (archive-identifier-library identifier)))
    (path . ,(archive-identifier-path identifier))
    (name . ,(scan-value->json (archive-identifier-name identifier)))))

(define (report->json report)
  `((formatVersion . 1)
    (source . ,(scan-value->json (archive-scan-report-source report)))
    (archive . ,(or (archive-scan-report-archive report) #f))
    (root . ((path . ,(archive-scan-report-root report))
             (name . ,(scan-value->json (archive-scan-report-name report)))
             (version . ,(archive-scan-report-version report))
             (license . ,(archive-scan-report-license report))
             (licenseStatus . ,(scan-value->json
                                (archive-scan-report-license-status report)))))
    (libraries . ,(list->vector
                   (map archive-library->json
                        (archive-scan-report-libraries report))))
    (identifiers . ,(list->vector
                     (map archive-identifier->json
                          (archive-scan-report-identifiers report))))))

(define (write-report-json report)
  (json-write (report->json report) (current-output-port))
  (newline))

(define (extract-archive archive)
  (let ((root (temporary-file-path "kons-archive-scan")))
    (run-command (string-append "mkdir -p " (shell-quote root)))
    (run-command
     (string-append
      "tar -xzf " (shell-quote archive)
      " -C " (shell-quote root)))
    root))

(define (manifest-from-archive archive)
  (let* ((root (extract-archive archive))
         (manifest-path (path-join root "kons.scm")))
    (unless (file-exists? manifest-path)
      (manifest-error "archive is missing kons.scm" archive))
    (parse-manifest manifest-path)))

(define (write-archive-scan-report cmd report)
  (if (json-format? (command-option cmd "format" "sexp"))
      (write-report-json report)
      (writeln (report->sexp report))))

(define (cmd-archive-scan cmd)
  (let ((archive (command-option cmd "archive" #f)))
    (if archive
        (write-archive-scan-report
         cmd
         (archive-scan-report
          (manifest-from-archive archive)
          'archive
          archive))
        (write-archive-scan-report
         cmd
         (archive-scan-report
          (parse-manifest (command-manifest-path cmd))
          'checkout
          #f)))))

  ))
