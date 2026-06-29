(define-library (kons actions status locked-dependencies)
  (export status-locked-dependencies-section)
  (import (scheme base)
    (kons lock)
    (kons dep registry)
    (kons dep akku)
    (kons dep snow))

  (begin
    (define (locked-registry-source-fields manifest entry)
      (let ((vendor-root (vendor-source-root manifest entry)))
        (if vendor-root
          `((source vendored)
            (source-path ,vendor-root))
          `((source registry)
            (source-path ,(locked-registry-entry-root entry))))))

    (define (locked-dependency-form manifest entry)
      (case (lock-entry-type entry)
        ((registry)
          `(dependency
            (scope ,(lock-entry-ref entry 'scope 'runtime))
            (type registry)
            (name ,(lock-entry-ref entry 'name '()))
            (version ,(lock-entry-ref entry 'version ""))
            (registry ,(lock-entry-ref entry 'registry "default"))
            ,@(locked-registry-source-fields manifest entry)))
        ((akku)
          `(dependency
            (scope ,(lock-entry-ref entry 'scope 'runtime))
            (type akku)
            (name ,(lock-entry-ref entry 'name '()))
            (version ,(lock-entry-ref entry 'version ""))
            (source ,(lock-entry-ref entry 'source "akku"))
            (source-url ,(lock-entry-ref entry 'source-url ""))
            (source-kind ,(lock-entry-ref entry 'source-kind 'unknown))
            (trust verified-index)
            (cache ,(if (akku-source-ready? entry) 'ready 'missing))
            (source-cache-path ,(lock-entry-ref entry 'source-cache-path ""))))
        ((snow)
          `(dependency
            (scope ,(lock-entry-ref entry 'scope 'runtime))
            (type snow)
            (name ,(lock-entry-ref entry 'name '()))
            (package-name ,(lock-entry-ref entry 'package-name '()))
            (version ,(lock-entry-ref entry 'version ""))
            (source ,(lock-entry-ref entry 'source "snow"))
            (source-url ,(lock-entry-ref entry 'source-url ""))
            (trust repository-checksum)
            (cache ,(if (snow-source-ready? entry) 'ready 'missing))
            (source-cache-path ,(lock-entry-ref entry 'source-cache-path ""))))
        (else
          `(dependency
            (scope ,(lock-entry-ref entry 'scope 'runtime))
            (type ,(lock-entry-type entry))
            (name ,(lock-entry-ref entry 'name '()))))))

    (define (status-locked-dependencies-section manifest lock)
      (if lock
        `((locked-dependencies
           ,@(map (lambda (entry)
                   (locked-dependency-form manifest entry))
              (lock-package-entries lock))))
        '()))))
