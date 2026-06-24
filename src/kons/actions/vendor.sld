(define-library (kons actions vendor)
  (export cmd-vendor)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons util)
          (kons names)
          (kons manifest)
          (kons features)
          (kons lock)
          (kons options)
          (kons registry)
          (kons actions paths)
          (kons actions lock-shared)
          (kons actions tree-clean))

  (begin
(define (vendor-directory manifest cmd)
  (let ((dir (command-option cmd "directory" "vendor/kons")))
    (if (absolute-path? dir)
        dir
        (path-join (manifest-root manifest) dir))))

(define (vendor-metadata-reference cmd)
  (let ((dir (command-option cmd "directory" "vendor/kons")))
    (path-join dir "kons-vendor.scm")))

(define (registry-lock-entry? entry)
  (eq? (lock-entry-type entry) 'registry))

(define (vendor-lock-entries lock)
  (filter registry-lock-entry? (lock-package-entries lock)))

(define (vendor-entry-directory-name entry)
  (safe-store-token
   (string-append
    (lock-entry-ref entry 'registry "default")
    "-"
    (name->string (lock-entry-ref entry 'name '()))
    "-"
    (lock-entry-ref entry 'version ""))))

(define (vendor-entry-path root entry)
  (path-join root (vendor-entry-directory-name entry)))

(define (vendor-entry-archive-name)
  ".kons-archive")

(define (vendor-source-content-hash path)
  (capture-first-line
   (string-append
    "cd " (shell-quote path)
    " && find . -type f -not -path './.git/*' -print | LC_ALL=C sort | xargs cksum | cksum")))

(define (locked-registry-package-root entry offline?)
  (download-registry-package!
   (lock-entry-ref entry 'registry "default")
   (name->string (lock-entry-ref entry 'name '()))
   (lock-entry-ref entry 'version "")
   (lock-entry-ref entry 'checksum "")
   (lock-entry-ref entry 'download "")
   offline?))

(define (locked-registry-archive-path entry)
  (registry-archive-path
   (lock-entry-ref entry 'registry "default")
   (name->string (lock-entry-ref entry 'name '()))
   (lock-entry-ref entry 'version "")
   (lock-entry-ref entry 'checksum "")))

(define (vendor-source-hash-field root entry)
  (let ((path (vendor-entry-path root entry)))
    (if (file-exists? path)
        `((source-hash ,(vendor-source-content-hash path)))
        '())))

(define (vendor-package-record root entry)
  `(package
    (name ,(lock-entry-ref entry 'name '()))
    (version ,(lock-entry-ref entry 'version ""))
    (registry ,(lock-entry-ref entry 'registry "default"))
    (checksum ,(lock-entry-ref entry 'checksum ""))
    (archive ,(vendor-entry-archive-name))
    (path ,(vendor-entry-directory-name entry))
    ,@(vendor-source-hash-field root entry)))

(define (vendor-metadata root entries)
  `(vendor
    (version 1)
    (directory ".")
    (source-replacement
     (kind registry)
     (directory "."))
    (packages
     ,@(map (lambda (entry) (vendor-package-record root entry)) entries))))

(define (vendor-metadata-path root)
  (path-join root "kons-vendor.scm"))

(define (vendor-pointer-path manifest)
  (path-join (manifest-root manifest) "kons-vendor.scm"))

(define (vendor-pointer cmd)
  `(source-replacement
    (version 1)
    (metadata ,(vendor-metadata-reference cmd))))

(define (copy-vendor-entry! manifest root entry offline?)
  (let* ((source (locked-registry-package-root entry offline?))
         (archive (locked-registry-archive-path entry))
         (dest (vendor-entry-path root entry))
         (dest-archive (path-join dest (vendor-entry-archive-name))))
    (run-command (string-append "rm -rf " (shell-quote dest)))
    (run-command (string-append "mkdir -p " (shell-quote (dirname dest))))
    (run-command (string-append "cp -pR " (shell-quote source) " " (shell-quote dest)))
    (unless (file-exists? archive)
      (dependency-error "registry archive cache is missing after materialization" archive))
    (run-command (string-append "cp -p " (shell-quote archive) " " (shell-quote dest-archive)))
    dest))

(define (display-vendor-summary root count)
  (display "vendored ")
  (write count)
  (display " registry package")
  (unless (= count 1) (display "s"))
  (display " to ")
  (displayln root)
  (display "wrote ")
  (displayln (vendor-metadata-path root)))

(define (cmd-vendor cmd)
  (let* ((manifest (parse-manifest (command-manifest-path cmd)))
         (features (active-features manifest cmd))
         (root (vendor-directory manifest cmd))
         (lock (matching-lock manifest features cmd)))
    (ensure-supported-active-features manifest features cmd)
    (unless lock
      (if (file-exists? (command-lock-path manifest cmd))
          (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`")
          (lockfile-error "kons.lock missing; run `kons update` first")))
    (let ((entries (vendor-lock-entries lock)))
      (if (command-flag? cmd "plan")
          (writeln
           `(vendor-plan
             (directory ,root)
             (sync ,(command-flag? cmd "sync"))
             (metadata ,(vendor-metadata-path root))
             (packages
              ,@(map (lambda (entry) (vendor-package-record root entry)) entries))))
          (begin
            (when (command-flag? cmd "sync")
              (run-command (string-append "rm -rf " (shell-quote root))))
            (run-command (string-append "mkdir -p " (shell-quote root)))
            (for-each
             (lambda (entry)
               (copy-vendor-entry!
                manifest
                root
                entry
                (or (command-flag? cmd "offline")
                    (command-flag? cmd "frozen"))))
             entries)
            (write-expr-file (vendor-metadata-path root) (vendor-metadata root entries))
            (write-expr-file (vendor-pointer-path manifest) (vendor-pointer cmd))
            (display-vendor-summary root (length entries)))))))

  ))
