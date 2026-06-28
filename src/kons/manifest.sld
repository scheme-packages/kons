(define-library (kons manifest)
  (export parse-package
    parse-dependency
    parse-dependency-block
    parse-overrides
    parse-manifest-exprs
    parse-manifest
    alist-ref
    package-name
    package-version
    package-license
    package-description
    package-owner
    package-keywords
    package-authors
    package-documentation
    package-homepage
    package-readme
    package-docs
    package-site
    package-repository
    package-repo
    package-source-path
    package-discover-libraries?
    package-features
    package-dialects
    package-main
    package-tests
    package-benches
    package-examples
    package-scripts
    package-bins
    package-build-hooks
    manifest-workspace?
    workspace-members
    workspace-default-members
    workspace-package-defaults
    workspace-dependencies
    manifest-root
    manifest-source-root)
  (import (scheme base)
    (scheme file)
    (kons util)
    (kons akku manifest))

  (begin
    (define current-manifest-path #f)

    (define (source-context name)
      (if current-manifest-path
        (cons name current-manifest-path)
        name))

    (define (parse-package form)
      (let ((fields (cdr form)))
        (ensure-known-fields
          fields
          '(name version owner license description keywords authors documentation docs homepage site readme repository repo dialects source-path discover-libraries libraries main tests benches examples scripts bins features build-hooks)
          (source-context 'package))
        (let* ((name (normalize-name (field-ref fields 'name #f) 'package-name))
               (version (field-ref fields 'version #f))
               (owner (field-ref fields 'owner ""))
               (license (field-ref fields 'license ""))
               (description (field-ref fields 'description ""))
               (keywords (field-rest fields 'keywords '()))
               (authors (field-rest fields 'authors '()))
               (documentation (field-ref fields 'documentation (field-ref fields 'docs "")))
               (homepage (field-ref fields 'homepage (field-ref fields 'site "")))
               (readme (field-ref fields 'readme ""))
               (repository (field-ref fields 'repository (field-ref fields 'repo "")))
               (dialects (field-rest fields 'dialects '(r7rs)))
               (source-path (field-ref fields 'source-path "src"))
               (discover-libraries? (field-ref fields 'discover-libraries #t))
               (libraries (field-rest fields 'libraries '()))
               (main (field-ref fields 'main "main.scm"))
               (tests (field-rest fields 'tests '()))
               (benches (field-rest fields 'benches '()))
               (examples (field-rest fields 'examples '()))
               (scripts (field-rest fields 'scripts '()))
               (bins (field-rest fields 'bins '()))
               (features (field-rest fields 'features '()))
               (build-hooks (field-rest fields 'build-hooks '())))
          (unless (or (not version) (string? version))
            (manifest-error "package version must be a string" version))
          (when (and version (not (semver-version? version)))
            (manifest-error "package version must be valid SemVer, for example 1.2.3" version))
          (for-each
            (lambda (field)
              (unless (string? (cdr field))
                (manifest-error "package metadata field must be a string" field)))
            `((owner . ,owner)
              (license . ,license)
              (description . ,description)
              (documentation . ,documentation)
              (docs . ,documentation)
              (homepage . ,homepage)
              (site . ,homepage)
              (readme . ,readme)
              (repository . ,repository)
              (repo . ,repository)))
          (for-each
            (lambda (author)
              (unless (string? author)
                (manifest-error "package authors entries must be strings" author)))
            authors)
          (let ((parsed-keywords (parse-keywords keywords)))
            (unless (string? source-path)
              (manifest-error "source-path must be a string" source-path))
            (unless (boolean? discover-libraries?)
              (manifest-error "discover-libraries must be a boolean" discover-libraries?))
            (unless (or (string? main) (not main))
              (manifest-error "main must be a string or #f" main))
            `((name . ,name)
              (version . ,version)
              (owner . ,owner)
              (license . ,license)
              (description . ,description)
              (keywords . ,parsed-keywords)
              (authors . ,authors)
              (documentation . ,documentation)
              (docs . ,documentation)
              (homepage . ,homepage)
              (site . ,homepage)
              (readme . ,readme)
              (repository . ,repository)
              (repo . ,repository)
              (dialects . ,dialects)
              (source-path . ,source-path)
              (discover-libraries . ,discover-libraries?)
              (libraries . ,libraries)
              (main . ,main)
              (tests . ,(parse-test-scripts tests))
              (benches . ,(parse-benchmark-scripts benches))
              (examples . ,(parse-examples examples))
              (scripts . ,(parse-scripts scripts))
              (bins . ,(parse-bins bins))
              (features . ,(parse-features features))
              (build-hooks . ,(parse-build-hooks build-hooks)))))))

    (define (parse-keyword keyword)
      (cond
        ((string? keyword)
          (when (string=? keyword "")
            (manifest-error "package keywords entries must not be empty" keyword))
          keyword)
        ((symbol? keyword) (symbol->string keyword))
        (else (manifest-error "package keywords entries must be strings or symbols" keyword))))

    (define (parse-keywords keywords)
      (map parse-keyword keywords))

    (define (feature-property? item)
      (and (pair? item) (symbol? (car item))))

    (define (parse-feature-entry feature)
      (unless (and (pair? feature) (symbol? (car feature)))
        (manifest-error "expected feature form" feature))
      (for-each
        (lambda (item)
          (when (feature-property? item)
            (case (car item)
              ((dependencies)
                (for-each
                  (lambda (dep)
                    (parse-dependency dep 'runtime))
                  (cdr item)))
              ((native?)
                (unless (and (pair? (cdr item))
                         (boolean? (cadr item))
                         (null? (cddr item)))
                  (manifest-error "feature native? requires a boolean" feature)))
              (else
                (manifest-error "unknown feature property" (car item))))))
        (cdr feature))
      feature)

    (define (parse-features features)
      (map parse-feature-entry features))

    (define (parse-build-hooks hooks)
      (map parse-build-hook hooks))

    (define (string-list-contains? value items)
      (let loop ((remaining items))
        (cond
          ((null? remaining) #f)
          ((string=? value (car remaining)) #t)
          (else (loop (cdr remaining))))))

    (define (parse-workspace form)
      (let ((fields (cdr form)))
        (ensure-known-fields
          fields
          '(members default-member default-members package dependencies)
          (source-context 'workspace))
        (let ((members (field-rest fields 'members '()))
              (default-members (append (field-rest fields 'default-members '())
                                (field-rest fields 'default-member '())))
              (package-defaults (parse-workspace-package-defaults
                                 (workspace-subform fields 'package)))
              (dependency-defaults (parse-workspace-dependencies
                                    (workspace-subform fields 'dependencies))))
          (for-each
            (lambda (member)
              (unless (string? member)
                (manifest-error "workspace members must be package directories" member)))
            members)
          (for-each
            (lambda (default-member-name)
              (unless (string? default-member-name)
                (manifest-error
                  "workspace default-members entries must be package directories"
                  default-member-name))
              (unless (string-list-contains? default-member-name members)
                (manifest-error
                  "workspace default-member is not listed in members"
                  default-member-name)))
            default-members)
          `((members . ,members)
            (default-members . ,default-members)
            (package . ,package-defaults)
            (dependencies . ,dependency-defaults)))))

    (define (workspace-subform fields key)
      (let ((found (assq key fields)))
        (if found (cdr found) '())))

    (define (parse-workspace-package-defaults fields)
      (ensure-known-fields
        fields
        '(license repository repo homepage site documentation docs authors)
        (source-context 'workspace-package))
      (let ((license (field-ref fields 'license ""))
            (repository (field-ref fields 'repository (field-ref fields 'repo "")))
            (homepage (field-ref fields 'homepage (field-ref fields 'site "")))
            (documentation (field-ref fields 'documentation (field-ref fields 'docs "")))
            (authors (field-rest fields 'authors '())))
        (for-each
          (lambda (field)
            (unless (string? (cdr field))
              (manifest-error "workspace package metadata field must be a string" field)))
          `((license . ,license)
            (repository . ,repository)
            (homepage . ,homepage)
            (documentation . ,documentation)))
        (for-each
          (lambda (author)
            (unless (string? author)
              (manifest-error "workspace package authors entries must be strings" author)))
          authors)
        `((license . ,license)
          (repository . ,repository)
          (repo . ,repository)
          (homepage . ,homepage)
          (site . ,homepage)
          (documentation . ,documentation)
          (docs . ,documentation)
          (authors . ,authors))))

    (define (parse-workspace-dependencies forms)
      (map (lambda (dep) (parse-dependency dep 'runtime)) forms))

    (define-record-type <workspace-inheritance>
      (make-workspace-inheritance package-defaults dependency-defaults)
      workspace-inheritance?
      (package-defaults workspace-inheritance-package-defaults)
      (dependency-defaults workspace-inheritance-dependency-defaults))

    (define (parse-test-scripts tests)
      (for-each
        (lambda (path)
          (unless (string? path)
            (manifest-error "tests entries must be script paths" path)))
        tests)
      tests)

    (define (parse-benchmark-scripts benches)
      (for-each
        (lambda (path)
          (unless (string? path)
            (manifest-error "benches entries must be script paths" path)))
        benches)
      benches)

    (define (parse-examples examples)
      (map parse-example examples))

    (define (example-path-last-segment path)
      (let ((parts (filter non-empty-string? (string-split path #\/))))
        (if (null? parts) path (car (reverse parts)))))

    (define (example-path-name path)
      (let ((file (example-path-last-segment path)))
        (string->symbol
          (cond
            ((string-suffix? ".scm" file)
              (substring file 0 (- (string-length file) 4)))
            ((string-suffix? ".sps" file)
              (substring file 0 (- (string-length file) 4)))
            ((string-suffix? ".sld" file)
              (substring file 0 (- (string-length file) 4)))
            ((string-suffix? ".sls" file)
              (substring file 0 (- (string-length file) 4)))
            (else file)))))

    (define (parse-example example)
      (cond
        ((string? example)
          (cons (example-path-name example) example))
        ((and (pair? example)
            (symbol? (car example))
            (pair? (cdr example))
            (string? (cadr example))
            (null? (cddr example)))
          (cons (car example) (cadr example)))
        (else
          (manifest-error "example entries must be script paths or (name \"path\")" example))))

    (define (parse-scripts scripts)
      (map parse-script scripts))

    (define (parse-script script)
      (unless (and (pair? script)
               (symbol? (car script))
               (pair? (cdr script))
               (string? (cadr script))
               (null? (cddr script)))
        (manifest-error "script entries must be (name \"path\")" script))
      (cons (car script) (cadr script)))

    (define (parse-bins bins)
      (map parse-bin bins))

    (define (parse-bin bin)
      (unless (and (pair? bin)
               (symbol? (car bin))
               (pair? (cdr bin))
               (string? (cadr bin))
               (null? (cddr bin)))
        (manifest-error "bin entries must be (name \"source-relative-path\")" bin))
      (cons (car bin) (cadr bin)))

    (define (parse-build-hook hook)
      (unless (and (pair? hook) (symbol? (car hook)))
        (manifest-error "expected build hook form" hook))
      (case (car hook)
        ((scheme)
          (unless (and (pair? (cdr hook)) (string? (cadr hook)))
            (manifest-error "scheme build hook requires script path" hook))
          (let* ((clauses (cddr hook))
                 (watch (parse-build-hook-watch clauses))
                 (impl (parse-build-hook-scheme-impl clauses)))
            `((type . scheme)
              (path . ,(cadr hook))
              ,@(if impl `((scheme-impl . ,impl)) '())
              ,@(if (null? watch) '() `((rerun-on-change . ,watch))))))
        (else (manifest-error "unknown build hook type" (car hook)))))

    (define (parse-build-hook-scheme-impl clauses)
      (let loop ((items clauses))
        (cond
          ((null? items) #f)
          ((and (pair? (car items))
              (eq? (car (car items)) 'scheme-impl)
              (pair? (cdr (car items)))
              (symbol? (car (cdr (car items))))
              (null? (cdr (cdr (car items)))))
            (car (cdr (car items))))
          (else (loop (cdr items))))))

    (define (parse-build-hook-watch clauses)
      (let loop ((items clauses) (watch '()))
        (cond
          ((null? items) (reverse watch))
          ((and (pair? (car items))
              (memq (caar items) '(rerun-on-change watch)))
            (for-each
              (lambda (path)
                (unless (string? path)
                  (manifest-error "build hook rerun-on-change entries must be paths" (car items))))
              (cdar items))
            (loop (cdr items) (append (reverse (cdar items)) watch)))
          ((and (pair? (car items))
              (eq? (caar items) 'scheme-impl))
            (loop (cdr items) watch))
          (else
            (manifest-error "unknown build hook property" (car items))))))

    (define (parse-dependency form scope)
      (unless (and (pair? form) (symbol? (car form)))
        (manifest-error "expected dependency form" form))
      (case (car form)
        ((path)
          (let ((fields (cdr form)))
            (ensure-known-fields
              fields
              '(name path raw version registry features optional schemes implementations dialects targets profiles compile-modes)
              (source-context 'path-dependency))
            (let ((name (field-ref fields 'name #f))
                  (path (field-ref fields 'path #f))
                  (raw (field-ref fields 'raw #f))
                  (selectors (dependency-selectors fields)))
              (unless name (manifest-error "path dependency requires name" form))
              (unless (string? path) (manifest-error "path dependency requires string path" form))
              (unless (boolean? raw) (manifest-error "path dependency raw must be a boolean" form))
              (append
                `((type . path)
                  (scope . ,scope)
                  (name . ,(normalize-name name 'dependency-name))
                  (path . ,path)
                  (raw . ,raw))
                (dependency-publish-metadata fields form)
                selectors))))
        ((workspace)
          (let ((fields (cdr form)))
            (ensure-known-fields
              fields
              '(name version registry features optional schemes implementations dialects targets profiles compile-modes)
              (source-context 'workspace-dependency))
            (let ((name (field-ref fields 'name #f))
                  (selectors (dependency-selectors fields)))
              (unless name (manifest-error "workspace dependency requires name" form))
              (append
                `((type . workspace)
                  (scope . ,scope)
                  (name . ,(normalize-name name 'dependency-name)))
                (dependency-publish-metadata fields form)
                selectors))))
        ((git)
          (let ((fields (cdr form)))
            (ensure-known-fields
              fields
              '(name url rev subpath version registry features optional schemes implementations dialects targets profiles compile-modes)
              (source-context 'git-dependency))
            (let ((name (field-ref fields 'name #f))
                  (url (field-ref fields 'url #f))
                  (rev (field-ref fields 'rev #f))
                  (subpath (field-ref fields 'subpath #f))
                  (selectors (dependency-selectors fields)))
              (unless name (manifest-error "git dependency requires name" form))
              (unless (string? url) (manifest-error "git dependency requires string url" form))
              (unless (or (not subpath) (string? subpath))
                (manifest-error "git dependency subpath must be a string" form))
              (append
                `((type . git)
                  (scope . ,scope)
                  (name . ,(normalize-name name 'dependency-name))
                  (url . ,url)
                  (rev . ,rev)
                  (subpath . ,subpath))
                (dependency-publish-metadata fields form)
                selectors))))
        ((system)
          (let ((names (field-rest (cdr form) 'names #f)))
            (append
              `((type . system)
                (scope . ,scope)
                (names . ,(if names
                           names
                           (filter
                             (lambda (item)
                               (not (and (pair? item)
                                     (member (car item) '(schemes implementations dialects targets profiles compile-modes)))))
                             (cdr form)))))
              (dependency-selectors (cdr form)))))
        ((registry)
          (let ((fields (cdr form)))
            (ensure-known-fields
              fields
              '(name version registry features optional schemes implementations dialects targets profiles compile-modes)
              (source-context 'registry-dependency))
            (let ((name (field-ref fields 'name #f))
                  (version (field-ref fields 'version "*"))
                  (registry (field-ref fields 'registry #f))
                  (features (field-rest fields 'features '()))
                  (optional (field-ref fields 'optional #f))
                  (selectors (dependency-selectors fields)))
              (unless name (manifest-error "registry dependency requires name" form))
              (unless (string? version)
                (manifest-error "registry dependency version must be a string" form))
              (unless (semver-requirement? version)
                (manifest-error "registry dependency version must be a valid SemVer requirement" form))
              (unless (or (not registry) (string? registry))
                (manifest-error "registry dependency registry must be a string" form))
              (unless (boolean? optional)
                (manifest-error "registry dependency optional must be a boolean" form))
              (append
                `((type . registry)
                  (scope . ,scope)
                  (name . ,(normalize-name name 'dependency-name))
                  (version . ,version)
                  (registry . ,registry)
                  (features . ,features)
                  (optional . ,optional))
                selectors))))
        ((akku)
          (parse-akku-dependency
            form
            scope
            (source-context 'akku-dependency)
            dependency-selectors))
        (else (manifest-error "unknown dependency type" (car form)))))

    (define (dependency-publish-metadata fields form)
      (let ((version (field-ref fields 'version #f))
            (registry (field-ref fields 'registry #f))
            (features (field-rest fields 'features '()))
            (optional (field-ref fields 'optional #f)))
        (unless (or (not version) (string? version))
          (manifest-error "dependency publish version must be a string" form))
        (when (and version (not (semver-requirement? version)))
          (manifest-error "dependency publish version must be a valid SemVer requirement" form))
        (unless (or (not registry) (string? registry))
          (manifest-error "dependency publish registry must be a string" form))
        (unless (boolean? optional)
          (manifest-error "dependency publish optional must be a boolean" form))
        (append
          (if version `((version . ,version)) '())
          (if registry `((registry . ,registry)) '())
          (if (null? features) '() `((features . ,features)))
          (if optional `((optional . ,optional)) '()))))

    (define (dependency-selectors fields)
      (let ((schemes (append (field-rest fields 'schemes '())
                      (field-rest fields 'implementations '())))
            (dialects (field-rest fields 'dialects '()))
            (targets (field-rest fields 'targets '()))
            (profiles (field-rest fields 'profiles '()))
            (compile-modes (field-rest fields 'compile-modes '())))
        (append
          (if (null? schemes) '() `((schemes . ,schemes)))
          (if (null? dialects) '() `((dialects . ,dialects)))
          (if (null? targets) '() `((targets . ,targets)))
          (if (null? profiles) '() `((profiles . ,profiles)))
          (if (null? compile-modes) '() `((compile-modes . ,compile-modes))))))

    (define (parse-dependency-block exprs kind scope)
      (let ((block (find-form kind exprs)))
        (if block
          (map (lambda (dep) (parse-dependency dep scope)) (cdr block))
          '())))

    (define (parse-overrides exprs)
      (let ((block (find-form 'overrides exprs)))
        (if block
          (map (lambda (dep) (parse-dependency dep 'override)) (cdr block))
          '())))

    (define (parse-manifest-exprs path exprs)
      (set! current-manifest-path path)
      (let* ((version-form (find-form 'kons-version exprs))
             (package-form (find-form 'package exprs))
             (workspace-form (find-form 'workspace exprs)))
        (when version-form
          (manifest-error "kons-version is not a supported manifest form" version-form))
        (unless (or package-form workspace-form)
          (manifest-error "manifest is missing package or workspace form" path))
        `((path . ,path)
          ,@(if package-form `((package . ,(parse-package package-form))) '())
          ,@(if workspace-form `((workspace . ,(parse-workspace workspace-form))) '())
          (dependencies . ,(parse-dependency-block exprs 'dependencies 'runtime))
          (dev-dependencies . ,(parse-dependency-block exprs 'dev-dependencies 'dev))
          (overrides . ,(parse-overrides exprs)))))

    (define (parse-manifest path)
      (unless (file-exists? path)
        (manifest-error "manifest not found" path))
      (let ((manifest (parse-manifest/raw path)))
        (if (manifest-workspace? manifest)
          manifest
          (let ((workspace (containing-workspace-manifest path)))
            (if workspace
              (apply-workspace-inheritance workspace manifest)
              manifest)))))

    (define (parse-manifest/raw path)
      (parse-manifest-exprs path (read-all-exprs path)))

    (define (same-file-path? a b)
      (string=? (absolute-path a) (absolute-path b)))

    (define (workspace-member-root workspace member)
      (path-join (manifest-root workspace) member))

    (define (workspace-contains-manifest? workspace manifest-path)
      (let ((root (dirname manifest-path)))
        (let loop ((members (workspace-members workspace)))
          (cond
            ((null? members) #f)
            ((same-file-path? root (workspace-member-root workspace (car members))) #t)
            (else (loop (cdr members)))))))

    (define (containing-workspace-manifest manifest-path)
      (let* ((manifest-path (absolute-path manifest-path))
             (package-root (dirname manifest-path)))
        (let loop ((dir (dirname package-root)))
          (cond
            ((or (not dir) (string=? dir package-root)) #f)
            (else
              (let ((workspace-path (path-join dir "kons.scm"))
                    (parent (dirname dir)))
                (cond
                  ((string=? parent dir) #f)
                  ((not (file-exists? workspace-path))
                    (loop parent))
                  ((same-file-path? workspace-path manifest-path)
                    (loop parent))
                  (else
                    (let ((workspace (parse-manifest/raw workspace-path)))
                      (if (and (manifest-workspace? workspace)
                           (workspace-contains-manifest? workspace manifest-path))
                        workspace
                        (loop parent)))))))))))

    (define (alist-replace entries key value)
      (let loop ((items entries) (out '()) (done? #f))
        (cond
          ((null? items)
            (reverse (if done? out (cons (cons key value) out))))
          ((eq? (caar items) key)
            (loop (cdr items) (cons (cons key value) out) #t))
          (else (loop (cdr items) (cons (car items) out) done?)))))

    (define (alist-has-key? entries key)
      (and (assq key entries) #t))

    (define (string-field-empty? fields key)
      (string=? (alist-ref fields key "") ""))

    (define (inherit-string-field fields defaults key)
      (let ((value (alist-ref defaults key "")))
        (if (and (string-field-empty? fields key)
             (not (string=? value "")))
          (alist-replace fields key value)
          fields)))

    (define (inherit-authors-field fields defaults)
      (let ((authors (alist-ref defaults 'authors '())))
        (if (and (null? (alist-ref fields 'authors '()))
             (not (null? authors)))
          (alist-replace fields 'authors authors)
          fields)))

    (define inheritable-string-fields
      '(license repository repo homepage site documentation docs))

    (define (inherit-package-defaults package defaults)
      (let loop ((fields inheritable-string-fields) (pkg package))
        (if (null? fields)
          (inherit-authors-field pkg defaults)
          (loop (cdr fields) (inherit-string-field pkg defaults (car fields))))))

    (define (workspace-dependency-default-for dependency defaults)
      (let ((name (alist-ref dependency 'name '())))
        (let loop ((items defaults))
          (cond
            ((null? items) #f)
            ((equal? name (alist-ref (car items) 'name '())) (car items))
            (else (loop (cdr items)))))))

    (define (dependency-version-inheritable? dependency)
      (or (not (alist-has-key? dependency 'version))
        (string=? (alist-ref dependency 'version "") "*")))

    (define (inherit-dependency-field dependency defaults key)
      (let ((value (alist-ref defaults key #f)))
        (if (and value (not (alist-ref dependency key #f)))
          (alist-replace dependency key value)
          dependency)))

    (define (inherit-dependency-default dependency defaults)
      (let ((version (alist-ref defaults 'version #f)))
        (inherit-dependency-field
          (if (and version (dependency-version-inheritable? dependency))
            (alist-replace dependency 'version version)
            dependency)
          defaults
          'registry)))

    (define (inherit-dependency-defaults dependencies defaults)
      (map
        (lambda (dependency)
          (let ((matching-default (workspace-dependency-default-for dependency defaults)))
            (if matching-default
              (inherit-dependency-default dependency matching-default)
              dependency)))
        dependencies))

    (define (apply-workspace-inheritance workspace manifest)
      (let* ((inheritance
               (make-workspace-inheritance
                 (workspace-package-defaults workspace)
                 (workspace-dependencies workspace)))
             (package (alist-ref manifest 'package '()))
             (inherited-package
               (inherit-package-defaults
                 package
                 (workspace-inheritance-package-defaults inheritance)))
             (inherited-dependencies
               (inherit-dependency-defaults
                 (alist-ref manifest 'dependencies '())
                 (workspace-inheritance-dependency-defaults inheritance)))
             (inherited-dev-dependencies
               (inherit-dependency-defaults
                 (alist-ref manifest 'dev-dependencies '())
                 (workspace-inheritance-dependency-defaults inheritance))))
        (alist-replace
          (alist-replace
            (alist-replace manifest 'package inherited-package)
            'dependencies
            inherited-dependencies)
          'dev-dependencies
          inherited-dev-dependencies)))

    (define (alist-ref alist key default)
      (let ((found (assoc key alist)))
        (if found (cdr found) default)))

    (define (package-name manifest)
      (alist-ref (alist-ref manifest 'package '()) 'name '()))

    (define (package-version manifest)
      (alist-ref (alist-ref manifest 'package '()) 'version #f))

    (define (package-license manifest)
      (alist-ref (alist-ref manifest 'package '()) 'license ""))

    (define (package-description manifest)
      (alist-ref (alist-ref manifest 'package '()) 'description ""))

    (define (package-owner manifest)
      (alist-ref (alist-ref manifest 'package '()) 'owner ""))

    (define (package-keywords manifest)
      (alist-ref (alist-ref manifest 'package '()) 'keywords '()))

    (define (package-authors manifest)
      (alist-ref (alist-ref manifest 'package '()) 'authors '()))

    (define (package-documentation manifest)
      (alist-ref (alist-ref manifest 'package '()) 'documentation ""))

    (define (package-homepage manifest)
      (alist-ref (alist-ref manifest 'package '()) 'homepage ""))

    (define (package-readme manifest)
      (alist-ref (alist-ref manifest 'package '()) 'readme ""))

    (define (package-docs manifest)
      (alist-ref (alist-ref manifest 'package '()) 'docs (package-documentation manifest)))

    (define (package-site manifest)
      (alist-ref (alist-ref manifest 'package '()) 'site (package-homepage manifest)))

    (define (package-repository manifest)
      (alist-ref (alist-ref manifest 'package '()) 'repository ""))

    (define (package-repo manifest)
      (alist-ref (alist-ref manifest 'package '()) 'repo (package-repository manifest)))

    (define (package-source-path manifest)
      (alist-ref (alist-ref manifest 'package '()) 'source-path "src"))

    (define (package-discover-libraries? manifest)
      (alist-ref (alist-ref manifest 'package '()) 'discover-libraries #t))

    (define (package-features manifest)
      (alist-ref (alist-ref manifest 'package '()) 'features '()))

    (define (package-dialects manifest)
      (alist-ref (alist-ref manifest 'package '()) 'dialects '(r7rs)))

    (define (package-main manifest)
      (alist-ref (alist-ref manifest 'package '()) 'main "main.scm"))

    (define (package-tests manifest)
      (alist-ref (alist-ref manifest 'package '()) 'tests '()))

    (define (package-benches manifest)
      (alist-ref (alist-ref manifest 'package '()) 'benches '()))

    (define (package-examples manifest)
      (alist-ref (alist-ref manifest 'package '()) 'examples '()))

    (define (package-scripts manifest)
      (alist-ref (alist-ref manifest 'package '()) 'scripts '()))

    (define (package-bins manifest)
      (alist-ref (alist-ref manifest 'package '()) 'bins '()))

    (define (package-build-hooks manifest)
      (alist-ref (alist-ref manifest 'package '()) 'build-hooks '()))

    (define (manifest-workspace? manifest)
      (not (null? (alist-ref manifest 'workspace '()))))

    (define (workspace-members manifest)
      (alist-ref (alist-ref manifest 'workspace '()) 'members '()))

    (define (workspace-default-members manifest)
      (alist-ref (alist-ref manifest 'workspace '()) 'default-members '()))

    (define (workspace-package-defaults manifest)
      (alist-ref (alist-ref manifest 'workspace '()) 'package '()))

    (define (workspace-dependencies manifest)
      (alist-ref (alist-ref manifest 'workspace '()) 'dependencies '()))

    (define (manifest-root manifest)
      (dirname (alist-ref manifest 'path "kons.scm")))

    (define (manifest-source-root manifest)
      (path-join (manifest-root manifest) (package-source-path manifest)))))
