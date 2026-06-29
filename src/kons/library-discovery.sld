(define-library (kons library-discovery)
  (export library-name-token
    library-source-path
    module-source-path
    r6rs-library-source-path
    string->path-parts
    gauche-module-source-path
    symbol-list-value?
    make-library-discovery-context
    effective-package-libraries
    effective-package-libraries/context
    effective-public-package-libraries
    manifest-with-effective-libraries
    library-entry-path
    library-entry-dialect
    library-entry-implementation
    library-entry-imports
    import-set-library-name
    library-entry-import-specs/context
    library-entry-exports
    library-key-entry
    r7rs-library-entry-name
    r6rs-library-entry-name
    guile-library-entry-name
    gauche-library-entry-name
    r7rs-library-entries/context
    r7rs-library-names
    r7rs-library-names/context
    r6rs-library-entries/context
    r6rs-library-names
    guile-library-entries/context
    guile-library-names
    guile-library-names/context)
  (import (scheme base)
    (scheme cxr)
    (scheme file)
    (kons compat files)
    (kons util)
    (kons manifest))

  (begin
    (define (package-libraries manifest)
      (alist-ref (alist-ref manifest 'package '()) 'libraries '()))

    (define (library-name-part? value)
      (or (symbol? value) (number? value)))

    (define (library-name-part->string value)
      (cond
        ((symbol? value) (symbol->string value))
        ((number? value) (number->string value))
        (else (manifest-error "library name part must be a symbol or number" value))))

    (define (library-name->string name)
      (if (symbol? name)
        (symbol->string name)
        (string-join (map library-name-part->string name) " ")))

    (define (library-name-token name)
      (safe-store-token (library-name->string name)))

    (define (library-source-path source-root name)
      (path-join source-root
        (string-append
          (string-join (map library-name-part->string name) "/")
          ".sld")))

    (define (module-source-path source-root name)
      (path-join source-root
        (string-append
          (string-join (map library-name-part->string name) "/")
          ".scm")))

    (define (r6rs-library-source-path source-root name)
      (path-join source-root
        (string-append
          (string-join (map library-name-part->string name) "/")
          ".sls")))

    (define (string->path-parts text)
      (let loop ((chars (string->list text)) (part "") (out '()))
        (cond
          ((null? chars)
            (reverse
              (if (string=? part "")
                out
                (cons part out))))
          ((char=? (car chars) #\.)
            (loop (cdr chars) "" (if (string=? part "") out (cons part out))))
          (else
            (loop (cdr chars) (string-append part (string (car chars))) out)))))

    (define (gauche-module-source-path source-root name)
      (path-join source-root
        (string-append
          (string-join (string->path-parts (symbol->string name)) "/")
          ".scm")))

    (define (scheme-library-file? path)
      (or (string-suffix? ".sld" path)
        (string-suffix? ".sls" path)
        (string-suffix? ".sps" path)
        (string-suffix? ".scm" path)))

    (define (hidden-path-entry? entry)
      (and (> (string-length entry) 0)
        (char=? (string-ref entry 0) #\.)))

    (define (insert-string item sorted)
      (cond
        ((null? sorted) (list item))
        ((string<? item (car sorted)) (cons item sorted))
        (else (cons (car sorted) (insert-string item (cdr sorted))))))

    (define (sort-strings items)
      (let loop ((rest items) (out '()))
        (if (null? rest)
          out
          (loop (cdr rest) (insert-string (car rest) out)))))

    (define (collect-library-source-files source-root)
      (define (collect-dir dir out)
        (let loop ((entries (directory-list dir)) (out out))
          (cond
            ((null? entries) out)
            (else
              (let ((path (path-join dir (car entries))))
                (cond
                  ((and (file-directory? path)
                      (not (hidden-path-entry? (car entries))))
                    (loop (cdr entries) (collect-dir path out)))
                  ((and (file-exists? path)
                      (scheme-library-file? path))
                    (loop (cdr entries) (cons path out)))
                  (else (loop (cdr entries) out))))))))
      (if (and (file-exists? source-root)
           (file-directory? source-root))
        (sort-strings (collect-dir source-root '()))
        '()))

    (define (read-library-exprs path)
      (guard (exn
              ((error-object? exn)
                (if (or (string-suffix? ".sld" path)
                     (string-suffix? ".sls" path))
                  (manifest-error "library source could not be read" path)
                  '()))
              (else '()))
        (read-all-exprs path)))

    (define (library-entry-ref entry key default)
      (let ((found (and (pair? (cdr entry))
                    (pair? (cddr entry))
                    (assq key (cddr entry)))))
        (if found (cadr found) default)))

    (define (library-entry-path source-root entry)
      (or (library-entry-ref entry 'path #f)
        (case (car entry)
          ((r7rs) (library-source-path source-root (cadr entry)))
          ((r6rs) (r6rs-library-source-path source-root (cadr entry)))
          ((guile) (module-source-path source-root (cadr entry)))
          ((gauche) (gauche-module-source-path source-root (cadr entry)))
          (else #f))))

    (define (library-entry-dialect entry)
      (or (library-entry-ref entry 'dialect #f)
        (case (car entry)
          ((r7rs r6rs) (car entry))
          (else #f))))

    (define (library-entry-implementation entry)
      (or (library-entry-ref entry 'implementation #f)
        (case (car entry)
          ((guile gauche) (car entry))
          (else #f))))

    (define (library-entry-imports entry)
      (let ((found (and (pair? (cdr entry))
                    (pair? (cddr entry))
                    (assq 'imports (cddr entry)))))
        (if found (cdr found) '())))

    (define (library-entry-exports entry)
      (let ((found (and (pair? (cdr entry))
                    (pair? (cddr entry))
                    (assq 'exports (cddr entry)))))
        (if found (cdr found) '())))

    (define (make-library-discovery-context features library-available?)
      `((features . ,features)
        (library-available? . ,library-available?)))

    (define (discovery-context-features context)
      (if context (alist-ref context 'features '()) '()))

    (define (discovery-context-library-available? context)
      (and context (alist-ref context 'library-available? #f)))

    (define (feature-available? feature context)
      (let loop ((items (discovery-context-features context)))
        (cond
          ((null? items) #f)
          ((eq? feature (car items)) #t)
          (else (loop (cdr items))))))

    (define (cond-expand-requirement-true? req context)
      (cond
        ((eq? req 'else) #t)
        ((symbol? req) (feature-available? req context))
        ((and (pair? req) (eq? (car req) 'library) (pair? (cdr req)))
          (let ((available? (discovery-context-library-available? context)))
            (and available? (available? (cadr req)))))
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
        (else #f)))

    (define (selected-cond-expand-declarations clauses context)
      (cond
        ((not context)
          (append-map cdr clauses))
        (else
          (let loop ((items clauses))
            (cond
              ((null? items) '())
              ((and (pair? (car items))
                  (cond-expand-requirement-true? (caar items) context))
                (cdar items))
              (else (loop (cdr items))))))))

    (define (library-key entry)
      (cons (car entry) (cadr entry)))

    (define (library-entry-variant-key entry)
      (list (car entry)
        (cadr entry)
        (library-entry-ref entry 'dialect #f)
        (library-entry-ref entry 'implementation #f)))

    (define (same-library-key? a b)
      (and (eq? (car a) (car b))
        (equal? (cdr a) (cdr b))))

    (define (same-library-variant-key? a b)
      (equal? a b))

    (define (library-key-present? key entries)
      (let loop ((items entries))
        (cond
          ((null? items) #f)
          ((same-library-key? key (library-key (car items))) #t)
          (else (loop (cdr items))))))

    (define (library-key-entry key entries)
      (let loop ((items entries))
        (cond
          ((null? items) #f)
          ((same-library-key? key (library-key (car items))) (car items))
          (else (loop (cdr items))))))

    (define (library-variant-key-entry key entries)
      (let loop ((items entries))
        (cond
          ((null? items) #f)
          ((same-library-variant-key? key (library-entry-variant-key (car items))) (car items))
          (else (loop (cdr items))))))

    (define (import-set-library-name spec)
      (cond
        ((symbol-list-value? spec) spec)
        ((and (pair? spec)
            (memq (car spec) '(only except prefix rename for))
            (pair? (cdr spec)))
          (import-set-library-name (cadr spec)))
        (else #f)))

    (define (import-declaration-names decl)
      (if (and (pair? decl) (eq? (car decl) 'import))
        (let loop ((sets (cdr decl)) (out '()))
          (cond
            ((null? sets) (reverse out))
            ((import-set-library-name (car sets))
              =>
              (lambda (name) (loop (cdr sets) (cons name out))))
            (else (loop (cdr sets) out))))
        '()))

    (define (import-declaration-specs decl)
      (if (and (pair? decl) (eq? (car decl) 'import))
        (cdr decl)
        '()))

    (define (symbol-append a b)
      (string->symbol (string-append (symbol->string a) (symbol->string b))))

    (define (export-spec-identifiers spec)
      (cond
        ((symbol? spec) (list spec))
        ((and (pair? spec) (eq? (car spec) 'rename))
          (cond
            ((and (pair? (cdr spec))
                (pair? (cddr spec))
                (symbol? (caddr spec))
                (null? (cdddr spec)))
              (list (caddr spec)))
            (else
              (let loop ((items (cdr spec)) (out '()))
                (cond
                  ((null? items) (reverse out))
                  ((and (pair? (car items))
                      (pair? (cdar items))
                      (symbol? (cadar items)))
                    (loop (cdr items) (cons (cadar items) out)))
                  (else (loop (cdr items) out)))))))
        ((and (pair? spec) (memq (car spec) '(only except)))
          (append-map export-spec-identifiers (cdr spec)))
        ((and (pair? spec)
            (eq? (car spec) 'prefix)
            (pair? (cdr spec))
            (pair? (cddr spec))
            (symbol? (caddr spec)))
          (map (lambda (identifier)
                (symbol-append (caddr spec) identifier))
            (export-spec-identifiers (cadr spec))))
        (else '())))

    (define (export-declaration-identifiers decl)
      (if (and (pair? decl) (eq? (car decl) 'export))
        (append-map export-spec-identifiers (cdr decl))
        '()))

    (define (included-declaration-path base file)
      (if (absolute-path? file) file (path-join (dirname base) file)))

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

    (define (read-library-include-exprs path case-fold?)
      (let ((exprs (read-library-exprs path)))
        (if case-fold?
          (map case-fold-datum exprs)
          exprs)))

    (define (library-declaration-imports/context path decls context)
      (let loop ((items decls) (out '()))
        (cond
          ((null? items) (reverse out))
          ((and (pair? (car items))
              (eq? (caar items) 'cond-expand))
            (loop (cdr items)
              (append
                (reverse
                  (library-declaration-imports/context
                    path
                    (selected-cond-expand-declarations (cdar items) context)
                    context))
                out)))
          ((and (pair? (car items))
              (eq? (caar items) 'include-library-declarations))
            (let include-loop ((files (cdar items)) (out out))
              (cond
                ((null? files) (loop (cdr items) out))
                ((string? (car files))
                  (let ((include-path (included-declaration-path path (car files))))
                    (unless (file-exists? include-path)
                      (manifest-error "included library declarations not found" include-path))
                    (include-loop
                      (cdr files)
                      (append (reverse (library-declaration-imports/context
                                        include-path
                                        (read-library-exprs include-path)
                                        context))
                        out))))
                (else
                  (manifest-error "include-library-declarations entries must be strings" (car items))))))
          ((and (pair? (car items))
              (memq (caar items) '(include include-ci)))
            (let ((case-fold? (eq? (caar items) 'include-ci)))
              (let include-loop ((files (cdar items)) (out out))
                (cond
                  ((null? files) (loop (cdr items) out))
                  ((string? (car files))
                    (let ((include-path (included-declaration-path path (car files))))
                      (unless (file-exists? include-path)
                        (manifest-error "included library file not found" include-path))
                      (include-loop
                        (cdr files)
                        (append (reverse (library-declaration-imports/context
                                          include-path
                                          (read-library-include-exprs include-path case-fold?)
                                          context))
                          out))))
                  (else
                    (manifest-error "include entries must be strings" (car items)))))))
          (else
            (loop (cdr items)
              (append (reverse (import-declaration-names (car items))) out))))))

    (define (library-declaration-imports path decls)
      (library-declaration-imports/context path decls #f))

    (define (library-declaration-import-specs/context path decls context)
      (let loop ((items decls) (out '()))
        (cond
          ((null? items) (reverse out))
          ((and (pair? (car items))
              (eq? (caar items) 'cond-expand))
            (loop (cdr items)
              (append
                (reverse
                  (library-declaration-import-specs/context
                    path
                    (selected-cond-expand-declarations (cdar items) context)
                    context))
                out)))
          ((and (pair? (car items))
              (eq? (caar items) 'include-library-declarations))
            (let include-loop ((files (cdar items)) (out out))
              (cond
                ((null? files) (loop (cdr items) out))
                ((string? (car files))
                  (let ((include-path (included-declaration-path path (car files))))
                    (unless (file-exists? include-path)
                      (manifest-error "included library declarations not found" include-path))
                    (include-loop
                      (cdr files)
                      (append
                        (reverse
                          (library-declaration-import-specs/context
                            include-path
                            (read-library-exprs include-path)
                            context))
                        out))))
                (else
                  (manifest-error "include-library-declarations entries must be strings" (car items))))))
          ((and (pair? (car items))
              (memq (caar items) '(include include-ci)))
            (let ((case-fold? (eq? (caar items) 'include-ci)))
              (let include-loop ((files (cdar items)) (out out))
                (cond
                  ((null? files) (loop (cdr items) out))
                  ((string? (car files))
                    (let ((include-path (included-declaration-path path (car files))))
                      (unless (file-exists? include-path)
                        (manifest-error "included library file not found" include-path))
                      (include-loop
                        (cdr files)
                        (append
                          (reverse
                            (library-declaration-import-specs/context
                              include-path
                              (read-library-include-exprs include-path case-fold?)
                              context))
                          out))))
                  (else
                    (manifest-error "include entries must be strings" (car items)))))))
          (else
            (loop (cdr items)
              (append (reverse (import-declaration-specs (car items))) out))))))

    (define (library-form-import-specs path expr context)
      (cond
        ((and (pair? expr)
            (eq? (car expr) 'define-library))
          (library-declaration-import-specs/context path (cddr expr) context))
        ((and (pair? expr)
            (eq? (car expr) 'library))
          (library-declaration-import-specs/context path (cddr expr) context))
        (else '())))

    (define (library-source-expr-key expr)
      (and (pair? expr)
        (pair? (cdr expr))
        (cond
          ((eq? (car expr) 'define-library)
            (cons 'r7rs (cadr expr)))
          ((eq? (car expr) 'library)
            (cons 'r6rs (cadr expr)))
          (else #f))))

    (define (library-entry-import-specs/context source-root entry context)
      (let ((path (library-entry-path source-root entry)))
        (if (and path (file-exists? path))
          (let loop ((exprs (read-library-exprs path)))
            (cond
              ((null? exprs) (library-entry-imports entry))
              ((equal? (library-key entry)
                  (library-source-expr-key (car exprs)))
                (library-form-import-specs path (car exprs) context))
              (else (loop (cdr exprs)))))
          (library-entry-imports entry))))

    (define (library-declaration-exports/context path decls context)
      (let loop ((items decls) (out '()))
        (cond
          ((null? items) (reverse out))
          ((and (pair? (car items))
              (eq? (caar items) 'cond-expand))
            (loop (cdr items)
              (append
                (reverse
                  (library-declaration-exports/context
                    path
                    (selected-cond-expand-declarations (cdar items) context)
                    context))
                out)))
          ((and (pair? (car items))
              (eq? (caar items) 'include-library-declarations))
            (let include-loop ((files (cdar items)) (out out))
              (cond
                ((null? files) (loop (cdr items) out))
                ((string? (car files))
                  (let ((include-path (included-declaration-path path (car files))))
                    (unless (file-exists? include-path)
                      (manifest-error "included library declarations not found" include-path))
                    (include-loop
                      (cdr files)
                      (append (reverse (library-declaration-exports/context
                                        include-path
                                        (read-library-exprs include-path)
                                        context))
                        out))))
                (else
                  (manifest-error "include-library-declarations entries must be strings" (car items))))))
          (else
            (loop (cdr items)
              (append (reverse (export-declaration-identifiers (car items))) out))))))

    (define (library-declaration-exports path decls)
      (library-declaration-exports/context path decls #f))

    (define (simple-module-imports expr)
      (let walk ((value expr) (out '()))
        (cond
          ((not (pair? value)) out)
          ((and (pair? value)
              (memq (car value) '(use-modules import))
              (pair? (cdr value)))
            (append (reverse (append-map
                              (lambda (item)
                                (cond
                                  ((symbol-list-value? item) (list item))
                                  ((and (pair? item) (symbol-list-value? (car item))) (list (car item)))
                                  (else '())))
                              (cdr value)))
              out))
          ((and (pair? value)
              (eq? (car value) 'use)
              (pair? (cdr value))
              (symbol? (cadr value)))
            (cons (cadr value) out))
          (else
            (let loop ((items value) (out out))
              (if (null? items)
                out
                (loop (cdr items) (walk (car items) out))))))))

    (define (keyword-symbol? value text)
      (and (symbol? value)
        (string=? (symbol->string value) text)))

    (define (simple-module-exports expr)
      (let walk ((items expr) (out '()))
        (cond
          ((not (pair? items)) out)
          ((and (pair? items)
              (keyword-symbol? (car items) "#:export")
              (pair? (cdr items))
              (pair? (cadr items)))
            (append (reverse (filter symbol? (cadr items))) out))
          (else
            (walk (cdr items)
              (walk (car items) out))))))

    (define (library-entries-from-expr/context path expr context)
      (define (variant-properties)
        (library-path-variant-properties path))
      (define (entry-properties imports)
        (append
          (variant-properties)
          (let ((implementation (implementation-from-imports imports)))
            (if implementation `((implementation ,implementation)) '()))))
      (cond
        ((and (pair? expr)
            (eq? (car expr) 'define-library)
            (pair? (cdr expr))
            (symbol-list-value? (cadr expr)))
          (let ((imports (library-declaration-imports/context path (cddr expr) context)))
            (list `(r7rs ,(cadr expr)
                    (path ,path)
                    ,@(entry-properties imports)
                    (imports ,@imports)
                    (exports ,@(library-declaration-exports/context path (cddr expr) context))))))
        ((and (pair? expr)
            (eq? (car expr) 'library)
            (pair? (cdr expr))
            (symbol-list-value? (cadr expr)))
          (let ((imports (library-declaration-imports/context path (cddr expr) context)))
            (list `(r6rs ,(cadr expr)
                    (path ,path)
                    ,@(entry-properties imports)
                    (imports ,@imports)
                    (exports ,@(library-declaration-exports/context path (cddr expr) context))))))
        ((and (pair? expr)
            (eq? (car expr) 'define-module)
            (pair? (cdr expr))
            (symbol-list-value? (cadr expr)))
          (let ((imports (reverse (simple-module-imports expr))))
            (list `(guile ,(cadr expr)
                    (path ,path)
                    ,@(entry-properties imports)
                    (imports ,@imports)
                    (exports ,@(reverse (simple-module-exports expr)))))))
        ((and (pair? expr)
            (eq? (car expr) 'define-module)
            (pair? (cdr expr))
            (symbol? (cadr expr)))
          (let ((imports (reverse (simple-module-imports expr))))
            (list `(gauche ,(cadr expr)
                    (path ,path)
                    ,@(entry-properties imports)
                    (imports ,@imports)
                    (exports ,@(reverse (simple-module-exports expr)))))))
        (else '())))

    (define implementation-variant-names
      '(capy gauche chibi guile chez mit sagittarius mosh stklos kawa loko ironscheme skint cyclone))

    (define dialect-variant-names
      '(r7rs r6rs guile gauche chez mit))

    (define (symbol-member? item items)
      (let loop ((rest items))
        (cond
          ((null? rest) #f)
          ((eq? item (car rest)) #t)
          (else (loop (cdr rest))))))

    (define (path-last-segment path)
      (let ((parts (filter non-empty-string? (string-split path #\/))))
        (if (null? parts) path (car (reverse parts)))))

    (define (path-remove-known-extension file)
      (cond
        ((string-suffix? ".sld" file)
          (substring file 0 (- (string-length file) 4)))
        ((string-suffix? ".sls" file)
          (substring file 0 (- (string-length file) 4)))
        ((string-suffix? ".sps" file)
          (substring file 0 (- (string-length file) 4)))
        ((string-suffix? ".scm" file)
          (substring file 0 (- (string-length file) 4)))
        (else file)))

    (define (last-path-token path)
      (let ((parts (string-split (path-remove-known-extension (path-last-segment path)) #\.)))
        (and (pair? parts)
          (let ((last (car (reverse parts))))
            (and (non-empty-string? last) (string->symbol last))))))

    (define (library-path-variant-properties path)
      (let ((tag (last-path-token path)))
        (cond
          ((not tag) '())
          ((symbol-member? tag implementation-variant-names)
            `((implementation ,tag)))
          ((symbol-member? tag dialect-variant-names)
            `((dialect ,tag)))
          (else '()))))

    (define (implementation-library-prefix name)
      (and (pair? name)
        (case (car name)
          ((capy) 'capy)
          ((chez chezscheme) 'chez)
          ((chibi) 'chibi)
          ((cyclone) 'cyclone)
          ((gauche) 'gauche)
          ((guile) 'guile)
          ((ironscheme) 'ironscheme)
          ((kawa) 'kawa)
          ((loko) 'loko)
          ((mit) 'mit)
          ((mosh nmosh) 'mosh)
          ((sagittarius) 'sagittarius)
          ((stklos) 'stklos)
          ((skint) 'skint)
          (else #f))))

    (define (implementation-from-imports imports)
      (let loop ((items imports))
        (cond
          ((null? items) #f)
          ((implementation-library-prefix (car items)))
          (else (loop (cdr items))))))

    (define (library-entries-from-expr path expr)
      (library-entries-from-expr/context path expr #f))

    (define (discovered-library-entries/context manifest context)
      (if (package-discover-libraries? manifest)
        (let loop-files ((files (collect-library-source-files (manifest-source-root manifest))) (out '()))
          (if (null? files)
            (reverse out)
            (loop-files
              (cdr files)
              (append (reverse
                       (append-map
                         (lambda (expr)
                           (library-entries-from-expr/context (car files) expr context))
                         (read-library-exprs (car files))))
                out))))
        '()))

    (define (discovered-library-entries manifest)
      (discovered-library-entries/context manifest #f))

    (define (dedupe-discovered-libraries entries)
      (let loop ((items entries) (out '()))
        (cond
          ((null? items) (reverse out))
          ((library-variant-key-entry (library-entry-variant-key (car items)) out)
            =>
            (lambda (existing)
              (if (string=? (library-entry-path "" existing)
                   (library-entry-path "" (car items)))
                (loop (cdr items) out)
                  (manifest-error "duplicate discovered library"
                    (cadr (car items))
                    (library-entry-path "" existing)
                    (library-entry-path "" (car items))))))
          (else (loop (cdr items) (cons (car items) out))))))

    (define (remove-library-property key props)
      (let loop ((items props) (out '()))
        (cond
          ((null? items) (reverse out))
          ((and (pair? (car items)) (eq? (caar items) key))
            (loop (cdr items) out))
          (else (loop (cdr items) (cons (car items) out))))))

    (define (library-entry-with-property entry key value)
      `(,(car entry) ,(cadr entry)
        ,@(remove-library-property key (cddr entry))
        (,key ,value)))

    (define (library-entry-with-imports entry imports)
      (if (null? imports)
        entry
        `(,(car entry) ,(cadr entry)
          ,@(remove-library-property 'imports (cddr entry))
          (imports ,@imports))))

    (define (library-entry-with-exports entry exports)
      (if (null? exports)
        entry
        `(,(car entry) ,(cadr entry)
          ,@(remove-library-property 'exports (cddr entry))
          (exports ,@exports))))

    (define (merge-library-entry-metadata declared discovered)
      (let* ((entry (if (library-entry-ref declared 'path #f)
                     declared
                     (library-entry-with-property
                       declared
                       'path
                       (library-entry-path "" discovered))))
             (imports (library-entry-imports discovered))
             (exports (library-entry-exports discovered)))
        (library-entry-with-exports
          (library-entry-with-imports entry imports)
          exports)))

    (define (discovered-entry-for-declared source-root entry context)
      (let ((path (library-entry-path source-root entry)))
        (and path
          (file-exists? path)
          (let loop ((exprs (read-library-exprs path)))
            (cond
              ((null? exprs) #f)
              ((library-key-entry
                  (library-key entry)
                  (library-entries-from-expr/context path (car exprs) context))
                =>
                (lambda (found) found))
              (else (loop (cdr exprs))))))))

    (define (enrich-declared-library-entries manifest entries context)
      (let ((source-root (manifest-source-root manifest)))
        (let loop ((items entries) (out '()))
          (cond
            ((null? items) (reverse out))
            ((discovered-entry-for-declared source-root (car items) context)
              =>
              (lambda (found)
                (loop (cdr items)
                  (cons (merge-library-entry-metadata (car items) found) out))))
            (else (loop (cdr items) (cons (car items) out)))))))

    (define (flatten-library-entries entries)
      (let loop ((items entries) (out '()))
        (cond
          ((null? items) (reverse out))
          ((and (pair? (car items)) (symbol? (caar items)))
            (loop (cdr items) (cons (car items) out)))
          ((pair? (car items))
            (loop (append (car items) (cdr items)) out))
          (else (loop (cdr items) out)))))

    (define (effective-package-libraries/context manifest context)
      (let ((declared (enrich-declared-library-entries
                       manifest
                       (flatten-library-entries (package-libraries manifest))
                       context)))
        (let ((entries
                (let loop ((items (dedupe-discovered-libraries
                                   (discovered-library-entries/context manifest context)))
                           (out declared))
                  (cond
                    ((null? items) out)
                    ((library-variant-key-entry (library-entry-variant-key (car items)) declared)
                      (loop (cdr items) out))
                    (else
                      (loop (cdr items) (append out (list (car items)))))))))
          (loadable-library-entries/context entries context))))

    (define (effective-package-libraries manifest)
      (effective-package-libraries/context manifest #f))

    (define (public-library-entry entry)
      `(,(car entry) ,(cadr entry)
        ,@(let ((path (library-entry-ref entry 'path #f)))
           (if path `((path ,path)) '()))
        ,@(let ((dialect (library-entry-ref entry 'dialect #f)))
           (if dialect `((dialect ,dialect)) '()))
        ,@(let ((implementation (library-entry-ref entry 'implementation #f)))
           (if implementation `((implementation ,implementation)) '()))
        ,@(let ((imports (library-entry-imports entry)))
           (if (null? imports) '() `((imports ,@imports))))
        ,@(let ((exports (library-entry-exports entry)))
           (if (null? exports) '() `((exports ,@exports))))))

    (define (effective-public-package-libraries manifest)
      (map public-library-entry (effective-package-libraries manifest)))

    (define (replace-alist key value alist)
      (let loop ((items alist) (out '()) (done? #f))
        (cond
          ((null? items)
            (reverse (if done? out (cons (cons key value) out))))
          ((eq? (caar items) key)
            (loop (cdr items) (cons (cons key value) out) #t))
          (else
            (loop (cdr items) (cons (car items) out) done?)))))

    (define (manifest-with-effective-libraries manifest)
      (let ((package (alist-ref manifest 'package '())))
        (replace-alist
          'package
          (replace-alist 'libraries (effective-public-package-libraries manifest) package)
          manifest)))

    (define (library-entry-of-kind? kind entry)
      (and (pair? entry) (eq? (car entry) kind)))

    (define (entries-of-kind kind entries)
      (filter (lambda (entry) (library-entry-of-kind? kind entry)) entries))

    (define (library-name-in-entries? kind name entries)
      (library-key-entry (cons kind name) entries))

    (define (library-import-available? kind name entries context)
      (or (library-name-in-entries? kind name entries)
        (let ((available? (discovery-context-library-available? context)))
          (and available? (available? name)))))

    (define (library-entry-loadable? entry entries context)
      (or (not context)
        (and
          (library-entry-variant-loadable? entry context)
          (let ((kind (car entry)))
            (let loop ((imports (filter symbol-list-value? (library-entry-imports entry))))
              (cond
                ((null? imports) #t)
                ((library-import-available? kind (car imports) entries context)
                  (loop (cdr imports)))
                (else #f)))))))

    (define (library-entry-variant-loadable? entry context)
      (let ((features (discovery-context-features context))
            (dialect (library-entry-ref entry 'dialect #f))
            (implementation (library-entry-ref entry 'implementation #f)))
        (and
          (or (not dialect) (symbol-member? dialect features))
          (or (not implementation) (symbol-member? implementation features)))))

    (define (loadable-library-entries/context entries context)
      (if context
        (prefer-specific-library-variants/context
          (filter
            (lambda (entry)
              (library-entry-loadable? entry entries context))
            entries)
          context)
        entries))

    (define (explicit-library-variant? entry)
      (or (library-entry-ref entry 'dialect #f)
        (library-entry-ref entry 'implementation #f)))

    (define (library-entry-variant-more-specific? candidate entry context)
      (and (same-library-key? (library-key candidate) (library-key entry))
        (explicit-library-variant? candidate)
        (not (equal? (library-entry-path "" candidate) (library-entry-path "" entry)))
        (library-entry-variant-loadable? candidate context)
        (or (not (library-entry-ref entry 'implementation #f))
          (library-entry-ref candidate 'implementation #f))
        (or (not (library-entry-ref entry 'dialect #f))
          (library-entry-ref candidate 'dialect #f))))

    (define (specific-library-variant-present? entry entries context)
      (let loop ((items entries))
        (cond
          ((null? items) #f)
          ((library-entry-variant-more-specific? (car items) entry context) #t)
          (else (loop (cdr items))))))

    (define (prefer-specific-library-variants/context entries context)
      (filter
        (lambda (entry)
          (or (explicit-library-variant? entry)
            (not (specific-library-variant-present? entry entries context))))
        entries))

    (define (same-kind-library-imports entry entries)
      (filter
        (lambda (name)
          (library-name-in-entries? (car entry) name entries))
        (filter symbol-list-value? (library-entry-imports entry))))

    (define (topological-library-entries kind entries)
      (let ((kind-entries (entries-of-kind kind entries)))
        (letrec
          ((temporary '())
            (permanent '())
            (sorted '())
            (marked? (lambda (key marks)
                      (let loop ((items marks))
                        (cond
                          ((null? items) #f)
                          ((same-library-key? key (car items)) #t)
                          (else (loop (cdr items)))))))
            (visit
              (lambda (entry stack)
                (let ((key (library-key entry)))
                  (cond
                    ((marked? key permanent) #t)
                    ((marked? key temporary)
                      (manifest-error "library import cycle"
                        (map cdr (reverse (cons key stack)))))
                    (else
                      (set! temporary (cons key temporary))
                      (for-each
                        (lambda (dep-name)
                          (let ((dep (library-key-entry (cons kind dep-name) kind-entries)))
                            (when dep (visit dep (cons key stack)))))
                        (same-kind-library-imports entry kind-entries))
                      (set! temporary
                        (filter (lambda (mark) (not (same-library-key? mark key)))
                          temporary))
                      (set! permanent (cons key permanent))
                      (set! sorted (cons entry sorted))
                      #t))))))
          (for-each (lambda (entry) (visit entry '())) kind-entries)
          (reverse sorted))))

    (define (library-names-for-kind/context manifest kind context)
      (map cadr (topological-library-entries kind (effective-package-libraries/context manifest context))))

    (define (library-entries-for-kind/context manifest kind context)
      (topological-library-entries kind (effective-package-libraries/context manifest context)))

    (define (library-names-for-kind manifest kind)
      (library-names-for-kind/context manifest kind #f))

    (define (symbol-list-value? value)
      (and (pair? value)
        (let loop ((items value))
          (or (null? items)
            (and (library-name-part? (car items))
              (loop (cdr items)))))))

    (define (r7rs-library-entry-name entry)
      (and (pair? entry)
        (eq? (car entry) 'r7rs)
        (pair? (cdr entry))
        (symbol-list-value? (cadr entry))
        (cadr entry)))

    (define (r6rs-library-entry-name entry)
      (and (pair? entry)
        (eq? (car entry) 'r6rs)
        (pair? (cdr entry))
        (symbol-list-value? (cadr entry))
        (cadr entry)))

    (define (guile-library-entry-name entry)
      (and (pair? entry)
        (eq? (car entry) 'guile)
        (pair? (cdr entry))
        (symbol-list-value? (cadr entry))
        (cadr entry)))

    (define (gauche-library-entry-name entry)
      (and (pair? entry)
        (eq? (car entry) 'gauche)
        (pair? (cdr entry))
        (symbol? (cadr entry))
        (cadr entry)))

    (define (r7rs-library-names manifest)
      (library-names-for-kind manifest 'r7rs))

    (define (r7rs-library-entries/context manifest context)
      (library-entries-for-kind/context manifest 'r7rs context))

    (define (r7rs-library-names/context manifest context)
      (library-names-for-kind/context manifest 'r7rs context))

    (define (r6rs-library-names manifest)
      (library-names-for-kind manifest 'r6rs))

    (define (r6rs-library-entries/context manifest context)
      (library-entries-for-kind/context manifest 'r6rs context))

    (define (guile-library-names manifest)
      (library-names-for-kind manifest 'guile))

    (define (guile-library-entries/context manifest context)
      (library-entries-for-kind/context manifest 'guile context))

    (define (guile-library-names/context manifest context)
      (library-names-for-kind/context manifest 'guile context))))
