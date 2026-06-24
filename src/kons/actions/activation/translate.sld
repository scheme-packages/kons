(define-library (kons actions activation translate)
  (export r7rs->r6rs-translation-active?
          r7rs->r6rs-translation-active-for-scheme?
          r7rs->r6rs-translation-report
          translation-report->sexp
          translation-report-active?
          translation-report-scheme
          translation-report-target
          translation-report-libraries
          translation-library-report-name
          translation-library-report-source
          translation-library-report-output
          translation-library-report-unsupported
          unsupported-translation-form-source
          unsupported-translation-form-message
          unsupported-translation-form-form
          r7rs-standard-library->r6rs-imports
          r7rs-import-set-translatable?
          translated-r6rs-library-form
          write-r7rs->r6rs-translations-for-scheme!
          write-r7rs->r6rs-translations!)
  (import (scheme base)
          (scheme cxr)
          (scheme file)
          (scheme write)
          (kons util)
          (kons implementation)
          (kons manifest)
          (kons library-discovery)
          (kons options))

(begin
(define-record-type <translation-context>
  (make-translation-context manifest cmd active-features library-available?)
  translation-context?
  (manifest translation-context-manifest)
  (cmd translation-context-cmd)
  (active-features translation-context-active-features)
  (library-available? translation-context-library-available?))

(define-record-type <translated-library>
  (make-translated-library name source output form)
  translated-library?
  (name translated-library-name)
  (source translated-library-source)
  (output translated-library-output)
  (form translated-library-form))

(define-record-type <translation-library-report>
  (make-translation-library-report name source output unsupported)
  translation-library-report?
  (name translation-library-report-name)
  (source translation-library-report-source)
  (output translation-library-report-output)
  (unsupported translation-library-report-unsupported))

(define-record-type <translation-report>
  (make-translation-report active? scheme target libraries)
  translation-report?
  (active? translation-report-active?)
  (scheme translation-report-scheme)
  (target translation-report-target)
  (libraries translation-report-libraries))

(define-record-type <unsupported-translation-form>
  (make-unsupported-translation-form source message form)
  unsupported-translation-form?
  (source unsupported-translation-form-source)
  (message unsupported-translation-form-message)
  (form unsupported-translation-form-form))

(define-record-type <translation-state>
  (make-translation-state exports imports body)
  translation-state?
  (exports translation-state-exports)
  (imports translation-state-imports)
  (body translation-state-body))

(define (package-has-dialect? manifest dialect)
  (memq dialect (package-dialects manifest)))

(define (implementation-supports-dialect? scheme dialect)
  (and (implementation-mode-for-dialects scheme (list dialect)) #t))

(define (implementation-supports-package-dialects? manifest scheme)
  (and (implementation-mode-for-dialects scheme (package-dialects manifest)) #t))

(define (r7rs->r6rs-translation-active-for-scheme? manifest scheme)
  (and (package-has-dialect? manifest 'r7rs)
       (not (implementation-supports-package-dialects? manifest scheme))
       (implementation-supports-dialect? scheme 'r6rs)))

(define (r7rs->r6rs-translation-active? manifest cmd)
  (r7rs->r6rs-translation-active-for-scheme?
   manifest
   (command-selected-scheme cmd)))

(define (mkdir-for-library-path path)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path)))))

(define (included-path source path)
  (if (absolute-path? path) path (path-join (dirname source) path)))

(define (raise-unsupported-translation-form message source form)
  (manifest-error message source form))

(define (target-feature? feature context)
  (or (eq? feature 'r6rs)
      (memq feature (translation-context-active-features context))))

(define (cond-expand-requirement-true? req context)
  (cond
   ((eq? req 'else) #t)
   ((eq? req 'r7rs) #f)
   ((symbol? req) (and (target-feature? req context) #t))
   ((and (pair? req) (eq? (car req) 'and))
    (let loop ((items (cdr req)))
      (or (null? items)
          (and (cond-expand-requirement-true? (car items) context)
               (loop (cdr items))))))
   ((and (pair? req) (eq? (car req) 'or))
    (let loop ((items (cdr req)))
      (and (pair? items)
           (or (cond-expand-requirement-true? (car items) context)
               (loop (cdr items))))))
   ((and (pair? req) (eq? (car req) 'not) (pair? (cdr req)))
    (not (cond-expand-requirement-true? (cadr req) context)))
   ((and (pair? req) (eq? (car req) 'library) (pair? (cdr req)))
    ((translation-context-library-available? context) (cadr req)))
   (else #f)))

(define (selected-cond-expand-declarations clauses context)
  (let loop ((items clauses))
    (cond
     ((null? items) '())
     ((and (pair? (car items))
           (cond-expand-requirement-true? (caar items) context))
      (cdar items))
     (else (loop (cdr items))))))

(define (r7rs-standard-library-name? name)
  (and (pair? name)
       (eq? (car name) 'scheme)))

(define (r7rs-standard-library->r6rs-imports name)
  (cond
   ((not (r7rs-standard-library-name? name)) #f)
   ((equal? name '(scheme base)) '((rnrs base)))
   ((equal? name '(scheme case-lambda)) '((rnrs control)))
   ((equal? name '(scheme char)) '((rnrs unicode)))
   ((equal? name '(scheme complex)) '((rnrs base)))
   ((equal? name '(scheme cxr)) '((rnrs lists)))
   ((equal? name '(scheme eval)) '((rnrs eval)))
   ((equal? name '(scheme file)) '((rnrs files)))
   ((equal? name '(scheme inexact)) '((rnrs arithmetic flonums)))
   ((equal? name '(scheme process-context)) '((rnrs programs)))
   ((equal? name '(scheme read)) '((rnrs io simple)))
   ((equal? name '(scheme write)) '((rnrs io simple)))
   ((equal? name '(scheme r5rs)) '((rnrs r5rs)))
   (else #f)))

(define r7rs-lazy-r6rs-identifiers '(delay force))

(define (r7rs-lazy-r6rs-identifier? name)
  (and (symbol? name) (memq name r7rs-lazy-r6rs-identifiers) #t))

(define (r7rs-lazy-only-identifiers? names)
  (let loop ((items names))
    (or (null? items)
        (and (r7rs-lazy-r6rs-identifier? (car items))
             (loop (cdr items))))))

(define (r7rs-lazy-only-import->r6rs spec)
  (and (pair? spec)
       (eq? (car spec) 'only)
       (pair? (cdr spec))
       (equal? (cadr spec) '(scheme lazy))
       (r7rs-lazy-only-identifiers? (cddr spec))
       (list (append '(only (rnrs r5rs)) (cddr spec)))))

(define (r7rs-import-set->r6rs spec)
  (cond
   ((r7rs-lazy-only-import->r6rs spec))
   ((symbol-list-value? spec)
    (if (r7rs-standard-library-name? spec)
        (r7rs-standard-library->r6rs-imports spec)
        (list spec)))
   ((and (pair? spec)
         (memq (car spec) '(only except prefix rename))
         (pair? (cdr spec)))
    (let ((inner (r7rs-import-set->r6rs (cadr spec))))
      (if (and inner (pair? inner) (null? (cdr inner)))
          (list
           (cons (car spec)
                 (cons (car inner)
                       (cddr spec))))
          #f)))
   (else (list spec))))

(define (r7rs-import-set-translatable? spec)
  (and (r7rs-import-set->r6rs spec) #t))

(define (unsupported-import-set? spec)
  (not (r7rs-import-set-translatable? spec)))

(define (unsupported-import-sets declaration)
  (filter unsupported-import-set? (cdr declaration)))

(define (translated-import-sets spec)
  (or (r7rs-import-set->r6rs spec) '()))

(define (member-import-set? spec imports)
  (let loop ((items imports))
    (cond
     ((null? items) #f)
     ((equal? spec (car items)) #t)
     (else (loop (cdr items))))))

(define (dedupe-import-sets imports)
  (let loop ((items imports) (out '()))
    (cond
     ((null? items) (reverse out))
     ((member-import-set? (car items) out) (loop (cdr items) out))
     (else (loop (cdr items) (cons (car items) out))))))

(define (declaration-imports decl)
  (if (and (pair? decl) (eq? (car decl) 'import))
      (dedupe-import-sets (append-map translated-import-sets (cdr decl)))
      '()))

(define (export-spec->r6rs spec)
  (cond
   ((symbol? spec) spec)
   ((and (pair? spec)
         (eq? (car spec) 'rename)
         (pair? (cdr spec))
         (pair? (cddr spec))
         (null? (cdddr spec))
         (symbol? (cadr spec))
         (symbol? (caddr spec)))
    `(rename (,(cadr spec) ,(caddr spec))))
   (else
    (manifest-error "unsupported R7RS export spec for R6RS translation" spec))))

(define (export-spec-translatable? spec)
  (cond
   ((symbol? spec) #t)
   ((and (pair? spec)
         (eq? (car spec) 'rename)
         (pair? (cdr spec))
         (pair? (cddr spec))
         (null? (cdddr spec))
         (symbol? (cadr spec))
         (symbol? (caddr spec)))
    #t)
   (else #f)))

(define (declaration-exports decl)
  (if (and (pair? decl) (eq? (car decl) 'export))
      (map export-spec->r6rs (cdr decl))
      '()))

(define (read-included-exprs source path)
  (let ((include-path (included-path source path)))
    (unless (file-exists? include-path)
      (manifest-error "included translation source not found" include-path))
    (read-all-exprs include-path)))

(define (ascii-upper-case? ch)
  (and (char<=? #\A ch) (char<=? ch #\Z)))

(define (ascii-downcase ch)
  (if (ascii-upper-case? ch)
      (integer->char
       (+ (char->integer #\a)
          (- (char->integer ch) (char->integer #\A))))
      ch))

(define (ascii-string-downcase value)
  (list->string (map ascii-downcase (string->list value))))

(define (case-fold-symbol value)
  (string->symbol (ascii-string-downcase (symbol->string value))))

(define (case-fold-datum value)
  (cond
   ((symbol? value) (case-fold-symbol value))
   ((pair? value)
    (cons (case-fold-datum (car value))
          (case-fold-datum (cdr value))))
   ((vector? value)
    (list->vector (map case-fold-datum (vector->list value))))
   (else value)))

(define (read-case-folded-included-exprs source path)
  (map case-fold-datum (read-included-exprs source path)))

(define (append-translation-state left right)
  (make-translation-state
   (append (translation-state-exports left)
           (translation-state-exports right))
   (append (translation-state-imports left)
           (translation-state-imports right))
   (append (translation-state-body left)
           (translation-state-body right))))

(define empty-translation-state (make-translation-state '() '() '()))

(define (analyze-include-declaration source declaration context)
  (let loop ((files (cdr declaration)) (out '()))
    (cond
     ((null? files) out)
     ((string? (car files))
      (let ((path (included-path source (car files))))
        (if (file-exists? path)
            (loop (cdr files)
                  (append
                   out
                   (analyze-translation-declarations
                    path
                    (read-all-exprs path)
                    context)))
            (loop (cdr files)
                  (append
                   out
                   (list
                    (make-unsupported-translation-form
                     source
                     "included library declarations not found"
                     declaration)))))))
     (else
      (append
       out
       (list
        (unsupported-translation
         source
         "include-library-declarations entries must be strings"
         declaration)))))))

(define (analyze-body-include source declaration)
  (let loop ((files (cdr declaration)) (out '()))
    (cond
     ((null? files) out)
     ((string? (car files))
      (let ((path (included-path source (car files))))
        (if (file-exists? path)
            (loop (cdr files) out)
            (loop (cdr files)
                  (append
                   out
                   (list
                    (unsupported-translation
                     source
                     "included body source not found"
                     declaration)))))))
     (else
      (append
       out
       (list
        (unsupported-translation
         source
         "include entries must be strings"
         declaration)))))))

(define (analyze-cond-expand source declaration context)
  (analyze-translation-declarations
   source
   (selected-cond-expand-declarations (cdr declaration) context)
   context))

(define (analyze-import-declaration source declaration)
  (map
   (lambda (spec)
     (unsupported-translation
      source
      "R7RS import set has no R6RS translation mapping"
      spec))
   (unsupported-import-sets declaration)))

(define (analyze-export-declaration source declaration)
  (map
   (lambda (spec)
     (unsupported-translation
      source
      "unsupported R7RS export spec for R6RS translation"
      spec))
   (filter
    (lambda (spec) (not (export-spec-translatable? spec)))
    (cdr declaration))))

(define (analyze-translation-declaration source declaration context)
  (cond
   ((and (pair? declaration) (eq? (car declaration) 'export))
    (analyze-export-declaration source declaration))
   ((and (pair? declaration) (eq? (car declaration) 'begin))
    '())
   ((and (pair? declaration) (eq? (car declaration) 'import))
    (analyze-import-declaration source declaration))
   ((and (pair? declaration) (eq? (car declaration) 'include-library-declarations))
    (analyze-include-declaration source declaration context))
   ((and (pair? declaration) (memq (car declaration) '(include include-ci)))
    (analyze-body-include source declaration))
   ((and (pair? declaration) (eq? (car declaration) 'cond-expand))
    (analyze-cond-expand source declaration context))
   (else
    (list
     (unsupported-translation
      source
      "unsupported R7RS library declaration for R6RS translation"
      declaration)))))

(define (analyze-translation-declarations source declarations context)
  (let loop ((items declarations) (out '()))
    (cond
     ((null? items) out)
     (else
       (loop
        (cdr items)
        (append
         out
         (analyze-translation-declaration source (car items) context)))))))

(define (translate-declarations source declarations context)
  (let loop ((items declarations) (state empty-translation-state))
    (cond
     ((null? items) state)
     (else
      (loop
       (cdr items)
       (append-translation-state
        state
        (translate-declaration source (car items) context)))))))

(define (translate-include-declaration source declaration context)
  (let loop ((files (cdr declaration)) (state empty-translation-state))
    (cond
     ((null? files) state)
     ((string? (car files))
      (loop
       (cdr files)
       (append-translation-state
        state
        (translate-declarations
         (included-path source (car files))
         (read-included-exprs source (car files))
         context))))
     (else
      (raise-unsupported-translation-form
       "include-library-declarations entries must be strings"
       source
       declaration)))))

(define (translate-body-include source declaration)
  (let ((case-fold? (eq? (car declaration) 'include-ci)))
    (let loop ((files (cdr declaration)) (body '()))
      (cond
       ((null? files) (make-translation-state '() '() body))
       ((string? (car files))
        (loop
         (cdr files)
         (append
          body
          (if case-fold?
              (read-case-folded-included-exprs source (car files))
              (read-included-exprs source (car files))))))
       (else
        (raise-unsupported-translation-form
         "include entries must be strings"
         source
         declaration))))))

(define (translate-cond-expand source declaration context)
  (translate-declarations
   source
   (selected-cond-expand-declarations (cdr declaration) context)
   context))

(define (translate-declaration source declaration context)
  (cond
   ((and (pair? declaration) (eq? (car declaration) 'export))
    (make-translation-state (declaration-exports declaration) '() '()))
   ((and (pair? declaration) (eq? (car declaration) 'import))
    (make-translation-state '() (declaration-imports declaration) '()))
   ((and (pair? declaration) (eq? (car declaration) 'begin))
    (make-translation-state '() '() (cdr declaration)))
   ((and (pair? declaration) (eq? (car declaration) 'include-library-declarations))
    (translate-include-declaration source declaration context))
   ((and (pair? declaration) (memq (car declaration) '(include include-ci)))
    (translate-body-include source declaration))
   ((and (pair? declaration) (eq? (car declaration) 'cond-expand))
    (translate-cond-expand source declaration context))
   (else
    (raise-unsupported-translation-form
     "unsupported R7RS library declaration for R6RS translation"
     source
     declaration))))

(define (translated-r6rs-library-form source expr context)
  (unless (and (pair? expr)
               (eq? (car expr) 'define-library)
               (pair? (cdr expr))
               (symbol-list-value? (cadr expr)))
    (manifest-error "expected R7RS define-library form" source expr))
  (let* ((name (cadr expr))
         (state (translate-declarations source (cddr expr) context))
         (exports (translation-state-exports state))
         (imports (dedupe-import-sets (translation-state-imports state)))
         (body (translation-state-body state)))
    `(library ,name
       (export ,@exports)
       (import ,@(if (null? imports) '((rnrs)) imports))
       ,@body)))

(define (library-form-for-entry entry)
  (let ((source (library-entry-path "" entry)))
    (let loop ((exprs (read-all-exprs source)))
      (cond
       ((null? exprs) #f)
       ((and (pair? (car exprs))
             (eq? (caar exprs) 'define-library)
             (equal? (cadar exprs) (cadr entry)))
        (car exprs))
       (else (loop (cdr exprs)))))))

(define (translation-library-report-for-entry build-root entry context)
  (let* ((name (cadr entry))
         (source (library-entry-path "" entry))
         (output (r6rs-library-source-path build-root name))
         (expr (library-form-for-entry entry))
          (unsupported
           (if expr
               (analyze-translation-declarations source (cddr expr) context)
               (list
                (make-unsupported-translation-form
                 source
                 "R7RS library source not found for translation"
                 name)))))
    (make-translation-library-report name source output unsupported)))

(define (manifest-library-entry-available? name entries)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((same-library-name? name (cadr (car items))) #t)
     (else (loop (cdr items))))))

(define (translation-library-available? manifest name)
  (or (and (r7rs-standard-library-name? name)
           (r7rs-standard-library->r6rs-imports name)
           #t)
      (manifest-library-entry-available?
       name
       (r7rs-library-entries/context manifest #f))
      (manifest-library-entry-available?
       name
       (r6rs-library-entries/context manifest #f))))

(define (translation-context-for manifest active-features)
  (make-translation-context
   manifest
   #f
   active-features
   (lambda (name)
     (translation-library-available? manifest name))))

(define (r7rs->r6rs-translation-report manifest active-features scheme build-root)
  (if (r7rs->r6rs-translation-active-for-scheme? manifest scheme)
      (let ((context (translation-context-for manifest active-features)))
        (make-translation-report
         #t
         scheme
         'r6rs
         (map
          (lambda (entry)
            (translation-library-report-for-entry build-root entry context))
          (r7rs-library-entries/context manifest #f))))
      (make-translation-report #f scheme #f '())))

(define (unsupported-translation-form->sexp item)
  `(unsupported
    (source ,(unsupported-translation-form-source item))
    (message ,(unsupported-translation-form-message item))
    (form ,(unsupported-translation-form-form item))))

(define (translation-library-report->sexp item)
  `(library
    (name ,(translation-library-report-name item))
    (source ,(translation-library-report-source item))
    (output ,(translation-library-report-output item))
    (status ,(if (null? (translation-library-report-unsupported item))
                 'translated
                 'unsupported))
    (unsupported ,@(map unsupported-translation-form->sexp
                        (translation-library-report-unsupported item)))))

(define (translation-report->sexp report)
  `(translation
    (active ,(translation-report-active? report))
    (scheme ,(translation-report-scheme report))
    (target ,(translation-report-target report))
    (libraries ,@(map translation-library-report->sexp
                      (translation-report-libraries report)))))

(define (translated-library-for-entry build-root entry context)
  (let* ((name (cadr entry))
         (source (library-entry-path "" entry))
         (output (r6rs-library-source-path build-root name))
         (expr (library-form-for-entry entry)))
    (unless expr
      (manifest-error "R7RS library source not found for translation" name source))
    (make-translated-library
     name
     source
     output
     (translated-r6rs-library-form source expr context))))

(define (write-translated-library! translated)
  (mkdir-for-library-path (translated-library-output translated))
  (write-expr-file
   (translated-library-output translated)
   (translated-library-form translated)))

(define (write-r7rs->r6rs-translations-for-scheme! manifest active-features scheme build-root)
  (when (r7rs->r6rs-translation-active-for-scheme? manifest scheme)
    (let ((context (translation-context-for manifest active-features)))
      (for-each
       (lambda (entry)
         (write-translated-library!
          (translated-library-for-entry build-root entry context)))
       (r7rs-library-entries/context manifest #f)))))

(define (write-r7rs->r6rs-translations! manifest active-features cmd build-root)
  (write-r7rs->r6rs-translations-for-scheme!
   manifest
   active-features
   (command-selected-scheme cmd)
   build-root))

)
)
