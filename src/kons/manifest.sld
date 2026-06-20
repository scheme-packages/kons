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
          package-scripts
          package-bins
          package-build-hooks
          manifest-workspace?
          workspace-members
          manifest-root
          manifest-source-root)
  (import (scheme base)
          (scheme file)
          (kons util))

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
     '(name version owner license description keywords authors documentation docs homepage site readme repository repo dialects source-path discover-libraries libraries main tests benches scripts bins features build-hooks)
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

(define (parse-workspace form)
  (let ((fields (cdr form)))
    (ensure-known-fields fields '(members) (source-context 'workspace))
    (let ((members (field-rest fields 'members '())))
      (for-each
       (lambda (member)
         (unless (string? member)
           (manifest-error "workspace members must be package directories" member)))
       members)
      `((members . ,members)))))

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
        '(name path raw version registry features optional schemes implementations targets)
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
        '(name version registry features optional schemes implementations targets)
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
        '(name url rev subpath version registry features optional schemes implementations targets)
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
                                     (member (car item) '(schemes implementations targets)))))
                         (cdr form)))))
        (dependency-selectors (cdr form)))))
    ((registry)
     (let ((fields (cdr form)))
       (ensure-known-fields
        fields
        '(name version registry features optional schemes implementations targets)
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
        (targets (field-rest fields 'targets '())))
    (append
     (if (null? schemes) '() `((schemes . ,schemes)))
     (if (null? targets) '() `((targets . ,targets))))))

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
  (parse-manifest-exprs path (read-all-exprs path)))

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

(define (manifest-root manifest)
  (dirname (alist-ref manifest 'path "kons.scm")))

(define (manifest-source-root manifest)
  (path-join (manifest-root manifest) (package-source-path manifest)))
  ))
