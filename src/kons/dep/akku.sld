(define-library (kons dep akku)
  (export locked-akku-entry-root
    akku-source-ready?
    prepare-akku-installed-root!
    materialize-locked-akku-entry)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons compat files)
    (kons util)
    (kons akku config)
    (kons dep git)
    (kons dep shared)
    (kons dep store)
    (kons manifest))

  (begin
    (define akku-ready-file ".kons-akku-ok")
    (define akku-installed-marker ".kons-akku-installed.scm")

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
            (lock-entry-ref entry 'name '())))))

    (define (library-name-part->string value)
      (cond
        ((symbol? value) (symbol->string value))
        ((number? value) (number->string value))
        (else (dependency-error "Akku library name part is not pathable" value))))

    (define (library-name->path name)
      (string-append
        (string-join (map library-name-part->string name) "/")
        ".sls"))

    (define (path-last-segment path)
      (let loop ((parts (string-split path #\/)) (last ""))
        (cond
          ((null? parts) last)
          ((string=? (car parts) "") (loop (cdr parts) last))
          (else (loop (cdr parts) (car parts))))))

    (define (path-relative-to root path)
      (let* ((root* (absolute-path root))
             (path* (absolute-path path))
             (prefix (if (string-suffix? "/" root*) root* (string-append root* "/"))))
        (cond
          ((string=? root* path*) "")
          ((string-prefix? prefix path*)
            (substring path* (string-length prefix) (string-length path*)))
          (else path*))))

    (define (relative-dir path)
      (let ((dir (dirname path)))
        (if (or (string=? dir ".") (string=? dir path)) "" dir)))

    (define (first-path-segment path)
      (let loop ((parts (string-split path #\/)))
        (cond
          ((null? parts) "")
          ((string=? (car parts) "") (loop (cdr parts)))
          (else (car parts)))))

    (define (library-source-file? path)
      (or (string-suffix? ".sls" path)
        (string-suffix? ".sld" path)
        (string-suffix? ".scm" path)))

    (define (hidden-entry? name)
      (and (> (string-length name) 0)
        (char=? (string-ref name 0) #\.)))

    (define (collect-files root)
      (define (scan dir out)
        (let loop ((entries (directory-list dir)) (out out))
          (cond
            ((null? entries) out)
            (else
              (let ((name (car entries))
                    (path (path-join dir (car entries))))
                (cond
                  ((and (file-directory? path) (not (hidden-entry? name)))
                    (loop (cdr entries) (scan path out)))
                  ((file-exists? path)
                    (loop (cdr entries) (cons path out)))
                  (else (loop (cdr entries) out))))))))
      (if (and (file-exists? root) (file-directory? root))
        (scan root '())
        '()))

    (define (read-library-file-exprs path)
      (guard (exn
              ((error-object? exn) '())
              (else '()))
        (read-all-exprs path)))

    (define (library-name-from-expr expr)
      (and (pair? expr)
        (eq? (car expr) 'library)
        (pair? (cdr expr))
        (symbol-list? (cadr expr))
        (cadr expr)))

    (define (file-library-names path)
      (append-map
        (lambda (expr)
          (let ((name (library-name-from-expr expr)))
            (if name (list name) '())))
        (read-library-file-exprs path)))

    (define known-implementation-tags
      '("capy" "chez" "chezscheme" "chibi" "cyclone" "gauche" "guile"
        "ikarus" "ironscheme" "kawa" "larceny" "loko" "mit" "mosh"
        "mzscheme" "racket" "sagittarius" "skint" "stklos" "ypsilon"))

    (define (path-implementation-tag path)
      (let ((name (path-last-segment path)))
        (let loop ((tags known-implementation-tags))
          (cond
            ((null? tags) #f)
            ((or (string-suffix? (string-append "." (car tags) ".sls") name)
               (string-suffix? (string-append "." (car tags) ".sld") name)
               (string-suffix? (string-append "." (car tags) ".scm") name))
              (car tags))
            (else (loop (cdr tags)))))))

    (define (scheme-implementation-tags scheme)
      (case scheme
        ((chez chez-r6rs) '("chez" "chezscheme"))
        ((guile guile-r6rs guile-native) '("guile"))
        ((gauche gauche-native) '("gauche"))
        (else (list (symbol->string scheme)))))

    (define (string-member? needle haystack)
      (let loop ((items haystack))
        (cond
          ((null? items) #f)
          ((string=? needle (car items)) #t)
          (else (loop (cdr items))))))

    (define (library-candidate-priority path scheme)
      (let ((tag (path-implementation-tag path)))
        (cond
          ((not tag) 0)
          ((string-member? tag (scheme-implementation-tags scheme)) 10)
          (else #f))))

    (define (make-library-candidate root path name scheme)
      (let ((priority (library-candidate-priority path scheme)))
        (and priority
          `((name . ,name)
            (path . ,path)
            (relative . ,(path-relative-to root path))
            (priority . ,priority)))))

    (define (source-root-library-candidates root scheme)
      (append-map
        (lambda (path)
          (if (library-source-file? path)
            (append-map
              (lambda (name)
                (let ((candidate (make-library-candidate root path name scheme)))
                  (if candidate (list candidate) '())))
              (file-library-names path))
            '()))
        (collect-files root)))

    (define (candidate-ref candidate key default)
      (let ((found (assq key candidate)))
        (if found (cdr found) default)))

    (define (candidate-better? candidate existing)
      (>= (candidate-ref candidate 'priority 0)
        (candidate-ref existing 'priority 0)))

    (define (replace-candidate candidate candidates)
      (let ((name (candidate-ref candidate 'name '())))
        (let loop ((items candidates) (out '()) (done? #f))
          (cond
            ((null? items)
              (reverse (if done? out (cons candidate out))))
            ((equal? name (candidate-ref (car items) 'name '()))
              (loop (cdr items)
                (cons (if (candidate-better? candidate (car items)) candidate (car items)) out)
                #t))
            (else (loop (cdr items) (cons (car items) out) done?))))))

    (define (best-library-candidates candidates)
      (let loop ((items candidates) (out '()))
        (if (null? items)
          (reverse out)
          (loop (cdr items) (replace-candidate (car items) out)))))

    (define (copy-file! source dest)
      (run-command (string-append "mkdir -p " (shell-quote (dirname dest))))
      (run-command (string-append "cp -p " (shell-quote source) " " (shell-quote dest))))

    (define (copy-tree-files! source-dir dest-dir)
      (for-each
        (lambda (path)
          (let ((rel (path-relative-to source-dir path)))
            (unless (string=? rel "")
              (copy-file! path (path-join dest-dir rel)))))
        (collect-files source-dir)))

    (define (copy-key source dest)
      (string-append (absolute-path source) "\n" (absolute-path dest)))

    (define (copy-key-present? key keys)
      (let loop ((items keys))
        (cond
          ((null? items) #f)
          ((string=? key (car items)) #t)
          (else (loop (cdr items))))))

    (define (copy-tree-once! source dest copied)
      (let ((key (copy-key source dest)))
        (if (copy-key-present? key copied)
          copied
          (begin
            (copy-tree-files! source dest)
            (cons key copied)))))

    (define (candidate-first-name candidate)
      (library-name-part->string (car (candidate-ref candidate 'name '()))))

    (define (candidate-source-dir root candidate)
      (let ((rel (candidate-ref candidate 'relative "")))
        (if (string=? (relative-dir rel) "")
          root
          (path-join root (relative-dir rel)))))

    (define (candidate-source-dir-relative root candidate)
      (path-relative-to root (candidate-source-dir root candidate)))

    (define (candidate-installed-support-relative-dir root candidate)
      (let* ((source-dir-rel (candidate-source-dir-relative root candidate))
             (first-name (candidate-first-name candidate))
             (first-source-segment (first-path-segment source-dir-rel)))
        (cond
          ((string=? first-source-segment first-name) source-dir-rel)
          ((string=? source-dir-rel "") first-name)
          (else (path-join first-name source-dir-rel)))))

    (define (copy-candidate-support-tree! root installed-root candidate copied)
      (let* ((source-dir (candidate-source-dir root candidate))
             (source-dir-rel (candidate-source-dir-relative root candidate))
             (first-name (candidate-first-name candidate))
             (first-source-segment (first-path-segment source-dir-rel)))
        (cond
          ((string=? first-source-segment first-name) copied)
          ((string=? source-dir-rel "")
            (copy-tree-once! source-dir (path-join installed-root first-name) copied))
          (else
            (copy-tree-once!
              source-dir
              (path-join (path-join installed-root first-name) source-dir-rel)
              copied)))))

    (define (copy-candidate-library! installed-root candidate)
      (copy-file!
        (candidate-ref candidate 'path "")
        (path-join installed-root
          (library-name->path (candidate-ref candidate 'name '())))))

    (define (all-strings? items)
      (cond
        ((null? items) #t)
        ((and (pair? items) (string? (car items))) (all-strings? (cdr items)))
        (else #f)))

    (define (include-asset-key expr)
      (and (pair? expr)
        (memq (car expr) '(include include-ci))
        (all-strings? (cdr expr))
        (cons (car expr) (cdr expr))))

    (define (include-asset-keys-list expr)
      (cond
        ((null? expr) '())
        ((pair? expr)
          (append
            (include-asset-keys (car expr))
            (include-asset-keys-list (cdr expr))))
        (else '())))

    (define (include-asset-keys expr)
      (cond
        ((not (pair? expr)) '())
        ((memq (car expr) '(quote quasiquote)) '())
        (else
          (append
            (let ((key (include-asset-key expr)))
              (if key (list key) '()))
            (include-asset-keys-list expr)))))

    (define (candidate-include-assets root candidate)
      (let* ((path (candidate-ref candidate 'path ""))
             (source-dir (candidate-source-dir root candidate))
             (support-rel (candidate-installed-support-relative-dir root candidate)))
        (append-map
          (lambda (key)
            (let ((targets
                    (filter
                      (lambda (target)
                        (file-exists? (path-join source-dir target)))
                      (cdr key))))
              (if (null? targets)
                '()
                (list
                  (list key
                    (map
                      (lambda (target)
                        (path-join support-rel target))
                      targets))))))
          (append-map include-asset-keys (read-library-file-exprs path)))))

    (define (same-asset-key? a b)
      (equal? (car a) (car b)))

    (define (asset-present? asset assets)
      (let loop ((items assets))
        (cond
          ((null? items) #f)
          ((same-asset-key? asset (car items)) #t)
          (else (loop (cdr items))))))

    (define (dedupe-assets assets)
      (let loop ((items assets) (out '()))
        (cond
          ((null? items) (reverse out))
          ((asset-present? (car items) out) (loop (cdr items) out))
          (else (loop (cdr items) (cons (car items) out))))))

    (define (candidate-root roots candidate)
      (let find-root ((roots roots))
        (cond
          ((null? roots) "")
          ((path-prefix-root? (car roots) (candidate-ref candidate 'path ""))
            (car roots))
          (else (find-root (cdr roots))))))

    (define (candidate-installed-assets roots candidate)
      (candidate-include-assets (candidate-root roots candidate) candidate))

    (define (write-akku-metadata! installed-root library-names installed-assets)
      (let ((path (path-join (path-join installed-root "akku") "metadata.sls")))
        (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
        (write-expr-file
          path
          `(library (akku metadata)
            (export installed-libraries installed-assets)
            (import (rnrs))
            (define installed-libraries ',library-names)
            (define installed-assets ',installed-assets)))))

    (define (installed-root-record entries scheme)
      `(akku-installed-root
        (format 4)
        (scheme ,scheme)
        (entries
         ,@(map
            (lambda (entry)
              (let ((root (locked-akku-entry-root entry)))
                `(entry
                  (name ,(lock-entry-ref entry 'name '()))
                  (version ,(lock-entry-ref entry 'version ""))
                  (root ,root)
                  (hash ,(if (file-exists? root) (path-content-hash root) #f)))))
            entries))))

    (define (stored-installed-root-record installed-root)
      (let ((path (path-join installed-root akku-installed-marker)))
        (if (file-exists? path)
          (let ((exprs (read-all-exprs path)))
            (if (null? exprs) #f (car exprs)))
          #f)))

    (define (write-installed-root-record! installed-root record)
      (write-expr-file (path-join installed-root akku-installed-marker) record))

    (define (prepare-akku-installed-root! installed-root entries scheme)
      (let ((record (installed-root-record entries scheme)))
        (unless (equal? (stored-installed-root-record installed-root) record)
          (run-command (string-append "rm -rf " (shell-quote installed-root)))
          (run-command (string-append "mkdir -p " (shell-quote installed-root)))
          (let* ((roots (map locked-akku-entry-root entries))
                 (candidates
                   (best-library-candidates
                     (append-map
                       (lambda (entry)
                         (source-root-library-candidates (locked-akku-entry-root entry) scheme))
                       entries))))
            (let loop ((items candidates) (copied '()))
              (cond
                ((null? items) '())
                (else
                  (copy-candidate-library! installed-root (car items))
                  (loop (cdr items)
                    (copy-candidate-support-tree!
                      (candidate-root roots (car items))
                      installed-root
                      (car items)
                      copied)))))
            (write-akku-metadata!
              installed-root
              (map (lambda (c) (candidate-ref c 'name '())) candidates)
              (dedupe-assets
                (append-map
                  (lambda (candidate)
                    (candidate-installed-assets roots candidate))
                  candidates)))
            (write-installed-root-record! installed-root record)))
        installed-root))))
