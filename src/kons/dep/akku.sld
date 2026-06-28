(define-library (kons dep akku)
  (export locked-akku-entry-root
    akku-source-ready?
    materialize-locked-akku-entry)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons util)
    (kons akku config)
    (kons dep git)
    (kons dep shared)
    (kons dep store)
    (kons manifest))

  (begin
    (define akku-ready-file ".kons-akku-ok")

    (define (locked-akku-entry-root entry)
      (lock-entry-ref entry 'source-cache-path ""))

    (define (entry-token entry)
      (safe-store-token
        (string-append
          (lock-entry-ref entry 'version "")
          "-"
          (lock-entry-ref entry 'revision
            (lock-entry-ref entry 'tag
              (lock-entry-ref entry 'url-sha256
                (lock-entry-ref entry 'path "")))))))

    (define (entry-name-token entry)
      (safe-store-token (lock-entry-ref entry 'key (lock-entry-ref entry 'name '()))))

    (define (write-akku-store-metadata! entry dest source)
      (write-store-metadata
        'akku
        (entry-token entry)
        (entry-name-token entry)
        `(store-entry
          (type akku)
          (name ,(lock-entry-ref entry 'name '()))
          (version ,(lock-entry-ref entry 'version ""))
          (source-kind ,(lock-entry-ref entry 'source-kind #f))
          (source ,source)
          (root ,dest))))

    (define (mark-akku-ready! entry dest source)
      (call-with-output-file (path-join dest akku-ready-file)
        (lambda (out)
          (write `(akku-source
                   (name ,(lock-entry-ref entry 'name '()))
                   (version ,(lock-entry-ref entry 'version ""))
                   (source-kind ,(lock-entry-ref entry 'source-kind #f))
                   (source ,source))
            out)
          (newline out)))
      (write-akku-store-metadata! entry dest source))

    (define (string-prefix? prefix text)
      (let ((plen (string-length prefix))
            (tlen (string-length text)))
        (and (>= tlen plen)
          (string=? prefix (substring text 0 plen)))))

    (define (path-prefix-root? root path)
      (let* ((root* (absolute-path root))
             (path* (absolute-path path))
             (prefix (if (string-suffix? "/" root*) root* (string-append root* "/"))))
        (or (string=? root* path*)
          (string-prefix? prefix path*))))

    (define (safe-cache-root! dest)
      (unless (and (string? dest)
               (not (string=? dest ""))
               (path-prefix-root? (akku-sources-root) dest))
        (dependency-error "Akku source cache path is outside the Akku source store" dest))
      dest)

    (define (component-unsafe? item)
      (or (string=? item "")
        (string=? item ".")
        (string=? item "..")))

    (define (relative-path-safe? path)
      (and (string? path)
        (not (string=? path ""))
        (not (absolute-path? path))
        (let loop ((items (string-split path #\/)))
          (or (null? items)
            (and (not (component-unsafe? (car items)))
              (loop (cdr items)))))))

    (define (directory-source-root manifest path)
      (cond
        ((relative-path-safe? path)
          (path-join (manifest-root manifest) path))
        ((and (absolute-path? path)
            (or (path-prefix-root? (manifest-root manifest) path)
              (path-prefix-root? (akku-sources-root) path)))
          path)
        (else
          (dependency-error "Akku directory source path is unsafe" path))))

    (define (file-sha256 path)
      (capture-first-line
        (string-append "sha256sum " (shell-quote path) " | awk '{print $1}'")))

    (define (archive-cache-path entry)
      (path-join
        (path-join (dirname (locked-akku-entry-root entry)) ".archives")
        (string-append (safe-store-token (lock-entry-ref entry 'url "source"))
          "-"
          (safe-store-token (lock-entry-ref entry 'url-sha256 ""))
          ".tar")))

    (define (download-url-source! entry archive offline?)
      (let ((url (lock-entry-ref entry 'url "")))
        (cond
          ((file-exists? archive) archive)
          (offline?
            (dependency-error "missing offline cache for Akku URL source" url))
          ((string=? url "")
            (dependency-error "Akku URL source is missing a URL" (lock-entry-ref entry 'name '())))
          (else
            (run-command (string-append "mkdir -p " (shell-quote (dirname archive))))
            (run-command
              (string-append "curl -fsSL " (shell-quote url) " -o " (shell-quote archive)))
            archive))))

    (define (verify-url-source! entry archive)
      (let ((expected (lock-entry-ref entry 'url-sha256 #f)))
        (unless (and expected (not (string=? expected "")))
          (dependency-error "Akku URL source is missing a SHA-256 checksum"
            (lock-entry-ref entry 'name '())))
        (let ((actual (file-sha256 archive)))
          (unless (string=? actual expected)
            (dependency-error "Akku URL source checksum mismatch"
              (lock-entry-ref entry 'name '())
              expected
              actual
              '(diagnostic-code . "checksum-mismatch"))))))

    (define (tar-list-safe? archive)
      (= (shell-command-status
          (string-append
            "tar -tvf "
            (shell-quote archive)
            " | awk '"
            "BEGIN { ok=1 } "
            "$1 !~ /^[-d]/ { ok=0 } "
            "{ name=$0; sub(/.* [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] /, \"\", name); "
            "if (name == \"\" || name ~ /^\\// || name ~ /(^|\\/)\\.\\.(\\/|$)/) ok=0 } "
            "END { exit ok ? 0 : 1 }'"
            " >/dev/null 2>/dev/null"))
        0))

    (define (ensure-safe-tarball! archive)
      (unless (tar-list-safe? archive)
        (dependency-error "Akku URL source archive contains unsafe entries" archive)))

    (define (akku-source-ready? entry)
      (let ((dest (locked-akku-entry-root entry)))
        (case (lock-entry-ref entry 'source-kind #f)
          ((git)
            (and (not (string=? dest ""))
              (git-checkout-ready? dest (lock-entry-ref entry 'revision ""))))
          ((url directory)
            (and (not (string=? dest ""))
              (file-exists? (path-join dest akku-ready-file))))
          (else #f))))

    (define (materialize-akku-git! manifest entry offline?)
      (let* ((dest (safe-cache-root! (locked-akku-entry-root entry)))
             (remote (lock-entry-ref entry 'remote ""))
             (revision (lock-entry-ref entry 'revision #f))
             (tag (lock-entry-ref entry 'tag #f)))
        (unless (and revision (not (string=? revision "")))
          (dependency-error "Akku git source is missing a locked revision"
            (lock-entry-ref entry 'name '())))
        (if (git-checkout-ready? dest revision)
          dest
          (let ((repo-root
                  (cond
                    ((file-exists? remote) remote)
                    (offline?
                      (dependency-error "missing offline cache for Akku git source" remote))
                    (else remote))))
            (materialize-git-checkout! repo-root (or tag revision) dest)
            (let ((actual (capture-first-line
                           (string-append "git -C " (shell-quote dest) " rev-parse HEAD"))))
              (unless (string=? actual revision)
                (run-command (string-append "rm -rf " (shell-quote dest)))
                (dependency-error "Akku git source revision mismatch"
                  (lock-entry-ref entry 'name '())
                  revision
                  actual)))
            (write-akku-store-metadata! entry dest remote)
            dest))))

    (define (extract-akku-url! entry archive dest)
      (run-command (string-append "rm -rf " (shell-quote dest)))
      (run-command (string-append "mkdir -p " (shell-quote dest)))
      (run-command
        (string-append "tar -xf " (shell-quote archive) " -C " (shell-quote dest)))
      (mark-akku-ready! entry dest (lock-entry-ref entry 'url ""))
      dest)

    (define (materialize-akku-url! manifest entry offline?)
      (let* ((dest (safe-cache-root! (locked-akku-entry-root entry)))
             (archive (archive-cache-path entry)))
        (if (akku-source-ready? entry)
          dest
          (begin
            (download-url-source! entry archive offline?)
            (verify-url-source! entry archive)
            (ensure-safe-tarball! archive)
            (extract-akku-url! entry archive dest)))))

    (define (materialize-akku-directory! manifest entry)
      (let* ((dest (safe-cache-root! (locked-akku-entry-root entry)))
             (source (directory-source-root manifest (lock-entry-ref entry 'path ""))))
        (if (akku-source-ready? entry)
          dest
          (begin
            (unless (file-exists? source)
              (dependency-error "Akku directory source is missing" source))
            (run-command (string-append "rm -rf " (shell-quote dest)))
            (run-command (string-append "mkdir -p " (shell-quote (dirname dest))))
            (run-command
              (string-append "cp -R " (shell-quote source) " " (shell-quote dest)))
            (mark-akku-ready! entry dest source)
            dest))))

    (define (materialize-locked-akku-entry manifest entry offline?)
      (case (lock-entry-ref entry 'source-kind #f)
        ((git) (materialize-akku-git! manifest entry offline?))
        ((url) (materialize-akku-url! manifest entry offline?))
        ((directory) (materialize-akku-directory! manifest entry))
        (else
          (dependency-error "unsupported Akku source kind"
            (lock-entry-ref entry 'source-kind #f)
            (lock-entry-ref entry 'name '())))))))
