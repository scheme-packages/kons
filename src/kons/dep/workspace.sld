(define-library (kons dep workspace)
  (export workspace-dependency-source-root
    locked-workspace-entry-root
    workspace-lock-entry)
  (import (scheme base)
    (scheme file)
    (kons util)
    (kons manifest)
    (kons dep shared)
    (kons dep path))

  (begin
    (define (workspace-dependency-source-root root dep)
      (let* ((dep-root (ensure-path-dependency-root root dep))
             (dep-manifest-path (path-join dep-root "kons.scm")))
        (let ((dep-manifest (parse-manifest dep-manifest-path)))
          (path-join dep-root (package-source-path dep-manifest)))))

    (define (locked-workspace-entry-root entry)
      (lock-entry-ref entry 'path #f))

    (define (workspace-lock-entry manifest dep)
      (let ((dep-root (ensure-path-dependency-root (manifest-root manifest) dep)))
        (append
          `(package
            (scope ,(alist-ref dep 'scope 'runtime))
            (type workspace)
            (name ,(alist-ref dep 'name '()))
            (member ,(alist-ref dep 'member ""))
            (path ,(alist-ref dep 'path ""))
            (source-hash ,(path-content-hash dep-root)))
          (dependency-selector-fields dep))))))
