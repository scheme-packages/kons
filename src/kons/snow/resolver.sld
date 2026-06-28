(define-library (kons snow resolver)
  (export snow-package-name->resolver-name
    snow-dependency->resolver-requirement
    snow-packages->resolver-candidates
    resolve-snow-dependencies
    resolve-snow-dependencies/failure-details)
  (import (scheme base)
    (kons util)
    (kons names)
    (kons resolver)
    (kons dep shared)
    (kons snow format))

  (begin
    (define (snow-ref alist key default)
      (let ((found (assoc key alist)))
        (if found (cdr found) default)))

    (define (snow-package-name->resolver-name name)
      (cond
        ((list? name) `(snow list ,@name))
        (else (dependency-error "unsupported Snow package name" name))))

    (define (snow-dependency->resolver-requirement dep)
      `((name . ,(snow-package-name->resolver-name (snow-ref dep 'name '())))
        (version . ,(snow-ref dep 'version "*"))
        (registry . ,(snow-ref dep 'source "snow"))
        (kind . ,(snow-ref dep 'scope 'runtime))
        (optional . ,(snow-ref dep 'optional #f))
        (features . ())
        ,@(dependency-selector-fields dep)))

    (define (system-library-name? name)
      (and (pair? name) (eq? (car name) 'scheme)))

    (define (snow-library-dependency->requirement dep source)
      `((name . ,(snow-package-name->resolver-name dep))
        (version . "*")
        (registry . ,source)
        (kind . runtime)
        (optional . #f)
        (features . ())))

    (define (library-dependencies libraries source)
      (append-map
        (lambda (library)
          (map (lambda (dep)
                (snow-library-dependency->requirement dep source))
            (filter (lambda (dep) (not (system-library-name? dep)))
              (snow-library-depends library))))
        libraries))

    (define (name-known? name names)
      (let loop ((items names))
        (cond
          ((null? items) #f)
          ((equal? name (car items)) #t)
          (else (loop (cdr items))))))

    (define (package-aliases package)
      (let ((names (cons (snow-package-name package)
                     (map snow-library-name (snow-package-libraries package)))))
        (let loop ((items names) (out '()))
          (cond
            ((null? items) (reverse out))
            ((name-known? (car items) out) (loop (cdr items) out))
            (else (loop (cdr items) (cons (car items) out)))))))

    (define (snow-version->candidate package alias source)
      `((name . ,(snow-package-name->resolver-name alias))
        (snow-name . ,alias)
        (snow-package-name . ,(snow-package-name package))
        (version . ,(snow-package-version package))
        (registry . ,source)
        (type . snow)
        (dependencies . ,(library-dependencies (snow-package-libraries package) source))
        (feature-dependencies . ())
        (snow-url . ,(snow-package-url package))
        (snow-sha256 . ,(snow-package-sha256 package))
        (snow-size . ,(snow-package-size package))
        (snow-description . ,(snow-package-description package))))

    (define (snow-package->candidates package source)
      (map (lambda (alias)
            (snow-version->candidate package alias source))
        (package-aliases package)))

    (define (snow-packages->resolver-candidates packages . maybe-source)
      (let ((source (if (null? maybe-source) "snow" (car maybe-source))))
        (append-map (lambda (package)
                     (snow-package->candidates package source))
          packages)))

    (define (candidate-display-name candidate)
      (name->string (snow-ref candidate 'name '())))

    (define (candidate-name-known? name candidates)
      (let loop ((items candidates))
        (cond
          ((null? items) #f)
          ((string=? name (candidate-display-name (car items))) #t)
          (else (loop (cdr items))))))

    (define (internal-snow-name? name)
      (and (string? name)
        (string-prefix? "snow/list/" name)))

    (define (join-strings items sep)
      (cond
        ((null? items) "")
        ((null? (cdr items)) (car items))
        (else (string-append (car items) sep (join-strings (cdr items) sep)))))

    (define (internal-snow-name->user-name name)
      (if (internal-snow-name? name)
        (string-append
          "("
          (join-strings (string-split (substring name 10 (string-length name)) #\/) " ")
          ")")
        name))

    (define (snow-failure-details details candidates)
      (cond
        ((not details) #f)
        ((and (pair? details)
            (string? (car details))
            (string=? (car details) "no matching package version")
            (pair? (cdr details))
            (string? (cadr details))
            (not (candidate-name-known? (cadr details) candidates)))
          (list "unknown Snow package"
            (internal-snow-name->user-name (cadr details))
            '(diagnostic-code . "unknown-snow-package")))
        (else details)))

    (define (resolve-snow-dependencies/failure-details requirements candidates . maybe-preferred-refs)
      (let ((preferred-refs (if (null? maybe-preferred-refs) '() (car maybe-preferred-refs))))
        (snow-failure-details
          (resolve-dependencies/failure-details requirements candidates preferred-refs)
          candidates)))

    (define (resolve-snow-dependencies requirements candidates . maybe-preferred-refs)
      (let* ((preferred-refs (if (null? maybe-preferred-refs) '() (car maybe-preferred-refs)))
             (failure (resolve-snow-dependencies/failure-details requirements candidates preferred-refs)))
        (if failure
          (apply dependency-error
            (append failure
              (list '(diagnostic-code . "resolver-conflict"))))
          (resolve-dependencies requirements candidates preferred-refs))))))
