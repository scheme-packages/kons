(define-library (kons features)
  (export feature-form
    feature-references
    feature-dependency-blocks
    parse-feature-dependencies
    requested-feature-symbols
    active-features
    default-feature-set
    ensure-supported-active-features
    feature-dependencies
    command-selected-dialect
    dependency-applies?
    applicable-overrides
    apply-overrides-to-dep
    all-dependencies-for
    all-dependencies)
  (import (scheme base)
    (scheme cxr)
    (scheme file)
    (kons conditions)
    (kons util)
    (kons implementation)
    (kons manifest)
    (kons options)
    (kons dep git)
    (kons dep path))

  (begin
    (define-record-type <dependency-selection-context>
      (make-dependency-selection-context scheme dialect target profile compile-mode condition-options)
      dependency-selection-context?
      (scheme dependency-selection-context-scheme)
      (dialect dependency-selection-context-dialect)
      (target dependency-selection-context-target)
      (profile dependency-selection-context-profile)
      (compile-mode dependency-selection-context-compile-mode)
      (condition-options dependency-selection-context-condition-options))

    (define (feature-form manifest name)
      (let loop ((features (package-features manifest)))
        (cond
          ((null? features) #f)
          ((and (pair? (car features)) (eq? (caar features) name)) (car features))
          (else (loop (cdr features))))))

    (define (feature-references feature-form)
      (filter symbol? (cdr feature-form)))

    (define (feature-dependency-blocks feature-form)
      (filter (lambda (item)
               (and (pair? item) (eq? (car item) 'dependencies)))
        (cdr feature-form)))

    (define (feature-native? feature-form)
      (let loop ((items (cdr feature-form)))
        (cond
          ((null? items) #f)
          ((and (pair? (car items))
              (eq? (caar items) 'native?)
              (pair? (cdar items)))
            (cadar items))
          (else (loop (cdr items))))))

    (define (parse-feature-dependencies feature-form)
      (append-map
        (lambda (block)
          (map (lambda (dep) (parse-dependency dep 'runtime)) (cdr block)))
        (feature-dependency-blocks feature-form)))

    (define (requested-feature-symbols cmd)
      (let ((raw (command-option cmd "features" "")))
        (map string->symbol
          (filter non-empty-string? (string-split raw #\,)))))

    (define (active-features manifest cmd)
      (let* ((initial (append (if (command-flag? cmd "no-default-features")
                               '()
                               '(default))
                       (requested-feature-symbols cmd))))
        (let loop ((queue initial) (seen '()))
          (cond
            ((null? queue) (reverse seen))
            ((memq (car queue) seen) (loop (cdr queue) seen))
            (else
              (let ((form (feature-form manifest (car queue))))
                (if form
                  (loop (append (cdr queue) (feature-references form))
                    (cons (car queue) seen))
                  (if (eq? (car queue) 'default)
                    (loop (cdr queue) (cons (car queue) seen))
                    (manifest-error "unknown feature" (car queue))))))))))

    (define (ensure-supported-active-features manifest features cmd)
      (for-each
        (lambda (feature)
          (let ((form (feature-form manifest feature)))
            (when (and form (feature-native? form))
              (manifest-error "native feature is not supported for selected implementation"
                feature
                (command-selected-scheme cmd)))))
        features))

    (define (feature-dependencies manifest features)
      (append-map
        (lambda (feature)
          (let ((form (feature-form manifest feature)))
            (if form (parse-feature-dependencies form) '())))
        features))

    (define (direct-dependencies manifest include-dev? features)
      (append (alist-ref manifest 'dependencies '())
        (feature-dependencies manifest features)
        (if include-dev? (alist-ref manifest 'dev-dependencies '()) '())))

    (define (command-selected-dialect manifest cmd)
      (let ((requested (command-option cmd "dialect" #f))
            (dialects (package-dialects manifest))
            (scheme (command-selected-scheme cmd)))
        (if requested
          (let ((dialect (string->symbol requested)))
            (unless (memq dialect dialects)
              (manifest-error "selected dialect is not declared by package"
                (package-name manifest)
                dialect
                dialects))
            (unless (implementation-mode-for-dialects scheme (list dialect))
              (manifest-error "selected scheme does not support selected dialect"
                scheme
                dialect))
            dialect)
          (let ((mode (implementation-mode-for-dialects scheme dialects)))
            (or (and mode (implementation-mode-field mode 'selected-dialect #f))
              (and (pair? dialects) (car dialects)))))))

    (define (command-dependency-selection-context manifest cmd)
      (make-dependency-selection-context
        (command-selected-scheme cmd)
        (command-selected-dialect manifest cmd)
        (command-option cmd "target" #f)
        (command-selected-profile cmd)
        (command-selected-compile-mode cmd)
        (condition-options
          (command-option cmd "target" #f)
          (command-selected-profile cmd)
          '()
          (command-selected-scheme cmd)
          (command-selected-dialect manifest cmd)
          (command-selected-compile-mode cmd))))

    (define (selector-matches-symbol? selected allowed)
      (or (null? allowed) (memq selected allowed)))

    (define (selector-matches-target? selected allowed)
      (or (null? allowed)
        (and selected (member selected allowed))))

    (define (dependency-applies-in-context? dep context)
      (and
        (selector-matches-symbol?
          (dependency-selection-context-scheme context)
          (alist-ref dep 'schemes '()))
        (selector-matches-symbol?
          (dependency-selection-context-dialect context)
          (alist-ref dep 'dialects '()))
        (selector-matches-target?
          (dependency-selection-context-target context)
          (alist-ref dep 'targets '()))
        (selector-matches-symbol?
          (dependency-selection-context-profile context)
          (alist-ref dep 'profiles '()))
        (selector-matches-symbol?
          (dependency-selection-context-compile-mode context)
          (alist-ref dep 'compile-modes '()))
        (condition-predicate-true?
          (alist-ref dep 'condition 'true)
          (dependency-selection-context-condition-options context))))

    (define (dependency-applies? dep manifest cmd)
      (dependency-applies-in-context?
        dep
        (command-dependency-selection-context manifest cmd)))

    (define (workspace-root-manifest-path cmd)
      (command-option cmd "workspace-root" #f))

    (define (workspace-member-directory workspace member)
      (path-join (manifest-root workspace) member))

    (define (workspace-member-record workspace member)
      (let* ((root (workspace-member-directory workspace member))
             (manifest-path (path-join root "kons.scm"))
             (manifest (parse-manifest manifest-path)))
        `((member . ,member)
          (root . ,root)
          (name . ,(package-name manifest)))))

    (define (workspace-member-records-for-resolution workspace)
      (map (lambda (member) (workspace-member-record workspace member))
        (workspace-members workspace)))

    (define (find-workspace-member-by-name workspace name)
      (let loop ((items (workspace-member-records-for-resolution workspace)))
        (cond
          ((null? items) #f)
          ((equal? (alist-ref (car items) 'name '()) name) (car items))
          (else (loop (cdr items))))))

    (define (resolve-workspace-dependency dep cmd)
      (if (not (eq? (alist-ref dep 'type #f) 'workspace))
        dep
        (let ((workspace-path (workspace-root-manifest-path cmd)))
          (unless workspace-path
            (dependency-error "workspace dependency requires running from a workspace with --package"
              (alist-ref dep 'name '())))
          (let* ((workspace (parse-manifest workspace-path))
                 (member (find-workspace-member-by-name workspace (alist-ref dep 'name '()))))
            (unless member
              (dependency-error "workspace member dependency not found"
                (alist-ref dep 'name '())
                workspace-path))
            (append
              `((type . workspace)
                (scope . ,(alist-ref dep 'scope 'runtime))
                (name . ,(alist-ref dep 'name '()))
                (member . ,(alist-ref member 'member ""))
                (path . ,(absolute-path (alist-ref member 'root ""))))
              (dependency-selector-fields dep))))))

    (define (direct-dependencies-for manifest include-dev? features cmd)
      (map (lambda (dep) (resolve-workspace-dependency dep cmd))
        (filter (lambda (dep) (dependency-applies? dep manifest cmd))
          (direct-dependencies manifest include-dev? features))))

    (define (dependency-key dep)
      (let ((type (alist-ref dep 'type #f)))
        (string-append
          (symbol->string type)
          ":"
          (cond
            ((alist-ref dep 'name #f) (value->key (alist-ref dep 'name '())))
            ((alist-ref dep 'names #f) (value->key (alist-ref dep 'names '())))
            (else "")))))

    (define (find-dependency-by-key key deps)
      (let loop ((xs deps))
        (cond
          ((null? xs) #f)
          ((equal? (dependency-key (car xs)) key) (car xs))
          (else (loop (cdr xs))))))

    (define (replace-dependency-by-key key replacement deps)
      (let loop ((xs deps) (out '()))
        (cond
          ((null? xs) (reverse out))
          ((equal? (dependency-key (car xs)) key)
            (loop (cdr xs) (cons replacement out)))
          (else (loop (cdr xs) (cons (car xs) out))))))

    (define (maybe-equal-or-empty? a b)
      (or (not a) (not b) (equal? a b)))

    (define (alist-set alist key value)
      (let loop ((xs alist) (out '()) (done? #f))
        (cond
          ((null? xs)
            (reverse (if done? out (cons (cons key value) out))))
          ((eq? (caar xs) key)
            (loop (cdr xs) (cons (cons key value) out) #t))
          (else (loop (cdr xs) (cons (car xs) out) done?)))))

    (define (alist-has-key? alist key)
      (and (assq key alist) #t))

    (define (merge-publish-field existing incoming key default label)
      (let ((existing-has? (alist-has-key? existing key))
            (incoming-has? (alist-has-key? incoming key))
            (existing-value (alist-ref existing key default))
            (incoming-value (alist-ref incoming key default)))
        (cond
          ((and existing-has? incoming-has? (not (equal? existing-value incoming-value)))
            (dependency-error
              (string-append "dependency conflict: incompatible publish " label)
              (alist-ref incoming 'name '())
              existing-value
              incoming-value))
          (existing-has? existing)
          (incoming-has? (alist-set existing key incoming-value))
          (else existing))))

    (define (merge-publish-metadata existing incoming)
      (let* ((merged-version (merge-publish-field existing incoming 'version #f "version"))
             (merged-registry (merge-publish-field merged-version incoming 'registry #f "registry"))
             (merged-features (merge-publish-field merged-registry incoming 'features '() "features")))
        (merge-publish-field merged-features incoming 'optional #f "optional flag")))

    (define (merge-path-dependency existing incoming)
      (unless (equal? (alist-ref existing 'path #f)
               (alist-ref incoming 'path #f))
        (dependency-error "dependency conflict: incompatible path sources"
          (alist-ref incoming 'name '())
          (alist-ref existing 'path #f)
          (alist-ref incoming 'path #f)))
      (merge-publish-metadata existing incoming))

    (define (merge-git-dependency existing incoming)
      (unless (and (equal? (alist-ref existing 'url #f)
                    (alist-ref incoming 'url #f))
               (maybe-equal-or-empty? (alist-ref existing 'rev #f)
                 (alist-ref incoming 'rev #f)))
        (dependency-error "dependency conflict: incompatible git sources"
          (alist-ref incoming 'name '())
          (alist-ref existing 'url #f)
          (alist-ref incoming 'url #f)))
      (merge-publish-metadata
        (if (alist-ref existing 'rev #f)
          existing
          (alist-set existing 'rev (alist-ref incoming 'rev #f)))
        incoming))

    (define (merge-registry-dependency existing incoming)
      (unless (and (equal? (alist-ref existing 'registry #f)
                    (alist-ref incoming 'registry #f))
               (equal? (alist-ref existing 'version "*")
                 (alist-ref incoming 'version "*")))
        (dependency-error "dependency conflict: incompatible registry requirements"
          (alist-ref incoming 'name '())
          (alist-ref existing 'version "*")
          (alist-ref incoming 'version "*")))
      (let* ((features (dedupe-symbols
                        (append (alist-ref existing 'features '())
                          (alist-ref incoming 'features '()))))
             (merged (alist-set existing 'features features)))
        (alist-set merged
          'optional
          (and (alist-ref existing 'optional #f)
            (alist-ref incoming 'optional #f)))))

    (define (merge-dependency existing incoming)
      (case (alist-ref existing 'type #f)
        ((path) (merge-path-dependency existing incoming))
        ((workspace) (merge-publish-metadata existing incoming))
        ((git) (merge-git-dependency existing incoming))
        ((registry) (merge-registry-dependency existing incoming))
        (else existing)))

    (define (value->key value)
      (cond
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        ((number? value) (number->string value))
        ((null? value) "")
        ((pair? value)
          (let loop ((items value) (out ""))
            (cond
              ((null? items) out)
              ((string=? out "")
                (loop (cdr items) (value->key (car items))))
              (else
                (loop (cdr items)
                  (string-append out "/" (value->key (car items))))))))
        (else "value")))

    (define (with-parent-root dep root)
      (if (or (not (memq (alist-ref dep 'type #f) '(path git)))
           (alist-ref dep 'parent-root #f))
        dep
        (cons `(parent-root . ,root) dep)))

    (define (with-dependency-context dep root)
      (with-parent-root dep root))

    (define (dependency-name dep)
      (alist-ref dep 'name #f))

    (define (dependency-scope dep)
      (alist-ref dep 'scope 'runtime))

    (define (scoped-dependency dep scope)
      (alist-set dep 'scope scope))

    (define (dependency-selector-fields dep)
      (append
        (let ((schemes (alist-ref dep 'schemes '())))
          (if (null? schemes) '() `((schemes . ,schemes))))
        (let ((dialects (alist-ref dep 'dialects '())))
          (if (null? dialects) '() `((dialects . ,dialects))))
        (let ((targets (alist-ref dep 'targets '())))
          (if (null? targets) '() `((targets . ,targets))))
        (let ((profiles (alist-ref dep 'profiles '())))
          (if (null? profiles) '() `((profiles . ,profiles))))
        (let ((compile-modes (alist-ref dep 'compile-modes '())))
          (if (null? compile-modes) '() `((compile-modes . ,compile-modes))))
        (let ((condition (alist-ref dep 'condition #f)))
          (if condition `((condition . ,condition)) '()))))

    (define (dependency-name=? a b)
      (and (dependency-name a)
        (dependency-name b)
        (equal? (dependency-name a) (dependency-name b))))

    (define (find-override-for dep overrides)
      (let loop ((items overrides))
        (cond
          ((null? items) #f)
          ((dependency-name=? dep (car items)) (car items))
          (else (loop (cdr items))))))

    (define (applicable-overrides manifest root cmd)
      (map (lambda (dep)
            (with-dependency-context dep root))
        (filter
          (lambda (dep)
            (and (memq (alist-ref dep 'type #f) '(path git workspace))
              (dependency-applies? dep manifest cmd)))
          (alist-ref manifest 'overrides '()))))

    (define (apply-overrides-to-dep dep overrides)
      (let ((override (find-override-for dep overrides)))
        (if override
          (scoped-dependency override (dependency-scope dep))
          dep)))

    (define (default-feature-set manifest)
      (let ((form (feature-form manifest 'default)))
        (if form
          (let loop ((queue '(default)) (seen '()))
            (cond
              ((null? queue) (reverse seen))
              ((memq (car queue) seen) (loop (cdr queue) seen))
              (else
                (let ((feature (feature-form manifest (car queue))))
                  (if feature
                    (loop (append (cdr queue) (feature-references feature))
                      (cons (car queue) seen))
                    (loop (cdr queue) (cons (car queue) seen)))))))
          '(default))))

    (define (path-dependency-manifest dep)
      (if (alist-ref dep 'raw #f)
        #f
        (let* ((root (alist-ref dep 'parent-root "."))
               (dep-root (ensure-path-dependency-root root dep))
               (dep-manifest-path (path-join dep-root "kons.scm")))
          (parse-manifest dep-manifest-path))))

    (define (subpath-package-root root subpath)
      (if subpath
        (path-join root subpath)
        root))

    (define (git-dependency-manifest dep)
      (let* ((root (alist-ref dep 'parent-root "."))
             (repo-root (git-dependency-resolution-root root dep #f))
             (package-root (and repo-root
                            (subpath-package-root repo-root (alist-ref dep 'subpath #f))))
             (manifest-path (and package-root (path-join package-root "kons.scm"))))
        (and manifest-path
          (file-exists? manifest-path)
          (parse-manifest manifest-path))))

    (define (dependency-manifest dep)
      (case (alist-ref dep 'type #f)
        ((path) (path-dependency-manifest dep))
        ((workspace) (path-dependency-manifest dep))
        ((git) (git-dependency-manifest dep))
        (else #f)))

    (define (nested-dependencies dep cmd)
      (let ((manifest (dependency-manifest dep)))
        (if manifest
          (map (lambda (child)
                (with-dependency-context
                  child
                  (manifest-root manifest)))
            (direct-dependencies-for manifest #f (default-feature-set manifest) cmd))
          '())))

    (define (all-dependencies-for manifest include-dev? features cmd)
      (let* ((root (manifest-root manifest))
             (overrides (applicable-overrides manifest root cmd)))
        (let loop ((queue (map (lambda (dep) (with-dependency-context dep root))
                           (direct-dependencies-for manifest include-dev? features cmd)))
                   (out '()))
          (cond
            ((null? queue) (reverse out))
            (else
              (let* ((dep (resolve-workspace-dependency
                           (apply-overrides-to-dep (car queue) overrides)
                           cmd))
                     (key (dependency-key dep))
                     (existing (find-dependency-by-key key out)))
                (if existing
                  (let ((merged (merge-dependency existing dep)))
                    (loop (cdr queue)
                      (replace-dependency-by-key key merged out)))
                  (loop (append (cdr queue) (nested-dependencies dep cmd))
                    (cons dep out)))))))))

    (define (all-dependencies manifest include-dev? features)
      (all-dependencies-for manifest include-dev? features '()))))
