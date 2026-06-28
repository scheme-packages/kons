(define-library (kons actions publish)
  (export cmd-publish
    cmd-package)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons util)
    (kons names)
    (kons manifest)
    (kons features)
    (kons library-discovery)
    (kons registry)
    (kons options))

  (begin
    (define (string-join xs sep)
      (let loop ((rest xs) (out ""))
        (cond
          ((null? rest) out)
          ((string=? out "") (loop (cdr rest) (car rest)))
          (else (loop (cdr rest) (string-append out sep (car rest)))))))

    (define (command-string-option cmd name)
      (let ((value (command-option cmd name #f)))
        (if (string? value) value #f)))

    (define (name-part->string part)
      (cond
        ((symbol? part) (symbol->string part))
        ((number? part) (number->string part))
        (else "")))

    (define (name-list->sexp name)
      (cond
        ((symbol? name) (symbol->string name))
        ((pair? name) (map name-part->string name))
        (else '())))

    (define (library-name-display name)
      (cond
        ((symbol? name) (symbol->string name))
        ((pair? name)
          (string-append
            "("
            (string-join
              (map (lambda (part)
                    (cond
                      ((symbol? part) (symbol->string part))
                      ((number? part) (number->string part))
                      (else "")))
                name)
              " ")
            ")"))
        (else "")))

    (define (library-name-key name)
      (cond
        ((symbol? name) (symbol->string name))
        ((pair? name)
          (string-join
            (map (lambda (part)
                  (cond
                    ((symbol? part) (symbol->string part))
                    ((number? part) (number->string part))
                    (else "")))
              name)
            "/"))
        (else "")))

    (define (library-entry-dialect kind)
      (case kind
        ((r7rs r6rs) (symbol->string kind))
        (else "")))

    (define (library-entry-implementation kind)
      (case kind
        ((guile gauche) (symbol->string kind))
        (else "")))

    (define (library-entry-sexp entry)
      (let ((kind (car entry))
            (name (cadr entry))
            (path (library-entry-path "" entry))
            (imports (filter symbol-list-value? (library-entry-imports entry)))
            (exports (filter symbol? (library-entry-exports entry))))
        `(library
          (kind ,kind)
          (name ,(name-list->sexp name))
          (display-name ,(library-name-display name))
          (key ,(library-name-key name))
          (path ,path)
          (implementation ,(library-entry-implementation kind))
          (dialect ,(library-entry-dialect kind))
          (imports ,@(map name-list->sexp imports))
          (exports ,@exports))))

    (define (libraries-sexp manifest)
      (map library-entry-sexp (effective-package-libraries manifest)))

    (define (registry-dependency-sexp dep kind)
      `(dependency
        (name ,(name->string (alist-ref dep 'name '())))
        (req ,(alist-ref dep 'version "*"))
        (kind ,(string->symbol kind))
        (registry ,(or (alist-ref dep 'registry #f) #f))
        (optional ,(and (alist-ref dep 'optional #f) #t))
        (features ,@(alist-ref dep 'features '()))
        (schemes ,@(alist-ref dep 'schemes '()))
        (dialects ,@(alist-ref dep 'dialects '()))
        (targets ,@(alist-ref dep 'targets '()))
        (profiles ,@(alist-ref dep 'profiles '()))
        (compile-modes ,@(alist-ref dep 'compile-modes '()))))

    (define (registry-dependencies-list-sexp deps kind)
      (map (lambda (dep) (registry-dependency-sexp dep kind)) deps))

    (define (feature-registry-dependencies feature)
      (filter publish-registry-dependency?
        (parse-feature-dependencies feature)))

    (define (feature-dependency-sexp feature)
      (let ((deps (feature-registry-dependencies feature)))
        `(feature-dependency
          (feature ,(car feature))
          (dependencies ,@(registry-dependencies-list-sexp deps "normal")))))

    (define (feature-dependencies-sexp manifest)
      (map feature-dependency-sexp (package-features manifest)))

    (define (publish-owner manifest cmd)
      (let ((owner (package-owner manifest)))
        (if (string=? owner "") #f owner)))

    (define (local-versioned-dependency? dep)
      (and (memq (alist-ref dep 'type #f) '(path workspace git))
        (alist-ref dep 'version #f)))

    (define (publishable-dependency? dep)
      (let ((type (alist-ref dep 'type #f)))
        (or (eq? type 'registry)
          (eq? type 'system)
          (local-versioned-dependency? dep))))

    (define (check-publishable-dependencies manifest command-name)
      (for-each
        (lambda (dep)
          (unless (publishable-dependency? dep)
            (manifest-error
              (string-append command-name " cannot include unversioned path, workspace, or git dependencies")
              (alist-ref dep 'name '()))))
        (append (alist-ref manifest 'dependencies '())
          (alist-ref manifest 'dev-dependencies '())
          (append-map parse-feature-dependencies (package-features manifest)))))

    (define (publish-registry-dependency? dep)
      (or (eq? (alist-ref dep 'type #f) 'registry)
        (local-versioned-dependency? dep)))

    (define (registry-dependencies-sexp manifest)
      (let ((runtime (filter publish-registry-dependency?
                      (alist-ref manifest 'dependencies '())))
            (dev (filter publish-registry-dependency?
                  (alist-ref manifest 'dev-dependencies '()))))
        (append
          (registry-dependencies-list-sexp runtime "normal")
          (registry-dependencies-list-sexp dev "dev"))))

    (define (feature-names manifest)
      (map (lambda (feature) (symbol->string (car feature)))
        (package-features manifest)))

    (define (require-publish-metadata manifest command-name)
      (when (null? (package-name manifest))
        (manifest-error (string-append command-name " requires package name")))
      (unless (package-version manifest)
        (manifest-error (string-append command-name " requires package version")))
      (when (string=? (package-owner manifest) "")
        (manifest-error (string-append command-name " requires package owner")))
      (when (string=? (package-description manifest) "")
        (manifest-error (string-append command-name " requires package description")))
      (when (string=? (package-license manifest) "")
        (manifest-error (string-append command-name " requires package license")))
      (check-publishable-dependencies manifest command-name))

    (define (ensure-git-clean root allow-dirty?)
      (when (and (not allow-dirty?)
             (= (shell-command-status
                 (string-append "test -d " (shell-quote (path-join root ".git"))))
               0)
             (not (= (shell-command-status
                      (string-append "git -C " (shell-quote root) " diff --quiet"
                        " && git -C "
                        (shell-quote root)
                        " diff --cached --quiet"))
                   0)))
        (usage-error "package refuses a dirty git worktree; pass --allow-dirty to override" root)))

    (define (archive-package root archive exclude-lockfile?)
      (let ((parent (dirname archive)))
        (run-command (string-append "mkdir -p " (shell-quote parent)))
        (run-command
          (string-append
            "cd "
            (shell-quote root)
            " && tar --exclude .git --exclude .kons "
            (if exclude-lockfile? "--exclude kons.lock " "")
            "--exclude '*~' --exclude '.DS_Store' "
            "-czf "
            (shell-quote archive)
            " ."))))

    (define (package-archive-path manifest)
      (path-join
        (path-join (manifest-root manifest) ".kons/package")
        (string-append
          (safe-store-token (name->string (package-name manifest)))
          "-"
          (package-version manifest)
          ".kons")))

    (define (list-archive archive)
      (run-command (string-append "tar -tzf " (shell-quote archive))))

    (define (archive-base64 archive)
      (capture-first-line
        (string-append "base64 " (shell-quote archive) " | tr -d '\\n'")))

    (define (publish-libraries-sexp manifest include-metadata?)
      (if include-metadata?
        (libraries-sexp manifest)
        '()))

    (define (write-publish-payload path manifest owner archive-b64 include-metadata?)
      (call-with-output-file path
        (lambda (out)
          (write
            `(kons-publish
              (name ,(name->string (package-name manifest)))
              (owner ,(or owner #f))
              (version ,(package-version manifest))
              (description ,(package-description manifest))
              (license ,(package-license manifest))
              (keywords ,@(package-keywords manifest))
              (homepage ,(package-homepage manifest))
              (site ,(package-site manifest))
              (repository ,(package-repository manifest))
              (repo ,(package-repo manifest))
              (documentation ,(package-documentation manifest))
              (docs ,(package-docs manifest))
              (readme ,(package-readme manifest))
              (dialects ,@(package-dialects manifest))
              (features ,@(feature-names manifest))
              (feature-dependencies ,@(feature-dependencies-sexp manifest))
              (dependencies ,@(registry-dependencies-sexp manifest))
              (libraries ,@(publish-libraries-sexp manifest include-metadata?))
              (archive-base64 ,archive-b64))
            out)
          (newline out))))

    (define (cmd-publish cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (root (manifest-root manifest))
             (registry (or (command-string-option cmd "index")
                        (command-string-option cmd "registry")
                        default-registry-alias))
             (archive (temporary-file-path "kons-publish.kons"))
             (payload (temporary-file-path "kons-publish.scm"))
             (owner (publish-owner manifest cmd)))
        (unless (command-flag? cmd "no-metadata")
          (require-publish-metadata manifest "publish"))
        (ensure-git-clean root (command-flag? cmd "allow-dirty"))
        (archive-package root archive (command-flag? cmd "exclude-lockfile"))
        (write-publish-payload
          payload
          manifest
          owner
          (archive-base64 archive)
          (not (command-flag? cmd "no-metadata")))
        (if (command-flag? cmd "dry-run")
          (begin
            (writeln
              `(publish-plan
                (registry ,registry)
                (url ,(registry-url registry))
                (name ,(package-name manifest))
                (owner ,(if owner owner ""))
                (version ,(package-version manifest))
                (archive ,archive)
                (payload ,payload)))
            (list-archive archive))
          (begin
            (registry-http-upload/token
              registry
              "/api/v1/packages/new"
              payload
              (command-string-option cmd "token"))
            (display "published ")
            (display (name->string (package-name manifest)))
            (display " ")
            (display (package-version manifest))
            (display " to ")
            (displayln registry)))))

    (define (cmd-package cmd)
      (let* ((manifest (parse-manifest (command-manifest-path cmd)))
             (root (manifest-root manifest))
             (archive (package-archive-path manifest)))
        (unless (command-flag? cmd "no-metadata")
          (require-publish-metadata manifest "package"))
        (ensure-git-clean root (command-flag? cmd "allow-dirty"))
        (archive-package root archive (command-flag? cmd "exclude-lockfile"))
        (if (command-flag? cmd "list")
          (list-archive archive)
          (begin
            (display "packaged ")
            (display (name->string (package-name manifest)))
            (display " ")
            (display (package-version manifest))
            (display " to ")
            (displayln archive)))))))
