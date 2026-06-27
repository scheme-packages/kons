(define-library (kons actions tree-clean)
  (export package-libraries
          package-feature-names
          tree-dependency-from-live
          tree-dependency-from-lock-entry
          tree-edge-from-lock-entry
          matching-lock
          store-token-dir
          metadata-token-dir
          lock-entry-source-token
          lock-entry-source-kind
          gc-keep-dirs
          path-member?
          gc-kind-root
          clean-store-gc)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons compat files)
          (kons util)
          (kons manifest)
          (kons lock)
          (kons options)
          (kons dep registry)
          (kons dep akku)
          (kons actions paths)
          (kons actions lock-shared))

  (begin
(define (package-libraries manifest)
  (alist-ref (alist-ref manifest 'package '()) 'libraries '()))

(define (package-feature-names manifest)
  (map car (package-features manifest)))


(define (tree-dependency-from-live dep)
  (let ((type (alist-ref dep 'type #f)))
    (case type
      ((system)
       `(dependency
         (scope ,(alist-ref dep 'scope 'runtime))
         (type system)
         (names ,@(alist-ref dep 'names '()))))
      ((path)
       `(dependency
         (scope ,(alist-ref dep 'scope 'runtime))
         (type path)
         (name ,(alist-ref dep 'name '()))
         (path ,(alist-ref dep 'path ""))
         (raw ,(alist-ref dep 'raw #f))
         (parent-root ,(alist-ref dep 'parent-root #f))))
      ((workspace)
       `(dependency
         (scope ,(alist-ref dep 'scope 'runtime))
         (type workspace)
         (name ,(alist-ref dep 'name '()))
         (member ,(alist-ref dep 'member ""))
         (path ,(alist-ref dep 'path ""))
         (parent-root ,(alist-ref dep 'parent-root #f))))
      ((git)
       `(dependency
         (scope ,(alist-ref dep 'scope 'runtime))
         (type git)
         (name ,(alist-ref dep 'name '()))
         (url ,(alist-ref dep 'url ""))
         (rev ,(alist-ref dep 'rev #f))
         (subpath ,(alist-ref dep 'subpath #f))))
      ((akku)
       `(dependency
         (scope ,(alist-ref dep 'scope 'runtime))
         (type akku)
         (name ,(alist-ref dep 'name '()))
         (version ,(alist-ref dep 'version "*"))
         (source ,(alist-ref dep 'source "akku"))))
      (else
       `(dependency
         (scope ,(alist-ref dep 'scope 'runtime))
         (type ,type))))))

(define (tree-dependency-source-fields manifest entry)
  (if (eq? (lock-entry-type entry) 'registry)
      (let ((vendor-root (vendor-source-root manifest entry)))
        (if vendor-root
            `((source vendored)
              (source-path ,vendor-root))
            `((source registry)
              (source-path ,(locked-registry-entry-root entry)))))
      '()))

(define (tree-dependency-from-lock-entry entry . maybe-manifest)
  (cond
   ((and (pair? entry) (eq? (car entry) 'system))
    `(dependency
      (scope ,(lock-entry-ref entry 'scope 'runtime))
      (type system)
      (names ,@(lock-entry-rest entry 'names))
      ,@(maybe-rest-field 'schemes (lock-entry-rest entry 'schemes))
      ,@(maybe-rest-field 'targets (lock-entry-rest entry 'targets))
      ,@(maybe-rest-field 'profiles (lock-entry-rest entry 'profiles))
      ,@(maybe-rest-field 'compile-modes (lock-entry-rest entry 'compile-modes))))
   ((eq? (lock-entry-type entry) 'path)
    `(dependency
      (scope ,(lock-entry-ref entry 'scope 'runtime))
      (type path)
      (name ,(lock-entry-ref entry 'name '()))
      (path ,(lock-entry-ref entry 'path ""))
      (raw ,(lock-entry-ref entry 'raw #f))
      (source-hash ,(lock-entry-ref entry 'source-hash #f))
      ,@(maybe-rest-field 'schemes (lock-entry-rest entry 'schemes))
      ,@(maybe-rest-field 'targets (lock-entry-rest entry 'targets))
      ,@(maybe-rest-field 'profiles (lock-entry-rest entry 'profiles))
      ,@(maybe-rest-field 'compile-modes (lock-entry-rest entry 'compile-modes))))
   ((eq? (lock-entry-type entry) 'workspace)
    `(dependency
      (scope ,(lock-entry-ref entry 'scope 'runtime))
      (type workspace)
      (name ,(lock-entry-ref entry 'name '()))
      (member ,(lock-entry-ref entry 'member ""))
      (path ,(lock-entry-ref entry 'path ""))
      (source-hash ,(lock-entry-ref entry 'source-hash #f))
      ,@(maybe-rest-field 'schemes (lock-entry-rest entry 'schemes))
      ,@(maybe-rest-field 'targets (lock-entry-rest entry 'targets))
      ,@(maybe-rest-field 'profiles (lock-entry-rest entry 'profiles))
      ,@(maybe-rest-field 'compile-modes (lock-entry-rest entry 'compile-modes))))
   ((eq? (lock-entry-type entry) 'git)
    `(dependency
      (scope ,(lock-entry-ref entry 'scope 'runtime))
      (type git)
      (name ,(lock-entry-ref entry 'name '()))
      (url ,(lock-entry-ref entry 'url ""))
      (rev ,(lock-entry-ref entry 'rev #f))
      (subpath ,(lock-entry-ref entry 'subpath #f))
      (commit ,(lock-entry-ref entry 'commit #f))
      ,@(maybe-rest-field 'schemes (lock-entry-rest entry 'schemes))
      ,@(maybe-rest-field 'targets (lock-entry-rest entry 'targets))
      ,@(maybe-rest-field 'profiles (lock-entry-rest entry 'profiles))
      ,@(maybe-rest-field 'compile-modes (lock-entry-rest entry 'compile-modes))))
   ((eq? (lock-entry-type entry) 'registry)
    `(dependency
      (scope ,(lock-entry-ref entry 'scope 'runtime))
      (type registry)
      (name ,(lock-entry-ref entry 'name '()))
      (req ,(lock-entry-ref entry 'req "*"))
      (version ,(lock-entry-ref entry 'version ""))
      (registry ,(lock-entry-ref entry 'registry "default"))
      (checksum ,(lock-entry-ref entry 'checksum ""))
      (id ,(lock-entry-ref entry 'id ""))
      ,@(if (pair? maybe-manifest)
            (tree-dependency-source-fields (car maybe-manifest) entry)
            '())))
   ((eq? (lock-entry-type entry) 'akku)
    `(dependency
      (scope ,(lock-entry-ref entry 'scope 'runtime))
      (type akku)
      (name ,(lock-entry-ref entry 'name '()))
      (resolver-name ,(lock-entry-ref entry 'resolver-name '()))
      (req ,(lock-entry-ref entry 'req "*"))
      (version ,(lock-entry-ref entry 'version ""))
      (source ,(lock-entry-ref entry 'source "akku"))
      (source-url ,(lock-entry-ref entry 'source-url ""))
      (source-kind ,(lock-entry-ref entry 'source-kind 'unknown))
      (trust verified-index)
      (cache ,(if (akku-source-ready? entry) 'ready 'missing))
      (source-cache-path ,(lock-entry-ref entry 'source-cache-path ""))))
   (else
    `(dependency
      (scope ,(lock-entry-ref entry 'scope 'runtime))
      (type ,(lock-entry-type entry))))))

(define (tree-edge-from-lock-entry entry)
  `(edge
    (from ,(lock-entry-ref entry 'from 'root))
    (to ,(lock-entry-ref entry 'to ""))
    (name ,(lock-entry-ref entry 'name '()))
    (req ,(lock-entry-ref entry 'req "*"))
    (kind ,(lock-entry-ref entry 'kind 'runtime))))

(define (matching-lock manifest features cmd)
  (let ((path (command-lock-path manifest cmd)))
    (and (file-exists? path)
         (let ((lock (read-lockfile path)))
           (and (lock-root-matches? manifest features cmd lock)
                (if (or (command-flag? cmd "offline")
                        (command-flag? cmd "frozen"))
                    lock
                    (and (lock-resolution-current? manifest features cmd lock)
                         lock)))))))

	
(define (store-token-dir kind token)
  (path-join
   (path-join (path-join (kons-store-root) "sources") (symbol->string kind))
   (safe-store-token token)))

(define (metadata-token-dir kind token)
  (path-join
   (path-join (path-join (kons-store-root) "metadata") (symbol->string kind))
   (safe-store-token token)))

(define (lock-entry-source-token entry)
  (case (lock-entry-type entry)
    ((path) (lock-entry-ref entry 'source-hash #f))
    ((git) (lock-entry-ref entry 'commit #f))
    (else #f)))

(define (lock-entry-source-kind entry)
  (case (lock-entry-type entry)
    ((path git) (lock-entry-type entry))
    (else #f)))

(define (gc-keep-dirs lock)
  (let loop ((entries (lock-package-entries lock)) (out '()))
    (cond
     ((null? entries) out)
     (else
      (let ((kind (lock-entry-source-kind (car entries)))
            (token (lock-entry-source-token (car entries))))
        (if (and kind token)
            (loop (cdr entries)
                  (cons (metadata-token-dir kind token)
                        (cons (store-token-dir kind token) out)))
            (loop (cdr entries) out)))))))

(define (path-member? path paths)
  (let loop ((items paths))
    (cond
     ((null? items) #f)
     ((equal? path (car items)) #t)
     (else (loop (cdr items))))))

(define (gc-kind-root root keep)
  (when (file-exists? root)
    (for-each
     (lambda (entry)
       (let ((path (path-join root entry)))
         (unless (path-member? path keep)
           (run-command (string-append "rm -rf " (shell-quote path))))))
     (directory-list root))))

(define (clean-store-gc manifest cmd)
  (let ((lock-path (command-lock-path manifest cmd)))
  (unless (file-exists? lock-path)
    (lockfile-error "store garbage collection requires kons.lock"))
  (let* ((lock (read-lockfile lock-path))
         (keep (gc-keep-dirs lock)))
    (for-each
     (lambda (kind)
       (gc-kind-root (path-join (path-join (kons-store-root) "sources") kind) keep)
       (gc-kind-root (path-join (path-join (kons-store-root) "metadata") kind) keep))
     '("path" "git"))
    (displayln "cleaned unreferenced store artifacts"))))

  ))
