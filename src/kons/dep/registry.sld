(define-library (kons dep registry)
  (export registry-dependency-version
          registry-dependency-registry
          registry-dependency-features
          registry-dependency-source-root
          locked-registry-entry-root
          materialize-registry-dependency
          materialize-locked-registry-entry
          registry-lock-entry)
  (import (scheme base)
          (scheme write)
          (kons util)
          (kons names)
          (kons manifest)
          (kons registry)
          (kons dep shared))

  (begin
(define (registry-dependency-version dep)
  (alist-ref dep 'version "*"))

(define (registry-dependency-registry dep)
  (alist-ref dep 'registry #f))

(define (registry-dependency-features dep)
  (alist-ref dep 'features '()))

(define (registry-dependency-source-root dep)
  (let* ((resolved (resolve-registry-version dep))
         (registry (alist-ref resolved 'registry default-registry-alias))
         (name (name->string (alist-ref dep 'name '())))
         (version (alist-ref resolved 'version ""))
         (checksum (alist-ref resolved 'checksum "")))
    (registry-package-source-root registry name version checksum)))

(define (locked-registry-entry-root entry)
  (registry-package-root
   (lock-entry-ref entry 'registry default-registry-alias)
   (name->string (lock-entry-ref entry 'name '()))
   (lock-entry-ref entry 'version "")
   (lock-entry-ref entry 'checksum "")))

(define (materialize-registry-dependency manifest dep offline?)
  (let* ((resolved (resolve-registry-version dep))
         (registry (alist-ref resolved 'registry default-registry-alias))
         (name (name->string (alist-ref dep 'name '())))
         (version (alist-ref resolved 'version ""))
         (checksum (alist-ref resolved 'checksum ""))
         (download (alist-ref resolved 'download "")))
    (download-registry-package! registry name version checksum download offline?)))

(define (materialize-locked-registry-entry manifest entry offline?)
  (download-registry-package!
   (lock-entry-ref entry 'registry default-registry-alias)
   (name->string (lock-entry-ref entry 'name '()))
   (lock-entry-ref entry 'version "")
   (lock-entry-ref entry 'checksum "")
   (lock-entry-ref entry 'download "")
   offline?))

(define (registry-lock-entry manifest dep)
  (let* ((resolved (resolve-registry-version dep))
         (registry (alist-ref resolved 'registry default-registry-alias))
         (name (alist-ref dep 'name '()))
         (version (alist-ref resolved 'version ""))
         (checksum (alist-ref resolved 'checksum ""))
         (download (alist-ref resolved 'download "")))
    (append
     `(package
       (scope ,(alist-ref dep 'scope 'runtime))
       (type registry)
       (name ,name)
       (req ,(registry-dependency-version dep))
       (version ,version)
       (registry ,registry)
       (checksum ,checksum)
       (download ,download)
       (optional ,(alist-ref dep 'optional #f))
       (features ,@(registry-dependency-features dep)))
     (dependency-selector-fields dep))))

  ))
