(define-library (kons akku resolver)
  (export akku-package-name->resolver-name
    akku-dependency->resolver-requirement
    akku-packages->resolver-candidates
    resolve-akku-dependencies
    resolve-akku-dependencies/failure-details)
  (import (scheme base)
    (kons util)
    (kons names)
    (kons resolver)
    (kons dep shared)
    (kons akku format))

  (begin
    (define (akku-ref alist key default)
      (let ((found (assoc key alist)))
        (if found (cdr found) default)))

    (define (akku-package-name->resolver-name name)
      (cond
        ((string? name) `(akku string ,name))
        ((symbol? name) `(akku string ,(symbol->string name)))
        ((list? name) `(akku list ,@name))
        (else (dependency-error "unsupported Akku package name" name))))

    (define (akku-dependency-name dep)
      (if (and (pair? dep) (not (eq? (car dep) 'or)))
        (car dep)
        (dependency-error "Akku dependency alternatives are not supported by Kons resolver" dep)))

    (define (dep-field-one fields key)
      (let loop ((items fields))
        (cond
          ((null? items) #f)
          ((and (pair? (car items))
              (eq? (car (car items)) key)
              (pair? (cdr (car items)))
              (null? (cdr (cdr (car items)))))
            (car (cdr (car items))))
          (else (loop (cdr items))))))

    (define (akku-dependency-range dep)
      (cond
        ((and (pair? (cdr dep)) (string? (cadr dep)))
          (cadr dep))
        ((and (pair? (cdr dep))
            (let loop ((items (cdr dep)))
              (or (null? items)
                (and (pair? (car items))
                  (symbol? (caar items))
                  (loop (cdr items))))))
          (let ((version (dep-field-one (cdr dep) 'version)))
            (if version
              version
              (dependency-error "Akku dependency requires a version range" dep))))
        (else
          (dependency-error "malformed Akku dependency" dep))))

    (define (akku-range->resolver-range range)
      (unless (semver-requirement? range)
        (dependency-error "Akku dependency version must be a valid SemVer requirement" range))
      range)

    (define (akku-dependency->requirement dep source kind)
      `((name . ,(akku-package-name->resolver-name (akku-dependency-name dep)))
        (version . ,(akku-range->resolver-range (akku-dependency-range dep)))
        (registry . ,source)
        (kind . ,kind)
        (optional . #f)
        (features . ())))

    (define (akku-dependency->resolver-requirement dep)
      `((name . ,(akku-package-name->resolver-name (akku-ref dep 'name "")))
        (version . ,(akku-range->resolver-range (akku-ref dep 'version "*")))
        (registry . ,(akku-ref dep 'source "akku"))
        (kind . ,(akku-ref dep 'scope 'runtime))
        (optional . ,(akku-ref dep 'optional #f))
        (features . ())
        ,@(dependency-selector-fields dep)))

    (define (akku-version->candidate package version source)
      `((name . ,(akku-package-name->resolver-name (akku-package-name package)))
        (akku-name . ,(akku-package-name package))
        (version . ,(akku-version-number version))
        (registry . ,source)
        (type . akku)
        (dependencies . ,(map (lambda (dep)
                               (akku-dependency->requirement dep source 'runtime))
                          (akku-version-depends version)))
        (feature-dependencies . ())
        (akku-depends . ,(akku-version-depends version))
        (akku-depends/dev . ,(akku-version-depends/dev version))
        (akku-conflicts . ,(akku-version-conflicts version))
        (akku-lock . ,(akku-version-lock version))
        (akku-source . ,(akku-version-source version))
        (install . ,(akku-ref (akku-version-properties version) 'install '()))))

    (define (akku-package->candidates package source)
      (map (lambda (version)
            (akku-version->candidate package version source))
        (akku-package-versions package)))

    (define (akku-packages->resolver-candidates packages . maybe-source)
      (let ((source (if (null? maybe-source) "akku" (car maybe-source))))
        (append-map (lambda (package)
                     (akku-package->candidates package source))
          packages)))

    (define (same-resolved-name? candidate req)
      (and (equal? (akku-ref candidate 'name '())
            (akku-ref req 'name '()))
        (string=? (akku-ref candidate 'registry "akku")
          (akku-ref req 'registry "akku"))))

    (define (selected-candidate-for req selected)
      (let loop ((items selected))
        (cond
          ((null? items) #f)
          ((same-resolved-name? (car items) req) (car items))
          (else (loop (cdr items))))))

    (define (requirement-satisfied-by-candidate? req candidate)
      (not (resolve-dependencies/failure-details (list req) (list candidate))))

    (define (conflict-detail source candidate req other)
      `((reason . akku-conflict)
        (package . ,(akku-ref candidate 'akku-name '()))
        (version . ,(akku-ref candidate 'version ""))
        (conflicts-with . ,(akku-ref other 'akku-name '()))
        (conflicting-version . ,(akku-ref other 'version ""))
        (range . ,(akku-ref req 'version "*"))
        (source . ,source)))

    (define (candidate-conflict-details candidate selected)
      (let ((source (akku-ref candidate 'registry "akku")))
        (let loop ((conflicts (akku-ref candidate 'akku-conflicts '())))
          (cond
            ((null? conflicts) #f)
            (else
              (let* ((req (akku-dependency->requirement (car conflicts) source 'conflict))
                     (other (selected-candidate-for req selected)))
                (if (and other (requirement-satisfied-by-candidate? req other))
                  (list "Akku package conflict"
                    (name->string (akku-ref candidate 'name '()))
                    (conflict-detail source candidate req other))
                  (loop (cdr conflicts)))))))))

    (define (first-akku-conflict resolution)
      (let ((selected (resolution-packages resolution)))
        (let loop ((items selected))
          (cond
            ((null? items) #f)
            (else
              (let ((details (candidate-conflict-details (car items) selected)))
                (or details (loop (cdr items)))))))))

    (define (resolve-akku-dependencies/failure-details requirements candidates . maybe-preferred-refs)
      (let ((preferred-refs (if (null? maybe-preferred-refs) '() (car maybe-preferred-refs))))
        (or (akku-failure-details
             (resolve-dependencies/failure-details requirements candidates preferred-refs)
             candidates)
          (first-akku-conflict
            (resolve-dependencies requirements candidates preferred-refs)))))

    (define (candidate-display-name candidate)
      (name->string (akku-ref candidate 'name '())))

    (define (candidate-name-known? name candidates)
      (let loop ((items candidates))
        (cond
          ((null? items) #f)
          ((string=? name (candidate-display-name (car items))) #t)
          (else (loop (cdr items))))))

    (define (internal-akku-name? name)
      (and (string? name)
        (or (string-prefix? "akku/string/" name)
          (string-prefix? "akku/list/" name))))

    (define (internal-akku-name->user-name name)
      (cond
        ((string-prefix? "akku/string/" name)
          (substring name 12 (string-length name)))
        ((string-prefix? "akku/list/" name)
          (string-append
            "("
            (string-join (string-split (substring name 10 (string-length name)) #\/) " ")
            ")"))
        (else name)))

    (define (akku-failure-details details candidates)
      (cond
        ((not details) #f)
        ((and (pair? details)
            (string? (car details))
            (string=? (car details) "no matching package version")
            (pair? (cdr details))
            (string? (cadr details))
            (not (candidate-name-known? (cadr details) candidates)))
          (list "unknown Akku package"
            (internal-akku-name->user-name (cadr details))
            '(diagnostic-code . "unknown-akku-package")))
        (else details)))

    (define (resolve-akku-dependencies requirements candidates . maybe-preferred-refs)
      (let* ((preferred-refs (if (null? maybe-preferred-refs) '() (car maybe-preferred-refs)))
             (failure (akku-failure-details
                       (resolve-dependencies/failure-details
                         requirements
                         candidates
                         preferred-refs)
                       candidates)))
        (if failure
          (apply dependency-error
            (append failure
              (list '(diagnostic-code . "resolver-conflict"))))
          (let* ((resolution (resolve-dependencies requirements candidates preferred-refs))
                 (conflict (first-akku-conflict resolution)))
            (if conflict
              (apply dependency-error
                (append conflict
                  (list '(diagnostic-code . "akku-conflict"))))
              resolution)))))))
