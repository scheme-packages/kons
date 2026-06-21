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
          library-entry-imports
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
          (scheme file)
          (kons compat files)
          (kons util)
          (kons manifest))

  (begin
(define (package-libraries manifest)
  (alist-ref (alist-ref manifest 'package '()) 'libraries '()))

(define (string-join items sep)
  (let loop ((xs items) (out ""))
    (cond
     ((null? xs) out)
     ((string=? out "") (loop (cdr xs) (car xs)))
     (else (loop (cdr xs) (string-append out sep (car xs)))))))

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

(define (library-entry-imports entry)
  (let ((found (and (pair? (cdr entry))
                    (pair? (cddr entry))
                    (assq 'imports (cddr entry)))))
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

(define (same-library-key? a b)
  (and (eq? (car a) (car b))
       (equal? (cdr a) (cdr b))))

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
          => (lambda (name) (loop (cdr sets) (cons name out))))
         (else (loop (cdr sets) out))))
      '()))

(define (included-declaration-path base file)
  (if (absolute-path? file) file (path-join (dirname base) file)))

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
                               (read-library-exprs include-path)
                               context))
                     out))))
         (else
          (manifest-error "include entries must be strings" (car items))))))
     (else
      (loop (cdr items)
            (append (reverse (import-declaration-names (car items))) out))))))

(define (library-declaration-imports path decls)
  (library-declaration-imports/context path decls #f))

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

(define (library-entries-from-expr/context path expr context)
  (cond
   ((and (pair? expr)
         (eq? (car expr) 'define-library)
         (pair? (cdr expr))
         (symbol-list-value? (cadr expr)))
    (list `(r7rs ,(cadr expr)
                 (path ,path)
                 (imports ,@(library-declaration-imports/context path (cddr expr) context)))))
   ((and (pair? expr)
         (eq? (car expr) 'library)
         (pair? (cdr expr))
         (symbol-list-value? (cadr expr)))
    (list `(r6rs ,(cadr expr)
                 (path ,path)
                 (imports ,@(library-declaration-imports/context path (cddr expr) context)))))
   ((and (pair? expr)
         (eq? (car expr) 'define-module)
         (pair? (cdr expr))
         (symbol-list-value? (cadr expr)))
    (list `(guile ,(cadr expr)
                  (path ,path)
                  (imports ,@(reverse (simple-module-imports expr))))))
   ((and (pair? expr)
         (eq? (car expr) 'define-module)
         (pair? (cdr expr))
         (symbol? (cadr expr)))
    (list `(gauche ,(cadr expr)
                   (path ,path)
                   (imports ,@(reverse (simple-module-imports expr))))))
   (else '())))

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
     ((library-key-entry (library-key (car items)) out)
      => (lambda (existing)
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

(define (merge-library-entry-metadata declared discovered)
  (let* ((entry (if (library-entry-ref declared 'path #f)
                    declared
                    (library-entry-with-property
                     declared
                     'path
                     (library-entry-path "" discovered))))
         (imports (library-entry-imports discovered)))
    (library-entry-with-imports entry imports)))

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
             => (lambda (found) found))
            (else (loop (cdr exprs))))))))

(define (enrich-declared-library-entries manifest entries context)
  (let ((source-root (manifest-source-root manifest)))
    (let loop ((items entries) (out '()))
      (cond
       ((null? items) (reverse out))
       ((discovered-entry-for-declared source-root (car items) context)
        => (lambda (found)
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
              ((library-key-present? (library-key (car items)) declared)
               (loop (cdr items) out))
              (else
               (loop (cdr items) (append out (list (car items)))))))))
      (loadable-library-entries/context entries context))))

(define (effective-package-libraries manifest)
  (effective-package-libraries/context manifest #f))

(define (public-library-entry entry)
  `(,(car entry) ,(cadr entry)))

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
      (let ((kind (car entry)))
        (let loop ((imports (filter symbol-list-value? (library-entry-imports entry))))
          (cond
           ((null? imports) #t)
           ((library-import-available? kind (car imports) entries context)
            (loop (cdr imports)))
           (else #f))))))

(define (loadable-library-entries/context entries context)
  (if context
      (filter
       (lambda (entry)
         (library-entry-loadable? entry entries context))
       entries)
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
  (library-names-for-kind/context manifest 'guile context))
  ))
