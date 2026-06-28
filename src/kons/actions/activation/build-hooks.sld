(define-library (kons actions activation build-hooks)
  (export build-output-files
    build-hook-output-records
    output-directive-paths
    build-hook-output-directives
    build-hook-output-load-paths
    dependency-build-output-load-paths
    command-with-runtime-build-env
    build-record
    build-hook-script
    build-hook-watch-paths
    directive-name
    directive-args
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
    feature-library-name
    feature-helper-library-name
    artifact-helper-library-name
    write-feature-libraries!
    run-build-hooks-if-needed!
    dependency-build-hook-source-roots
    run-dependency-build-hooks-for-source-root!
    run-dependency-build-hooks-if-needed!)
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
    (kons commands framework)
    (kons actions activation core)
    (kons actions activation generated)
    (kons actions activation translate))

  (begin
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

    (define (path-last-segment path)
      (let loop ((parts (string-split path #\/)) (last ""))
        (cond
          ((null? parts) last)
          ((string=? (car parts) "") (loop (cdr parts) last))
          (else (loop (cdr parts) (car parts))))))

    (define (build-hook-script-token script)
      (string-append
        (safe-store-token (path-last-segment script))
        "-"
        (safe-store-token (file-content-hash script))))

    (define (build-hook-marker-path build-root script)
      (path-join (build-hook-marker-dir build-root)
        (string-append (build-hook-script-token script) ".scm")))

    (define (build-hook-directives-path build-root script)
      (path-join (build-hook-marker-dir build-root)
        (string-append (build-hook-script-token script) ".directives.scm")))

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

    (define (entry-default-output-path build-root entry)
      (case (car entry)
        ((r7rs) (library-source-path build-root (cadr entry)))
        ((r6rs) (r6rs-library-output-path build-root (cadr entry)))
        ((guile) (module-source-path build-root (cadr entry)))
        ((gauche) (gauche-module-source-path build-root (cadr entry)))
        (else #f)))

    (define (entry-default-source-path source-root entry)
      (case (car entry)
        ((r7rs) (library-source-path source-root (cadr entry)))
        ((r6rs) (r6rs-library-source-path source-root (cadr entry)))
        ((guile) (module-source-path source-root (cadr entry)))
        ((gauche) (gauche-module-source-path source-root (cadr entry)))
        (else #f)))

    (define (library-form-matches-entry? expr entry)
      (and (pair? expr)
        (pair? (cdr expr))
        (case (car entry)
          ((r7rs)
            (and (eq? (car expr) 'define-library)
              (equal? (cadr expr) (cadr entry))))
          ((r6rs)
            (and (eq? (car expr) 'library)
              (equal? (cadr expr) (cadr entry))))
          ((guile)
            (and (eq? (car expr) 'define-module)
              (equal? (cadr expr) (cadr entry))))
          ((gauche)
            (and (eq? (car expr) 'define-module)
              (equal? (cadr expr) (cadr entry))))
          (else #f))))

    (define (library-entry-source-form entry)
      (let ((source (library-entry-path "" entry)))
        (and source
          (file-exists? source)
          (let loop ((exprs (read-all-exprs source)))
            (cond
              ((null? exprs) #f)
              ((library-form-matches-entry? (car exprs) entry) (car exprs))
              (else (loop (cdr exprs))))))))

    (define (materialized-library-needed? source-root entry output)
      (let ((source (library-entry-path source-root entry))
            (default-source (entry-default-source-path source-root entry)))
        (and output
          source
          (file-exists? source)
          (or (library-entry-explicit-property entry 'implementation)
            (library-entry-explicit-property entry 'dialect)
            (not default-source)
            (not (same-path? source default-source))))))

    (define (library-entry-explicit-property entry key)
      (let ((found (and (pair? (cdr entry))
                    (pair? (cddr entry))
                    (assq key (cddr entry)))))
        (and found (cadr found))))

    (define (write-materialized-library-entry! source-root build-root entry)
      (let ((output (entry-default-output-path build-root entry)))
        (when (materialized-library-needed? source-root entry output)
          (let ((form (library-entry-source-form entry)))
            (unless form
              (manifest-error "library source form not found for materialization"
                (cadr entry)
                (library-entry-path source-root entry)))
            (write-library-expr! output form)))))

    (define (write-materialized-libraries! manifest features cmd build-root)
      (let* ((source-root (manifest-source-root manifest))
             (mode (implementation-mode (adapter-scheme manifest (command-selected-scheme cmd))))
             (context (make-library-discovery-context
                       (if mode
                         (implementation-mode-features mode)
                         (list (adapter-scheme manifest (command-selected-scheme cmd))))
                       (lambda (name) #t))))
        (for-each
          (lambda (entry)
            (write-materialized-library-entry! source-root build-root entry))
          (effective-package-libraries/context manifest context))))

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
         dyld-library-paths
         dlopen-paths
         ld-preloads
         ld-preload-paths
         link-search-paths
         link-libs
         outputs
         metadata
         env
         env-paths)
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
         dyld-library-paths
         dlopen-paths
         ld-preloads
         ld-preload-paths
         link-search-paths
         link-libs
         outputs
         metadata
         env
         env-paths)
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
          (write-materialized-libraries! manifest features cmd dir)
          (write-r7rs->r6rs-translations! manifest features cmd dir)
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
                 (dep-features
                   (dependency-features-for-source-root
                     manifest
                     include-dev?
                     features
                     cmd
                     dep-source-root
                     dep-manifest)))
            (when (build-output-needed? dep-manifest)
              (let ((dep-build-root (dependency-build-output-dir dep-manifest package-root dep-features cmd)))
                (run-command (string-append "mkdir -p " (shell-quote dep-build-root)))
                (write-feature-libraries! dep-manifest dep-features dep-build-root)
                (write-materialized-libraries! dep-manifest dep-features cmd dep-build-root)
                (write-r7rs->r6rs-translations! dep-manifest dep-features cmd dep-build-root)
                (when (has-build-hooks? dep-manifest)
                  (let ((srcs (dependency-build-hook-source-roots
                               manifest
                               include-dev?
                               features
                               cmd
                               dep-source-root
                               dep-build-root)))
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

    (define (prepare-dependency-build-root! manifest include-dev? features cmd dep-source-root)
      (let ((dep-build-root
              (dependency-build-output-for-source-root
                dep-source-root
                cmd
                manifest
                include-dev?
                features)))
        (when dep-build-root
          (run-command (string-append "mkdir -p " (shell-quote dep-build-root))))))

    (define (run-dependency-build-hooks-if-needed! manifest include-dev? features cmd)
      (let ((roots (cdr (effective-activation-source-roots manifest include-dev? features cmd))))
        (for-each
          (lambda (root)
            (prepare-dependency-build-root! manifest include-dev? features cmd root))
          roots)
        (let loop ((items roots) (done 0) (total (length roots)))
          (cond
            ((null? items) '())
            (else
              (ui-progress "dependency build hooks" (+ done 1) total (car items))
              (run-dependency-build-hooks-for-source-root! manifest include-dev? features cmd (car items))
              (loop (cdr items) (+ done 1) total))))))))
