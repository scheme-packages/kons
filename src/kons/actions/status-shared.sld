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
          (kons dep registry)
          (kons runner)
          (kons options)
          (kons actions paths)
          (kons actions lock-shared)
          (kons actions activation)
          (kons actions targets))

  (begin
(define (fetch-plan-form manifest features cmd)
  (let* ((lock-path (command-lock-path manifest cmd))
         (lock (stored-lockfile lock-path))
         (status (best-effort-lock-status manifest features cmd lock))
         (complete (lock-completeness-status manifest features cmd lock))
         (materialized? (and lock
                             (eq? status 'current)
                             (lock-materialized? lock #t manifest)))
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
       (status ,status)
       (completeness ,complete))
      (store
       (root ,(kons-store-root))
       (materialized ,(if materialized? #t #f))
       (offline-ready ,(if (and lock
                                (eq? status 'current)
                                (eq? complete 'complete)
                                materialized?)
                           #t
                           #f)))
	      (build-hooks
	       (present ,hooks?)
	       (build-root ,(build-output-dir manifest features cmd))
	       (will-run-if-stale ,hooks?))
      (actions
       ,@(if lock '() '(write-lockfile))
       ,@(if (eq? status 'stale) '(refresh-lockfile) '())
       ,@(if materialized? '() '(materialize-dependencies))
       ,@(if hooks? '(run-stale-build-hooks) '()))
      (dependencies ,@deps))))

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

(define (status-action-list lock-status complete materialized? main-path)
  (append
   (if (or (eq? lock-status 'missing)
           (eq? lock-status 'stale)
           (eq? complete 'incomplete)
           (not materialized?))
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

(define (best-effort-lock-status manifest features cmd lock)
  (if (best-effort-lock-status? cmd)
      (fallback-lock-status manifest features cmd lock)
      (lock-status manifest features cmd lock)))

(define (status-locked-registry-source-fields manifest entry)
  (let ((vendor-root (vendor-source-root manifest entry)))
    (if vendor-root
        `((source vendored)
          (source-path ,vendor-root))
        `((source registry)
          (source-path ,(locked-registry-entry-root entry))))))

(define (status-locked-dependency-form manifest entry)
  (case (lock-entry-type entry)
    ((registry)
     `(dependency
       (scope ,(lock-entry-ref entry 'scope 'runtime))
       (type registry)
       (name ,(lock-entry-ref entry 'name '()))
       (version ,(lock-entry-ref entry 'version ""))
       (registry ,(lock-entry-ref entry 'registry "default"))
       ,@(status-locked-registry-source-fields manifest entry)))
    (else
     `(dependency
       (scope ,(lock-entry-ref entry 'scope 'runtime))
       (type ,(lock-entry-type entry))
       (name ,(lock-entry-ref entry 'name '()))))))

(define (status-locked-dependencies-section manifest lock)
  (if lock
      `((locked-dependencies
         ,@(map (lambda (entry)
                  (status-locked-dependency-form manifest entry))
                (lock-package-entries lock))))
      '()))

(define (status-form manifest features cmd)
  (let* ((lock-path (command-lock-path manifest cmd))
         (lock (stored-lockfile lock-path))
         (status (best-effort-lock-status manifest features cmd lock))
         (complete (lock-completeness-status manifest features cmd lock))
         (materialized? (and lock
                             (eq? status 'current)
                             (lock-materialized? lock #t manifest)))
         (srcs (if (and lock
                        (eq? status 'current)
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
       (status ,status)
       (completeness ,complete))
      (store
       (root ,(kons-store-root))
       (materialized ,(if materialized? #t #f))
       (offline-ready ,(if (and lock
                                (eq? status 'current)
                                (eq? complete 'complete)
                                materialized?)
                           #t
                           #f)))
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
      (actions ,@(status-action-list status complete materialized? main-path))
      ,@(status-locked-dependencies-section manifest lock)
      (dependencies
       (runtime ,@(all-dependencies-for manifest #f features cmd))
       (dev ,@(alist-ref manifest 'dev-dependencies '()))))))


(define (fetch-with-progress manifest features include-dev? offline? cmd)
  (let ((deps (filter materializable-dependency?
                      (all-dependencies-for manifest include-dev? features cmd))))
    (if (null? deps)
        '()
        (let ((total (length deps)))
          (ui-progress "Fetching" 0 total)
          (let ((result (materialize-local-sources manifest features include-dev? offline? cmd)))
            (ui-display-status "Fetched" 'green
                               (string-append (number->string total)
                                              " dependencies"))
            result)))))

(define (fetch-lock-with-progress manifest lock include-dev? offline? cmd)
  (let ((entries (filter (lambda (entry)
                           (and (locked-entry-in-scope? entry include-dev?)
                                (memq (lock-entry-type entry) '(path git registry akku))))
                         (lock-package-entries lock))))
    (if (null? entries)
        '()
        (let ((total (length entries)))
          (ui-progress "Fetching" 0 total)
          (let ((result (materialize-lock-sources manifest lock include-dev? offline? cmd)))
            (ui-display-status "Fetched" 'green
                               (string-append (number->string total)
                                              " dependencies"))
            result)))))

  ))
