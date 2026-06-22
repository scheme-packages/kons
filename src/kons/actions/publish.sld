(define-library (kons actions publish)
  (export cmd-publish
          cmd-package)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons util)
          (kons names)
          (kons manifest)
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

(define (symbol-list->json strings)
  (string-append
   "["
   (string-join (map (lambda (item) (json-string (symbol->string item))) strings) ",")
   "]"))

(define (name-part->json part)
  (cond
   ((symbol? part) (json-string (symbol->string part)))
   ((number? part) (json-string (number->string part)))
   (else (json-string ""))))

(define (name-list->json name)
  (cond
   ((symbol? name) (json-string (symbol->string name)))
   ((pair? name)
    (string-append
     "["
     (string-join (map name-part->json name) ",")
     "]"))
   (else "[]")))

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

(define (string-list->json strings)
  (string-append
   "["
   (string-join (map json-string strings) ",")
   "]"))

(define (library-entry-json entry)
  (let ((kind (car entry))
        (name (cadr entry))
        (path (library-entry-path "" entry))
        (imports (filter symbol-list-value? (library-entry-imports entry)))
        (exports (filter symbol? (library-entry-exports entry))))
    (string-append
     "{"
     "\"kind\":" (json-string (symbol->string kind)) ","
     "\"name\":" (name-list->json name) ","
     "\"displayName\":" (json-string (library-name-display name)) ","
     "\"key\":" (json-string (library-name-key name)) ","
     "\"path\":" (json-string path) ","
     "\"implementation\":" (json-string (library-entry-implementation kind)) ","
     "\"dialect\":" (json-string (library-entry-dialect kind)) ","
     "\"imports\":["
     (string-join (map name-list->json imports) ",")
     "],"
     "\"exports\":" (symbol-list->json exports)
     "}")))

(define (libraries-json manifest)
  (string-append
   "["
   (string-join
    (map library-entry-json (effective-package-libraries manifest))
    ",")
   "]"))

(define (registry-dependency-json dep kind)
  (string-append
   "{"
   "\"name\":" (json-string (name->string (alist-ref dep 'name '()))) ","
   "\"req\":" (json-string (alist-ref dep 'version "*")) ","
   "\"kind\":" (json-string kind) ","
   "\"registry\":" (if (alist-ref dep 'registry #f)
                       (json-string (alist-ref dep 'registry #f))
                       "null") ","
   "\"optional\":" (if (alist-ref dep 'optional #f) "true" "false") ","
   "\"features\":" (symbol-list->json (alist-ref dep 'features '()))
   "}"))

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
           (alist-ref manifest 'dev-dependencies '()))))

(define (publish-registry-dependency? dep)
  (or (eq? (alist-ref dep 'type #f) 'registry)
      (local-versioned-dependency? dep)))

(define (registry-dependencies-json manifest)
  (let ((runtime (filter publish-registry-dependency?
                         (alist-ref manifest 'dependencies '())))
        (dev (filter publish-registry-dependency?
                     (alist-ref manifest 'dev-dependencies '()))))
    (string-append
     "["
     (string-join
      (append (map (lambda (dep) (registry-dependency-json dep "normal")) runtime)
              (map (lambda (dep) (registry-dependency-json dep "dev")) dev))
      ",")
     "]")))

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
                                     " && git -C " (shell-quote root) " diff --cached --quiet"))
                     0)))
    (usage-error "package refuses a dirty git worktree; pass --allow-dirty to override" root)))

(define (archive-package root archive exclude-lockfile?)
  (let ((parent (dirname archive)))
    (run-command (string-append "mkdir -p " (shell-quote parent)))
    (run-command
     (string-append
      "cd " (shell-quote root)
      " && tar --exclude .git --exclude .kons "
      (if exclude-lockfile? "--exclude kons.lock " "")
      "--exclude '*~' --exclude '.DS_Store' "
      "-czf " (shell-quote archive) " ."))))

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

(define (write-publish-json path manifest owner archive-b64)
  (call-with-output-file path
    (lambda (out)
      (display "{" out)
      (display "\"name\":" out) (display (json-string (name->string (package-name manifest))) out) (display "," out)
      (display "\"owner\":" out) (display (if owner (json-string owner) "null") out) (display "," out)
      (display "\"version\":" out) (display (json-string (package-version manifest)) out) (display "," out)
      (display "\"description\":" out) (display (json-string (package-description manifest)) out) (display "," out)
      (display "\"license\":" out) (display (json-string (package-license manifest)) out) (display "," out)
      (display "\"keywords\":" out) (display (string-list->json (package-keywords manifest)) out) (display "," out)
      (display "\"homepage\":" out) (display (json-string (package-homepage manifest)) out) (display "," out)
      (display "\"site\":" out) (display (json-string (package-site manifest)) out) (display "," out)
      (display "\"repository\":" out) (display (json-string (package-repository manifest)) out) (display "," out)
      (display "\"repo\":" out) (display (json-string (package-repo manifest)) out) (display "," out)
      (display "\"documentation\":" out) (display (json-string (package-documentation manifest)) out) (display "," out)
      (display "\"docs\":" out) (display (json-string (package-docs manifest)) out) (display "," out)
      (display "\"readme\":" out) (display (json-string (package-readme manifest)) out) (display "," out)
      (display "\"dialects\":" out) (display (symbol-list->json (package-dialects manifest)) out) (display "," out)
      (display "\"features\":" out) (display (string-list->json (feature-names manifest)) out) (display "," out)
      (display "\"dependencies\":" out) (display (registry-dependencies-json manifest) out) (display "," out)
      (display "\"libraries\":" out) (display (libraries-json manifest) out) (display "," out)
      (display "\"archiveBase64\":\"" out) (display archive-b64 out) (display "\"" out)
      (display "}" out))))

(define (cmd-publish cmd)
  (let* ((manifest (parse-manifest (command-manifest-path cmd)))
         (root (manifest-root manifest))
         (registry (or (command-string-option cmd "index")
                       (command-string-option cmd "registry")
                       default-registry-alias))
         (archive (temporary-file-path "kons-publish.kons"))
         (json (temporary-file-path "kons-publish.json"))
         (owner (publish-owner manifest cmd)))
    (unless (command-flag? cmd "no-metadata")
      (require-publish-metadata manifest "publish"))
    (ensure-git-clean root (command-flag? cmd "allow-dirty"))
    (archive-package root archive (command-flag? cmd "exclude-lockfile"))
    (write-publish-json json manifest owner (archive-base64 archive))
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
             (payload ,json)))
          (list-archive archive))
        (begin
          (registry-http-upload/token
           registry
           "/api/v1/packages/new"
           json
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
          (displayln archive)))))

  ))
