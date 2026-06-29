(define-library (kons actions activation generated)
  (export r7rs-build-helper-library
    r6rs-build-helper-library)
  (import (scheme base))

  (begin
    (define (r7rs-build-helper-library)
      '(define-library (kons build)
        (export build-root source-root package-root out-dir arg-value
         arg-values
         target-scheme
         hook-scheme
         profile
         target
         package-name
         package-version
         features
         active-features
         feature-enabled?
         dialects
         dialect-enabled?
         r6rs?
         library-source-path
         write-library
         emit
         rerun-on-change
         add-load-path
         add-library-path
         add-ld-library-path
         add-dyld-library-path
         add-dlopen-path
         add-ld-preload
         add-ld-preload-path
         set-runtime-env
         add-runtime-env-path
         link-search
         link-lib
         output
         metadata)
        (import (scheme base)
         (scheme cxr)
         (only (scheme process-context) command-line)
         (scheme write))
        (begin
         (define (arg-value name default)
          (let loop ((items (command-line)))
           (cond
            ((null? items) default)
            ((and (pair? (cdr items)) (string=? (car items) name))
             (cadr items))
            (else (loop (cdr items))))))
         (define (arg-values name)
          (let loop ((items (command-line)) (out '()))
           (cond
            ((null? items) (reverse out))
            ((and (pair? (cdr items)) (string=? (car items) name))
             (loop (cddr items) (cons (cadr items) out)))
            (else (loop (cdr items) out)))))
         (define build-root (arg-value "--kons-build-root" (cadr (command-line))))
         (define source-root (arg-value "--kons-source-root" (caddr (command-line))))
         (define package-root (arg-value "--kons-package-root" source-root))
         (define out-dir (arg-value "--kons-out-dir" build-root))
         (define target-scheme (string->symbol (arg-value "--kons-target-scheme" "")))
         (define hook-scheme (string->symbol (arg-value "--kons-hook-scheme" "")))
         (define profile (string->symbol (arg-value "--kons-profile" "")))
         (define target (arg-value "--kons-target" ""))
         (define package-name (arg-value "--kons-package-name" ""))
         (define package-version (arg-value "--kons-package-version" ""))
         (define active-features (map string->symbol (arg-values "--kons-feature")))
         (define features active-features)
         (define (feature-enabled? feature)
          (and (memq feature active-features) #t))
         (define dialects (map string->symbol (arg-values "--kons-dialect")))
         (define (dialect-enabled? dialect)
          (and (memq dialect dialects) #t))
         (define r6rs? (dialect-enabled? 'r6rs))
         (define (path-join a b)
          (if (or (string=? a "") (string=? a "."))
           b
           (string-append a "/" b)))
         (define (library-name-part->string part)
          (if (symbol? part) (symbol->string part) part))
         (define (library-source-path name)
          (let loop ((parts name) (dir out-dir))
           (cond
            ((null? parts) dir)
            ((null? (cdr parts))
             (path-join dir
              (string-append
               (library-name-part->string (car parts))
               (if r6rs? ".sls" ".sld"))))
            (else
             (loop (cdr parts)
              (path-join dir (library-name-part->string (car parts))))))))
         (define (write-library name expr)
          (emit 'kons::library name expr)
          (add-library-path out-dir)
          (library-source-path name))
         (define (emit name . values)
          (write (cons name values))
          (newline))
         (define (rerun-on-change . paths)
          (apply emit 'kons::rerun-on-change paths))
         (define (add-load-path . paths)
          (apply emit 'kons::load-path paths))
         (define (add-library-path . paths)
          (apply emit 'kons::library-path paths))
         (define (add-ld-library-path . paths)
          (apply emit 'kons::ld-library-path paths))
         (define (add-dyld-library-path . paths)
          (apply emit 'kons::dyld-library-path paths))
         (define (add-dlopen-path . paths)
          (apply emit 'kons::dlopen-path paths))
         (define (add-ld-preload . paths)
          (apply emit 'kons::ld-preload paths))
         (define (add-ld-preload-path . paths)
          (apply emit 'kons::ld-preload-path paths))
         (define (set-runtime-env name value)
          (emit 'kons::env name value))
         (define (add-runtime-env-path name . paths)
          (apply emit 'kons::env-path name paths))
         (define (link-search . paths)
          (apply emit 'kons::link-search paths))
         (define (link-lib . libs)
          (apply emit 'kons::link-lib libs))
         (define (output key value)
          (emit 'kons::output key value))
         (define (metadata key value)
          (emit 'kons::metadata key value)))))

    (define (r6rs-build-helper-library)
      '(library (kons build)
        (export build-root source-root package-root out-dir arg-value
         arg-values
         target-scheme
         hook-scheme
         profile
         target
         package-name
         package-version
         features
         feature-enabled?
         dialects
         dialect-enabled?
         r6rs?
         library-source-path
         write-library
         emit
         rerun-on-change
         add-load-path
         add-library-path
         add-ld-library-path
         add-dyld-library-path
         add-dlopen-path
         add-ld-preload
         add-ld-preload-path
         set-runtime-env
         add-runtime-env-path
         link-search
         link-lib
         output
         metadata)
        (import (rnrs)
         (rnrs programs))
        (define (arg-value name default)
         (let loop ((items (command-line)))
          (cond
           ((null? items) default)
           ((and (pair? (cdr items)) (string=? (car items) name))
            (cadr items))
           (else (loop (cdr items))))))
        (define (arg-values name)
         (let loop ((items (command-line)) (out '()))
          (cond
           ((null? items) (reverse out))
           ((and (pair? (cdr items)) (string=? (car items) name))
            (loop (cddr items) (cons (cadr items) out)))
           (else (loop (cdr items) out)))))
        (define build-root (arg-value "--kons-build-root" (cadr (command-line))))
        (define source-root (arg-value "--kons-source-root" (caddr (command-line))))
        (define package-root (arg-value "--kons-package-root" source-root))
        (define out-dir (arg-value "--kons-out-dir" build-root))
        (define target-scheme (string->symbol (arg-value "--kons-target-scheme" "")))
        (define hook-scheme (string->symbol (arg-value "--kons-hook-scheme" "")))
        (define profile (string->symbol (arg-value "--kons-profile" "")))
        (define target (arg-value "--kons-target" ""))
        (define package-name (arg-value "--kons-package-name" ""))
        (define package-version (arg-value "--kons-package-version" ""))
        (define features (map string->symbol (arg-values "--kons-feature")))
        (define (feature-enabled? feature)
         (and (memq feature features) #t))
        (define dialects (map string->symbol (arg-values "--kons-dialect")))
        (define (dialect-enabled? dialect)
         (and (memq dialect dialects) #t))
        (define r6rs? (dialect-enabled? 'r6rs))
        (define (path-join a b)
         (if (or (string=? a "") (string=? a "."))
          b
          (string-append a "/" b)))
        (define (library-name-part->string part)
         (if (symbol? part) (symbol->string part) part))
        (define (library-source-path name)
         (let loop ((parts name) (dir out-dir))
          (cond
           ((null? parts) dir)
           ((null? (cdr parts))
            (path-join dir
             (string-append
              (library-name-part->string (car parts))
              (if r6rs? ".sls" ".sld"))))
           (else
            (loop (cdr parts)
             (path-join dir (library-name-part->string (car parts))))))))
        (define (write-library name expr)
         (emit 'kons::library name expr)
         (add-library-path out-dir)
         (library-source-path name))
        (define (emit name . values)
         (write (cons name values))
         (newline))
        (define (rerun-on-change . paths)
         (apply emit 'kons::rerun-on-change paths))
        (define (add-load-path . paths)
         (apply emit 'kons::load-path paths))
        (define (add-library-path . paths)
         (apply emit 'kons::library-path paths))
        (define (add-ld-library-path . paths)
         (apply emit 'kons::ld-library-path paths))
        (define (add-dyld-library-path . paths)
         (apply emit 'kons::dyld-library-path paths))
        (define (add-dlopen-path . paths)
         (apply emit 'kons::dlopen-path paths))
        (define (add-ld-preload . paths)
         (apply emit 'kons::ld-preload paths))
        (define (add-ld-preload-path . paths)
         (apply emit 'kons::ld-preload-path paths))
        (define (set-runtime-env name value)
         (emit 'kons::env name value))
        (define (add-runtime-env-path name . paths)
         (apply emit 'kons::env-path name paths))
        (define (link-search . paths)
         (apply emit 'kons::link-search paths))
        (define (link-lib . libs)
         (apply emit 'kons::link-lib libs))
        (define (output key value)
         (emit 'kons::output key value))
        (define (metadata key value)
         (emit 'kons::metadata key value))))))
