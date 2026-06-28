(define-library (kons actions resolve)
  (export cmd-resolve)
  (import (scheme base)
    (scheme file)
    (scheme process-context)
    (scheme write)
    (kons util)
    (kons implementation)
    (kons manifest)
    (kons features)
    (kons lock)
    (kons dep akku)
    (kons runner)
    (kons options)
    (kons compat json)
    (kons actions paths)
    (kons actions lock-shared))

  (begin
    (define (name->json name)
      (list->vector (map (lambda (part)
                          (cond
                            ((symbol? part) (symbol->string part))
                            ((number? part) (number->string part))
                            ((string? part) part)
                            (else "")))
                     name)))

    (define (symbol-list->json items)
      (list->vector (map symbol->string items)))

    (define (resolve-value->json value)
      (cond
        ((symbol? value) (symbol->string value))
        ((or (string? value) (number? value) (boolean? value)) value)
        ((null? value) '#())
        ((and (pair? value) (symbol? (car value))) (name->json value))
        ((pair? value) (list->vector (map resolve-value->json value)))
        (else #f)))

    (define (dependency->json dep)
      (map (lambda (entry)
            (cons (car entry) (resolve-value->json (cdr entry))))
        dep))

    (define (dependencies->json deps)
      (list->vector (map dependency->json deps)))

    (define (locked-dependency-form entry)
      `(dependency
        (scope ,(lock-entry-ref entry 'scope 'runtime))
        (type ,(lock-entry-type entry))
        (name ,(lock-entry-ref entry 'name '()))
        (version ,(lock-entry-ref entry 'version ""))
        ,@(if (eq? (lock-entry-type entry) 'akku)
           `((source ,(lock-entry-ref entry 'source "akku"))
             (source-kind ,(lock-entry-ref entry 'source-kind 'unknown))
             (trust verified-index)
             (cache ,(if (akku-source-ready? entry) 'ready 'missing))
             (source-cache-path ,(lock-entry-ref entry 'source-cache-path "")))
           '())))

    (define (locked-field-values->json values)
      (cond
        ((null? values) '#())
        ((null? (cdr values)) (resolve-value->json (car values)))
        (else (list->vector (map resolve-value->json values)))))

    (define (locked-dependency->json form)
      (map (lambda (field)
            (cons (car field) (locked-field-values->json (cdr field))))
        (cdr form)))

    (define (locked-dependencies->json entries)
      (list->vector (map (lambda (entry)
                          (locked-dependency->json (locked-dependency-form entry)))
                     entries)))

    (define (matching-resolution-lock manifest features cmd)
      (let* ((lock-path (command-lock-path manifest cmd))
             (lock (stored-lockfile lock-path)))
        (and lock
          (lock-root-matches? manifest features cmd lock)
          (lock-resolution-current? manifest features cmd lock)
          lock)))

    (define (resolution-form manifest features cmd)
      (let ((lock (matching-resolution-lock manifest features cmd)))
        `(resolution
          (root ,(package-name manifest))
          (features ,@features)
          (runtime-dependencies ,@(all-dependencies-for manifest #f features cmd))
          (dev-dependencies ,@(alist-ref manifest 'dev-dependencies '()))
          (overrides ,@(alist-ref manifest 'overrides '()))
          ,@(if lock
             `((locked-dependencies
                ,@(map locked-dependency-form (lock-package-entries lock))))
             '()))))

    (define (resolution-json manifest features cmd)
      (let ((lock (matching-resolution-lock manifest features cmd)))
        `((formatVersion . 1)
          (root . ,(name->json (package-name manifest)))
          (features . ,(symbol-list->json features))
          (runtime-dependencies . ,(dependencies->json (all-dependencies-for manifest #f features cmd)))
          (dev-dependencies . ,(dependencies->json (alist-ref manifest 'dev-dependencies '())))
          (overrides . ,(dependencies->json (alist-ref manifest 'overrides '())))
          ,@(if lock
             `((locked-dependencies . ,(locked-dependencies->json (lock-package-entries lock))))
             '()))))

    (define (write-resolution cmd manifest features)
      (writeln (resolution-form manifest features cmd)))

    (define (cmd-resolve cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (features (active-features manifest cmd)))
        (ensure-supported-active-features manifest features cmd)
        (write-resolution cmd manifest features)))))
