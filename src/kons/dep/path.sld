(define-library (kons dep path)
  (export path-dependency-root
    ensure-path-dependency-root
    path-dependency-source-root
    locked-path-entry-root
    materialize-path-dependency
    materialize-locked-path-entry
    path-lock-entry)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons util)
    (kons names)
    (kons manifest)
    (kons dep shared)
    (kons dep store))

  (begin
    (define (path-dependency-root root dep)
      (let ((path (alist-ref dep 'path ""))
            (origin-root (alist-ref dep 'parent-root root)))
        (if (absolute-path? path) path (path-join origin-root path))))

    (define (ensure-path-dependency-root root dep)
      (let* ((dep-root (path-dependency-root root dep))
             (manifest-path (path-join dep-root "kons.scm")))
        (unless (file-exists? dep-root)
          (dependency-error
            "path dependency root not found"
            (alist-ref dep 'name '())
            (alist-ref dep 'path "")
            dep-root))
        (unless (or (alist-ref dep 'raw #f)
                 (file-exists? manifest-path))
          (dependency-error
            "path dependency manifest not found"
            (alist-ref dep 'name '())
            manifest-path))
        dep-root))

    (define (path-dependency-source-root root dep)
      (let* ((dep-root (ensure-path-dependency-root root dep))
             (dep-manifest-path (path-join dep-root "kons.scm"))
             (raw? (alist-ref dep 'raw #f)))
        (if raw?
          dep-root
          (let ((dep-manifest (parse-manifest dep-manifest-path)))
            (path-join dep-root (package-source-path dep-manifest))))))

    (define (locked-path-entry-root entry)
      (let* ((hash (lock-entry-ref entry 'source-hash ""))
             (name-token (safe-store-token (name->string (lock-entry-ref entry 'name '(dependency)))))
             (store-root (path-join (path-join (kons-store-root) "sources/path") (safe-store-token hash))))
        (path-join store-root name-token)))

    (define (materialize-path-dependency manifest dep)
      (let* ((root (manifest-root manifest))
             (dep-root (ensure-path-dependency-root root dep))
             (hash (path-content-hash dep-root))
             (token (safe-store-token hash))
             (name-token (safe-store-token (name->string (alist-ref dep 'name '(dependency)))))
             (store-root (path-join (path-join (kons-store-root) "sources/path") token))
             (dest (path-join store-root name-token)))
        (run-command (string-append "mkdir -p " (shell-quote store-root)))
        (unless (file-exists? dest)
          (run-command
            (string-append "cp -R " (shell-quote dep-root) " " (shell-quote dest))))
        (write-store-metadata
          'path
          hash
          name-token
          `(store-entry
            (type path)
            (name ,(alist-ref dep 'name '()))
            (raw ,(alist-ref dep 'raw #f))
            (source ,dep-root)
            (source-hash ,hash)
            (root ,dest)))
        dest))

    (define (materialize-locked-path-entry manifest entry)
      (let* ((root (manifest-root manifest))
             (path (lock-entry-ref entry 'path ""))
             (dep-root (if (absolute-path? path) path (path-join root path)))
             (hash (lock-entry-ref entry 'source-hash ""))
             (dest (locked-path-entry-root entry))
             (store-root (dirname dest)))
        (if (file-exists? dest)
          dest
          (begin
            (unless (file-exists? dep-root)
              (dependency-error "locked path dependency source is missing" dep-root))
            (unless (equal? (path-content-hash dep-root) hash)
              (lockfile-error "locked path dependency source hash does not match lockfile" dep-root))
            (run-command (string-append "mkdir -p " (shell-quote store-root)))
            (run-command
              (string-append "cp -R " (shell-quote dep-root) " " (shell-quote dest)))
            (write-store-metadata
              'path
              hash
              (safe-store-token (name->string (lock-entry-ref entry 'name '(dependency))))
              `(store-entry
                (type path)
                (name ,(lock-entry-ref entry 'name '()))
                (raw ,(lock-entry-ref entry 'raw #f))
                (source ,dep-root)
                (source-hash ,hash)
                (root ,dest)))
            dest))))

    (define (path-lock-entry manifest dep)
      (let ((dep-root (ensure-path-dependency-root (manifest-root manifest) dep)))
        (append
          `(package
            (scope ,(alist-ref dep 'scope 'runtime))
            (type path)
            (name ,(alist-ref dep 'name '()))
            (path ,(alist-ref dep 'path ""))
            (raw ,(alist-ref dep 'raw #f))
            (source-hash ,(path-content-hash dep-root)))
          (dependency-selector-fields dep))))))
