(define-library (kons runner)
  (export adapter-command
    adapter-repl-command
    command-env
    command-argv
    command->shell
    run-command-record
    scheme-command
    launcher-command
    dependency-source-roots
    activation-source-roots
    locked-activation-source-roots
    locked-entry-source-root
    effective-activation-source-roots
    prepare-akku-activation-root!
    locked-entry-in-scope?
    lock-missing-materializations
    missing-materialization-details
    lock-materialized?
    materializable-dependency?
    materialize-local-sources
    materialize-lock-sources
    check-system-dependencies
    run-script
    collect-scheme-files
    collect-test-files
    command-adapter-scheme
    adapter-scheme)
  (import (scheme base)
    (scheme cxr)
    (scheme file)
    (scheme process-context)
    (scheme write)
    (kons compat files)
    (kons util)
    (kons names)
    (kons implementation)
    (kons manifest)
    (kons features)
    (kons options)
    (kons lock)
    (kons registry)
    (kons jobs)
    (kons ui)
    (kons dep store)
    (kons dep git)
    (kons dep path)
    (kons dep registry)
    (kons dep akku)
    (kons dep snow)
    (kons dep workspace)
    (kons actions paths))

  (begin
    (define (adapter-scheme manifest scheme . maybe-dialect)
      (let* ((declared-dialects (package-dialects manifest))
             (requested-dialect (and (pair? maybe-dialect) (car maybe-dialect)))
             (dialects (if requested-dialect (list requested-dialect) declared-dialects))
             (mode (implementation-mode-for-dialects scheme dialects)))
        (cond
          (mode (implementation-mode-id mode))
          ((and requested-dialect (not (memq requested-dialect declared-dialects)))
            (manifest-error "selected dialect is not declared by package"
              (package-name manifest)
              requested-dialect
              declared-dialects))
          (requested-dialect
            (manifest-error "selected scheme does not support selected dialect"
              scheme
              requested-dialect))
          ((and (memq 'r7rs declared-dialects)
             (implementation-mode-for-dialects scheme '(r6rs)))
            (implementation-mode-id
              (implementation-mode-for-dialects scheme '(r6rs))))
          (else
            (manifest-error "unsupported dialect for selected implementation"
              (package-name manifest)
              declared-dialects
              scheme)))))

    (define (command-adapter-scheme manifest cmd)
      (if (command-option cmd "dialect" #f)
        (adapter-scheme
          manifest
          (command-selected-scheme cmd)
          (command-selected-dialect manifest cmd))
        (adapter-scheme manifest (command-selected-scheme cmd))))

    (define (compile-mode-arg maybe index default)
      (let loop ((items maybe) (n index))
        (cond
          ((null? items) default)
          ((= n 0) (car items))
          (else (loop (cdr items) (- n 1))))))

    (define (adapter-command scheme src script rest . maybe-compile)
      (let ((mode (compile-mode-arg maybe-compile 0 'normal))
            (compiled-roots (compile-mode-arg maybe-compile 1 '()))
            (profile (compile-mode-arg maybe-compile 2 'release)))
        (implementation-command-record scheme src script rest mode compiled-roots profile)))

    (define (adapter-repl-command scheme src . maybe-compile)
      (let ((mode (compile-mode-arg maybe-compile 0 'normal))
            (compiled-roots (compile-mode-arg maybe-compile 1 '()))
            (profile (compile-mode-arg maybe-compile 2 'release)))
        (implementation-repl-command-record scheme src mode compiled-roots profile)))

    (define (command-env command)
      (let ((field (assq 'env (cdr command))))
        (if field (cdr field) '())))

    (define (command-argv command)
      (let ((field (assq 'argv (cdr command))))
        (if field (cdr field) '())))

    (define (shell-join xs)
      (string-join (map shell-quote xs) " "))

    (define (command-env->shell env)
      (string-join
        (map (lambda (entry)
              (string-append (car entry) "=" (shell-quote (cadr entry))))
          env)
        " "))

    (define (command->shell command)
      (let ((env (command-env command))
            (argv (command-argv command)))
        (string-append
          (if (null? env) "" (string-append (command-env->shell env) " "))
          (shell-join argv))))

    (define (run-command-record command)
      (run-command (command->shell command)))

    (define (scheme-command scheme src script rest)
      (command->shell (adapter-command scheme src script rest)))

    (define (launcher-command scheme src script . maybe-compile)
      (let* ((mode (compile-mode-arg maybe-compile 0 'normal))
             (compiled-roots (compile-mode-arg maybe-compile 1 '()))
             (profile (compile-mode-arg maybe-compile 2 'release))
             (command (adapter-command scheme src script '() mode compiled-roots profile))
             (env (command-env command))
             (argv (command-argv command)))
        (string-append
          (if (null? env)
            ""
            (string-append (command-env->shell env) " "))
          "exec "
          (shell-join argv)
          " \"$@\"")))

    (define (source-root-from-package-root package-root)
      (let ((manifest-path (path-join package-root "kons.scm")))
        (if (file-exists? manifest-path)
          (let ((package-manifest (parse-manifest manifest-path)))
            (path-join package-root (package-source-path package-manifest)))
          package-root)))

    (define (lock-entry-rest entry key)
      (let ((field (and (pair? entry) (assq key (cdr entry)))))
        (if field (cdr field) '())))

    (define (path-component-unsafe? item)
      (or (string=? item "")
        (string=? item ".")
        (string=? item "..")))

    (define (safe-relative-path? path)
      (and (string? path)
        (not (string=? path ""))
        (not (absolute-path? path))
        (let loop ((items (string-split path #\/)))
          (or (null? items)
            (and (not (path-component-unsafe? (car items)))
              (loop (cdr items)))))))

    (define (scheme-library-file? path)
      (or (string-suffix? ".sld" path)
        (string-suffix? ".sls" path)
        (string-suffix? ".scm" path)))

    (define (hidden-path-entry? entry)
      (and (> (string-length entry) 0)
        (char=? (string-ref entry 0) #\.)))

    (define (directory-has-scheme-library? dir)
      (and (file-exists? dir)
        (file-directory? dir)
        (let scan-dir ((current dir))
          (let loop ((entries (directory-list current)))
            (cond
              ((null? entries) #f)
              (else
                (let ((path (path-join current (car entries))))
                  (cond
                    ((and (file-directory? path)
                        (not (hidden-path-entry? (car entries))))
                      (or (scan-dir path) (loop (cdr entries))))
                    ((and (file-exists? path)
                        (scheme-library-file? path))
                      #t)
                    (else (loop (cdr entries)))))))))))

    (define (locked-akku-load-path-roots entry root)
      (let loop ((items (lock-entry-rest entry 'load-paths)) (out '()))
        (cond
          ((null? items) (reverse out))
          ((safe-relative-path? (car items))
            (loop (cdr items) (cons (path-join root (car items)) out)))
          (else
            (dependency-error "unsafe Akku load path in lockfile"
              (lock-entry-ref entry 'name '())
              (car items))))))

    (define (existing-common-akku-source-roots root)
      (let loop ((items '("src" "lib" "source")) (out '()))
        (cond
          ((null? items) (reverse out))
          (else
            (let ((candidate (path-join root (car items))))
              (if (directory-has-scheme-library? candidate)
                (loop (cdr items) (cons candidate out))
                (loop (cdr items) out)))))))

    (define (discovered-akku-source-roots root)
      (let ((common (existing-common-akku-source-roots root)))
        (cond
          ((not (null? common)) common)
          ((directory-has-scheme-library? root) (list root))
          (else (list root)))))

    (define (locked-akku-entry-source-roots entry root)
      (let ((load-paths (locked-akku-load-path-roots entry root)))
        (cond
          ((not (null? load-paths)) load-paths)
          ((file-exists? (path-join root "kons.scm"))
            (list (source-root-from-package-root root)))
          (else (discovered-akku-source-roots root)))))

    (define-record-type <missing-materialization>
      (make-missing-materialization entry root reason archive)
      missing-materialization?
      (entry missing-materialization-entry)
      (root missing-materialization-root)
      (reason missing-materialization-reason)
      (archive missing-materialization-archive))

    (define (locked-entry-expected-root entry . maybe-manifest)
      (case (lock-entry-type entry)
        ((path) (locked-path-entry-root entry))
        ((workspace) (locked-workspace-entry-root entry))
        ((git) (locked-git-entry-root entry))
        ((registry) (apply locked-registry-entry-root entry maybe-manifest))
        ((akku) (locked-akku-entry-root entry))
        ((snow) (locked-snow-entry-root entry))
        (else #f)))

    (define (locked-entry-source-root entry . maybe-manifest)
      (let ((root (apply locked-entry-expected-root entry maybe-manifest)))
        (if root
          (begin
            (unless (file-exists? root)
              (dependency-error "locked dependency is not materialized; run `kons fetch` first"
                (lock-entry-ref entry 'name '())))
            (let ((package-root (subpath-package-root root (lock-entry-ref entry 'subpath #f))))
              (if (eq? (lock-entry-type entry) 'akku)
                (car (locked-akku-entry-source-roots entry package-root))
                (source-root-from-package-root package-root))))
          #f)))

    (define (locked-entry-source-roots entry . maybe-manifest)
      (let ((root (apply locked-entry-expected-root entry maybe-manifest)))
        (if root
          (begin
            (unless (file-exists? root)
              (dependency-error "locked dependency is not materialized; run `kons fetch` first"
                (lock-entry-ref entry 'name '())))
            (let ((package-root (subpath-package-root root (lock-entry-ref entry 'subpath #f))))
              (if (eq? (lock-entry-type entry) 'akku)
                (locked-akku-entry-source-roots entry package-root)
                (list (source-root-from-package-root package-root)))))
          '())))

    (define (locked-entry-materialized? entry . maybe-manifest)
      (let ((root (apply locked-entry-expected-root entry maybe-manifest)))
        (case (lock-entry-type entry)
          ((git) (and root (git-checkout-ready? root (lock-entry-ref entry 'commit ""))))
          ((akku) (akku-source-ready? entry))
          ((snow) (snow-source-ready? entry))
          (else
            (or (not root)
              (file-exists? root))))))

    (define (registry-entry-archive-path entry)
      (registry-archive-path
        (lock-entry-ref entry 'registry default-registry-alias)
        (name->string (lock-entry-ref entry 'name '()))
        (lock-entry-ref entry 'version "")
        (lock-entry-ref entry 'checksum "")))

    (define (locked-entry-missing-materialization entry . maybe-manifest)
      (let ((root (apply locked-entry-expected-root entry maybe-manifest)))
        (cond
          ((not root) #f)
          ((and (eq? (lock-entry-type entry) 'git)
              (not (git-checkout-ready? root (lock-entry-ref entry 'commit ""))))
            (make-missing-materialization entry root 'git-checkout-not-ready #f))
          ((and (eq? (lock-entry-type entry) 'akku)
              (not (akku-source-ready? entry)))
            (make-missing-materialization entry root 'akku-source-not-ready #f))
          ((and (eq? (lock-entry-type entry) 'snow)
              (not (snow-source-ready? entry)))
            (make-missing-materialization entry root 'snow-source-not-ready #f))
          ((not (file-exists? root))
            (make-missing-materialization
              entry
              root
              'missing-root
              (if (eq? (lock-entry-type entry) 'registry)
                (registry-entry-archive-path entry)
                #f)))
          (else #f))))

    (define (lock-missing-materializations lock include-dev? . maybe-manifest)
      (let loop ((entries (lock-package-entries lock)) (out '()))
        (cond
          ((null? entries) (reverse out))
          ((not (locked-entry-in-scope? (car entries) include-dev?))
            (loop (cdr entries) out))
          ((apply locked-entry-missing-materialization (car entries) maybe-manifest)
            =>
            (lambda (missing)
              (loop (cdr entries) (cons missing out))))
          (else (loop (cdr entries) out)))))

    (define (missing-materialization-details missing)
      (let* ((entry (missing-materialization-entry missing))
             (archive (missing-materialization-archive missing)))
        `((reason . missing-materialization)
          (type . ,(lock-entry-type entry))
          (name . ,(value-token (lock-entry-ref entry 'name '())))
          (scope . ,(lock-entry-ref entry 'scope 'runtime))
          (root . ,(missing-materialization-root missing))
          (cause . ,(missing-materialization-reason missing))
          ,@(if archive `((archive . ,archive)) '()))))

    (define (locked-entry-in-scope? entry include-dev?)
      (let ((scope (lock-entry-ref entry 'scope 'runtime)))
        (or include-dev? (not (eq? scope 'dev)))))

    (define (lock-materialized? lock include-dev? . maybe-manifest)
      (let loop ((entries (lock-package-entries lock)))
        (cond
          ((null? entries) #t)
          ((not (locked-entry-in-scope? (car entries) include-dev?))
            (loop (cdr entries)))
          ((apply locked-entry-materialized? (car entries) maybe-manifest)
            (loop (cdr entries)))
          (else #f))))

    (define (locked-dependency-source-roots lock include-dev? . maybe-manifest)
      (let loop ((entries (lock-package-entries lock)) (out '()))
        (cond
          ((null? entries) (reverse out))
          ((not (locked-entry-in-scope? (car entries) include-dev?))
            (loop (cdr entries) out))
          (else
            (let ((roots (apply locked-entry-source-roots (car entries) maybe-manifest)))
              (loop (cdr entries) (append (reverse roots) out)))))))

    (define (project-config-path manifest)
      (path-join (manifest-root manifest) ".kons/config.scm"))

    (define (scheme-load-path-form scheme)
      (string->symbol
        (string-append (symbol->string scheme) "-load-paths")))

    (define (config-load-path-form? form scheme)
      (and (pair? form)
        (symbol? (car form))
        (or (eq? (car form) 'load-paths)
          (eq? (car form) (scheme-load-path-form scheme)))))

    (define (config-load-path manifest path)
      (if (absolute-path? path)
        path
        (path-join (manifest-root manifest) path)))

    (define (config-form-load-paths manifest config-path form)
      (for-each
        (lambda (path)
          (unless (string? path)
            (manifest-error "config load paths must be strings" config-path form)))
        (cdr form))
      (map (lambda (path) (config-load-path manifest path)) (cdr form)))

    (define (project-config-load-paths manifest scheme)
      (let ((config-path (project-config-path manifest)))
        (if (file-exists? config-path)
          (let loop ((forms (read-all-exprs config-path)) (out '()))
            (cond
              ((null? forms) (reverse out))
              ((config-load-path-form? (car forms) scheme)
                (loop (cdr forms)
                  (append (reverse (config-form-load-paths manifest config-path (car forms)))
                    out)))
              ((and (pair? (car forms)) (symbol? (caar forms)))
                (manifest-error "unknown project config form" config-path (caar forms)))
              (else
                (manifest-error "expected project config form" config-path (car forms)))))
          '())))

    (define (with-project-config-load-paths manifest cmd srcs)
      (append srcs
        (project-config-load-paths manifest (command-selected-scheme cmd))))

    (define (dependency-source-roots manifest include-dev? features cmd)
      (let ((root (manifest-root manifest)))
        (let loop ((deps (all-dependencies-for manifest include-dev? features cmd)) (out '()))
          (cond
            ((null? deps) (reverse out))
            ((eq? (alist-ref (car deps) 'type #f) 'path)
              (loop (cdr deps) (cons (path-dependency-source-root root (car deps)) out)))
            ((eq? (alist-ref (car deps) 'type #f) 'workspace)
              (loop (cdr deps) (cons (workspace-dependency-source-root root (car deps)) out)))
            ((eq? (alist-ref (car deps) 'type #f) 'git)
              (loop (cdr deps) (cons (git-dependency-source-root root (car deps)) out)))
            ((eq? (alist-ref (car deps) 'type #f) 'registry)
              (loop (cdr deps)
                (cons (registry-dependency-source-root (car deps)) out)))
            (else (loop (cdr deps) out))))))

    (define (activation-source-roots manifest include-dev? features cmd)
      (with-project-config-load-paths
        manifest
        cmd
        (cons (manifest-source-root manifest)
          (dependency-source-roots manifest include-dev? features cmd))))

    (define (akku-lock-entry? entry)
      (eq? (lock-entry-type entry) 'akku))

    (define (akku-lock-entries lock include-dev?)
      (filter
        (lambda (entry)
          (and (akku-lock-entry? entry)
            (locked-entry-in-scope? entry include-dev?)))
        (lock-package-entries lock)))

    (define (activation-akku-installed-root manifest)
      (project-kons-path manifest (path-join "akku" "installed")))

    (define (locked-activation-source-roots manifest lock include-dev?)
      (let ((dependencies (locked-dependency-source-roots lock include-dev? manifest)))
        (cons (manifest-source-root manifest)
          (if (null? (akku-lock-entries lock include-dev?))
            dependencies
            (cons (activation-akku-installed-root manifest) dependencies)))))

    (define (prepare-akku-activation-root! manifest lock include-dev? scheme)
      (let ((entries (akku-lock-entries lock include-dev?)))
        (if (null? entries)
          '()
          (prepare-akku-installed-root!
            (activation-akku-installed-root manifest)
            entries
            scheme))))

    (define (workspace-shared-lock? cmd)
      (and (command-option cmd "workspace-root" #f) #t))

    (define (lock-root-identity-matches-activation? manifest cmd lock)
      (or (workspace-shared-lock? cmd)
        (and (equal? (lock-root-name lock) (package-name manifest))
          (equal? (lock-root-version lock) (package-version manifest)))))

    (define (lock-matches-activation? manifest features include-dev? cmd lock)
      (and (lock-root-identity-matches-activation? manifest cmd lock)
        (equal? (lock-root-features lock) features)
        (or (command-flag? cmd "offline")
          (command-flag? cmd "frozen")
          (workspace-shared-lock? cmd)
          (lock-resolution-equivalent? lock (make-lock manifest features cmd include-dev? lock))
          (and (not include-dev?)
            (lock-resolution-equivalent? lock (make-lock manifest features cmd #t lock))))))

    (define (lock-section lock name)
      (let ((section (and (pair? lock) (assq name (cdr lock)))))
        (if section (cdr section) '())))

    (define (lock-resolution-equivalent? old-lock new-lock)
      (and (equal? (lock-package-entries old-lock)
            (lock-package-entries new-lock))
        (equal? (lock-section old-lock 'edges)
          (lock-section new-lock 'edges))
        (equal? (lock-section old-lock 'overrides)
          (lock-section new-lock 'overrides))))

    (define (activation-lock-path manifest cmd)
      (command-lock-path manifest cmd))

    (define (matching-activation-lock manifest features include-dev? cmd)
      (let ((path (activation-lock-path manifest cmd)))
        (and (file-exists? path)
          (let ((lock (read-lockfile path)))
            (and (lock-matches-activation? manifest features include-dev? cmd lock)
              lock)))))

    (define (activation-lock-or-live manifest features include-dev? cmd)
      (let ((lock (matching-activation-lock manifest features include-dev? cmd)))
        (cond
          ((and lock (lock-materialized? lock include-dev? manifest)) lock)
          ((and lock (command-locked-mode? cmd))
            (dependency-error "locked dependency is not materialized; run `kons fetch` first"
              (package-name manifest)))
          (lock #f)
          ((command-locked-mode? cmd)
            (if (file-exists? (activation-lock-path manifest cmd))
              (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`")
              (lockfile-error "kons.lock missing; run `kons update` first")))
          (else #f))))

    (define (effective-activation-source-roots manifest include-dev? features cmd)
      (let ((lock (activation-lock-or-live manifest features include-dev? cmd)))
        (if lock
          (with-project-config-load-paths
            manifest
            cmd
            (locked-activation-source-roots manifest lock include-dev?))
          (activation-source-roots manifest include-dev? features cmd))))

    (define (value-token value)
      (cond
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        ((number? value) (number->string value))
        ((null? value) "")
        ((pair? value)
          (let loop ((items value) (out ""))
            (cond
              ((null? items) out)
              ((string=? out "") (loop (cdr items) (value-token (car items))))
              (else (loop (cdr items) (string-append out "-" (value-token (car items))))))))
        (else "value")))

    (define (scheme-library-name? name)
      (or (symbol? name)
        (and (pair? name)
          (let loop ((items name))
            (or (null? items)
              (and (symbol? (car items))
                (loop (cdr items))))))))

    (define (library-name-form name)
      (if (symbol? name) (list name) name))

    (define (live-system-dependency-names manifest include-dev? features cmd)
      (append-map
        (lambda (dep)
          (if (eq? (alist-ref dep 'type #f) 'system)
            (alist-ref dep 'names '())
            '()))
        (all-dependencies-for manifest include-dev? features cmd)))

    (define (locked-system-entry-names lock include-dev?)
      (append-map
        (lambda (entry)
          (if (and (pair? entry)
               (eq? (car entry) 'system)
               (locked-entry-in-scope? entry include-dev?))
            (let ((names-form (assq 'names (cdr entry))))
              (if names-form (cdr names-form) '()))
            '()))
        (lock-package-entries lock)))

    (define (effective-system-dependency-names manifest include-dev? features cmd)
      (let ((lock (activation-lock-or-live manifest features include-dev? cmd)))
        (if lock
          (locked-system-entry-names lock include-dev?)
          (live-system-dependency-names manifest include-dev? features cmd))))

    (define (write-system-check-script path scheme library-name)
      (call-with-output-file path
        (lambda (out)
          (let* ((mode (implementation-mode scheme))
                 (standard (and mode (implementation-mode-field mode 'standard #f)))
                 (base-import (if (eq? standard 'r6rs) '(rnrs) '(scheme base)))
                 (checked-import (library-name-form library-name)))
            (write `(import ,base-import
                     ,@(if (equal? base-import checked-import)
                        '()
                        (list checked-import)))
              out))
          (newline out)
          (write '(define kons-system-check #t) out)
          (newline out))))

    (define (check-system-library scheme srcs library-name)
      (let* ((script (temporary-file-path
                      (string-append
                        "kons-system-check-"
                        (symbol->string scheme)
                        "-"
                        (safe-store-token (value-token library-name))
                        ".scm")))
             (cmd #f)
             (status #f))
        (write-system-check-script script scheme library-name)
        (set! cmd (scheme-command scheme srcs script '()))
        (set! status (shell-command-status (string-append cmd " >/dev/null 2>/dev/null")))
        (when (file-exists? script)
          (delete-file script))
        (unless (= status 0)
          (dependency-error "system Scheme library is not available for selected implementation"
            library-name
            scheme))))

    (define (check-system-dependencies manifest cmd include-dev? features srcs)
      (let ((scheme (command-adapter-scheme manifest cmd))
            (available-srcs (filter file-exists? srcs)))
        (ui-status "checking system dependencies")
        (for-each
          (lambda (name)
            (when (scheme-library-name? name)
              (check-system-library scheme available-srcs name)))
          (effective-system-dependency-names manifest include-dev? features cmd))
        (ui-status-done "checked system dependencies")))

    (define (dependency-progress-label dep)
      (let ((type (alist-ref dep 'type #f)))
        (string-append
          (if type (symbol->string type) "dependency")
          " "
          (cond
            ((alist-ref dep 'name #f) (name->string (alist-ref dep 'name '())))
            ((alist-ref dep 'names #f) (string-join (map symbol->string (alist-ref dep 'names '())) " "))
            (else "")))))

    (define (materializable-dependency? dep)
      (memq (alist-ref dep 'type #f) '(path git registry)))

    (define (runner-job-event-field event key default)
      (let loop ((items (cdr event)))
        (cond
          ((null? items) default)
          ((and (pair? (car items))
              (eq? (caar items) key)
              (pair? (cdar items)))
            (cadar items))
          (else (loop (cdr items))))))

    (define (make-materialize-job-event-handler total)
      (let ((done 0)
            (active '()))
        (lambda (event)
          (let* ((status (runner-job-event-field event 'status #f))
                 (label (runner-job-event-field event 'label #f))
                 (metadata (runner-job-event-field event 'metadata '()))
                 (done-label (alist-ref metadata 'done-label label))
                 (entry-name (and label (let ((parts (string-split label #\space)))
                                         (if (> (length parts) 1)
                                           (string-join (cdr parts) " ")
                                           #f)))))
            (when (and label (alist-ref metadata 'ui #f))
              (case status
                ((started)
                  (when entry-name
                    (set! active (cons entry-name active)))
                  (ui-progress "Materializing" done total (active-materialize-message active)))
                ((done planned)
                  (when entry-name
                    (set! active (remove-string entry-name active)))
                  (set! done (+ done 1))
                  (ui-display-status "Materialized" 'green entry-name)
                  (if (= done total)
                    (ui-display-status
                      "Finished"
                      'bold
                      (string-append "materialized "
                        (number->string total)
                        " dependencies"))
                    (when (not (null? active))
                      (ui-progress "Materializing" done total (active-materialize-message active)))))
                ((failed)
                  (ui-status-fail "Failed" entry-name))
                (else #f)))))))

    (define (active-materialize-message active)
      (if (null? active)
        #f
        (let loop ((items (reverse active)) (count 0) (shown '()))
          (cond
            ((null? items) (string-join (reverse shown) ", "))
            ((>= count 4) (string-join (reverse (cons "..." shown)) ", "))
            (else (loop (cdr items) (+ count 1) (cons (car items) shown)))))))

    (define (materialize-job-event-handler event)
      (let* ((status (runner-job-event-field event 'status #f))
             (label (runner-job-event-field event 'label #f))
             (metadata (runner-job-event-field event 'metadata '()))
             (done-label (alist-ref metadata 'done-label label)))
        (when (and label (alist-ref metadata 'ui #f))
          (case status
            ((started) (ui-status label))
            ((done planned) (ui-status-done done-label))
            ((failed) (ui-status-fail label))
            (else #f)))))

    (define (job-results-values results)
      (map job-result-value results))

    (define (remove-string item items)
      (let loop ((xs items) (out '()) (removed? #f))
        (cond
          ((null? xs) (reverse out))
          ((and (not removed?) (string=? item (car xs)))
            (loop (cdr xs) out #t))
          (else (loop (cdr xs) (cons (car xs) out) removed?)))))

    (define (materialize-runner-options cmd total)
      (make-job-runner-options
        (if cmd (command-job-count cmd) 1)
        #f
        #t
        #f
        (make-materialize-job-event-handler total)))

    (define (dependency-resource dep)
      `(dependency
        ,(alist-ref dep 'type #f)
        ,(alist-ref dep 'name (alist-ref dep 'names '()))
        ,(alist-ref dep 'path (alist-ref dep 'url (alist-ref dep 'ref "")))))

    (define (dependency-resources dep)
      (let ((type (alist-ref dep 'type #f)))
        (append
          (list (dependency-resource dep))
          (case type
            ((git) `((git-cache ,(alist-ref dep 'url ""))))
            ((registry) `((registry-cache ,(alist-ref dep 'registry default-registry-alias))))
            (else '())))))

    (define (lock-entry-resource entry)
      `(locked-dependency
        ,(lock-entry-type entry)
        ,(lock-entry-ref entry 'name (lock-entry-ref entry 'names '()))
        ,(lock-entry-ref entry 'path (lock-entry-ref entry 'url (lock-entry-ref entry 'ref "")))))

    (define (lock-entry-resources entry)
      (let ((type (lock-entry-type entry)))
        (append
          (list (lock-entry-resource entry))
          (case type
            ((git) `((git-cache ,(lock-entry-ref entry 'url ""))))
            ((registry) `((registry-cache ,(lock-entry-ref entry 'registry default-registry-alias))))
            (else '())))))

    (define (lock-entry-progress-label entry)
      (let ((type (lock-entry-type entry)))
        (string-append
          (if type (symbol->string type) "dependency")
          " "
          (cond
            ((lock-entry-ref entry 'name #f) (value-token (lock-entry-ref entry 'name '())))
            ((lock-entry-ref entry 'names #f) (string-join (map symbol->string (lock-entry-ref entry 'names '())) " "))
            (else "")))))

    (define (materialize-local-job manifest offline? index dep)
      (let* ((type (alist-ref dep 'type #f))
             (label (string-append "materializing " (dependency-progress-label dep)))
             (done-label (string-append "materialized " (dependency-progress-label dep))))
        (make-job
          `(materialize ,index)
          'dependency
          label
          '()
          `((ui . #t)
            (done-label . ,done-label)
            (dependency ,dep))
          (dependency-resources dep)
          #t
          (lambda ()
            (case type
              ((path) (materialize-path-dependency manifest dep))
              ((git) (materialize-git-dependency manifest dep offline?))
              ((registry) (materialize-registry-dependency manifest dep offline?))
              (else (dependency-error "unsupported materializable dependency" type)))))))

    (define (materialize-local-sources manifest features include-dev? offline? cmd)
      (let ((deps (filter materializable-dependency?
                   (all-dependencies-for manifest include-dev? features cmd))))
        (if (null? deps)
          '()
          (let ((total (length deps)))
            (let loop ((items deps) (index 0) (jobs '()) (roots '()))
              (if (null? items)
                (job-results-values
                  (run-job-graph!
                    (make-job-graph (reverse jobs) (reverse roots))
                    (materialize-runner-options cmd total)))
                (let ((job (materialize-local-job manifest offline? index (car items))))
                  (loop (cdr items)
                    (+ index 1)
                    (cons job jobs)
                    (cons (job-id job) roots)))))))))

    (define (materialize-lock-job manifest offline? index entry)
      (let* ((type (lock-entry-type entry))
             (label (string-append "materializing " (lock-entry-progress-label entry)))
             (done-label (string-append "materialized " (lock-entry-progress-label entry))))
        (make-job
          `(materialize-lock ,index)
          'dependency
          label
          '()
          `((ui . #t)
            (done-label . ,done-label)
            (lock-entry ,entry))
          (lock-entry-resources entry)
          #t
          (lambda ()
            (case type
              ((path) (materialize-locked-path-entry manifest entry))
              ((git) (materialize-locked-git-entry manifest entry offline?))
              ((registry) (materialize-locked-registry-entry manifest entry offline?))
              ((akku) (materialize-locked-akku-entry manifest entry offline?))
              ((snow) (materialize-locked-snow-entry manifest entry offline?))
              (else (dependency-error "unsupported materializable locked dependency" type)))))))

    (define (materialize-lock-sources manifest lock include-dev? offline? . maybe-cmd)
      (let ((entries (filter (lambda (entry)
                              (and (locked-entry-in-scope? entry include-dev?)
                                (memq (lock-entry-type entry) '(path git registry akku snow))))
                      (lock-package-entries lock)))
            (cmd (and (pair? maybe-cmd) (car maybe-cmd))))
        (if (null? entries)
          '()
          (let ((total (length entries)))
            (let loop ((items entries) (index 0) (jobs '()) (roots '()))
              (if (null? items)
                (job-results-values
                  (run-job-graph!
                    (make-job-graph (reverse jobs) (reverse roots))
                    (materialize-runner-options cmd total)))
                (let ((job (materialize-lock-job manifest offline? index (car items))))
                  (loop (cdr items)
                    (+ index 1)
                    (cons job jobs)
                    (cons (job-id job) roots)))))))))

    (define (run-script manifest cmd script include-dev? rest)
      (let* ((adapted-scheme (command-adapter-scheme manifest cmd))
             (features (active-features manifest cmd))
             (srcs (effective-activation-source-roots manifest include-dev? features cmd))
             (command (adapter-command adapted-scheme srcs script rest 'normal '() (command-selected-profile cmd))))
        (check-system-dependencies manifest cmd include-dev? features srcs)
        (when include-dev?
          (log-info "dev dependencies are available when materialized"))
        (log-debug "command" (command->shell command))
        (log-debug "argv" (command-argv command))
        (run-command-record command)))

    (define (collect-scheme-files dir label)
      (define (directory? path)
        (= (shell-command-status
            (string-append "test -d " (shell-quote path) " >/dev/null 2>/dev/null"))
          0))
      (define (scheme-test-file? path)
        (or (string-suffix? ".scm" path)
          (string-suffix? ".sps" path)
          (string-suffix? ".sld" path)
          (string-suffix? ".sls" path)))
      (define (hidden-entry? entry)
        (and (> (string-length entry) 0)
          (char=? (string-ref entry 0) #\.)))
      (define (collect-dir dir out)
        (let loop ((entries (directory-list dir)) (out out))
          (cond
            ((null? entries) out)
            (else
              (let ((path (path-join dir (car entries))))
                (cond
                  ((and (file-directory? path)
                      (not (hidden-entry? (car entries))))
                    (loop (cdr entries) (collect-dir path out)))
                  ((and (file-exists? path)
                      (scheme-test-file? path))
                    (loop (cdr entries) (cons path out)))
                  (else (loop (cdr entries) out))))))))
      (cond
        ((not (file-exists? dir))
          (usage-error (string-append label " directory not found") dir))
        ((not (file-directory? dir))
          (usage-error (string-append label " path is not a directory") dir))
        (else
          (reverse (collect-dir dir '())))))

    (define (collect-test-files tests-dir)
      (collect-scheme-files tests-dir "tests"))))
