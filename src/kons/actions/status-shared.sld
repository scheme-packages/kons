(define-library (kons actions status-shared)
  (export fetch-plan-form
    file-status
    status-test-files
    status-bench-files
    status-example-files
    status-action-list
    status-form
    fetch-with-progress
    fetch-lock-with-progress)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons compat files)
    (kons util)
    (kons ui)
    (kons manifest)
    (kons library-discovery)
    (kons features)
    (kons lock)
    (kons runner)
    (kons options)
    (kons actions paths)
    (kons actions lock-shared)
    (kons actions activation)
    (kons actions targets)
    (kons actions status locked-dependencies))

  (begin
    (define (fetch-plan-form manifest features cmd)
      (let* ((lock-path (command-lock-path manifest cmd))
             (lock (stored-lockfile lock-path))
             (lock-status (best-effort-lock-status manifest features cmd lock))
             (completeness (lock-completeness-status manifest features cmd lock))
             (materialized? (lock-materialized-status manifest lock lock-status #t))
             (locked? (command-flag? cmd "locked"))
             (frozen? (command-flag? cmd "frozen"))
             (offline? (or (command-flag? cmd "offline") frozen?))
             (deps (all-dependencies-for manifest #t features cmd))
             (hooks? (has-build-hooks? manifest)))
        `(fetch-plan
          (root ,(package-name manifest))
          (features ,@features)
          (profile ,(command-selected-profile cmd))
          (includes-dev-dependencies #t)
          (mode
           (locked ,locked?)
           (frozen ,frozen?)
           (offline ,offline?))
          (lockfile
           (path ,lock-path)
           (status ,lock-status)
           (completeness ,completeness))
          (store
           (root ,(kons-store-root))
           (materialized ,(truthy->boolean materialized?))
           (offline-ready ,(lock-offline-ready? lock lock-status completeness materialized?)))
          (build-hooks
           (present ,hooks?)
           (build-root ,(build-output-dir manifest features cmd))
           (will-run-if-stale ,hooks?))
          (actions
           ,@(if lock '() '(write-lockfile))
           ,@(if (eq? lock-status 'stale) '(refresh-lockfile) '())
           ,@(if materialized? '() '(materialize-dependencies))
           ,@(if hooks? '(run-stale-build-hooks) '()))
          (dependencies ,@deps))))

    (define (truthy->boolean value)
      (if value #t #f))

    (define (current-lock? lock lock-status)
      (and lock (eq? lock-status 'current)))

    (define (lock-materialized-status manifest lock lock-status include-dev?)
      (and (current-lock? lock lock-status)
        (lock-materialized? lock include-dev? manifest)))

    (define (lock-offline-ready? lock lock-status completeness materialized?)
      (and (current-lock? lock lock-status)
        (eq? completeness 'complete)
        (truthy->boolean materialized?)))

    (define (file-status path)
      `(,path ,(if (and path (file-exists? path)) 'present 'missing)))

    (define (status-test-files manifest)
      (let ((declared (package-tests manifest)))
        (if (null? declared)
          (let ((dir (path-join (manifest-root manifest) "tests")))
            (if (and (file-exists? dir) (file-directory? dir))
              (collect-test-files dir)
              '()))
          (map (lambda (path) (manifest-root-path manifest path)) declared))))

    (define (status-bench-files manifest)
      (let ((declared (package-benches manifest)))
        (if (null? declared)
          (let ((dir (path-join (manifest-root manifest) "benches")))
            (if (and (file-exists? dir) (file-directory? dir))
              (collect-scheme-files dir "benches")
              '()))
          (map (lambda (path) (manifest-root-path manifest path)) declared))))

    (define (status-example-files manifest)
      (package-example-files manifest))

    (define (status-needs-fetch? lock-status completeness materialized?)
      (or (memq lock-status '(missing stale))
        (eq? completeness 'incomplete)
        (not materialized?)))

    (define (status-action-list lock-status completeness materialized? main-path)
      (append
        (if (status-needs-fetch? lock-status completeness materialized?)
          '(run-fetch)
          '())
        (if main-path '() '(add-main-or-bin))))

    (define (lock-direct-coverage-complete? manifest features cmd lock)
      (guard (exn
              ((error-object? exn) #f))
        (ensure-lock-covers-direct-dependencies manifest features cmd lock)
        #t))

    (define (fallback-lock-status manifest features cmd lock)
      (cond
        ((not lock) 'missing)
        ((not (lock-root-matches? manifest features cmd lock)) 'stale)
        ((lock-direct-coverage-complete? manifest features cmd lock) 'current)
        (else 'stale)))

    (define (best-effort-lock-status? cmd)
      (or (command-flag? cmd "offline")
        (command-flag? cmd "frozen")))

    ;; Offline and frozen commands must report from the stored lock only.
    (define (best-effort-lock-status manifest features cmd lock)
      (if (best-effort-lock-status? cmd)
        (fallback-lock-status manifest features cmd lock)
        (lock-status manifest features cmd lock)))

    (define (status-form manifest features cmd)
      (let* ((lock-path (command-lock-path manifest cmd))
             (lock (stored-lockfile lock-path))
             (lock-status (best-effort-lock-status manifest features cmd lock))
             (completeness (lock-completeness-status manifest features cmd lock))
             (materialized? (lock-materialized-status manifest lock lock-status #t))
             (srcs (if (and lock
                        (eq? lock-status 'current)
                        materialized?)
                    (effective-activation-source-roots manifest #f features cmd)
                    (activation-source-roots manifest #f features cmd)))
             (main-path (package-main-path manifest))
             (tests (status-test-files manifest))
             (benches (status-bench-files manifest))
             (examples (status-example-files manifest)))
        `(status
          (root
           (name ,(package-name manifest))
           (version ,(package-version manifest))
           (scheme ,(command-selected-scheme cmd))
           (target ,(command-option cmd "target" #f))
           (profile ,(command-selected-profile cmd))
           (features ,@features))
          (manifest
           (path ,(command-manifest-path cmd))
           (source-root ,(manifest-source-root manifest))
           (libraries ,@(map (lambda (entry)
                              `(,(car entry) ,(cadr entry) ,(third entry)
                                ,(if (file-exists? (third entry)) 'present 'missing)))
                         (library-entry-files manifest)))
           (main ,(if main-path (file-status main-path) #f))
           (tests ,@(map file-status tests))
           (benches ,@(map file-status benches))
           (examples ,@(map (lambda (example)
                             `(,(car example) ,@(file-status (cdr example))))
                        examples))
           (scripts ,@(map (lambda (script)
                            `(,(car script)
                              ,@(file-status (manifest-root-path manifest (cdr script)))))
                       (package-scripts manifest)))
           (bins ,@(map (lambda (bin)
                         `(,(car bin)
                           ,@(file-status (manifest-source-path manifest (cdr bin)))))
                    (package-bins manifest))))
          (lockfile
           (path ,lock-path)
           (status ,lock-status)
           (completeness ,completeness))
          (store
           (root ,(kons-store-root))
           (materialized ,(truthy->boolean materialized?))
           (offline-ready ,(lock-offline-ready? lock lock-status completeness materialized?)))
          (activation
           (includes-dev-dependencies #f)
           (source-roots ,@srcs)
           (load-paths ,@srcs))
          (build-hooks
           (present ,(has-build-hooks? manifest))
           (build-root ,(build-output-dir manifest features cmd)))
          (targets
           (default ,(if main-path (default-binary-name manifest) #f))
           (bins ,@(map car (package-bins manifest)))
           (scripts ,@(map car (package-scripts manifest)))
           (examples ,@(map car examples))
           (tests ,@(map (lambda (path) path) tests))
           (benches ,@(map (lambda (path) path) benches)))
          (actions ,@(status-action-list lock-status completeness materialized? main-path))
          ,@(status-locked-dependencies-section manifest lock)
          (dependencies
           (runtime ,@(all-dependencies-for manifest #f features cmd))
           (dev ,@(alist-ref manifest 'dev-dependencies '()))))))

    (define (dependency-count-message total)
      (string-append (number->string total) " dependencies"))

    (define (run-fetch-with-progress total fetch)
      (ui-progress "Fetching" 0 total)
      (let ((result (fetch)))
        (ui-display-status "Fetched" 'green (dependency-count-message total))
        result))

    (define (fetch-with-progress manifest features include-dev? offline? cmd)
      (let ((deps (filter materializable-dependency?
                   (all-dependencies-for manifest include-dev? features cmd))))
        (if (null? deps)
          '()
          (run-fetch-with-progress (length deps)
            (lambda ()
              (materialize-local-sources manifest features include-dev? offline? cmd))))))

    (define (fetchable-lock-entry? include-dev? entry)
      (and (locked-entry-in-scope? entry include-dev?)
        (memq (lock-entry-type entry) '(path git registry akku snow))))

    (define (fetch-lock-with-progress manifest lock include-dev? offline? cmd)
      (let ((entries (filter (lambda (entry)
                              (fetchable-lock-entry? include-dev? entry))
                      (lock-package-entries lock))))
        (if (null? entries)
          '()
          (run-fetch-with-progress (length entries)
            (lambda ()
              (materialize-lock-sources manifest lock include-dev? offline? cmd))))))))
