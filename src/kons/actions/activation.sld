(define-library (kons actions activation)
  (export ensure-activation-ready!
          build-token
          build-output-dir
          has-build-hooks?
          implicit-build-hooks
          effective-build-hooks
          activation-source-roots-with-build
          dependency-build-output-dir
          dependency-build-output-for-source-root
          activation-source-roots-with-dependency-builds
          implementation-field
          cache-record-hash
          compiled-cache-record
          compiled-cache-token
          compiled-output-dir
          command-compiled-output-dirs
          command-runtime-compile-mode
          adapter-command-for-cmd
          adapter-repl-command-for-cmd
          launcher-command-for-cmd
          compiled-artifact-records
          build-record
          build-hook-script
          build-hook-watch-paths
          build-hook-watch-hashes
          build-hook-cache-record
          build-hook-marker-dir
          build-hook-marker-path
          build-hook-directives-path
          stored-hook-record
          stored-hook-directives
          run-build-hook-with-source-roots
          run-build-hook
          run-build-hooks
          run-build-hooks-if-needed!
          feature-library-name
          feature-helper-library-name
          write-feature-libraries!
          dependency-build-hook-source-roots
          run-dependency-build-hooks-for-source-root!
          run-dependency-build-hooks-if-needed!
          ensure-build-hooks-ready!
          ensure-runtime-activation-ready!
          ensure-dev-activation-ready!
          activation-job-graph
          run-activation-job-graph!
          run-activated-script
          module-name-string
          compile-implementation-libraries
          ensure-implementation-compiled!)
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
          (kons runner)
          (kons jobs)
          (kons options)
          (kons actions paths)
          (kons actions lock-shared)
          (kons commands framework))

(begin
(define (ensure-activation-ready-core! manifest features include-dev? cmd)
  (let ((offline? (or (command-flag? cmd "offline")
                      (command-flag? cmd "frozen")))
        (lock-path (project-lock-path manifest)))
    (cond
     ((file-exists? lock-path)
      (let ((stored (read-lockfile lock-path)))
        (cond
         ((activation-lock-fast-ready? manifest features include-dev? cmd stored offline?)
          '())
         ((and offline? (lock-root-matches? manifest features cmd stored))
          (unless (lock-materialized? stored include-dev?)
            (materialize-lock-sources manifest stored include-dev? offline? cmd)))
         ((lock-root-matches? manifest features cmd stored)
          (let ((new-lock (make-lock manifest features cmd include-dev?)))
            (cond
             ((activation-lock-compatible? manifest features include-dev? cmd stored)
              (unless (lock-materialized? stored include-dev?)
                (materialize-lock-sources manifest stored include-dev? #f cmd)))
             ((command-locked-mode? cmd)
              (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`"))
             (else
              (write-expr-file lock-path new-lock)
              (log-info "updated kons.lock for activation")
              (materialize-local-sources manifest features include-dev? #f cmd)))))
         ((command-locked-mode? cmd)
          (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`"))
         (offline?
         (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`"))
         (else
          (let ((new-lock (make-lock manifest features cmd include-dev?)))
            (write-expr-file lock-path new-lock)
            (log-info "updated kons.lock for activation")
            (materialize-local-sources manifest features include-dev? #f cmd))))))
     ((or (command-locked-mode? cmd) offline?)
     (lockfile-error "kons.lock missing; run `kons update` first"))
     (else
      (let ((new-lock (make-lock manifest features cmd include-dev?)))
        (write-expr-file lock-path new-lock)
        (log-info "created kons.lock for activation")
        (materialize-local-sources manifest features include-dev? #f cmd))))))

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

(define (dependency-build-output-for-source-root source-root cmd)
  (let ((package-root (find-package-root-for-source-root source-root)))
    (and package-root
         (let* ((dep-manifest (parse-manifest (path-join package-root "kons.scm")))
                (dep-features (default-feature-set dep-manifest)))
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
            (let ((build-root (dependency-build-output-for-source-root (car items) cmd)))
              (loop (cdr items)
                    (if build-root
                        (append
                         (reverse
                          (cons build-root
                                (dependency-build-output-load-paths (car items) cmd build-root)))
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
      (lock-hash ,(let ((lock-path (project-lock-path manifest)))
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

(define (source-root-library-available? source-root library-name)
  (cond
   ((source-root-package-manifest source-root)
    => (lambda (source-manifest)
         (or (library-key-entry
              (cons 'r7rs library-name)
              (effective-package-libraries source-manifest))
             (library-key-entry
              (cons 'guile library-name)
              (effective-package-libraries source-manifest))
             (library-key-entry
              (cons 'r6rs library-name)
              (effective-package-libraries source-manifest)))))
   (else #f)))

(define (source-roots-library-available? source-roots library-name)
  (let loop ((items source-roots))
    (cond
     ((null? items) #f)
     ((source-root-library-available? (car items) library-name) #t)
     (else (loop (cdr items))))))

(define (compiler-library-discovery-context manifest cmd source-roots)
  (let ((scheme (adapter-scheme manifest (command-selected-scheme cmd))))
    (make-library-discovery-context
     (scheme-cond-expand-features scheme)
     (lambda (library-name)
       (or (scheme-implementation-library-available? scheme library-name)
           (source-roots-library-available? source-roots library-name))))))

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

(define (build-output-files build-root)
  (define marker-name ".kons-build-hooks")
  (define (scan dir prefix out)
    (let loop ((entries (directory-list dir)) (out out))
      (cond
       ((null? entries) out)
       ((string=? (car entries) marker-name)
        (loop (cdr entries) out))
       (else
        (let* ((name (car entries))
               (path (path-join dir name))
               (rel (if (string=? prefix "")
                        name
                        (path-join prefix name))))
          (cond
           ((file-directory? path)
            (loop (cdr entries) (scan path rel out)))
           ((file-exists? path)
            (loop (cdr entries) (cons rel out)))
           (else (loop (cdr entries) out))))))))
  (if (file-exists? build-root)
      (sort-strings (scan build-root "" '()))
      '()))

(define (build-hook-output-records manifest features cmd)
  (let ((build-root (build-output-dir manifest features cmd)))
    (map (lambda (file)
           `(hook-output
             (path ,file)
             (absolute ,(path-join build-root file))))
         (build-output-files build-root))))

(define (output-directive-paths build-root directive)
  (map
   (lambda (path)
     (if (absolute-path? path) path (path-join build-root path)))
   (directive-args directive)))

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

(define (dependency-build-output-load-paths source-root cmd build-root)
  (let ((package-root (find-package-root-for-source-root source-root)))
    (if package-root
        (let ((dep-manifest (parse-manifest (path-join package-root "kons.scm"))))
          (build-hook-output-load-paths
           dep-manifest
           (default-feature-set dep-manifest)
           cmd
           build-root))
        '())))

(define (directive-value->string value)
  (cond
   ((string? value) value)
   ((symbol? value) (symbol->string value))
   (else "")))

(define (directive-string-values directive)
  (map directive-value->string (directive-args directive)))

(define (build-hook-directive-values directives name)
  (append-map
   (lambda (directive)
     (if (eq? (directive-name directive) name)
         (directive-string-values directive)
         '()))
   directives))

(define (build-hook-directive-path-values build-root directives name)
  (append-map
   (lambda (directive)
     (if (eq? (directive-name directive) name)
         (output-directive-paths build-root directive)
         '()))
   directives))

(define (path-list-string paths)
  (string-join paths ":"))

(define (env-entry name values)
  (if (null? values) '() (list (list name (path-list-string values)))))

(define (explicit-env-directives directives)
  (append-map
   (lambda (directive)
     (case (directive-name directive)
       ((kons::env)
        (let ((args (directive-string-values directive)))
          (if (and (pair? args) (pair? (cdr args)))
              (list (list (car args) (cadr args)))
              '())))
       ((kons::env-path)
        (let ((args (directive-string-values directive)))
          (if (and (pair? args) (pair? (cdr args)))
              (list (list (car args) (path-list-string (cdr args))))
              '())))
       (else '())))
   directives))

(define (build-hook-runtime-env manifest features cmd)
  (let* ((build-root (build-output-dir manifest features cmd))
         (directives (build-hook-output-directives manifest build-root))
         (ld-paths (append
                    (build-hook-directive-path-values build-root directives 'kons::ld-library-path)
                    (build-hook-directive-path-values build-root directives 'kons::dlopen-path)))
         (dyld-paths (append
                      (build-hook-directive-path-values build-root directives 'kons::dyld-library-path)
                      (build-hook-directive-path-values build-root directives 'kons::dlopen-path)))
         (ld-preloads (build-hook-directive-path-values build-root directives 'kons::ld-preload))
         (ld-preload-paths (build-hook-directive-path-values build-root directives 'kons::ld-preload-path)))
    (append
     (env-entry "LD_LIBRARY_PATH" ld-paths)
     (env-entry "DYLD_LIBRARY_PATH" dyld-paths)
     (env-entry "LD_PRELOAD" ld-preloads)
     (env-entry "LD_PRELOAD_PATH" ld-preload-paths)
     (explicit-env-directives directives))))

(define (merge-env-entry entry entries)
  (let loop ((items entries) (out '()) (done? #f))
    (cond
     ((null? items)
      (reverse (if done? out (cons entry out))))
     ((string=? (car entry) (caar items))
      (loop (cdr items)
            (cons (list (car entry)
                        (if (string=? (cadr entry) "")
                            (cadar items)
                            (if (string=? (cadar items) "")
                                (cadr entry)
                                (string-append (cadr entry) ":" (cadar items)))))
                  out)
            #t))
     (else (loop (cdr items) (cons (car items) out) done?)))))

(define (merge-env additions existing)
  (let loop ((items additions) (out existing))
    (if (null? items)
        out
        (loop (cdr items) (merge-env-entry (car items) out)))))

(define (command-with-runtime-build-env manifest features cmd command)
  (let ((env (build-hook-runtime-env manifest features cmd)))
    (if (null? env)
        command
        `(command
          (env ,@(merge-env env (command-env command)))
          (argv ,@(command-argv command))))))

(define (build-record manifest features cmd)
	  `(build
	    (root ,(package-name manifest))
	    (version ,(package-version manifest))
	    (profile ,(command-selected-profile cmd))
	    (features ,@features)
    (source-root ,(manifest-source-root manifest))
    (dependencies ,@(all-dependencies-for manifest #t features cmd))
    (outputs
     (metadata "build.scm")
     ,@(build-hook-output-records manifest features cmd)
     ,@(compiled-artifact-records manifest features cmd))))

(define (build-hook-script manifest hook)
  (path-join (manifest-root manifest) (alist-ref hook 'path "")))

(define (build-hook-watch-paths manifest hook)
  (map
   (lambda (path)
     (manifest-root-path manifest path))
   (alist-ref hook 'rerun-on-change '())))

(define (directive-name directive)
  (and (pair? directive) (symbol? (car directive)) (car directive)))

(define (directive-args directive)
  (if (pair? directive) (cdr directive) '()))

(define (known-build-directive? directive)
  (case (directive-name directive)
    ((kons::rerun-on-change
      kons::load-path
      kons::library-path
      kons::ld-library-path
      kons::dyld-library-path
      kons::ld-preload
      kons::ld-preload-path
      kons::dlopen-path
      kons::env
      kons::env-path
      kons::library
      kons::link-search
      kons::link-lib
      kons::output
      kons::metadata)
     #t)
    (else #f)))

(define (build-directive-output? directive)
  (case (directive-name directive)
    ((kons::load-path
      kons::library-path
      kons::ld-library-path
      kons::dyld-library-path
      kons::ld-preload
      kons::ld-preload-path
      kons::dlopen-path
      kons::env
      kons::env-path
      kons::library
      kons::link-search
      kons::link-lib
      kons::output
      kons::metadata)
     #t)
    (else #f)))

(define (string-prefix? prefix s)
  (let ((plen (string-length prefix)))
    (and (>= (string-length s) plen)
         (string=? prefix (substring s 0 plen)))))

(define (directive-output-line? line)
  (string-prefix? "(kons::" line))

(define (hook-directive-exprs lines)
  (let ((path (temporary-file-path "kons-hook-directives.scm")))
    (call-with-output-file path
      (lambda (out)
        (for-each
         (lambda (line)
           (when (directive-output-line? line)
             (display line out)
             (newline out)))
         lines)))
    (let ((exprs (if (file-exists? path) (read-all-exprs path) '())))
      (when (file-exists? path)
        (delete-file path))
      exprs)))

(define (hook-nondirective-lines lines)
  (let loop ((items lines) (out '()))
    (cond
     ((null? items) (reverse out))
     ((directive-output-line? (car items)) (loop (cdr items) out))
     (else (loop (cdr items) (cons (car items) out))))))

(define (validate-build-directive directive)
  (unless (known-build-directive? directive)
    (manifest-error "unknown build hook directive" directive))
  (if (eq? (directive-name directive) 'kons::library)
      (unless (and (= (length (directive-args directive)) 2)
                   (symbol-list? (car (directive-args directive)))
                   (pair? (cadr (directive-args directive))))
        (manifest-error "build hook library directive expects a library name and form" directive))
      (for-each
       (lambda (arg)
         (unless (or (string? arg) (symbol? arg))
           (manifest-error "build hook directive values must be strings or symbols" directive)))
       (directive-args directive)))
  directive)

(define (capture-build-directives command)
  (let* ((result (capture-command-lines/status (command->shell command)))
         (status (car result))
         (lines (cadr result)))
    (for-each displayln (hook-nondirective-lines lines))
    (unless (= status 0)
      (die "command failed" (command->shell command) status))
    (map validate-build-directive (hook-directive-exprs lines))))

(define (directive-paths manifest directive)
  (map
   (lambda (path)
     (manifest-root-path manifest path))
   (directive-args directive)))

(define (dynamic-build-hook-watch-paths manifest directives)
  (append-map
   (lambda (directive)
     (if (eq? (directive-name directive) 'kons::rerun-on-change)
         (directive-paths manifest directive)
         '()))
   directives))

(define (build-hook-watch-hashes/paths paths)
  (map
   (lambda (path)
     (unless (file-exists? path)
       (manifest-error "build hook watched path not found" path))
     `(,path ,(path-content-hash path)))
   paths))

(define (build-hook-watch-hashes manifest hook)
  (build-hook-watch-hashes/paths (build-hook-watch-paths manifest hook)))

(define (build-hook-cache-record manifest cmd features build-root hook script)
  (let* ((directive-path (build-hook-directives-path build-root script))
         (directives (stored-hook-directives directive-path))
         (watched (append
                   (build-hook-watch-paths manifest hook)
                   (dynamic-build-hook-watch-paths manifest directives)))
         (resolved-scheme (resolve-build-hook-scheme manifest hook cmd)))
    `(build-hook-cache
      (root ,(package-name manifest))
      (version ,(package-version manifest))
      (hook ,hook)
      (script ,script)
      (script-hash ,(file-content-hash script))
      (source-root ,(manifest-source-root manifest))
      ,@(if (null? watched)
            `((source-hash ,(path-content-hash (manifest-source-root manifest))))
            `((watched-paths ,@watched)
              (watched-hashes ,@(build-hook-watch-hashes/paths watched))))
	      (scheme ,resolved-scheme)
	      (target ,(command-option cmd "target" #f))
	      (profile ,(command-selected-profile cmd))
	      (features ,@features)
      (dependencies ,@(all-dependencies-for manifest #t features cmd)))))

(define (build-hook-marker-dir build-root)
  (path-join build-root ".kons-build-hooks"))

(define (build-hook-marker-path build-root script)
  (path-join (build-hook-marker-dir build-root)
             (string-append (safe-store-token script) ".scm")))

(define (build-hook-directives-path build-root script)
  (path-join (build-hook-marker-dir build-root)
             (string-append (safe-store-token script) ".directives.scm")))

(define (stored-hook-record marker)
  (if (file-exists? marker)
      (let ((exprs (read-all-exprs marker)))
        (if (null? exprs) #f (car exprs)))
      #f))

(define (stored-hook-directives path)
  (if (file-exists? path)
      (read-all-exprs path)
      '()))

(define (build-hook-argv-context manifest cmd features build-root source-root hook-scheme)
  (append
   (list build-root
         source-root
         "--kons-build-root"
         build-root
         "--kons-source-root"
         source-root
         "--kons-package-root"
         (manifest-root manifest)
         "--kons-out-dir"
         build-root
         "--kons-target-scheme"
         (symbol->string (adapter-scheme manifest (command-selected-scheme cmd)))
         "--kons-hook-scheme"
         (symbol->string hook-scheme)
         "--kons-profile"
         (symbol->string (command-selected-profile cmd))
         "--kons-target"
         (or (command-option cmd "target" #f) "")
         "--kons-package-name"
         (name->string (package-name manifest))
         "--kons-package-version"
         (or (package-version manifest) ""))
   (append-map
    (lambda (feature)
      (list "--kons-feature" (symbol->string feature)))
    features)
   (append-map
    (lambda (dialect)
      (list "--kons-dialect" (symbol->string dialect)))
    (package-dialects manifest))))

(define (resolve-build-hook-scheme manifest hook cmd)
  (let ((per-hook (alist-ref hook 'scheme-impl #f)))
    (adapter-scheme manifest
      (if per-hook
          per-hook
          (or (command-selected-hook-scheme cmd)
              (command-selected-scheme cmd))))))

(define (run-build-hook-with-source-roots manifest cmd features build-root hook srcs source-root)
  (case (alist-ref hook 'type #f)
    ((scheme)
     (let* ((script (build-hook-script manifest hook))
            (marker (build-hook-marker-path build-root script))
            (directives-path (build-hook-directives-path build-root script))
            (record (and (file-exists? script)
                         (build-hook-cache-record manifest cmd features build-root hook script)))
            (scheme (resolve-build-hook-scheme manifest hook cmd))
            (command (adapter-command
                  scheme
                  (cons build-root srcs)
                  script
                  (build-hook-argv-context manifest cmd features build-root source-root scheme)
                  'normal
                  '()
                  (command-selected-profile cmd))))
       (unless (file-exists? script)
         (manifest-error "build hook script not found" script))
	       (if (equal? (stored-hook-record marker) record)
	           (log-info "build hook unchanged" script)
	           (begin
                 (ui-status "running build hook" script)
	             (log-info "running build hook" script)
		             (log-debug "build command" (command->shell command))
		             (log-debug "build argv" (command-argv command))
	             (run-command (string-append "mkdir -p " (shell-quote (build-hook-marker-dir build-root))))
                 (let ((directives (capture-build-directives command)))
                   (write-build-directive-libraries! manifest build-root directives)
                   (call-with-output-file directives-path
                     (lambda (out)
                       (for-each
                        (lambda (directive)
                          (write directive out)
                          (newline out))
                        directives)))
                   (write-expr-file
                    marker
                    (build-hook-cache-record manifest cmd features build-root hook script)))
                 (ui-status-done "ran build hook" script)))))
    (else (manifest-error "unknown build hook type" (alist-ref hook 'type #f)))))

(define (run-build-hook manifest cmd features build-root hook)
  (run-build-hook-with-source-roots
   manifest
   cmd
   features
   build-root
   hook
   (activation-source-roots-with-dependency-builds manifest #t features cmd)
   (manifest-source-root manifest)))

(define (run-build-hooks manifest cmd features build-root)
  (let ((hooks (effective-build-hooks manifest)))
    (let loop ((items hooks) (done 0) (total (length hooks)))
      (cond
       ((null? items) '())
       (else
        (ui-progress "build hooks" (+ done 1) total
                     (alist-ref (car items) 'path "build hook"))
        (run-build-hook manifest cmd features build-root (car items))
        (loop (cdr items) (+ done 1) total))))))

(define (feature-library-name manifest feature)
  (append (package-name manifest) (list 'kons feature)))

(define (feature-helper-library-name manifest)
  (append (package-name manifest) '(kons features)))

(define (artifact-helper-library-name manifest)
  (append (package-name manifest) '(kons artifacts)))

(define (mkdir-for-library-path path)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path)))))

(define (write-library-expr! path expr)
  (mkdir-for-library-path path)
  (write-expr-file path expr))

(define (build-directive-library-name directive)
  (car (directive-args directive)))

(define (build-directive-library-form directive)
  (cadr (directive-args directive)))

(define (write-build-directive-library! manifest build-root directive)
  (let ((name (build-directive-library-name directive))
        (form (build-directive-library-form directive))
        (dialects (package-dialects manifest)))
    (when (memq 'r7rs dialects)
      (write-library-expr!
       (library-source-path build-root name)
       form))
    (when (memq 'guile dialects)
      (write-library-expr!
       (module-source-path build-root name)
       form))
    (when (memq 'r6rs dialects)
      (write-library-expr!
       (r6rs-library-output-path build-root name)
       form))))

(define (write-build-directive-libraries! manifest build-root directives)
  (for-each
   (lambda (directive)
     (when (eq? (directive-name directive) 'kons::library)
       (write-build-directive-library! manifest build-root directive)))
   directives))

(define (feature-cond-rules active-features)
  (append
   (map
    (lambda (feature)
      `((_ (,feature body ...) more ...)
        (begin body ...)))
    active-features)
   '(((_ (else body ...) more ...)
      (begin body ...))
     ((_ (_ body ...) more ...)
      (feature-cond more ...))
     ((_)
      (begin)))))

(define (feature-cond-syntax active-features)
  `(define-syntax feature-cond
     (syntax-rules ,(dedupe-symbols (cons 'else active-features))
       ,@(feature-cond-rules active-features))))

(define (r7rs-feature-marker-library name)
  `(define-library ,name
     (export active?)
     (import (scheme base))
     (begin
       (define active? #t))))

(define (r6rs-feature-marker-library name)
  `(library ,name
     (export active?)
     (import (rnrs))
     (define active? #t)))

(define (r7rs-feature-helper-library name active-features)
  `(define-library ,name
     (export active-features feature-enabled? feature-cond)
     (import (scheme base))
     (begin
       (define active-features ',active-features)
       (define (feature-enabled? feature)
         (and (memq feature active-features) #t))
       ,(feature-cond-syntax active-features))))

(define (r6rs-feature-helper-library name active-features)
  `(library ,name
     (export active-features feature-enabled? feature-cond)
     (import (rnrs))
     (define active-features ',active-features)
     (define (feature-enabled? feature)
     (and (memq feature active-features) #t))
     ,(feature-cond-syntax active-features)))

(define (r7rs-build-helper-library)
  '(define-library (kons build)
     (export build-root source-root package-root out-dir arg-value
             arg-values target-scheme hook-scheme profile target
             package-name package-version features feature-enabled?
             dialects dialect-enabled? r6rs?
             library-source-path write-library
             emit rerun-on-change add-load-path add-library-path
             add-ld-library-path add-dyld-library-path add-dlopen-path
             add-ld-preload add-ld-preload-path set-runtime-env
             add-runtime-env-path link-search link-lib output metadata)
     (import (scheme base)
             (scheme process-context)
             (scheme write))
     (begin
       (define (arg-value name default)
         (let loop ((items (command-line)))
           (cond
            ((null? items) default)
            ((and (pair? (cdr items)) (string=? (car items) name))
             (cadr items))
            (else (loop (cdr items)))))))
       (define (arg-values name)
         (let loop ((items (command-line)) (out '()))
           (cond
            ((null? items) (reverse out))
            ((and (pair? (cdr items)) (string=? (car items) name))
             (loop (cddr items) (cons (cadr items) out)))
            (else (loop (cdr items) out)))))
       (define build-root (arg-value "--kons-build-root" (cadr (command-line))))
       (define source-root (arg-value "--kons-source-root" (caddr (command-line))))
       (define package-root (arg-value "--kons-package-root" source-root))
       (define out-dir (arg-value "--kons-out-dir" build-root))
       (define target-scheme (string->symbol (arg-value "--kons-target-scheme" "")))
       (define hook-scheme (string->symbol (arg-value "--kons-hook-scheme" "")))
       (define profile (string->symbol (arg-value "--kons-profile" "")))
       (define target (arg-value "--kons-target" ""))
       (define package-name (arg-value "--kons-package-name" ""))
       (define package-version (arg-value "--kons-package-version" ""))
       (define features (map string->symbol (arg-values "--kons-feature")))
       (define (feature-enabled? feature)
         (and (memq feature features) #t))
       (define dialects (map string->symbol (arg-values "--kons-dialect")))
       (define (dialect-enabled? dialect)
         (and (memq dialect dialects) #t))
       (define r6rs? (dialect-enabled? 'r6rs))
       (define (path-join a b)
         (if (or (string=? a "") (string=? a "."))
             b
             (string-append a "/" b)))
       (define (library-name-part->string part)
         (if (symbol? part) (symbol->string part) part))
       (define (library-source-path name)
         (let loop ((parts name) (dir out-dir))
           (cond
            ((null? parts) dir)
            ((null? (cdr parts))
             (path-join dir
                        (string-append
                         (library-name-part->string (car parts))
                         (if r6rs? ".sls" ".sld"))))
            (else
             (loop (cdr parts)
                   (path-join dir (library-name-part->string (car parts))))))))
       (define (write-library name expr)
         (emit 'kons::library name expr)
         (add-library-path out-dir)
         (library-source-path name))
       (define (emit name . values)
         (write (cons name values))
         (newline))
       (define (rerun-on-change . paths)
         (apply emit 'kons::rerun-on-change paths))
       (define (add-load-path . paths)
         (apply emit 'kons::load-path paths))
       (define (add-library-path . paths)
         (apply emit 'kons::library-path paths))
       (define (add-ld-library-path . paths)
         (apply emit 'kons::ld-library-path paths))
       (define (add-dyld-library-path . paths)
         (apply emit 'kons::dyld-library-path paths))
       (define (add-dlopen-path . paths)
         (apply emit 'kons::dlopen-path paths))
       (define (add-ld-preload . paths)
         (apply emit 'kons::ld-preload paths))
       (define (add-ld-preload-path . paths)
         (apply emit 'kons::ld-preload-path paths))
       (define (set-runtime-env name value)
         (emit 'kons::env name value))
       (define (add-runtime-env-path name . paths)
         (apply emit 'kons::env-path name paths))
       (define (link-search . paths)
         (apply emit 'kons::link-search paths))
       (define (link-lib . libs)
         (apply emit 'kons::link-lib libs))
       (define (output key value)
         (emit 'kons::output key value))
       (define (metadata key value)
         (emit 'kons::metadata key value))))

(define (r6rs-build-helper-library)
  '(library (kons build)
     (export build-root source-root package-root out-dir arg-value
             arg-values target-scheme hook-scheme profile target
             package-name package-version features feature-enabled?
             dialects dialect-enabled? r6rs?
             library-source-path write-library
             emit rerun-on-change add-load-path add-library-path
             add-ld-library-path add-dyld-library-path add-dlopen-path
             add-ld-preload add-ld-preload-path set-runtime-env
             add-runtime-env-path link-search link-lib output metadata)
     (import (rnrs)
             (rnrs programs))
     (define (arg-value name default)
       (let loop ((items (command-line)))
         (cond
          ((null? items) default)
         ((and (pair? (cdr items)) (string=? (car items) name))
           (cadr items))
          (else (loop (cdr items))))))
     (define (arg-values name)
       (let loop ((items (command-line)) (out '()))
         (cond
          ((null? items) (reverse out))
          ((and (pair? (cdr items)) (string=? (car items) name))
           (loop (cddr items) (cons (cadr items) out)))
          (else (loop (cdr items) out)))))
     (define build-root (arg-value "--kons-build-root" (cadr (command-line))))
     (define source-root (arg-value "--kons-source-root" (caddr (command-line))))
     (define package-root (arg-value "--kons-package-root" source-root))
     (define out-dir (arg-value "--kons-out-dir" build-root))
     (define target-scheme (string->symbol (arg-value "--kons-target-scheme" "")))
     (define hook-scheme (string->symbol (arg-value "--kons-hook-scheme" "")))
     (define profile (string->symbol (arg-value "--kons-profile" "")))
     (define target (arg-value "--kons-target" ""))
     (define package-name (arg-value "--kons-package-name" ""))
     (define package-version (arg-value "--kons-package-version" ""))
     (define features (map string->symbol (arg-values "--kons-feature")))
     (define (feature-enabled? feature)
       (and (memq feature features) #t))
     (define dialects (map string->symbol (arg-values "--kons-dialect")))
     (define (dialect-enabled? dialect)
       (and (memq dialect dialects) #t))
     (define r6rs? (dialect-enabled? 'r6rs))
     (define (path-join a b)
       (if (or (string=? a "") (string=? a "."))
           b
           (string-append a "/" b)))
     (define (library-name-part->string part)
       (if (symbol? part) (symbol->string part) part))
     (define (library-source-path name)
       (let loop ((parts name) (dir out-dir))
         (cond
          ((null? parts) dir)
          ((null? (cdr parts))
           (path-join dir
                      (string-append
                       (library-name-part->string (car parts))
                       (if r6rs? ".sls" ".sld"))))
          (else
           (loop (cdr parts)
                 (path-join dir (library-name-part->string (car parts))))))))
     (define (write-library name expr)
       (emit 'kons::library name expr)
       (add-library-path out-dir)
       (library-source-path name))
     (define (emit name . values)
       (write (cons name values))
       (newline))
     (define (rerun-on-change . paths)
       (apply emit 'kons::rerun-on-change paths))
     (define (add-load-path . paths)
       (apply emit 'kons::load-path paths))
     (define (add-library-path . paths)
       (apply emit 'kons::library-path paths))
     (define (add-ld-library-path . paths)
       (apply emit 'kons::ld-library-path paths))
     (define (add-dyld-library-path . paths)
       (apply emit 'kons::dyld-library-path paths))
     (define (add-dlopen-path . paths)
       (apply emit 'kons::dlopen-path paths))
     (define (add-ld-preload . paths)
       (apply emit 'kons::ld-preload paths))
     (define (add-ld-preload-path . paths)
       (apply emit 'kons::ld-preload-path paths))
     (define (set-runtime-env name value)
       (emit 'kons::env name value))
     (define (add-runtime-env-path name . paths)
       (apply emit 'kons::env-path name paths))
     (define (link-search . paths)
       (apply emit 'kons::link-search paths))
     (define (link-lib . libs)
       (apply emit 'kons::link-lib libs))
     (define (output key value)
       (emit 'kons::output key value))
     (define (metadata key value)
       (emit 'kons::metadata key value))))

(define (directive-values-for-name build-root directives name path?)
  (append-map
   (lambda (directive)
     (if (eq? (directive-name directive) name)
         (if path?
             (output-directive-paths build-root directive)
             (directive-string-values directive))
         '()))
   directives))

(define (paired-directive-values directives name)
  (append-map
   (lambda (directive)
     (if (eq? (directive-name directive) name)
         (let ((args (directive-string-values directive)))
           (if (and (pair? args) (pair? (cdr args)))
               (list (list (car args) (cadr args)))
               '()))
         '()))
   directives))

(define (env-path-directive-values directives)
  (append-map
   (lambda (directive)
     (if (eq? (directive-name directive) 'kons::env-path)
         (let ((args (directive-string-values directive)))
           (if (and (pair? args) (pair? (cdr args)))
               (list (cons (car args) (cdr args)))
               '()))
         '()))
   directives))

(define (artifact-helper-data build-root directives)
  `((directives ,@directives)
    (load-paths
     ,@(append
        (directive-values-for-name build-root directives 'kons::load-path #t)
        (directive-values-for-name build-root directives 'kons::library-path #t)))
    (library-paths ,@(directive-values-for-name build-root directives 'kons::library-path #t))
    (ld-library-paths ,@(directive-values-for-name build-root directives 'kons::ld-library-path #t))
    (dyld-library-paths ,@(directive-values-for-name build-root directives 'kons::dyld-library-path #t))
    (dlopen-paths ,@(directive-values-for-name build-root directives 'kons::dlopen-path #t))
    (ld-preloads ,@(directive-values-for-name build-root directives 'kons::ld-preload #t))
    (ld-preload-paths ,@(directive-values-for-name build-root directives 'kons::ld-preload-path #t))
    (link-search-paths ,@(directive-values-for-name build-root directives 'kons::link-search #t))
    (link-libs ,@(directive-values-for-name build-root directives 'kons::link-lib #f))
    (outputs ,@(paired-directive-values directives 'kons::output))
    (metadata ,@(paired-directive-values directives 'kons::metadata))
    (env ,@(paired-directive-values directives 'kons::env))
    (env-paths ,@(env-path-directive-values directives))))

(define (artifact-field data name)
  (let ((field (assq name data)))
    (if field (cdr field) '())))

(define (r7rs-artifact-helper-library name data)
  `(define-library ,name
     (export directives load-paths library-paths ld-library-paths
             dyld-library-paths dlopen-paths ld-preloads
             ld-preload-paths link-search-paths link-libs
             outputs metadata env env-paths)
     (import (scheme base))
     (begin
       (define directives ',(artifact-field data 'directives))
       (define load-paths ',(artifact-field data 'load-paths))
       (define library-paths ',(artifact-field data 'library-paths))
       (define ld-library-paths ',(artifact-field data 'ld-library-paths))
       (define dyld-library-paths ',(artifact-field data 'dyld-library-paths))
       (define dlopen-paths ',(artifact-field data 'dlopen-paths))
       (define ld-preloads ',(artifact-field data 'ld-preloads))
       (define ld-preload-paths ',(artifact-field data 'ld-preload-paths))
       (define link-search-paths ',(artifact-field data 'link-search-paths))
       (define link-libs ',(artifact-field data 'link-libs))
       (define outputs ',(artifact-field data 'outputs))
       (define metadata ',(artifact-field data 'metadata))
       (define env ',(artifact-field data 'env))
       (define env-paths ',(artifact-field data 'env-paths)))))

(define (r6rs-artifact-helper-library name data)
  `(library ,name
     (export directives load-paths library-paths ld-library-paths
             dyld-library-paths dlopen-paths ld-preloads
             ld-preload-paths link-search-paths link-libs
             outputs metadata env env-paths)
     (import (rnrs))
     (define directives ',(artifact-field data 'directives))
     (define load-paths ',(artifact-field data 'load-paths))
     (define library-paths ',(artifact-field data 'library-paths))
     (define ld-library-paths ',(artifact-field data 'ld-library-paths))
     (define dyld-library-paths ',(artifact-field data 'dyld-library-paths))
     (define dlopen-paths ',(artifact-field data 'dlopen-paths))
     (define ld-preloads ',(artifact-field data 'ld-preloads))
     (define ld-preload-paths ',(artifact-field data 'ld-preload-paths))
     (define link-search-paths ',(artifact-field data 'link-search-paths))
     (define link-libs ',(artifact-field data 'link-libs))
     (define outputs ',(artifact-field data 'outputs))
     (define metadata ',(artifact-field data 'metadata))
     (define env ',(artifact-field data 'env))
     (define env-paths ',(artifact-field data 'env-paths))))

(define (r6rs-library-output-path source-root name)
  (r6rs-library-source-path source-root name))

(define (write-feature-marker-library! build-root name)
  (write-library-expr!
   (library-source-path build-root name)
   (r7rs-feature-marker-library name))
  (write-library-expr!
   (r6rs-library-output-path build-root name)
   (r6rs-feature-marker-library name)))

(define (write-feature-helper-library! build-root name active-features)
  (write-library-expr!
   (library-source-path build-root name)
   (r7rs-feature-helper-library name active-features))
  (write-library-expr!
   (r6rs-library-output-path build-root name)
   (r6rs-feature-helper-library name active-features)))

(define (write-build-helper-library! build-root)
  (write-library-expr!
   (library-source-path build-root '(kons build))
   (r7rs-build-helper-library))
  (write-library-expr!
   (r6rs-library-output-path build-root '(kons build))
   (r6rs-build-helper-library)))

(define (write-artifact-helper-library! manifest build-root)
  (let* ((name (artifact-helper-library-name manifest))
         (data (artifact-helper-data
                build-root
                (build-hook-output-directives manifest build-root))))
    (write-library-expr!
     (library-source-path build-root name)
     (r7rs-artifact-helper-library name data))
    (write-library-expr!
     (r6rs-library-output-path build-root name)
     (r6rs-artifact-helper-library name data))))

(define (write-feature-libraries! manifest features build-root)
  (let ((helper (feature-helper-library-name manifest)))
    (write-build-helper-library! build-root)
    (write-feature-helper-library! build-root helper features)
    (for-each
     (lambda (feature)
       (write-feature-marker-library!
        build-root
        (feature-library-name manifest feature)))
     features)))

(define (run-build-hooks-if-needed! manifest features cmd)
  (when (build-output-needed? manifest)
    (let ((dir (build-output-dir manifest features cmd)))
      (run-command (string-append "mkdir -p " (shell-quote dir)))
      (write-feature-libraries! manifest features dir)
      (when (has-build-hooks? manifest)
        (run-build-hooks manifest cmd features dir))
      (write-artifact-helper-library! manifest dir))))

(define (dependency-build-hook-source-roots manifest include-dev? features cmd dep-source-root dep-build-root)
  (let loop ((items (cdr (activation-source-roots-with-dependency-builds manifest include-dev? features cmd)))
             (out (list dep-build-root dep-source-root)))
    (cond
     ((null? items) (reverse out))
     ((same-path? (car items) dep-source-root) (loop (cdr items) out))
     ((same-path? (car items) dep-build-root) (loop (cdr items) out))
     (else (loop (cdr items) (cons (car items) out))))))

(define (run-dependency-build-hooks-for-source-root! manifest include-dev? features cmd dep-source-root)
  (let ((package-root (find-package-root-for-source-root dep-source-root)))
    (when package-root
      (let* ((dep-manifest (parse-manifest (path-join package-root "kons.scm")))
             (dep-features (default-feature-set dep-manifest)))
        (when (build-output-needed? dep-manifest)
          (let ((dep-build-root (dependency-build-output-dir dep-manifest package-root dep-features cmd)))
            (run-command (string-append "mkdir -p " (shell-quote dep-build-root)))
            (write-feature-libraries! dep-manifest dep-features dep-build-root)
            (when (has-build-hooks? dep-manifest)
              (let ((srcs (dependency-build-hook-source-roots
                           manifest include-dev? features cmd dep-source-root dep-build-root)))
                (for-each
                 (lambda (hook)
                   (run-build-hook-with-source-roots
                    dep-manifest
                    cmd
                    dep-features
                    dep-build-root
                    hook
                    srcs
                    dep-source-root))
                 (effective-build-hooks dep-manifest))))
            (write-artifact-helper-library! dep-manifest dep-build-root)))))))

(define (run-dependency-build-hooks-if-needed! manifest include-dev? features cmd)
  (let ((roots (cdr (effective-activation-source-roots manifest include-dev? features cmd))))
    (let loop ((items roots) (done 0) (total (length roots)))
      (cond
       ((null? items) '())
       (else
        (ui-progress "dependency build hooks" (+ done 1) total (car items))
        (run-dependency-build-hooks-for-source-root! manifest include-dev? features cmd (car items))
        (loop (cdr items) (+ done 1) total))))))

(define (activation-job-runner-options cmd)
  (make-job-runner-options (command-job-count cmd) #f #t #f command-job-event-handler))

(define (job-event-field event key default)
  (let loop ((items (cdr event)))
    (cond
     ((null? items) default)
     ((and (pair? (car items))
           (eq? (caar items) key)
           (pair? (cdar items)))
      (cadar items))
     (else (loop (cdr items))))))

(define (command-job-event-handler event)
  (let ((status (job-event-field event 'status #f))
        (label (job-event-field event 'label #f))
        (metadata (job-event-field event 'metadata '())))
    (when (and label (alist-ref metadata 'ui #f))
      (let ((done-label (alist-ref metadata 'done-label label)))
        (case status
          ((started) (ui-status label))
          ((done planned) (ui-status-done done-label))
          ((failed) (ui-status-fail label))
          (else #f))))))

(define (command-job id kind label deps metadata resources parallel-safe? thunk)
  (make-job id kind label deps metadata resources parallel-safe? thunk))

(define (command-job-graph id kind label metadata thunk)
  (make-job-graph
   (list
    (command-job id
                 kind
                 label
                 '()
                 metadata
                 '(ui)
                 #f
                 thunk))
   (list id)))

(define (run-command-job-graph! graph cmd)
  (run-job-graph!
   graph
   (make-job-runner-options
    (command-job-count cmd)
    #f
    #t
    #f
    command-job-event-handler)))

(define (activation-job-graph manifest features cmd include-dev? root-build-output?)
  (let* ((activation-id 'activation)
         (dep-hooks-id 'dependency-build-hooks)
         (root-hooks-id 'root-build-hooks)
         (lock-path (project-lock-path manifest))
         (activation
          (make-job
           activation-id
           'activation
           "prepare activation"
           '()
           `((root ,(package-name manifest))
             (features ,@features)
             (includes-dev-dependencies ,include-dev?)
             (lockfile ,lock-path))
           `(ui ,lock-path ,(kons-store-root))
           #f
           (lambda ()
             (ensure-activation-ready-core! manifest features include-dev? cmd))))
         (dep-hooks
          (make-job
           dep-hooks-id
           'build-hooks
           "prepare dependency build hooks"
           (list activation-id)
           `((root ,(package-name manifest))
             (features ,@features)
             (includes-dev-dependencies ,include-dev?))
           `(ui ,(kons-store-root))
           #f
           (lambda ()
             (run-dependency-build-hooks-if-needed! manifest include-dev? features cmd))))
         (root-hooks
          (make-job
           root-hooks-id
           'build-hooks
           "prepare root build hooks"
           (list dep-hooks-id)
           `((root ,(package-name manifest))
             (features ,@features)
             (build-root ,(build-output-dir manifest features cmd)))
           `(ui ,(build-output-dir manifest features cmd))
           #f
           (lambda ()
             (run-build-hooks-if-needed! manifest features cmd)))))
    (if root-build-output?
        (make-job-graph (list activation dep-hooks root-hooks) (list root-hooks-id))
        (make-job-graph (list activation dep-hooks) (list dep-hooks-id)))))

(define (run-activation-job-graph! graph cmd)
  (run-job-graph! graph (activation-job-runner-options cmd)))

(define (ensure-activation-ready! manifest features include-dev? cmd)
  (run-activation-job-graph!
   (make-job-graph
    (list
     (make-job
      'activation
      'activation
      "prepare activation"
      '()
      `((root ,(package-name manifest))
        (features ,@features)
        (includes-dev-dependencies ,include-dev?)
        (lockfile ,(project-lock-path manifest)))
      `(ui ,(project-lock-path manifest) ,(kons-store-root))
      #f
      (lambda ()
        (ensure-activation-ready-core! manifest features include-dev? cmd))))
    '(activation))
   cmd))

(define (ensure-build-hooks-ready! manifest features cmd)
  (when (has-build-hooks? manifest)
    (ui-status "preparing build hooks")
    (run-activation-job-graph!
     (activation-job-graph manifest features cmd #t (build-output-needed? manifest))
     cmd)
    (ui-status-done "prepared build hooks")))

(define (ensure-runtime-activation-ready! manifest features cmd)
  (ui-status "preparing runtime activation")
  (run-activation-job-graph!
   (activation-job-graph manifest
                         features
                         cmd
                         (if (has-build-hooks? manifest) #t #f)
                         (build-output-needed? manifest))
   cmd)
  (ui-status-done "prepared runtime activation"))

(define (ensure-dev-activation-ready! manifest features cmd)
  (ui-status "preparing dev activation")
  (run-activation-job-graph!
   (activation-job-graph manifest features cmd #t (build-output-needed? manifest))
   cmd)
  (ui-status-done "prepared dev activation"))

(define (run-activated-script manifest cmd script include-dev? rest)
  (let* ((scheme (command-selected-scheme cmd))
         (adapted-scheme (adapter-scheme manifest scheme))
         (features (active-features manifest cmd))
         (srcs (activation-source-roots-with-build manifest include-dev? features cmd))
         (command (adapter-command-for-cmd manifest cmd adapted-scheme srcs script rest)))
    (check-system-dependencies manifest cmd include-dev? features srcs)
    (when include-dev?
      (log-info "dev dependencies are available when materialized"))
    (log-debug "command" (command->shell command))
    (log-debug "argv" (command-argv command))
    (ui-status-done "running" script)
    (run-command-record command)))

(define (module-name-string name)
  (let loop ((items name) (out "("))
    (cond
     ((null? items) (string-append out ")"))
     ((string=? out "(")
      (loop (cdr items) (string-append out (lock-value-key (car items)))))
     (else
      (loop (cdr items) (string-append out " " (lock-value-key (car items))))))))

(define (ui-compiled-library name)
  (ui-status-done "Compiled" (module-name-string name)))

(define (compiler-source-roots manifest features cmd . maybe-srcs)
  (if (pair? maybe-srcs)
      (car maybe-srcs)
      (activation-source-roots-with-dependency-builds manifest #f features cmd)))

(define (library-source-path-for-kind source-root kind name entry)
  (if entry
      (library-entry-path source-root entry)
      (case kind
        ((r7rs) (library-source-path source-root name))
        ((r6rs) (r6rs-library-source-path source-root name))
        ((guile) (module-source-path source-root name))
        (else (manifest-error "unknown compilation library kind" kind)))))

(define (compile-library-entry compiled-root mode-id source-root kind name entry srcs)
  (let* ((source (library-source-path-for-kind source-root kind name entry))
         (output (implementation-compile-output-path mode-id compiled-root kind name))
         (log (string-append output ".log"))
         (command (implementation-compile-command mode-id kind srcs output source)))
    (unless (file-exists? source)
      (manifest-error "declared library source not found" name source))
    (unless (file-exists? output)
      (run-command (string-append "mkdir -p " (shell-quote (dirname output))))
      (run-command (string-append (command->shell command)
                                  " > " (shell-quote log)
                                  " 2>&1")))
    output))

(define (compile-spec-source-manifest spec) (list-ref spec 0))
(define (compile-spec-source-root spec) (list-ref spec 1))
(define (compile-spec-kind spec) (list-ref spec 2))
(define (compile-spec-name spec) (list-ref spec 3))
(define (compile-spec-entry spec) (list-ref spec 4))
(define (compile-spec-output spec) (list-ref spec 5))
(define (compile-spec-id spec) (list-ref spec 6))

(define (compile-spec-import-deps spec kind name specs)
  (let loop ((items specs) (out '()))
    (cond
     ((null? items) (reverse out))
     ((and (not (equal? (compile-spec-id spec) (compile-spec-id (car items))))
           (eq? kind (compile-spec-kind (car items)))
           (equal? name (compile-spec-name (car items))))
      (loop (cdr items) (cons (compile-spec-id (car items)) out)))
     (else (loop (cdr items) out)))))

(define (compile-spec-deps spec specs)
  (let ((kind (compile-spec-kind spec))
        (imports (library-entry-imports (compile-spec-entry spec))))
    (let loop ((items imports) (out '()))
      (cond
       ((null? items) (reverse out))
       (else
        (loop (cdr items)
              (append (reverse (compile-spec-import-deps spec kind (car items) specs))
                      out)))))))

(define (compile-job-done-label name)
  (string-append "compiled " (module-name-string name)))

(define (compile-job-label name)
  (string-append "compiling " (module-name-string name)))

(define (compile-job-results-values results)
  (map job-result-value results))

(define (compile-spec-resources spec)
  (list (compile-spec-output spec)))

(define (compile-specs->jobs compiled-root mode-id specs srcs)
  (let loop ((items specs) (jobs '()))
    (if (null? items)
        (reverse jobs)
        (let* ((spec (car items))
               (kind (compile-spec-kind spec))
               (name (compile-spec-name spec)))
          (loop
           (cdr items)
           (cons
            (make-job
             (compile-spec-id spec)
             'compile
             (compile-job-label name)
             (compile-spec-deps spec specs)
             `((ui . #t)
               (done-label . ,(compile-job-done-label name))
               (library . ,name)
               (kind . ,kind))
             (compile-spec-resources spec)
             #t
             (lambda ()
               (compile-library-entry
                compiled-root
                mode-id
                (compile-spec-source-root spec)
                kind
                name
                (compile-spec-entry spec)
                srcs)))
            jobs))))))

(define (active-compile-message active)
  (if (null? active)
      #f
      (let loop ((items (reverse active)) (count 0) (shown '()))
        (cond
         ((null? items) (string-join (reverse shown) ", "))
         ((>= count 4) (string-join (reverse (cons "..." shown)) ", "))
         (else (loop (cdr items) (+ count 1) (cons (car items) shown)))))))

(define (display-padding count)
  (let loop ((n count))
    (when (> n 0)
      (display " " (current-error-port))
      (loop (- n 1)))))

(define (display-compile-status label color message)
  (when (ui-enabled?)
    (ui-clear-active-line)
    (display-padding (max 1 (- 12 (string-length label))))
    (display (ui-colorize color label) (current-error-port))
    (when message
      (display " " (current-error-port))
      (display message (current-error-port)))
    (newline (current-error-port))))

(define (remove-string item items)
  (let loop ((xs items) (out '()) (removed? #f))
    (cond
     ((null? xs) (reverse out))
     ((and (not removed?) (string=? item (car xs)))
      (loop (cdr xs) out #t))
     (else (loop (cdr xs) (cons (car xs) out) removed?)))))

(define (make-compile-job-event-handler total)
  (let ((done 0)
        (active '()))
    (lambda (event)
      (let* ((status (job-event-field event 'status #f))
             (metadata (job-event-field event 'metadata '()))
             (name (alist-ref metadata 'library #f))
             (message-name (and name (module-name-string name))))
        (case status
          ((started)
           (when message-name
             (set! active (cons message-name active)))
           (ui-progress "Compiling" done total (active-compile-message active)))
          ((done planned)
           (when message-name
             (set! active (remove-string message-name active)))
           (set! done (+ done 1))
           (display-compile-status "Compiled" 'green message-name)
           (if (= done total)
               (display-compile-status
                "Finished"
                'bold
                (string-append "compiled "
                               (number->string total)
                               " libraries"))
               (when (not (null? active))
                 (ui-progress "Compiling" done total (active-compile-message active)))))
          ((failed)
           (ui-status-fail "Failed" message-name))
          (else #f))))))

(define (run-compile-specs! cmd compiled-root mode-id specs srcs)
  (if (null? specs)
      '()
      (let ((total (length specs)))
        (run-command (string-append "mkdir -p " (shell-quote compiled-root)))
        (compile-job-results-values
         (run-job-graph!
          (make-job-graph
           (compile-specs->jobs compiled-root mode-id specs srcs)
           (map compile-spec-id specs))
          (make-job-runner-options
           (command-job-count cmd)
           #f
           #t
           #f
           (make-compile-job-event-handler total)))))))

(define (implementation-compile-specs mode-id compiled-root records)
  (let loop-records ((items records) (index 0) (out '()))
    (if (null? items)
        (reverse out)
        (let ((source-manifest (car (car items)))
              (source-root (cadr (car items)))
              (entries (list-ref (car items) 4)))
          (log-trace "planning implementation compile record"
                     mode-id
                     (package-name source-manifest)
                     source-root
                     (length entries))
          (let loop-entries ((entries entries) (index index) (out out))
            (if (null? entries)
                (loop-records (cdr items) index out)
                (let* ((entry (car entries))
                       (kind (car entry))
                       (name (cadr entry))
                       (output (implementation-compile-output-path mode-id compiled-root kind name)))
                  (loop-entries
                   (cdr entries)
                   (+ index 1)
                   (if (file-exists? output)
                       out
                       (cons `(,source-manifest
                               ,source-root
                               ,kind
                               ,name
                               ,entry
                               ,output
                               (compile ,mode-id ,kind ,index ,name))
                             out))))))))))

(define (compile-implementation-libraries manifest features cmd . maybe-srcs)
  (let* ((mode-id (adapter-scheme manifest (command-selected-scheme cmd)))
         (records (apply compilable-source-root-records manifest features cmd maybe-srcs)))
    (log-trace "planning implementation compilation" mode-id (package-name manifest))
    (cond
     ((not (implementation-compiler-command mode-id)) '())
     ((null? records) '())
     ((not (implementation-compiler-available? mode-id)) '())
     (else
      (let* ((compiled-root (compiled-output-dir manifest features cmd))
             (specs (implementation-compile-specs mode-id compiled-root records))
             (srcs (apply compiler-source-roots manifest features cmd maybe-srcs)))
        (log-trace "running implementation compile specs"
                   mode-id
                   (length specs)
                   (command-job-count cmd))
        (run-compile-specs! cmd compiled-root mode-id specs srcs))))))

(define (command-runtime-compile-mode manifest features cmd . maybe-install?)
  (let* ((install? (and (pair? maybe-install?) (car maybe-install?)))
         (mode-id (adapter-scheme manifest (command-selected-scheme cmd))))
    (cond
     ((not (implementation-compiler-command mode-id)) 'normal)
     ((not (has-compiled-artifacts? manifest cmd))
      (if (and (not install?) (eq? (command-selected-compile-mode cmd) 'fresh-auto))
          'fresh-auto
          'normal))
     ((and install? (eq? (command-selected-compile-mode cmd) 'fresh-auto))
      'normal)
     ((and (not install?) (eq? (command-selected-compile-mode cmd) 'fresh-auto))
      'fresh-auto)
     ((implementation-compiler-available? mode-id) 'compiled)
     (install? 'normal)
     (else 'fresh-auto))))

(define (command-compiled-output-dirs manifest features cmd . maybe-install?)
  (if (eq? (apply command-runtime-compile-mode manifest features cmd maybe-install?) 'compiled)
      (list (compiled-output-dir manifest features cmd))
      '()))

(define (adapter-command-for-cmd manifest cmd scheme src script rest . maybe-install?)
  (let* ((features (active-features manifest cmd))
         (mode (apply command-runtime-compile-mode manifest features cmd maybe-install?))
         (compiled-roots (apply command-compiled-output-dirs manifest features cmd maybe-install?))
         (command (adapter-command scheme src script rest mode compiled-roots (command-selected-profile cmd))))
    (command-with-runtime-build-env manifest features cmd command)))

(define (adapter-repl-command-for-cmd manifest cmd scheme src . maybe-install?)
  (let ((mode (apply command-runtime-compile-mode manifest (active-features manifest cmd) cmd maybe-install?))
        (compiled-roots (apply command-compiled-output-dirs manifest (active-features manifest cmd) cmd maybe-install?)))
    (adapter-repl-command scheme src mode compiled-roots (command-selected-profile cmd))))

(define (launcher-command-for-cmd manifest cmd scheme src script . maybe-compiled-roots)
  (let* ((features (active-features manifest cmd))
         (compiled-roots (if (pair? maybe-compiled-roots)
                             (car maybe-compiled-roots)
                             (command-compiled-output-dirs manifest features cmd #t)))
         (mode (if (null? compiled-roots) 'normal 'compiled)))
    (launcher-command scheme src script mode compiled-roots (command-selected-profile cmd))))

(define (ensure-implementation-compiled! manifest features cmd)
  (let ((mode (command-runtime-compile-mode manifest features cmd)))
    (cond
     ((eq? mode 'compiled)
      (compile-implementation-libraries manifest features cmd))
     ((and (eq? mode 'fresh-auto)
           (eq? (command-selected-compile-mode cmd) 'compiled)
           (has-compiled-artifacts? manifest cmd))
      (log-info "compiler not found; using fresh auto compile"
                (command-selected-scheme cmd))
      '())
     (else '()))))

  ))
