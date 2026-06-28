(define-library (kons dep snow)
  (export locked-snow-entry-root
    snow-source-ready?
    materialize-locked-snow-entry)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons util)
    (kons snow config)
    (kons dep shared)
    (kons dep store)
    (kons manifest))

  (begin
    (define snow-ready-file ".kons-snow-ok")

    (define (locked-snow-entry-root entry)
      (lock-entry-ref entry 'source-cache-path ""))

    (define (write-snow-store-metadata! entry dest source)
      (write-store-metadata
        'snow
        (lock-entry-ref entry 'version "")
        (safe-store-token (lock-entry-ref entry 'key (lock-entry-ref entry 'name '())))
        `(store-entry
          (type snow)
          (name ,(lock-entry-ref entry 'name '()))
          (package-name ,(lock-entry-ref entry 'package-name '()))
          (version ,(lock-entry-ref entry 'version ""))
          (source ,source)
          (root ,dest))))

    (define (mark-snow-ready! entry dest source)
      (call-with-output-file (path-join dest snow-ready-file)
        (lambda (out)
          (write `(snow-source
                   (name ,(lock-entry-ref entry 'name '()))
                   (package-name ,(lock-entry-ref entry 'package-name '()))
                   (version ,(lock-entry-ref entry 'version ""))
                   (source ,source))
            out)
          (newline out)))
      (write-snow-store-metadata! entry dest source))

    (define (path-prefix-root? root path)
      (let* ((root* (absolute-path root))
             (path* (absolute-path path))
             (prefix (if (string-suffix? "/" root*) root* (string-append root* "/"))))
        (or (string=? root* path*)
          (string-prefix? prefix path*))))

    (define (safe-cache-root! dest)
      (unless (and (string? dest)
               (not (string=? dest ""))
               (path-prefix-root? (snow-sources-root) dest))
        (dependency-error "Snow source cache path is outside the Snow source store" dest))
      dest)

    (define (file-sha256 path)
      (capture-first-line
        (string-append "sha256sum " (shell-quote path) " | awk '{print $1}'")))

    (define (gzip-tar-sha256 path)
      (capture-first-line
        (string-append "gzip -dc " (shell-quote path) " | sha256sum | awk '{print $1}'")))

    (define (archive-cache-path entry)
      (path-join
        (path-join (dirname (locked-snow-entry-root entry)) ".archives")
        (string-append (safe-store-token (lock-entry-ref entry 'url "source"))
          "-"
          (safe-store-token (lock-entry-ref entry 'sha256 ""))
          ".tgz")))

    (define (file-url-path url)
      (and (string-prefix? "file://" url)
        (substring url 7 (string-length url))))

    (define (download-snowball! entry archive offline?)
      (let ((url (lock-entry-ref entry 'url "")))
        (cond
          ((file-exists? archive) archive)
          ((and (file-url-path url)
             (file-exists? (file-url-path url)))
            (run-command (string-append "mkdir -p " (shell-quote (dirname archive))))
            (run-command
              (string-append "cp " (shell-quote (file-url-path url)) " " (shell-quote archive)))
            archive)
          ((file-exists? url)
            (run-command (string-append "mkdir -p " (shell-quote (dirname archive))))
            (run-command
              (string-append "cp " (shell-quote url) " " (shell-quote archive)))
            archive)
          (offline?
            (dependency-error "missing offline cache for Snow package" url))
          ((string=? url "")
            (dependency-error "Snow package is missing a URL" (lock-entry-ref entry 'name '())))
          (else
            (run-command (string-append "mkdir -p " (shell-quote (dirname archive))))
            (run-command
              (string-append "curl -fsSL " (shell-quote url) " -o " (shell-quote archive)))
            archive))))

    (define (verify-snowball! entry archive)
      (let ((expected (lock-entry-ref entry 'sha256 #f)))
        (when (and expected (not (string=? expected "")))
          (let ((actual (file-sha256 archive)))
            (unless (or (string=? actual expected)
                    (string=? (gzip-tar-sha256 archive) expected))
              (dependency-error "Snow package checksum mismatch"
                (lock-entry-ref entry 'name '())
                expected
                actual
                '(diagnostic-code . "checksum-mismatch")))))))

    (define (tar-list-safe? archive)
      (= (shell-command-status
          (string-append
            "tar -tzf "
            (shell-quote archive)
            " | awk '"
            "BEGIN { ok=1; root=\"\" } "
            "{ name=$0; "
            "if (name == \"\" || name ~ /^\\// || name ~ /(^|\\/)\\.\\.(\\/|$)/) ok=0; "
            "split(name, parts, \"/\"); if (root == \"\") root=parts[1]; else if (parts[1] != root) ok=0 } "
            "END { exit ok ? 0 : 1 }'"
            " >/dev/null 2>/dev/null"))
        0))

    (define (ensure-safe-snowball! archive)
      (unless (tar-list-safe? archive)
        (dependency-error "Snow package archive contains unsafe entries" archive)))

    (define (snow-source-ready? entry)
      (let ((dest (locked-snow-entry-root entry)))
        (and (not (string=? dest ""))
          (file-exists? (path-join dest snow-ready-file)))))

    (define (materialize-locked-snow-entry manifest entry offline?)
      (let* ((dest (safe-cache-root! (locked-snow-entry-root entry)))
             (archive (archive-cache-path entry)))
        (if (snow-source-ready? entry)
          dest
          (begin
            (download-snowball! entry archive offline?)
            (verify-snowball! entry archive)
            (ensure-safe-snowball! archive)
            (run-command (string-append "rm -rf " (shell-quote dest)))
            (run-command (string-append "mkdir -p " (shell-quote dest)))
            (run-command
              (string-append
                "tar -xzf "
                (shell-quote archive)
                " -C "
                (shell-quote dest)
                " --strip-components=1"))
            (mark-snow-ready! entry dest (lock-entry-ref entry 'url ""))
            dest))))))
