(define-library (kons dep registry)
  (export registry-dependency-version
          registry-dependency-registry
          registry-dependency-features
          registry-dependency-source-root
          vendor-source-root
          locked-registry-entry-root
          materialize-registry-dependency
          materialize-locked-registry-entry
          registry-lock-entry)
  (import (scheme base)
          (scheme file)
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

(define (locked-entry-ref entry key default)
  (let ((found (and (pair? entry) (assq key (cdr entry)))))
    (if found (cadr found) default)))

(define (default-vendor-metadata-path manifest)
  (path-join (path-join (manifest-root manifest) "vendor/kons") "kons-vendor.scm"))

(define (vendor-pointer-path manifest)
  (path-join (manifest-root manifest) "kons-vendor.scm"))

(define (source-replacements-path)
  (path-join (path-join (kons-home) "config") "source-replacements.scm"))

(define (vendor-entry-field entry key default)
  (field-ref (cdr entry) key default))

(define (vendor-package-matches? vendor-entry entry)
  (and (pair? vendor-entry)
       (eq? (car vendor-entry) 'package)
       (equal? (vendor-entry-field vendor-entry 'name '())
               (locked-entry-ref entry 'name '()))
       (string=? (vendor-entry-field vendor-entry 'version "")
                 (locked-entry-ref entry 'version ""))
       (string=? (vendor-entry-field vendor-entry 'registry default-registry-alias)
                 (locked-entry-ref entry 'registry default-registry-alias))
       (string=? (vendor-entry-field vendor-entry 'checksum "")
                 (locked-entry-ref entry 'checksum ""))))

(define (vendor-source-content-hash path)
  (capture-first-line
   (string-append
    "cd " (shell-quote path)
    " && find . -type f -not -path './.git/*' -print | LC_ALL=C sort | xargs cksum | cksum")))

(define (vendor-package-source-valid? vendor-entry path)
  (let ((expected (vendor-entry-field vendor-entry 'source-hash #f)))
    (cond
     ((not expected)
      (dependency-error "vendor metadata is missing source-hash; rerun `kons vendor --sync`" path))
     ((not (file-exists? path))
      #f)
     ((string=? expected (vendor-source-content-hash path))
      #t)
     (else
      (dependency-error "vendored source hash does not match metadata; rerun `kons vendor --sync`" path)))))

(define (vendor-package-archive-valid? vendor-entry entry path)
  (let* ((archive-name (vendor-entry-field vendor-entry 'archive ".kons-archive"))
         (archive-path (path-join path archive-name))
         (expected (locked-entry-ref entry 'checksum "")))
    (cond
     ((string=? archive-name "")
      (dependency-error "vendor metadata is missing archive; rerun `kons vendor --sync`" path))
     ((not (file-exists? archive-path))
      (dependency-error "vendored archive is missing; rerun `kons vendor --sync`" archive-path))
     ((string=? (capture-first-line
                 (string-append "sha256sum " (shell-quote archive-path) " | awk '{print $1}'"))
                expected)
      #t)
     (else
      (dependency-error "vendored archive checksum does not match lockfile; rerun `kons vendor --sync`" archive-path)))))

(define (vendor-packages metadata)
  (let ((packages (assq 'packages (cdr metadata))))
    (if packages (cdr packages) '())))

(define (read-vendor-metadata path)
  (let* ((exprs (read-all-exprs path))
         (expr (if (null? exprs) '(vendor) (car exprs))))
    (cond
     ((and (pair? expr) (eq? (car expr) 'vendor))
      (cons path expr))
     ((and (pair? expr) (eq? (car expr) 'source-replacement))
      (let* ((metadata (field-ref (cdr expr) 'metadata "vendor/kons/kons-vendor.scm"))
             (metadata-path (if (absolute-path? metadata)
                                metadata
                                (path-join (dirname path) metadata))))
        (and (file-exists? metadata-path)
             (read-vendor-metadata metadata-path))))
     (else #f))))

(define (read-source-replacements path)
  (if (file-exists? path)
      (let* ((exprs (read-all-exprs path))
             (expr (if (null? exprs) '(source-replacements) (car exprs))))
        (if (and (pair? expr) (eq? (car expr) 'source-replacements))
            (cdr expr)
            '()))
      '()))

(define (source-replacement-registry entry)
  (field-ref (cdr entry) 'registry default-registry-alias))

(define (source-replacement-matches-entry? replacement entry)
  (string=?
   (source-replacement-registry replacement)
   (locked-entry-ref entry 'registry default-registry-alias)))

(define (source-replacement-metadata-reference replacement)
  (let ((metadata (field-ref (cdr replacement) 'metadata #f))
        (directory (field-ref (cdr replacement) 'directory #f)))
    (cond
     (metadata metadata)
     (directory (path-join directory "kons-vendor.scm"))
     (else #f))))

(define (source-replacement-metadata-path config-path replacement)
  (let ((metadata (source-replacement-metadata-reference replacement)))
    (and metadata
         (if (absolute-path? metadata)
             metadata
             (path-join (dirname config-path) metadata)))))

(define (source-replacement-vendor-metadata config-path replacement)
  (let ((metadata-path (source-replacement-metadata-path config-path replacement)))
    (and metadata-path
         (file-exists? metadata-path)
         (read-vendor-metadata metadata-path))))

(define (configured-vendor-metadata-candidates entry)
  (let ((config-path (source-replacements-path)))
    (filter
     (lambda (item) item)
     (map (lambda (replacement)
            (and (pair? replacement)
                 (memq (car replacement) '(replace source-replacement))
                 (source-replacement-matches-entry? replacement entry)
                 (source-replacement-vendor-metadata config-path replacement)))
          (read-source-replacements config-path)))))

(define (vendor-metadata-root metadata-path directory)
  (cond
   ((absolute-path? directory) directory)
   ((string=? directory ".") (dirname metadata-path))
   (else (path-join (dirname metadata-path) directory))))

(define (project-vendor-metadata-candidates manifest)
  (filter
   (lambda (item) item)
   (map (lambda (path)
          (and (file-exists? path) (read-vendor-metadata path)))
        (list (vendor-pointer-path manifest)
              (default-vendor-metadata-path manifest)))))

(define (vendor-metadata-candidates manifest entry)
  (append (project-vendor-metadata-candidates manifest)
          (configured-vendor-metadata-candidates entry)))

(define (vendor-source-root-from-metadata metadata-entry entry)
  (let* ((metadata-path (car metadata-entry))
         (metadata (cdr metadata-entry))
         (directory (field-ref (cdr metadata) 'directory "vendor/kons"))
         (root (vendor-metadata-root metadata-path directory)))
    (let loop ((items (vendor-packages metadata)))
      (cond
       ((null? items) #f)
       ((vendor-package-matches? (car items) entry)
        (let ((path (path-join root (vendor-entry-field (car items) 'path ""))))
          (and (vendor-package-archive-valid? (car items) entry path)
               (vendor-package-source-valid? (car items) path)
               path)))
       (else (loop (cdr items)))))))

(define (vendor-source-root manifest entry)
  (let loop ((items (vendor-metadata-candidates manifest entry)))
    (cond
     ((null? items) #f)
     ((vendor-source-root-from-metadata (car items) entry) => (lambda (path) path))
     (else (loop (cdr items))))))

(define (locked-registry-entry-root entry . maybe-manifest)
  (or (and (pair? maybe-manifest)
           (vendor-source-root (car maybe-manifest) entry))
      (registry-package-root
       (locked-entry-ref entry 'registry default-registry-alias)
       (name->string (locked-entry-ref entry 'name '()))
       (locked-entry-ref entry 'version "")
       (locked-entry-ref entry 'checksum ""))))

(define (materialize-registry-dependency manifest dep offline?)
  (let* ((resolved (resolve-registry-version dep))
         (registry (alist-ref resolved 'registry default-registry-alias))
         (name (name->string (alist-ref dep 'name '())))
         (version (alist-ref resolved 'version ""))
         (checksum (alist-ref resolved 'checksum ""))
         (download (alist-ref resolved 'download "")))
    (download-registry-package! registry name version checksum download offline?)))

(define (materialize-locked-registry-entry manifest entry offline?)
  (or (vendor-source-root manifest entry)
      (download-registry-package!
       (locked-entry-ref entry 'registry default-registry-alias)
       (name->string (locked-entry-ref entry 'name '()))
       (locked-entry-ref entry 'version "")
       (locked-entry-ref entry 'checksum "")
       (locked-entry-ref entry 'download "")
       offline?)))

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
