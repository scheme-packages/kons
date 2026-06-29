(define-library (kons actions compat-scan)
  (export cmd-compat-scan
    compat-scan-report
    compat-report-diagnostics
    compat-diagnostic-status
    compat-diagnostic-import
    compat-diagnostic-advice
    compat-report-translations
    compat-import-name)
  (import (scheme base)
    (scheme write)
    (kons util)
    (kons manifest)
    (kons features)
    (kons runner)
    (kons options)
    (kons actions paths)
    (kons actions activation)
    (kons actions activation translate)
    (kons implementation)
    (kons compat json)
    (kons library-discovery))

  (begin
    (define-record-type <compat-import>
      (make-compat-import library path name spec)
      compat-import?
      (library compat-import-library)
      (path compat-import-path)
      (name compat-import-name)
      (spec compat-import-spec))

    (define-record-type <compat-diagnostic>
      (make-compat-diagnostic status reason advice import)
      compat-diagnostic?
      (status compat-diagnostic-status)
      (reason compat-diagnostic-reason)
      (advice compat-diagnostic-advice)
      (import compat-diagnostic-import))

    (define-record-type <compat-report>
      (make-compat-report name version features scheme standard libraries diagnostics translations)
      compat-report?
      (name compat-report-name)
      (version compat-report-version)
      (features compat-report-features)
      (scheme compat-report-scheme)
      (standard compat-report-standard)
      (libraries compat-report-libraries)
      (diagnostics compat-report-diagnostics)
      (translations compat-report-translations))

    (define (same-name? left right)
      (equal? left right))

    (define (name-present? name names)
      (let loop ((items names))
        (cond
          ((null? items) #f)
          ((same-name? name (car items)) #t)
          (else (loop (cdr items))))))

    (define (same-import? left right)
      (and (equal? (compat-import-library left) (compat-import-library right))
        (equal? (compat-import-path left) (compat-import-path right))
        (equal? (compat-import-name left) (compat-import-name right))
        (equal? (compat-import-spec left) (compat-import-spec right))))

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

    (define (source-root-manifest source-root)
      (let ((package-root (find-package-root-for-source-root source-root)))
        (and package-root
          (parse-manifest (path-join package-root "kons.scm")))))

    (define (source-root-libraries source-root)
      (let ((manifest (source-root-manifest source-root)))
        (if manifest
          (effective-package-libraries manifest)
          '())))

    (define (source-roots-libraries source-roots)
      (append-map source-root-libraries source-roots))

    (define (library-entry->imports source-root entry)
      (let ((path (library-entry-path source-root entry)))
        (map
          (lambda (spec)
            (let ((name (import-set-library-name spec)))
              (make-compat-import
                (cadr entry)
                path
                name
                spec)))
          (filter import-set-library-name
            (library-entry-import-specs/context source-root entry #f)))))

    (define (symbol-name? value text)
      (and (symbol? value)
        (string=? (symbol->string value) text)))

    (define (name-head? name text)
      (and (pair? name)
        (symbol-name? (car name) text)))

    (define (implementation-feature? mode feature)
      (let loop ((items (implementation-mode-features mode)))
        (cond
          ((null? items) #f)
          ((eq? feature (car items)) #t)
          (else (loop (cdr items))))))

    (define (standard-import-supported? name standard mode)
      (cond
        ((name-head? name "scheme") (eq? standard 'r7rs))
        ((name-head? name "rnrs") (eq? standard 'r6rs))
        ((name-head? name "srfi") #t)
        ((name-head? name "guile") (implementation-feature? mode 'guile))
        ((name-head? name "ice-9") (implementation-feature? mode 'guile))
        ((name-head? name "chezscheme") (implementation-feature? mode 'chez))
        ((name-head? name "gauche") (implementation-feature? mode 'gauche))
        ((name-head? name "util") (implementation-feature? mode 'gauche))
        ((name-head? name "rfc") (implementation-feature? mode 'gauche))
        ((name-head? name "text") (implementation-feature? mode 'gauche))
        ((name-head? name "data") (implementation-feature? mode 'gauche))
        (else #f)))

    (define (compat-advice status reason)
      (case status
        ((provided) "")
        ((implementation-unsupported)
          "select a compatible Scheme implementation or use a dependency variant for this import")
        ((missing)
          "add a dependency that provides this library, or replace the import with a supported variant")
        (else
          (string-append "review compatibility reason " (symbol->string reason)))))

    (define (make-import-diagnostic status reason import)
      (make-compat-diagnostic
        status
        reason
        (compat-advice status reason)
        import))

    (define (compat-diagnostic-for-import import provided-names standard mode translation-active?)
      (let ((name (compat-import-name import))
            (spec (compat-import-spec import)))
        (cond
          ((name-present? name provided-names)
            (make-import-diagnostic 'provided 'local-library import))
          ((and translation-active?
             (name-head? name "scheme")
             (r7rs-import-set-translatable? spec))
            (make-import-diagnostic 'provided 'translated-standard-library import))
          ((and translation-active? (name-head? name "scheme"))
            (make-import-diagnostic 'implementation-unsupported 'translation-mapping import))
          ((standard-import-supported? name standard mode)
            (make-import-diagnostic 'provided 'implementation-library import))
          ((or (name-head? name "scheme")
              (name-head? name "rnrs")
              (name-head? name "guile")
              (name-head? name "ice-9")
              (name-head? name "chezscheme")
              (name-head? name "gauche")
              (name-head? name "util")
              (name-head? name "rfc")
              (name-head? name "text")
              (name-head? name "data"))
            (make-import-diagnostic 'implementation-unsupported 'selected-implementation import))
          (else
            (make-import-diagnostic 'missing 'unknown-provider import)))))

    (define (compat-scan-mode manifest scheme)
      (or (implementation-mode-for-dialects scheme (package-dialects manifest))
        (and (r7rs->r6rs-translation-active-for-scheme? manifest scheme)
          (or (implementation-mode-for-dialects scheme '(r6rs))
            (implementation-mode scheme)))))

    (define (translation-report-build-root manifest features maybe-cmd)
      (if (null? maybe-cmd)
        (path-join (project-kons-path manifest "builds") "translation-report")
        (build-output-dir manifest features (car maybe-cmd))))

    (define (compat-scan-report manifest features scheme . maybe-cmd)
      (let* ((effective-scheme
               (if (null? maybe-cmd)
                 scheme
                 (command-adapter-scheme manifest (car maybe-cmd))))
             (mode (compat-scan-mode manifest effective-scheme))
             (standard (and mode (implementation-mode-field mode 'standard #f)))
             (translation-report
               (r7rs->r6rs-translation-report
                 manifest
                 features
                 effective-scheme
                 (translation-report-build-root manifest features maybe-cmd)))
             (translation-active? (translation-report-active? translation-report)))
        (unless mode
          (usage-error
            "selected scheme does not support package dialects; select a compatible implementation or dependency variant"
            scheme
            (package-dialects manifest)))
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
               (provided-names (map cadr provider-libraries))
               (imports (dedupe-imports
                         (append-map
                           (lambda (entry)
                             (library-entry->imports source-root entry))
                           root-libraries)))
               (diagnostics (map (lambda (import)
                                  (compat-diagnostic-for-import
                                    import
                                    provided-names
                                    standard
                                    mode
                                    translation-active?))
                             imports)))
          (make-compat-report
            (package-name manifest)
            (package-version manifest)
            features
            scheme
            standard
            provider-libraries
            diagnostics
            translation-report))))

    (define (compat-import->sexp import)
      `(import
        (library ,(compat-import-library import))
        (path ,(compat-import-path import))
        (name ,(compat-import-name import))
        (spec ,(compat-import-spec import))))

    (define (compat-diagnostic->sexp diagnostic)
      `(diagnostic
        (status ,(compat-diagnostic-status diagnostic))
        (reason ,(compat-diagnostic-reason diagnostic))
        (advice ,(compat-diagnostic-advice diagnostic))
        ,(compat-import->sexp (compat-diagnostic-import diagnostic))))

    (define (library-entry->sexp entry)
      `(library
        (kind ,(car entry))
        (name ,(cadr entry))
        (path ,(library-entry-path "" entry))
        (imports ,@(library-entry-imports entry))
        (exports ,@(library-entry-exports entry))))

    (define (report->sexp report)
      `(compat-scan
        (root
         (name ,(compat-report-name report))
         (version ,(compat-report-version report))
         (features ,@(compat-report-features report)))
        (implementation
         (scheme ,(compat-report-scheme report))
         (standard ,(compat-report-standard report)))
        (libraries ,@(map library-entry->sexp (compat-report-libraries report)))
        ,(translation-report->sexp (compat-report-translations report))
        (diagnostics ,@(map compat-diagnostic->sexp
                        (compat-report-diagnostics report)))))

    (define (scan-value->json value)
      (cond
        ((symbol? value) (symbol->string value))
        ((or (string? value) (number? value) (boolean? value)) value)
        ((null? value) '#())
        ((pair? value) (list->vector (map scan-value->json value)))
        (else #f)))

    (define (compat-import->json import)
      `((library . ,(scan-value->json (compat-import-library import)))
        (path . ,(compat-import-path import))
        (name . ,(scan-value->json (compat-import-name import)))
        (spec . ,(scan-value->json (compat-import-spec import)))))

    (define (compat-diagnostic->json diagnostic)
      `((status . ,(scan-value->json (compat-diagnostic-status diagnostic)))
        (reason . ,(scan-value->json (compat-diagnostic-reason diagnostic)))
        (advice . ,(compat-diagnostic-advice diagnostic))
        (import . ,(compat-import->json (compat-diagnostic-import diagnostic)))))

    (define (unsupported-translation-form->json item)
      `((source . ,(unsupported-translation-form-source item))
        (message . ,(unsupported-translation-form-message item))
        (form . ,(scan-value->json (unsupported-translation-form-form item)))))

    (define (translation-library-report->json item)
      `((name . ,(scan-value->json (translation-library-report-name item)))
        (source . ,(translation-library-report-source item))
        (output . ,(translation-library-report-output item))
        (status . ,(if (null? (translation-library-report-unsupported item))
                    "translated"
                    "unsupported"))
        (unsupported . ,(list->vector
                         (map unsupported-translation-form->json
                           (translation-library-report-unsupported item))))))

    (define (translation-report->json report)
      `((active . ,(translation-report-active? report))
        (scheme . ,(scan-value->json (translation-report-scheme report)))
        (target . ,(scan-value->json (translation-report-target report)))
        (libraries . ,(list->vector
                       (map translation-library-report->json
                         (translation-report-libraries report))))))

    (define (library-entry->json entry)
      `((kind . ,(scan-value->json (car entry)))
        (name . ,(scan-value->json (cadr entry)))
        (path . ,(library-entry-path "" entry))
        (imports . ,(scan-value->json (library-entry-imports entry)))
        (exports . ,(scan-value->json (library-entry-exports entry)))))

    (define (report->json report)
      `((formatVersion . 1)
        (root . ((name . ,(scan-value->json (compat-report-name report)))
                 (version . ,(compat-report-version report))
                 (features . ,(scan-value->json (compat-report-features report)))))
        (implementation . ((scheme . ,(scan-value->json (compat-report-scheme report)))
                           (standard . ,(scan-value->json (compat-report-standard report)))))
        (libraries . ,(list->vector
                       (map library-entry->json (compat-report-libraries report))))
        (translations . ,(translation-report->json
                          (compat-report-translations report)))
        (diagnostics . ,(list->vector
                         (map compat-diagnostic->json
                           (compat-report-diagnostics report))))))

    (define (write-report-json report)
      (json-write (report->json report) (current-output-port))
      (newline))

    (define (write-compat-scan-report cmd report)
      (writeln (report->sexp report)))

    (define (cmd-compat-scan cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (features (active-features manifest cmd)))
        (ensure-supported-active-features manifest features cmd)
        (write-compat-scan-report
          cmd
          (compat-scan-report manifest features (command-selected-scheme cmd) cmd))))))
