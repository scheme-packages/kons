(define-library (kons actions tree)
  (export cmd-tree)
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
    (kons compat json)
    (kons actions paths)
    (kons actions lock-shared)
    (kons actions tree-clean))

  (begin
    (define (json-format? value)
      (and value (string=? value "json")))

    (define (field-form-key form)
      (and (pair? form) (car form)))

    (define (field-form-values form)
      (if (and (pair? form) (pair? (cdr form)))
        (cdr form)
        '()))

    (define (single-field-value values)
      (cond
        ((null? values) #f)
        ((null? (cdr values)) (car values))
        (else values)))

    (define (tree-value->json value)
      (cond
        ((symbol? value) (symbol->string value))
        ((or (string? value) (number? value) (boolean? value)) value)
        ((null? value) '#())
        ((pair? value) (list->vector (map tree-value->json value)))
        (else #f)))

    (define (tree-fields->json fields)
      (map (lambda (field)
            (cons (field-form-key field)
              (tree-value->json (single-field-value (field-form-values field)))))
        fields))

    (define (tree-entry->json entry)
      (tree-fields->json (cdr entry)))

    (define (tree-entries->json entries)
      (list->vector (map tree-entry->json entries)))

    (define (tree-form-ref form key default)
      (let ((found (assq key (cdr form))))
        (if found found default)))

    (define (tree-form->json form)
      (let ((root (tree-form-ref form 'root '(root)))
            (source (tree-form-ref form 'source '(source unknown)))
            (dependencies (tree-form-ref form 'dependencies '(dependencies)))
            (edges (tree-form-ref form 'edges '(edges))))
        `((formatVersion . 1)
          (root . ,(tree-entry->json root))
          (source . ,(tree-value->json (single-field-value (field-form-values source))))
          (dependencies . ,(tree-entries->json (cdr dependencies)))
          (edges . ,(tree-entries->json (cdr edges))))))

    (define (write-tree cmd form)
      (if (json-format? (command-option cmd "format" "sexp"))
        (begin
          (json-write (tree-form->json form) (current-output-port))
          (newline))
        (writeln form)))

    (define (locked-tree-form manifest features lock)
      `(tree
        (root
         (name ,(package-name manifest))
         (version ,(package-version manifest))
         (scheme ,(lock-root-scheme lock))
         (target ,(lock-root-target lock))
         (profile ,(lock-root-profile lock))
         (features ,@(lock-root-features lock)))
        (source lockfile)
        (dependencies
         ,@(map (lambda (entry)
                 (tree-dependency-from-lock-entry entry manifest))
            (lock-package-entries lock)))
        (edges
         ,@(map tree-edge-from-lock-entry
            (lock-edge-entries lock)))))

    (define (candidate-tree-form manifest features cmd)
      `(tree
        (root
         (name ,(package-name manifest))
         (version ,(package-version manifest))
         (scheme ,(command-selected-scheme cmd))
         (target ,(command-option cmd "target" #f))
         (profile ,(command-selected-profile cmd))
         (features ,@features))
        (source candidate)
        (dependencies
         ,@(map tree-dependency-from-live
            (all-dependencies-for manifest #t features cmd)))))

    (define (cmd-tree cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (features (active-features manifest cmd))
             (lock (matching-lock manifest features cmd)))
        (ensure-supported-active-features manifest features cmd)
        (when (and (not lock) (command-locked-mode? cmd))
          (if (file-exists? (command-lock-path manifest cmd))
            (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`")
            (lockfile-error "kons.lock missing; run `kons update` first")))
        (if lock
          (write-tree cmd (locked-tree-form manifest features lock))
          (write-tree cmd (candidate-tree-form manifest features cmd)))))))
