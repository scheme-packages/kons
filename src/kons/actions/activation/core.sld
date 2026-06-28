(define-library (kons actions activation core)
  (export ensure-activation-ready-core!
          build-token
          build-output-dir
          build-output-needed?
          has-build-hooks?
          implicit-build-hooks
          effective-build-hooks
          activation-source-roots-with-build
          dependency-build-output-dir
          dependency-build-output-for-source-root
          dependency-features-for-source-root
          activation-source-roots-with-dependency-builds
          implementation-field
          cache-record-hash
          compiled-cache-record
          compiled-cache-token
          compiled-output-dir
          compilable-source-root-records
          compilable-artifact-names
          has-compiled-artifacts-for-features?
          has-compiled-artifacts?
          compiled-artifact-records)
  (import (scheme base)
          (scheme cxr)
          (scheme file)
          (scheme write)
          (kons compat files)
          (kons util)
          (kons ui)
          (kons names)
          (kons implementation)
          (kons manifest)
          (kons library-discovery)
          (kons features)
          (kons lock)
          (kons registry)
          (kons runner)
          (kons jobs)
          (kons options)
          (kons dep registry)
          (kons actions paths)
          (kons actions lock-shared)
          (kons commands framework))

(begin
(define (frozen-mode? cmd)
  (command-flag? cmd "frozen"))

(define (lock-entry-in-activation-scope? entry include-dev?)
  (let ((scope (lock-entry-ref entry 'scope 'runtime)))
    (or include-dev? (not (eq? scope 'dev)))))

(define (registry-entry-name-text entry)
  (name->string (lock-entry-ref entry 'name '())))

(define (registry-entry-archive-path entry)
  (registry-archive-path
   (lock-entry-ref entry 'registry default-registry-alias)
   (registry-entry-name-text entry)
   (lock-entry-ref entry 'version "")
   (lock-entry-ref entry 'checksum "")))

(define (verify-frozen-registry-archive! entry)
  (let ((archive (registry-entry-archive-path entry))
        (expected (lock-entry-ref entry 'checksum "")))
    (when (file-exists? archive)
      (let ((actual
             (capture-first-line
              (string-append
               "sha256sum " (shell-quote archive) " | awk '{print $1}'"))))
        (unless (string=? actual expected)
          (dependency-error "registry archive checksum mismatch"
                            (lock-entry-ref entry 'name '())
                            (lock-entry-ref entry 'version "")
                            expected
                            actual
                            '(diagnostic-code . "checksum-mismatch")))))))

(define (verify-frozen-registry-metadata! entry)
  (registry-package-candidates
   (lock-entry-ref entry 'registry default-registry-alias)
   (lock-entry-ref entry 'name '())
   #t))

(define (registry-entry-uses-vendor? manifest entry)
  (and (vendor-source-root manifest entry) #t))

(define (verify-frozen-registry-entry! manifest entry)
  (unless (registry-entry-uses-vendor? manifest entry)
    (verify-frozen-registry-metadata! entry)
    (verify-frozen-registry-archive! entry)))

(define (verify-frozen-registry-cache! manifest lock include-dev?)
  (let loop ((entries (lock-package-entries lock)))
    (cond
     ((null? entries) '())
     ((and (eq? (lock-entry-type (car entries)) 'registry)
           (lock-entry-in-activation-scope? (car entries) include-dev?))
      (verify-frozen-registry-entry! manifest (car entries))
      (loop (cdr entries)))
     (else (loop (cdr entries))))))

(define (verify-frozen-lock-cache-if-needed! manifest lock include-dev? cmd)
  (when (frozen-mode? cmd)
    (verify-frozen-registry-cache! manifest lock include-dev?)))

(define (ensure-activation-ready-core! manifest features include-dev? cmd)
  (let ((offline? (or (command-flag? cmd "offline")
                      (command-flag? cmd "frozen")))
        (lock-path (command-lock-path manifest cmd)))
    (cond
     ((file-exists? lock-path)
      (let ((stored (read-lockfile lock-path)))
        (cond
         ((activation-lock-fast-ready? manifest features include-dev? cmd stored offline?)
          (verify-frozen-lock-cache-if-needed! manifest stored include-dev? cmd)
          '())
         ((and offline? (lock-root-matches? manifest features cmd stored))
          (unless (lock-materialized? stored include-dev? manifest)
            (materialize-lock-sources manifest stored include-dev? offline? cmd))
          (verify-frozen-lock-cache-if-needed! manifest stored include-dev? cmd))
         ((lock-root-matches? manifest features cmd stored)
          (let ((new-lock (make-lock manifest features cmd include-dev? stored)))
            (cond
             ((activation-lock-compatible? manifest features include-dev? cmd stored)
             (unless (lock-materialized? stored include-dev? manifest)
                (materialize-lock-sources manifest stored include-dev? #f cmd)))
             ((command-locked-mode? cmd)
              (stale-lockfile-error manifest features cmd stored include-dev?))
             (else
              (write-expr-file lock-path new-lock)
              (log-info "updated kons.lock for activation")
              (materialize-live-and-akku-lock-sources manifest features include-dev? new-lock cmd)))))
         ((command-locked-mode? cmd)
          (stale-lockfile-error manifest features cmd stored include-dev?))
         (offline?
         (stale-lockfile-error manifest features cmd stored include-dev?))
         (else
          (let ((new-lock (make-lock manifest features cmd include-dev?)))
            (write-expr-file lock-path new-lock)
            (log-info "updated kons.lock for activation")
            (materialize-live-and-akku-lock-sources manifest features include-dev? new-lock cmd))))))
     ((or (command-locked-mode? cmd) offline?)
     (lockfile-error "kons.lock missing; run `kons update` first"))
     (else
      (let ((new-lock (make-lock manifest features cmd include-dev?)))
        (write-expr-file lock-path new-lock)
        (log-info "created kons.lock for activation")
        (materialize-live-and-akku-lock-sources manifest features include-dev? new-lock cmd))))))

(define (akku-lock-entry? entry)
  (eq? (lock-entry-type entry) 'akku))

(define (akku-only-lock lock)
  `(lockfile
    (packages ,@(filter akku-lock-entry? (lock-package-entries lock)))))

(define (materialize-live-and-akku-lock-sources manifest features include-dev? lock cmd)
  (append
   (materialize-local-sources manifest features include-dev? #f cmd)
   (materialize-lock-sources manifest (akku-only-lock lock) include-dev? #f cmd)))

(define (build-token manifest features profile)
  (safe-store-token
   (string-append (name->string (package-name manifest))
                  "-"
                  (if (package-version manifest) (package-version manifest) "0")
                  "-"
                  (symbol->string profile)
                  "-"
                  (string-join (map symbol->string features) "+"))))

(define (build-output-dir manifest features cmd)
  (path-join
   (path-join (project-kons-path manifest "builds") (build-token manifest features (command-selected-profile cmd)))
   (safe-store-token (name->string (package-name manifest)))))

(define (has-build-hooks? manifest)
  (not (null? (effective-build-hooks manifest))))

(define (build-output-needed? manifest)
  #t)

(define (implicit-build-hooks manifest)
  (let ((script (path-join (manifest-root manifest) "build.scm")))
    (if (file-exists? script)
        '(((type . scheme) (path . "build.scm") (implicit . #t)))
        '())))

(define (effective-build-hooks manifest)
  (let ((declared (package-build-hooks manifest)))
    (if (null? declared)
        (implicit-build-hooks manifest)
        declared)))

(define (build-hook-script manifest hook)
  (path-join (manifest-root manifest) (alist-ref hook 'path "")))

(define (directive-name directive)
  (and (pair? directive) (symbol? (car directive)) (car directive)))

(define (directive-args directive)
  (if (pair? directive) (cdr directive) '()))

(define (output-directive-paths build-root directive)
  (map
   (lambda (path)
     (if (absolute-path? path) path (path-join build-root path)))
   (directive-args directive)))

(define (build-hook-directives-path build-root script)
  (path-join (path-join build-root ".kons-build-hooks")
             (string-append (safe-store-token script) ".directives.scm")))

(define (stored-hook-directives path)
  (if (file-exists? path)
      (read-all-exprs path)
      '()))

(define (build-hook-output-directives manifest build-root)
  (append-map
   (lambda (hook)
     (let ((script (build-hook-script manifest hook)))
       (stored-hook-directives
        (build-hook-directives-path build-root script))))
   (effective-build-hooks manifest)))

(define (build-hook-output-load-paths manifest features cmd build-root)
  (append-map
   (lambda (directive)
     (if (or (eq? (directive-name directive) 'kons::load-path)
             (eq? (directive-name directive) 'kons::library-path))
         (output-directive-paths build-root directive)
         '()))
   (build-hook-output-directives manifest build-root)))

(define (compatible-activation-lock manifest include-dev? features cmd)
  (let ((lock-path (command-lock-path manifest cmd)))
    (and (file-exists? lock-path)
         (let ((lock (read-lockfile lock-path)))
           (and (lock-root-matches? manifest features cmd lock)
                (lock-materialized? lock include-dev? manifest)
                lock)))))

(define (locked-entry-for-source-root manifest include-dev? features cmd source-root)
  (let ((lock (compatible-activation-lock manifest include-dev? features cmd)))
    (and lock
         (let loop ((entries (lock-package-entries lock)))
           (cond
            ((null? entries) #f)
            ((not (locked-entry-in-scope? (car entries) include-dev?))
             (loop (cdr entries)))
            (else
             (let ((entry-root (locked-entry-source-root (car entries) manifest)))
               (if (and entry-root (same-path? entry-root source-root))
                   (car entries)
                   (loop (cdr entries))))))))))

(define (dependency-features-for-source-root manifest include-dev? features cmd source-root dep-manifest)
  (let ((entry (locked-entry-for-source-root manifest include-dev? features cmd source-root)))
    (if entry
        (lock-entry-rest entry 'features)
        (default-feature-set dep-manifest))))

(define (dependency-build-features source-root cmd dep-manifest maybe-context)
  (if (and (pair? maybe-context)
           (pair? (cdr maybe-context))
           (pair? (cddr maybe-context)))
      (dependency-features-for-source-root
       (car maybe-context)
       (cadr maybe-context)
       (caddr maybe-context)
       cmd
       source-root
       dep-manifest)
      (default-feature-set dep-manifest)))

(define (dependency-build-output-load-paths source-root cmd build-root . maybe-context)
  (let ((package-root (find-package-root-for-source-root source-root)))
    (if package-root
        (let ((dep-manifest (parse-manifest (path-join package-root "kons.scm"))))
          (build-hook-output-load-paths
           dep-manifest
           (dependency-build-features source-root cmd dep-manifest maybe-context)
           cmd
           build-root))
        '())))

(define (activation-source-roots-with-build manifest include-dev? features cmd)
  (let ((srcs (activation-source-roots-with-dependency-builds manifest include-dev? features cmd)))
    (if (or (not (build-output-needed? manifest)) (null? srcs))
        srcs
        (let* ((build-root (build-output-dir manifest features cmd))
               (generated-load-paths
                (build-hook-output-load-paths manifest features cmd build-root)))
          (cons (car srcs)
                (append (cons build-root generated-load-paths)
                        (cdr srcs)))))))

(define (dependency-build-output-dir dep-manifest dep-package-root dep-features cmd)
  (path-join
   (path-join
    (path-join (kons-store-root) "builds")
    (string-append
     (build-token dep-manifest dep-features (command-selected-profile cmd))
     "-"
     (safe-store-token (path-content-hash dep-package-root))))
   (safe-store-token (name->string (package-name dep-manifest)))))

(define (dependency-build-output-for-source-root source-root cmd . maybe-context)
  (let ((package-root (find-package-root-for-source-root source-root)))
    (and package-root
         (let* ((dep-manifest (parse-manifest (path-join package-root "kons.scm")))
                (dep-features (dependency-build-features source-root cmd dep-manifest maybe-context)))
	           (and (build-output-needed? dep-manifest)
	                (dependency-build-output-dir dep-manifest package-root dep-features cmd))))))

(define (activation-source-roots-with-dependency-builds manifest include-dev? features cmd)
  (let ((srcs (effective-activation-source-roots manifest include-dev? features cmd)))
    (if (null? srcs)
        srcs
        (let loop ((items (cdr srcs)) (out (list (car srcs))))
          (cond
           ((null? items) (reverse out))
           (else
            (let ((build-root
                   (dependency-build-output-for-source-root
                    (car items)
                    cmd
                    manifest
                    include-dev?
                    features)))
              (loop (cdr items)
                    (if build-root
                        (append
                         (reverse
                          (cons build-root
                                (dependency-build-output-load-paths
                                 (car items)
                                 cmd
                                 build-root
                                 manifest
                                 include-dev?
                                 features)))
                         (cons (car items) out))
                        (cons (car items) out))))))))))

(define (implementation-field probe key default)
  (let ((field (assq key (cdr probe))))
    (if (and field (pair? (cdr field)))
        (cadr field)
        default)))

(define (cache-record-hash record)
  (let ((path "/tmp/kons-cache-input.scm"))
    (write-expr-file path record)
    (let ((hash (file-content-hash path)))
      (when (file-exists? path)
        (delete-file path))
      (safe-store-token hash))))

(define (compiler-options cmd)
  `((scheme ,(command-selected-scheme cmd))
    (target ,(command-option cmd "target" #f))
    (profile ,(command-selected-profile cmd))
    (compile-mode ,(command-selected-compile-mode cmd))))

(define (compiled-cache-record manifest features cmd)
  (let ((scheme (command-selected-scheme cmd)))
    `(compiled-cache
      (root ,(package-name manifest))
	      (version ,(package-version manifest))
	      ,(implementation-probe scheme)
	      (target ,(command-option cmd "target" #f))
	      (profile ,(command-selected-profile cmd))
	      (features ,@features)
      (source-root ,(manifest-source-root manifest))
      (source-hash ,(path-content-hash (manifest-source-root manifest)))
      (lock-hash ,(let ((lock-path (command-lock-path manifest cmd)))
                    (if (file-exists? lock-path) (file-content-hash lock-path) #f)))
      (dependencies ,@(all-dependencies-for manifest #t features cmd))
      (options ,@(compiler-options cmd)))))

(define (compiled-cache-token manifest features cmd)
  (cache-record-hash (compiled-cache-record manifest features cmd)))

(define (compiled-output-dir manifest features cmd)
	  (let* ((scheme (command-selected-scheme cmd))
	         (probe (implementation-probe scheme))
	         (impl-version (implementation-field probe 'version "unknown"))
	         (target (if (command-option cmd "target" #f)
	                     (command-option cmd "target" #f)
	                     "host")))
	    (path-join
	     (path-join
	      (path-join
	       (path-join
	        (path-join (project-kons-path manifest "compiled") (symbol->string scheme))
	        (safe-store-token impl-version))
	       (safe-store-token target))
	      (symbol->string (command-selected-profile cmd)))
	     (compiled-cache-token manifest features cmd))))

(define cond-expand-library-probe-cache '())

(define (scheme-cond-expand-features scheme)
  (let ((mode (implementation-mode scheme)))
    (if mode
        (implementation-mode-features mode)
        (list scheme))))

(define (write-library-import-check-script path library-name)
  (call-with-output-file path
    (lambda (out)
      (write `(import (scheme base) ,library-name) out)
      (newline out)
      (write '(define kons-library-probe #t) out)
      (newline out))))

(define (scheme-implementation-library-available? scheme library-name)
  (let ((key `(,scheme ,library-name)))
    (cond
     ((assoc key cond-expand-library-probe-cache) => cdr)
     (else
      (let* ((script (temporary-file-path
                      (string-append "kons-cond-expand-"
                                     (symbol->string scheme)
                                     "-"
                                     (library-name-token library-name)
                                     ".scm")))
             (status #f))
        (write-library-import-check-script script library-name)
        (set! status
              (shell-command-status
               (string-append
                (scheme-command scheme '() script '())
                " >/dev/null 2>/dev/null")))
        (when (file-exists? script)
          (delete-file script))
        (let ((available? (= status 0)))
          (set! cond-expand-library-probe-cache
                (cons (cons key available?) cond-expand-library-probe-cache))
          available?))))))

(define (source-root-library-available? source-root library-name entries)
  (or (library-key-entry (cons 'r7rs library-name) entries)
      (library-key-entry (cons 'guile library-name) entries)
      (library-key-entry (cons 'r6rs library-name) entries)))

(define (cached-source-root-library-entries source-root cache)
  (cond
   ((assoc source-root cache)
    => (lambda (entry) (values (cdr entry) cache)))
   ((source-root-package-manifest source-root)
    => (lambda (source-manifest)
         (let ((entries (effective-package-libraries source-manifest)))
           (values entries (cons (cons source-root entries) cache)))))
   (else (values '() (cons (cons source-root '()) cache)))))

(define (source-roots-library-available? source-roots library-name cache)
  (let loop ((items source-roots))
    (cond
     ((null? items) (values #f cache))
     (else
      (call-with-values
       (lambda () (cached-source-root-library-entries (car items) cache))
       (lambda (entries new-cache)
         (set! cache new-cache)
         (if (source-root-library-available? (car items) library-name entries)
             (values #t cache)
             (loop (cdr items)))))))))

(define (compiler-library-discovery-context manifest cmd source-roots)
  (let ((scheme (adapter-scheme manifest (command-selected-scheme cmd)))
        (source-root-library-cache '()))
    (make-library-discovery-context
     (scheme-cond-expand-features scheme)
     (lambda (library-name)
       (or (scheme-implementation-library-available? scheme library-name)
           (call-with-values
            (lambda ()
              (source-roots-library-available?
               source-roots
               library-name
               source-root-library-cache))
            (lambda (available? new-cache)
              (set! source-root-library-cache new-cache)
              available?)))))))

(define (compiled-artifact-entries-for-scheme/context manifest scheme context)
  (let ((mode (implementation-mode scheme)))
    (if mode
        (append-map
         (lambda (kind)
           (case kind
             ((r7rs) (r7rs-library-entries/context manifest context))
             ((r6rs) (r6rs-library-entries/context manifest context))
             ((guile) (guile-library-entries/context manifest context))
             (else '())))
         (implementation-mode-compile-kinds mode))
        '())))

(define (package-declared-library-entries manifest)
  (alist-ref (alist-ref manifest 'package '()) 'libraries '()))

(define (same-kind-entry-name-in? kind name entries)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((and (eq? (caar items) kind)
           (equal? (cadar items) name))
      #t)
     (else (loop (cdr items))))))

(define (same-kind-entry-by-name kind name entries)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((and (eq? (caar items) kind)
           (equal? (cadar items) name))
      (car items))
     (else (loop (cdr items))))))

(define (compile-root-names manifest kind entries)
  (cond
   ((not (null? (package-declared-library-entries manifest))) #f)
   ((same-kind-entry-name-in? kind (package-name manifest) entries)
    (list (package-name manifest)))
   (else #f)))

(define (reachable-compile-entry-keys kind roots entries)
  (let ((seen '()))
    (define (seen? name)
      (let loop ((items seen))
        (cond
         ((null? items) #f)
         ((equal? (car items) name) #t)
         (else (loop (cdr items))))))
    (define (visit name)
      (unless (seen? name)
        (set! seen (cons name seen))
        (let ((entry (same-kind-entry-by-name kind name entries)))
          (when entry
            (for-each
             (lambda (import-name)
               (when (same-kind-entry-by-name kind import-name entries)
                 (visit import-name)))
             (library-entry-imports entry))))))
    (for-each visit roots)
    seen))

(define (compile-entry-reachable? entry reachable)
  (let loop ((items reachable))
    (cond
     ((null? items) #f)
     ((equal? (car items) (cadr entry)) #t)
     (else (loop (cdr items))))))

(define (compile-reachable-entries manifest entries)
  (let loop ((items entries) (out '()) (cache '()))
    (if (null? items)
        (reverse out)
        (let* ((entry (car items))
               (kind (car entry))
               (cached (assq kind cache))
               (roots (if cached
                          (cadr cached)
                          (compile-root-names manifest kind entries)))
               (reachable (if cached
                              (cddr cached)
                              (and roots
                                   (reachable-compile-entry-keys kind roots entries))))
               (cache (if cached cache (cons (cons kind (cons roots reachable)) cache))))
          (loop (cdr items)
                (if (or (not roots) (compile-entry-reachable? entry reachable))
                    (cons entry out)
                    out)
                cache)))))

(define (compiled-artifact-names-for-scheme/context manifest scheme context)
  (map cadr (compiled-artifact-entries-for-scheme/context manifest scheme context)))

(define (compiled-artifact-names-for-scheme manifest scheme)
  (compiled-artifact-names-for-scheme/context manifest scheme #f))

(define (compiled-artifact-names manifest cmd)
  (compiled-artifact-names-for-scheme
   manifest
   (adapter-scheme manifest (command-selected-scheme cmd))))

(define (source-root-package-manifest source-root)
  (let ((package-root (find-package-root-for-source-root source-root)))
    (and package-root
         (let* ((manifest (parse-manifest (path-join package-root "kons.scm")))
                (expected-source-root (path-join package-root (package-source-path manifest))))
           (and (same-path? source-root expected-source-root)
                manifest)))))

(define (compiler-source-roots manifest features cmd . maybe-srcs)
  (if (pair? maybe-srcs)
      (car maybe-srcs)
      (activation-source-roots-with-dependency-builds manifest #f features cmd)))

(define (compilable-source-root-records manifest features cmd . maybe-srcs)
  (let* ((scheme (adapter-scheme manifest (command-selected-scheme cmd)))
         (source-roots (apply compiler-source-roots manifest features cmd maybe-srcs))
         (context (compiler-library-discovery-context manifest cmd source-roots))
         (roots source-roots))
    (let loop ((roots (if (null? roots)
                          roots
                          (append (cdr roots) (list (car roots)))))
               (out '()))
      (cond
       ((null? roots) (reverse out))
       ((source-root-package-manifest (car roots))
        => (lambda (source-manifest)
             (let* ((entries
                     (compile-reachable-entries
                      source-manifest
                      (compiled-artifact-entries-for-scheme/context source-manifest scheme context)))
                    (names (map cadr entries)))
               (loop (cdr roots)
                     (if (null? names)
                         out
                         (cons `(,source-manifest ,(car roots) ,names ,context ,entries) out))))))
       (else (loop (cdr roots) out))))))

(define (compilable-artifact-names manifest features cmd . maybe-srcs)
  (let loop ((records (apply compilable-source-root-records manifest features cmd maybe-srcs)) (out '()))
    (if (null? records)
        (reverse out)
        (loop (cdr records)
              (append (reverse (third (car records))) out)))))

(define (has-compiled-artifacts-for-features? manifest features cmd)
  (not (null? (compilable-artifact-names manifest features cmd))))

(define (has-compiled-artifacts? manifest cmd)
  (has-compiled-artifacts-for-features? manifest (active-features manifest cmd) cmd))

(define (compiled-artifact-records manifest features cmd)
  (let ((compiled-root (compiled-output-dir manifest features cmd))
        (mode-id (adapter-scheme manifest (command-selected-scheme cmd))))
    (let loop-records ((records (compilable-source-root-records manifest features cmd)) (out '()))
      (if (null? records)
          (reverse out)
          (let loop-entries ((entries (list-ref (car records) 4)) (out out))
            (if (null? entries)
                (loop-records (cdr records) out)
                (let* ((entry (car entries))
                       (kind (car entry))
                       (name (cadr entry)))
                  (loop-entries
                   (cdr entries)
                   (cons `(compiled
                           (kind ,kind)
                           (library ,name)
                           (path ,(implementation-compile-output-path mode-id compiled-root kind name)))
                         out)))))))))

  ))
