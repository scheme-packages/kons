(define-library (kons registry)
  (export default-registry-alias
    default-registry-url
    registries-path
    credentials-path
    registry-source-root
    registry-archive-path
    registry-package-root
    registry-package-source-root
    registry-ref
    registry-token
    registry-url
    registry-name->url
    registry-list
    write-registry-list!
    registry-add!
    registry-remove!
    registry-default!
    registry-login!
    registry-logout!
    resolve-registry-version
    registry-package-candidates
    download-registry-package!
    registry-http-json
    registry-http-json/token
    registry-http-upload
    registry-http-upload/token
    registry-http-action
    registry-http-action/token
    registry-json-read
    json-ref
    json-string-ref
    json-bool-ref
    json-array->list
    url-encode
    json-string)
  (import (scheme base)
    (scheme file)
    (scheme process-context)
    (scheme write)
    (kons util)
    (kons compat json)
    (kons names)
    (kons manifest))

  (begin
    (define default-registry-alias "default")
    (define default-registry-url "https://kons.playxe.org")

    (define (string-join xs sep)
      (let loop ((rest xs) (out ""))
        (cond
          ((null? rest) out)
          ((string=? out "") (loop (cdr rest) (car rest)))
          (else (loop (cdr rest) (string-append out sep (car rest)))))))

    (define (read-all-text port)
      (let loop ((chars '()))
        (let ((ch (read-char port)))
          (if (eof-object? ch)
            (list->string (reverse chars))
            (loop (cons ch chars))))))

    (define (registry-config-root)
      (path-join (kons-home) "config"))

    (define (registries-path)
      (path-join (registry-config-root) "registries.scm"))

    (define (credentials-path)
      (path-join (kons-home) "credentials.scm"))

    (define (ensure-private-root!)
      (run-command (string-append "mkdir -p " (shell-quote (registry-config-root))))
      (run-command (string-append "mkdir -p " (shell-quote (kons-home)))))

    (define (read-one-expr path default)
      (if (file-exists? path)
        (let ((exprs (read-all-exprs path)))
          (if (null? exprs) default (car exprs)))
        default))

    (define (registry-list)
      (let ((expr (read-one-expr (registries-path) '(registries))))
        (if (and (pair? expr) (eq? (car expr) 'registries))
          (cdr expr)
          '())))

    (define (credentials-list)
      (let ((expr (read-one-expr (credentials-path) '(credentials))))
        (if (and (pair? expr) (eq? (car expr) 'credentials))
          (cdr expr)
          '())))

    (define (write-registry-list! registries)
      (ensure-private-root!)
      (write-expr-file (registries-path) (cons 'registries registries)))

    (define (write-credentials-list! credentials)
      (ensure-private-root!)
      (write-expr-file (credentials-path) (cons 'credentials credentials))
      (run-command (string-append "chmod 600 " (shell-quote (credentials-path)))))

    (define (entry-field entry key default)
      (field-ref (cdr entry) key default))

    (define (registry-entry-name entry)
      (entry-field entry 'name ""))

    (define (registry-entry-url entry)
      (entry-field entry 'url ""))

    (define (registry-entry-default? entry)
      (entry-field entry 'default #f))

    (define (registry-entry-trust-required? entry)
      (or (entry-field entry 'trust-required #f)
        (eq? (entry-field entry 'trust 'none) 'required)))

    (define-record-type <registry-signing-key>
      (make-registry-signing-key id public-key)
      registry-signing-key?
      (id registry-signing-key-record-id)
      (public-key registry-signing-key-record-public-key))

    (define (registry-signing-key-path path)
      (if (or (not (string? path)) (string=? path ""))
        ""
        (if (absolute-path? path)
          path
          (path-join (registry-config-root) path))))

    (define (registry-entry-signing-key-id entry)
      (let ((key-id (entry-field entry 'key-id "")))
        (if (string=? key-id "")
          (entry-field entry 'signing-key-id "")
          key-id)))

    (define (registry-entry-signing-public-key entry)
      (let ((key-file (entry-field entry 'key-file "")))
        (cond
          ((not (string=? key-file ""))
            (registry-signing-key-path key-file))
          (else
            (registry-signing-key-path (entry-field entry 'signing-public-key ""))))))

    (define (registry-entry-legacy-signing-key entry)
      (let ((key-id (registry-entry-signing-key-id entry))
            (public-key (registry-entry-signing-public-key entry)))
        (if (string=? public-key "")
          '()
          (list (make-registry-signing-key key-id public-key)))))

    (define (registry-signing-key-form? value)
      (and (pair? value) (eq? (car value) 'key)))

    (define (registry-signing-key-from-form form)
      (let* ((fields (cdr form))
             (id (field-ref fields 'id (field-ref fields 'key-id "")))
             (file (field-ref fields 'file (field-ref fields 'key-file "")))
             (public-key (registry-signing-key-path
                          (if (string=? file "")
                            (field-ref fields 'signing-public-key "")
                            file))))
        (and (not (string=? public-key ""))
          (make-registry-signing-key id public-key))))

    (define (registry-entry-signing-keys entry)
      (append
        (registry-entry-legacy-signing-key entry)
        (let loop ((items (field-rest (cdr entry) 'keys '())) (out '()))
          (cond
            ((null? items) (reverse out))
            ((registry-signing-key-form? (car items))
              (let ((key (registry-signing-key-from-form (car items))))
                (loop (cdr items) (if key (cons key out) out))))
            (else (loop (cdr items) out))))))

    (define (find-registry-entry name)
      (let loop ((items (registry-list)))
        (cond
          ((null? items) #f)
          ((and (pair? (car items))
              (eq? (caar items) 'registry)
              (string=? (registry-entry-name (car items)) name))
            (car items))
          (else (loop (cdr items))))))

    (define (default-registry-entry)
      (let loop ((items (registry-list)))
        (cond
          ((null? items) #f)
          ((and (pair? (car items))
              (eq? (caar items) 'registry)
              (registry-entry-default? (car items)))
            (car items))
          (else (loop (cdr items))))))

    (define (registry-name->url name)
      (cond
        ((or (not name) (string=? name "") (string=? name default-registry-alias))
          (or (get-environment-variable "KONS_REGISTRY")
            (let ((entry (or (default-registry-entry)
                          (find-registry-entry default-registry-alias))))
              (if entry (registry-entry-url entry) default-registry-url))))
        ((or (string-prefix? "http://" name)
            (string-prefix? "https://" name))
          name)
        (else
          (let ((entry (find-registry-entry name)))
            (unless entry (dependency-error "unknown registry" name))
            (registry-entry-url entry)))))

    (define (registry-entry-for-ref registry)
      (let* ((name (registry-ref registry))
             (url (registry-url registry)))
        (let loop ((items (registry-list)))
          (cond
            ((null? items) #f)
            ((and (pair? (car items))
                (eq? (caar items) 'registry)
                (or (string=? (registry-entry-name (car items)) name)
                  (string=? (registry-entry-url (car items)) url)))
              (car items))
            (else (loop (cdr items)))))))

    (define (registry-trust-required? registry)
      (let ((entry (registry-entry-for-ref registry)))
        (and entry (registry-entry-trust-required? entry))))

    (define (registry-signing-key-id registry)
      (let ((entry (registry-entry-for-ref registry)))
        (if entry (registry-entry-signing-key-id entry) "")))

    (define (registry-signing-public-key registry)
      (let ((entry (registry-entry-for-ref registry)))
        (if entry (registry-entry-signing-public-key entry) "")))

    (define (registry-signing-keys registry)
      (let ((entry (registry-entry-for-ref registry)))
        (if entry (registry-entry-signing-keys entry) '())))

    (define (registry-signing-key-for-id registry key-id)
      (let loop ((keys (registry-signing-keys registry)) (fallback #f))
        (cond
          ((null? keys) fallback)
          ((string=? key-id (registry-signing-key-record-id (car keys)))
            (car keys))
          ((and (not fallback) (string=? (registry-signing-key-record-id (car keys)) ""))
            (loop (cdr keys) (car keys)))
          (else (loop (cdr keys) fallback)))))

    (define (string-prefix? prefix s)
      (let ((plen (string-length prefix))
            (slen (string-length s)))
        (and (>= slen plen)
          (string=? prefix (substring s 0 plen)))))

    (define (registry-url registry)
      (registry-name->url registry))

    (define (without-trailing-slash s)
      (let ((len (string-length s)))
        (if (and (> len 0) (char=? (string-ref s (- len 1)) #\/))
          (substring s 0 (- len 1))
          s)))

    (define (registry-ref registry)
      (or registry default-registry-alias))

    (define (registry-token registry)
      (or (get-environment-variable "KONS_REGISTRY_TOKEN")
        (let ((url (registry-url registry))
              (name (registry-ref registry)))
          (let loop ((items (credentials-list)))
            (cond
              ((null? items) #f)
              ((and (pair? (car items))
                  (eq? (caar items) 'credential)
                  (or (string=? (entry-field (car items) 'registry "") name)
                    (string=? (entry-field (car items) 'url "") url)))
                (entry-field (car items) 'token #f))
              (else (loop (cdr items))))))))

    (define (replace-named-entry entries new-entry)
      (let ((name (registry-entry-name new-entry)))
        (let loop ((items entries) (out '()) (done? #f))
          (cond
            ((null? items) (reverse (if done? out (cons new-entry out))))
            ((and (pair? (car items))
                (eq? (caar items) 'registry)
                (string=? (registry-entry-name (car items)) name))
              (loop (cdr items) (cons new-entry out) #t))
            (else (loop (cdr items) (cons (car items) out) done?))))))

    (define (registry-entry-set-field entry key value)
      (let loop ((fields (cdr entry)) (out '()) (done? #f))
        (cond
          ((null? fields)
            (cons 'registry
              (reverse (if done? out (cons (list key value) out)))))
          ((and (pair? (car fields)) (eq? (caar fields) key))
            (loop (cdr fields) (cons (list key value) out) #t))
          (else
            (loop (cdr fields) (cons (car fields) out) done?)))))

    (define (registry-entry-set-fields entry fields)
      (let loop ((items fields) (out entry))
        (if (null? items)
          out
          (loop (cdr items)
            (registry-entry-set-field out (caar items) (cdar items))))))

    (define (clear-default entries)
      (map (lambda (entry)
            (if (and (pair? entry) (eq? (car entry) 'registry))
              (registry-entry-set-field entry 'default #f)
              entry))
        entries))

    (define (registry-add! name url default? . maybe-fields)
      (let* ((old-entry (find-registry-entry name))
             (extra-fields (if (null? maybe-fields) '() (car maybe-fields)))
             (entry (registry-entry-set-fields
                     (or old-entry '(registry))
                     (append
                       `((name . ,name)
                         (url . ,(without-trailing-slash url))
                         (default . ,default?))
                       extra-fields))))
        (write-registry-list!
          (replace-named-entry
            (if default? (clear-default (registry-list)) (registry-list))
            entry))))

    (define (registry-remove! name)
      (write-registry-list!
        (filter (lambda (entry)
                 (not (and (pair? entry)
                       (eq? (car entry) 'registry)
                       (string=? (registry-entry-name entry) name))))
          (registry-list))))

    (define (registry-default! name)
      (let ((entry (find-registry-entry name)))
        (unless entry (dependency-error "unknown registry" name))
        (write-registry-list!
          (replace-named-entry
            (clear-default (registry-list))
            (registry-entry-set-field entry 'default #t)))))

    (define (replace-credential credentials new-entry)
      (let ((name (entry-field new-entry 'registry "")))
        (let loop ((items credentials) (out '()) (done? #f))
          (cond
            ((null? items) (reverse (if done? out (cons new-entry out))))
            ((and (pair? (car items))
                (eq? (caar items) 'credential)
                (string=? (entry-field (car items) 'registry "") name))
              (loop (cdr items) (cons new-entry out) #t))
            (else (loop (cdr items) (cons (car items) out) done?))))))

    (define (registry-login! registry token)
      (let ((name (registry-ref registry)))
        (write-credentials-list!
          (replace-credential
            (credentials-list)
            `(credential
              (registry ,name)
              (url ,(registry-url name))
              (token ,token))))))

    (define (registry-logout! registry)
      (let ((name (registry-ref registry)))
        (write-credentials-list!
          (filter (lambda (entry)
                   (not (and (pair? entry)
                         (eq? (car entry) 'credential)
                         (string=? (entry-field entry 'registry "") name))))
            (credentials-list)))))

    (define (registry-source-root)
      (path-join (kons-store-root) "registry"))

    (define (registry-archive-path registry name version checksum)
      (path-join
        (path-join
          (path-join (registry-source-root) "archives")
          (safe-store-token (registry-url registry)))
        (string-append
          (safe-store-token name)
          "-"
          (safe-store-token version)
          "-"
          (safe-store-token checksum)
          ".kons")))

    (define (registry-package-root registry name version checksum)
      (path-join
        (path-join
          (path-join (registry-source-root) "sources")
          (safe-store-token (registry-url registry)))
        (string-append
          (safe-store-token name)
          "-"
          (safe-store-token version)
          "-"
          (safe-store-token checksum))))

    (define (registry-package-source-root registry name version checksum)
      (let* ((root (registry-package-root registry name version checksum))
             (manifest-path (path-join root "kons.scm")))
        (unless (file-exists? manifest-path)
          (dependency-error "registry dependency is not materialized; run `kons fetch` first" name version))
        (let ((manifest (parse-manifest manifest-path)))
          (path-join root (package-source-path manifest)))))

    (define (registry-metadata-root registry)
      (path-join
        (path-join (registry-source-root) "metadata")
        (safe-store-token (registry-url registry))))

    (define (registry-package-versions-cache-path registry name)
      (path-join
        (registry-metadata-root registry)
        (string-append (safe-store-token name) "-versions.scm")))

    (define (registry-package-versions-signature-cache-path registry name)
      (string-append (registry-package-versions-cache-path registry name) ".sig.json"))

    (define (registry-metadata-cache-path? path)
      (string-contains? path "/store/registry/metadata/"))

    (define (registry-json-read-error-message path kind)
      (if (registry-metadata-cache-path? path)
        (string-append "registry metadata JSON could not be " kind "; run `kons update` to refresh it")
        (string-append "registry response JSON could not be " kind)))

    (define (registry-space? ch)
      (or (char=? ch #\space)
        (char=? ch #\tab)
        (char=? ch #\newline)
        (char=? ch #\return)))

    (define (read-first-nonspace path)
      (call-with-input-file path
        (lambda (in)
          (let loop ((ch (read-char in)))
            (cond
              ((eof-object? ch) ch)
              ((registry-space? ch) (loop (read-char in)))
              (else ch))))))

    (define (sexp-field fields key default)
      (let loop ((items fields))
        (cond
          ((null? items) default)
          ((and (pair? (car items)) (eq? (caar items) key))
            (let ((values (cdar items)))
              (cond
                ((null? values) default)
                ((null? (cdr values)) (car values))
                (else values))))
          (else (loop (cdr items))))))

    (define (sexp-field-values fields key)
      (let loop ((items fields))
        (cond
          ((null? items) '())
          ((and (pair? (car items)) (eq? (caar items) key)) (cdar items))
          (else (loop (cdr items))))))

    (define (sexp-field-forms fields key)
      (let loop ((items fields) (out '()))
        (cond
          ((null? items) (reverse out))
          ((and (pair? (car items)) (eq? (caar items) key))
            (loop (cdr items) (cons (car items) out)))
          (else (loop (cdr items) out)))))

    (define (sexp-symbol-string value)
      (cond
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        (else "")))

    (define (sexp-symbol-vector values)
      (list->vector (map sexp-symbol-string values)))

    (define (sexp-string-value value)
      (cond
        ((string? value) value)
        ((symbol? value) (symbol->string value))
        ((number? value) (number->string value))
        (else "")))

    (define (sexp-user->json form)
      (let ((fields (if (and (pair? form) (eq? (car form) 'user)) (cdr form) '())))
        `((id . ,(sexp-field fields 'id #f))
          (username . ,(sexp-string-value (sexp-field fields 'username "")))
          (displayName . ,(sexp-string-value (sexp-field fields 'display-name ""))))))

    (define (sexp-provenance->json form)
      (let ((fields (if (and (pair? form) (eq? (car form) 'provenance)) (cdr form) '())))
        `((publishedBy . ,(sexp-user->json (sexp-field fields 'published-by '())))
          (publishedAt . ,(sexp-string-value (sexp-field fields 'published-at "")))
          (checksum . ,(sexp-string-value (sexp-field fields 'checksum "")))
          (size . ,(sexp-field fields 'size 0)))))

    (define (sexp-dependency->json form)
      (let ((fields (if (and (pair? form) (eq? (car form) 'dependency)) (cdr form) '())))
        `((name . ,(sexp-string-value (sexp-field fields 'name "")))
          (req . ,(sexp-string-value (sexp-field fields 'req "*")))
          (kind . ,(sexp-symbol-string (sexp-field fields 'kind 'normal)))
          (registry . ,(let ((value (sexp-field fields 'registry #f)))
                         (and value (sexp-string-value value))))
          (optional . ,(and (sexp-field fields 'optional #f) #t))
          (target . ,(let ((value (sexp-field fields 'target #f)))
                       (and value (sexp-string-value value))))
          (schemes . ,(sexp-symbol-vector (sexp-field-values fields 'schemes)))
          (implementations . ,(sexp-symbol-vector (sexp-field-values fields 'implementations)))
          (dialects . ,(sexp-symbol-vector (sexp-field-values fields 'dialects)))
          (targets . ,(list->vector (map sexp-string-value (sexp-field-values fields 'targets))))
          (profiles . ,(sexp-symbol-vector (sexp-field-values fields 'profiles)))
          (compileModes . ,(sexp-symbol-vector (sexp-field-values fields 'compile-modes)))
          (features . ,(sexp-symbol-vector (sexp-field-values fields 'features))))))

    (define (sexp-feature-dependency->json form)
      (let ((fields (if (and (pair? form) (eq? (car form) 'feature-dependency)) (cdr form) '())))
        `((feature . ,(sexp-symbol-string (sexp-field fields 'feature 'unknown)))
          (dependencies . ,(list->vector
                            (map sexp-dependency->json
                              (sexp-field-values fields 'dependencies)))))))

    (define (sexp-library-name->json value)
      (cond
        ((pair? value)
          (list->vector (map sexp-string-value value)))
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        (else "")))

    (define (sexp-library->json form)
      (let ((fields (if (and (pair? form) (eq? (car form) 'library)) (cdr form) '())))
        `((kind . ,(sexp-symbol-string (sexp-field fields 'kind 'r7rs)))
          (name . ,(sexp-library-name->json (sexp-field fields 'name "")))
          (displayName . ,(sexp-string-value (sexp-field fields 'display-name "")))
          (key . ,(sexp-string-value (sexp-field fields 'key "")))
          (path . ,(sexp-string-value (sexp-field fields 'path "")))
          (implementation . ,(sexp-string-value (sexp-field fields 'implementation "")))
          (dialect . ,(sexp-string-value (sexp-field fields 'dialect "")))
          (imports . ,(list->vector
                        (map sexp-library-name->json
                          (sexp-field-values fields 'imports))))
          (exports . ,(sexp-symbol-vector (sexp-field-values fields 'exports))))))

    (define (sexp-version->json form)
      (let ((fields (if (and (pair? form) (eq? (car form) 'version)) (cdr form) '())))
        `((version . ,(sexp-string-value (sexp-field fields 'number "")))
          (checksum . ,(sexp-string-value (sexp-field fields 'checksum "")))
          (size . ,(sexp-field fields 'size 0))
          (downloadUrl . ,(sexp-string-value (sexp-field fields 'download-url "")))
          (yanked . ,(and (sexp-field fields 'yanked #f) #t))
          (publishedAt . ,(sexp-string-value (sexp-field fields 'published-at "")))
          (provenance . ,(sexp-provenance->json (sexp-field fields 'provenance '())))
          (description . ,(sexp-string-value (sexp-field fields 'description "")))
          (license . ,(sexp-string-value (sexp-field fields 'license "")))
          (dialects . ,(sexp-symbol-vector (sexp-field-values fields 'dialects)))
          (features . ,(sexp-symbol-vector (sexp-field-values fields 'features)))
          (featureDependencies . ,(list->vector
                                   (map sexp-feature-dependency->json
                                     (sexp-field-values fields 'feature-dependencies))))
          (dependencies . ,(list->vector
                            (map sexp-dependency->json
                              (sexp-field-values fields 'dependencies))))
          (libraries . ,(list->vector
                         (map sexp-library->json
                           (sexp-field-values fields 'libraries)))))))

    (define (sexp-entry->version-json api form)
      (let* ((fields (if (and (pair? form) (eq? (car form) 'entry)) (cdr form) '()))
             (name (sexp-string-value (sexp-field fields 'name "")))
             (version (sexp-string-value (sexp-field fields 'version ""))))
        `((version . ,version)
          (checksum . ,(sexp-string-value (sexp-field fields 'checksum "")))
          (downloadUrl . ,(string-append api "/api/v1/packages/" name "/" version "/download"))
          (yanked . ,(and (sexp-field fields 'yanked #f) #t))
          (provenance . ,(sexp-provenance->json (sexp-field fields 'provenance '())))
          (dialects . ,(sexp-symbol-vector (sexp-field-values fields 'dialects)))
          (features . ,(sexp-symbol-vector (sexp-field-values fields 'features)))
          (featureDependencies . ,(list->vector
                                   (map sexp-feature-dependency->json
                                     (sexp-field-values fields 'feature-dependencies))))
          (dependencies . ,(list->vector
                            (map sexp-dependency->json
                              (sexp-field-values fields 'dependencies)))))))

    (define (registry-sexp-read path)
      (let ((forms (read-all-exprs path)))
        (cond
          ((and (= (length forms) 1)
             (pair? (car forms))
             (eq? (caar forms) 'kons-registry-versions))
            (let ((fields (cdar forms)))
              `((package . ,(sexp-string-value (sexp-field fields 'package "")))
                (versions . ,(list->vector
                              (map sexp-version->json
                                (sexp-field-values fields 'versions)))))))
          ((and (= (length forms) 1)
             (pair? (car forms))
             (eq? (caar forms) 'kons-registry-index))
            (let* ((api "")
                   (entries (sexp-field-forms (cdar forms) 'entry)))
              `((entries . ,(list->vector
                             (map (lambda (entry) (sexp-entry->version-json api entry))
                               entries))))))
          (else
            (dependency-error "registry metadata S-expression could not be parsed" path)))))

    (define (registry-json-read path)
      (guard (exn
              ((json-error? exn)
                (dependency-error (registry-json-read-error-message path "parsed")
                  path
                  (json-error-reason exn)))
              ((error-object? exn)
                (dependency-error (registry-json-read-error-message path "read")
                  path
                  (error-object-message exn))))
        (if (let ((first (read-first-nonspace path)))
              (and (char? first) (char=? first #\()))
          (registry-sexp-read path)
          (call-with-input-file path json-read))))

    (define (write-text-file path text)
      (call-with-output-file path
        (lambda (out)
          (display text out))))

    (define (decode-base64-file input output)
      (= (shell-command-status
          (string-append
            "openssl base64 -d -A -in "
            (shell-quote input)
            " -out "
            (shell-quote output)))
        0))

    (define (verify-ed25519-signature public-key payload signature)
      (= (shell-command-status
          (string-append
            "openssl pkeyutl -verify -rawin -pubin -inkey "
            (shell-quote public-key)
            " -in "
            (shell-quote payload)
            " -sigfile "
            (shell-quote signature)
            " >/dev/null 2>&1"))
        0))

    (define-record-type <signed-registry-payload>
      (make-signed-registry-payload version alg key-id payload-base64 signature-base64)
      signed-registry-payload?
      (version signed-registry-payload-version)
      (alg signed-registry-payload-alg)
      (key-id signed-registry-payload-key-id)
      (payload-base64 signed-registry-payload-payload-base64)
      (signature-base64 signed-registry-payload-signature-base64))

    (define (json-signed-registry-payload signed)
      (if signed
        (make-signed-registry-payload
          (json-ref signed 'version 0)
          (json-string-ref signed 'alg "")
          (json-string-ref signed 'keyId "")
          (json-string-ref signed 'payloadBase64 "")
          (json-string-ref signed 'signatureBase64 ""))
        #f))

    (define (copy-file! source dest)
      (run-command
        (string-append "cp " (shell-quote source) " " (shell-quote dest))))

    (define (same-file-contents? left right)
      (= (shell-command-status
          (string-append "cmp -s " (shell-quote left) " " (shell-quote right)))
        0))

    (define (verify-registry-signed-envelope registry name envelope-path payload-path refresh?)
      (let* ((data (registry-json-read envelope-path))
             (payload (json-signed-registry-payload (json-ref data 'signed #f)))
             (payload-b64-path (temporary-file-path "kons-registry-payload.b64"))
             (decoded-payload-path (temporary-file-path "kons-registry-payload.json"))
             (signature-b64-path (temporary-file-path "kons-registry-signature.b64"))
             (signature-path (temporary-file-path "kons-registry-signature.bin")))
        (unless payload
          (dependency-error "registry metadata signature missing" registry name))
        (unless (= (signed-registry-payload-version payload) 1)
          (dependency-error "registry metadata signature version is unsupported" registry name))
        (unless (string=? (signed-registry-payload-alg payload) "ed25519")
          (dependency-error "registry metadata signature algorithm is unsupported" registry name))
        (let* ((signed-key-id (signed-registry-payload-key-id payload))
               (signing-key (registry-signing-key-for-id registry signed-key-id)))
          (unless signing-key
            (dependency-error "registry metadata signing key is not trusted" registry name signed-key-id))
          (let ((public-key (registry-signing-key-record-public-key signing-key)))
            (when (string=? public-key "")
              (dependency-error "registry signing public key is required" registry name))
            (unless (file-exists? public-key)
              (dependency-error "registry signing public key is missing" public-key))
            (run-command (string-append "mkdir -p " (shell-quote (dirname payload-path))))
            (write-text-file payload-b64-path (signed-registry-payload-payload-base64 payload))
            (write-text-file signature-b64-path (signed-registry-payload-signature-base64 payload))
            (unless (decode-base64-file payload-b64-path decoded-payload-path)
              (dependency-error "registry metadata signed payload could not be decoded" registry name))
            (unless (decode-base64-file signature-b64-path signature-path)
              (dependency-error "registry metadata signature could not be decoded" registry name))
            (unless (verify-ed25519-signature public-key decoded-payload-path signature-path)
              (dependency-error "registry metadata signature mismatch" registry name))))
        (cond
          (refresh?
            (copy-file! decoded-payload-path payload-path))
          ((not (file-exists? payload-path))
            (dependency-error "verified registry metadata cache is missing and offline/frozen mode is active" name))
          ((not (same-file-contents? decoded-payload-path payload-path))
            (dependency-error "verified registry metadata cache does not match its signature; run `kons update`" name)))
        payload-path))

    (define (verified-registry-metadata-path registry name envelope-path payload-path refresh?)
      (if (registry-trust-required? registry)
        (verify-registry-signed-envelope registry name envelope-path payload-path refresh?)
        envelope-path))

    (define (json-ref object key default)
      (let ((found (and (pair? object) (assq key object))))
        (if found (cdr found) default)))

    (define (json-string-ref object key default)
      (let ((value (json-ref object key default)))
        (if (string? value) value default)))

    (define (json-bool-ref object key)
      (let ((value (json-ref object key #f)))
        (and value #t)))

    (define (json-array->list value)
      (cond
        ((vector? value) (vector->list value))
        ((list? value) value)
        (else '())))

    (define (registry-json-name name)
      (map string->symbol (filter non-empty-string? (string-split name #\/))))

    (define (registry-json-symbol value default)
      (cond
        ((symbol? value) value)
        ((and (string? value) (non-empty-string? value)) (string->symbol value))
        (else default)))

    (define (registry-json-symbol-list value)
      (map (lambda (item) (registry-json-symbol item 'unknown))
        (filter (lambda (item)
                 (or (symbol? item) (and (string? item) (non-empty-string? item))))
          (json-array->list value))))

    (define (registry-json-string-list value)
      (filter string?
        (map (lambda (item)
              (cond
                ((string? item) item)
                ((symbol? item) (symbol->string item))
                (else #f)))
          (json-array->list value))))

    (define (absolute-http-url? text)
      (or (string-prefix? "http://" text)
        (string-prefix? "https://" text)))

    (define (registry-version-download api package-name version row)
      (let ((raw (let ((value (json-string-ref row 'downloadUrl "")))
                  (if (string=? value "")
                    (json-string-ref row 'download "")
                    value))))
        (cond
          ((and (not (string=? raw "")) (absolute-http-url? raw)) raw)
          ((not (string=? raw "")) (string-append api raw))
          (else
            (string-append api "/api/v1/packages/" package-name "/" version "/download")))))

    (define (registry-json-dependency registry dep)
      (let ((features (registry-json-symbol-list (json-ref dep 'features '#())))
            (schemes (registry-json-symbol-list (json-ref dep 'schemes '#())))
            (implementations (registry-json-symbol-list (json-ref dep 'implementations '#())))
            (dialects (registry-json-symbol-list (json-ref dep 'dialects '#())))
            (targets (registry-json-string-list (json-ref dep 'targets '#())))
            (profiles (registry-json-symbol-list (json-ref dep 'profiles '#())))
            (compile-modes (registry-json-symbol-list (json-ref dep 'compileModes '#())))
            (legacy-target (json-string-ref dep 'target "")))
        `((name . ,(registry-json-name (json-string-ref dep 'name "")))
          (version . ,(let ((req (json-string-ref dep 'req "")))
                       (if (string=? req "")
                         (json-string-ref dep 'version "*")
                         req)))
          (registry . ,(let ((dep-registry (json-string-ref dep 'registry "")))
                        (if (string=? dep-registry "") registry dep-registry)))
          (kind . ,(registry-json-symbol (json-ref dep 'kind "runtime") 'runtime))
          ,@(if (json-bool-ref dep 'optional) '((optional . #t)) '())
          ,@(if (null? features) '() `((features . ,features)))
          ,@(if (null? (append schemes implementations)) '() `((schemes . ,(append schemes implementations))))
          ,@(if (null? dialects) '() `((dialects . ,dialects)))
          ,@(let ((all-targets (if (and (null? targets) (non-empty-string? legacy-target))
                                (list legacy-target)
                                targets)))
             (if (null? all-targets) '() `((targets . ,all-targets))))
          ,@(if (null? profiles) '() `((profiles . ,profiles)))
          ,@(if (null? compile-modes) '() `((compile-modes . ,compile-modes))))))

    (define (registry-json-feature-dependency registry dep)
      `((feature . ,(registry-json-symbol (json-ref dep 'feature "") 'unknown))
        (dependencies . ,(map (lambda (item) (registry-json-dependency registry item))
                          (json-array->list (json-ref dep 'dependencies '#()))))))

    (define (registry-json-candidate registry api package-name row)
      (let ((version (json-string-ref row 'version ""))
            (features (registry-json-symbol-list (json-ref row 'features '#()))))
        `((name . ,(registry-json-name package-name))
          (version . ,version)
          (registry . ,registry)
          (checksum . ,(json-string-ref row 'checksum ""))
          (download . ,(registry-version-download api package-name version row))
          ,@(if (json-bool-ref row 'yanked) '((yanked . #t)) '())
          ,@(if (null? features) '() `((features . ,features)))
          (feature-dependencies
           .
           ,(map (lambda (dep) (registry-json-feature-dependency registry dep))
             (json-array->list (json-ref row 'featureDependencies '#()))))
          (dependencies . ,(map (lambda (dep) (registry-json-dependency registry dep))
                            (json-array->list (json-ref row 'dependencies '#())))))))

    (define (registry-json-candidates path registry api fallback-package-name)
      (let* ((data (registry-json-read path))
             (package-name (json-string-ref data 'package ""))
             (versions (let ((items (json-array->list (json-ref data 'versions '#()))))
                         (if (null? items)
                           (json-array->list (json-ref data 'entries '#()))
                           items))))
        (map (lambda (row)
              (registry-json-candidate
                registry
                api
                (if (string=? package-name "")
                  fallback-package-name
                  package-name)
                row))
          versions)))

    (define (registry-package-sparse-index-cache-path registry name)
      (path-join
        (registry-metadata-root registry)
        (string-append (safe-store-token name) "-index.scm")))

    (define (lowercase-ascii-alphanumeric? ch)
      (or (and (char>=? ch #\a) (char<=? ch #\z))
        (and (char>=? ch #\0) (char<=? ch #\9))))

    (define (registry-sparse-token name)
      (list->string
        (map (lambda (ch)
              (if (char=? ch #\/) #\- ch))
          (string->list name))))

    (define (registry-sparse-compact-token token)
      (list->string
        (filter lowercase-ascii-alphanumeric?
          (string->list token))))

    (define (pad-sparse-path-part text)
      (cond
        ((= (string-length text) 0) "__")
        ((= (string-length text) 1) (string-append text "_"))
        (else text)))

    (define (registry-sparse-index-path name)
      (let* ((token (registry-sparse-token name))
             (compact (registry-sparse-compact-token token))
             (first-end (min 2 (string-length compact)))
             (second-end (min 4 (string-length compact)))
             (first (pad-sparse-path-part (substring compact 0 first-end)))
             (second (pad-sparse-path-part (substring compact first-end second-end))))
        (string-append "/index/" first "/" second "/" token)))

    (define (read-sparse-index-lines path)
      (filter non-empty-string?
        (string-split
          (call-with-input-file path read-all-text)
          #\newline)))

    (define (verified-sparse-index-entry registry name line refresh?)
      (let ((envelope-path (temporary-file-path "kons-registry-index-envelope.json"))
            (payload-path (temporary-file-path "kons-registry-index-payload.json")))
        (write-text-file envelope-path line)
        (verify-registry-signed-envelope registry name envelope-path payload-path #t)
        (let ((data (registry-json-read payload-path)))
          (delete-temp-file envelope-path)
          (delete-temp-file payload-path)
          data)))

    (define (sparse-index-dependency registry dep)
      `((name . ,(json-string-ref dep 'name ""))
        (req . ,(json-string-ref dep 'req "*"))
        (kind . ,(json-ref dep 'kind "runtime"))
        (registry . ,(let ((dep-registry (json-string-ref dep 'registry "")))
                      (if (string=? dep-registry "") registry dep-registry)))
        (optional . ,(json-bool-ref dep 'optional))
        ,@(let ((target (json-string-ref dep 'target "")))
           (if (string=? target "") '() `((target . ,target))))
        (schemes . ,(json-ref dep 'schemes '#()))
        (implementations . ,(json-ref dep 'implementations '#()))
        (dialects . ,(json-ref dep 'dialects '#()))
        (targets . ,(json-ref dep 'targets '#()))
        (profiles . ,(json-ref dep 'profiles '#()))
        (compileModes . ,(json-ref dep 'compileModes '#()))
        (features . ,(json-ref dep 'features '#()))))

    (define (sparse-index-version-row registry api entry)
      (let* ((name (json-string-ref entry 'name ""))
             (version (json-string-ref entry 'vers ""))
             (download (string-append api "/api/v1/packages/" name "/" version "/download"))
             (dependencies
               (list->vector
                 (map (lambda (dep)
                       (sparse-index-dependency registry dep))
                   (json-array->list (json-ref entry 'deps '#()))))))
        (list
          (cons 'version version)
          (cons 'checksum (json-string-ref entry 'checksum ""))
          (cons 'downloadUrl download)
          (cons 'yanked (json-bool-ref entry 'yanked))
          (cons 'publishedAt (json-string-ref entry 'publishedAt ""))
          (cons 'provenance (json-ref entry 'provenance '()))
          (cons 'dialects (json-ref entry 'dialects '#()))
          (cons 'features (json-ref entry 'features '#()))
          (cons 'featureDependencies (json-ref entry 'featureDependencies '#()))
          (cons 'dependencies dependencies))))

    (define (sparse-index-entries->versions-payload registry api name entries)
      `((package . ,name)
        (versions . ,(list->vector
                      (map (lambda (entry)
                            (sparse-index-version-row registry api entry))
                        entries)))))

    (define (write-registry-json-file path value)
      (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
      (call-with-output-file path
        (lambda (out)
          (json-write value out))))

    (define (verified-sparse-index-lines->payload registry name sparse-path cache-path refresh?)
      (let* ((api (without-trailing-slash (registry-url registry)))
             (entries (map (lambda (line)
                            (verified-sparse-index-entry registry name line refresh?))
                       (read-sparse-index-lines sparse-path)))
             (payload (sparse-index-entries->versions-payload registry api name entries))
             (fresh-path (temporary-file-path "kons-registry-index-versions.json")))
        (write-registry-json-file fresh-path payload)
        (cond
          (refresh?
            (copy-file! fresh-path cache-path))
          ((not (file-exists? cache-path))
            (dependency-error "verified registry metadata cache is missing and offline/frozen mode is active" name))
          ((not (same-file-contents? fresh-path cache-path))
            (dependency-error "verified registry metadata cache does not match its signature; run `kons update`" name)))
        (delete-temp-file fresh-path)
        cache-path))

    (define (json->display-string value)
      (cond
        ((not value) "")
        ((string? value) value)
        ((symbol? value) (symbol->string value))
        ((number? value) (number->string value))
        ((boolean? value) (if value "true" "false"))
        (else (json-string value))))

    (define (registry-error-details-message details)
      (let ((fields (json-array->list (json-ref details 'fields '#()))))
        (cond
          ((pair? fields)
            (string-join
              (map (lambda (field)
                    (string-append
                      (json-string-ref field 'field "")
                      ": "
                      (json-string-ref field 'message "")))
                fields)
              "\n"))
          ((and details (not (json-null? details)))
            (json->display-string details))
          (else ""))))

    (define (registry-response-error-message file)
      (if (file-exists? file)
        (guard (exn
                ((error-object? exn)
                  (let ((text (call-with-input-file file read-all-text)))
                    (if (string=? text "") "registry request failed" text))))
          (let* ((data (registry-json-read file))
                 (message (let ((value (json-string-ref data 'message "")))
                           (if (string=? value "")
                             (json-string-ref data 'error "registry request failed")
                             value)))
                 (details (registry-error-details-message (json-ref data 'details #f))))
            (if (string=? details "")
              message
              (string-append message "\n" details))))
        "registry request failed"))

    (define (http-success-status? status)
      (and (>= status 200) (< status 300)))

    (define (delete-temp-file path)
      (when (file-exists? path)
        (delete-file path)))

    (define (registry-http-request method registry path body-file explicit-token)
      (let ((body (temporary-file-path "registry-response.json"))
            (code (temporary-file-path "registry-status.txt")))
        (let ((status
                (shell-command-status
                  (string-append
                    "curl -sSL -X "
                    (shell-quote method)
                    (curl-auth-header/token registry explicit-token)
                    (if body-file
                      (string-append
                        " -H "
                        (shell-quote "Content-Type: text/x-scheme")
                        " --data-binary @"
                        (shell-quote body-file))
                      "")
                    " -w "
                    (shell-quote "%{http_code}")
                    " -o "
                    (shell-quote body)
                    " "
                    (shell-quote (http-url registry path))
                    " > "
                    (shell-quote code)))))
          (unless (= status 0)
            (dependency-error "registry request failed" (http-url registry path)))
          (let ((http-code (string->number (call-with-input-file code read-line))))
            (delete-temp-file code)
            (if (and http-code (http-success-status? http-code))
              body
              (let ((message (registry-response-error-message body)))
                (delete-temp-file body)
                (dependency-error message (http-url registry path) (if http-code http-code "unknown"))))))))

    (define (curl-auth-header/token registry explicit-token)
      (let ((token (or explicit-token (registry-token registry))))
        (if token
          (string-append " -H " (shell-quote (string-append "Authorization: Bearer " token)))
          "")))

    (define (curl-auth-header registry)
      (curl-auth-header/token registry #f))

    (define (http-url registry path)
      (string-append (without-trailing-slash (registry-url registry)) path))

    (define (registry-http-json/token registry path explicit-token)
      (registry-http-request "GET" registry path #f explicit-token))

    (define (registry-http-json registry path)
      (registry-http-json/token registry path #f))

    (define (registry-http-action/token method registry path explicit-token)
      (delete-temp-file
        (registry-http-request method registry path #f explicit-token)))

    (define (registry-http-action method registry path)
      (registry-http-action/token method registry path #f))

    (define (registry-http-upload/token registry path json-file explicit-token)
      (delete-temp-file
        (registry-http-request "PUT" registry path json-file explicit-token)))

    (define (registry-http-upload registry path json-file)
      (registry-http-upload/token registry path json-file #f))

    (define (unreserved-uri-byte? byte)
      (or (and (>= byte (char->integer #\a)) (<= byte (char->integer #\z)))
        (and (>= byte (char->integer #\A)) (<= byte (char->integer #\Z)))
        (and (>= byte (char->integer #\0)) (<= byte (char->integer #\9)))
        (= byte (char->integer #\-))
        (= byte (char->integer #\_))
        (= byte (char->integer #\.))
        (= byte (char->integer #\~))))

    (define (hex-digit n)
      (string-ref "0123456789ABCDEF" n))

    (define (percent-encoded-byte byte)
      (string #\%
        (hex-digit (quotient byte 16))
        (hex-digit (remainder byte 16))))

    (define (url-encode s)
      (let ((bytes (string->utf8 s)))
        (let loop ((i 0) (out '()))
          (if (= i (bytevector-length bytes))
            (string-join (reverse out) "")
            (let ((byte (bytevector-u8-ref bytes i)))
              (loop (+ i 1)
                (cons (if (unreserved-uri-byte? byte)
                       (string (integer->char byte))
                       (percent-encoded-byte byte))
                  out)))))))

    (define (resolve-registry-version dep)
      (let* ((registry (registry-ref (alist-ref dep 'registry #f)))
             (name (name->string (alist-ref dep 'name '())))
             (req (alist-ref dep 'version "*"))
             (json (registry-http-json
                    registry
                    (string-append "/api/v1/packages/"
                      (url-encode name)
                      "/resolve?req="
                      (url-encode req))))
             (data (registry-json-read json))
             (package (json-ref data 'package '()))
             (latest (json-ref package 'latest '()))
             (version (json-string-ref data 'version ""))
             (checksum (json-string-ref latest 'checksum ""))
             (download (string-append (without-trailing-slash (registry-url registry))
                        "/api/v1/packages/"
                        name
                        "/"
                        version
                        "/download")))
        `((version . ,version)
          (checksum . ,checksum)
          (download . ,download)
          (registry . ,registry))))

    (define (registry-package-candidates registry name . maybe-offline?)
      (let* ((registry (registry-ref registry))
             (name-text (if (string? name) name (name->string name)))
             (offline? (and (pair? maybe-offline?) (car maybe-offline?)))
             (cache-path (registry-package-versions-cache-path registry name-text))
             (signature-cache-path
               (registry-package-versions-signature-cache-path registry name-text))
             (sparse-cache-path
               (registry-package-sparse-index-cache-path registry name-text))
             (json (cond
                    ((registry-trust-required? registry)
                      (let ((sparse-json
                              (cond
                                ((and offline? (file-exists? sparse-cache-path))
                                  sparse-cache-path)
                                (offline?
                                  (dependency-error
                                    "registry metadata cache is missing and offline/frozen mode is active"
                                    name-text))
                                (else
                                  (let ((fresh (registry-http-json
                                                registry
                                                (registry-sparse-index-path name-text))))
                                    (run-command
                                      (string-append "mkdir -p "
                                        (shell-quote (dirname sparse-cache-path))))
                                    (copy-file! fresh sparse-cache-path)
                                    fresh)))))
                        sparse-json))
                    ((and offline? (registry-trust-required? registry)
                        (file-exists? signature-cache-path))
                      signature-cache-path)
                    ((and offline? (file-exists? cache-path)) cache-path)
                    (offline?
                      (dependency-error "registry metadata cache is missing and offline/frozen mode is active" name-text))
                    (else
                      (let ((fresh (registry-http-json
                                    registry
                                    (string-append "/api/v1/packages/"
                                      (url-encode name-text)
                                      "/versions?includeYanked=1"
                                      (if (registry-trust-required? registry)
                                        "&signed=1"
                                        "")))))
                        (run-command (string-append "mkdir -p " (shell-quote (dirname cache-path))))
                        (copy-file!
                          fresh
                          (if (registry-trust-required? registry)
                            signature-cache-path
                            cache-path))
                        fresh))))
             (metadata-path
               (if (registry-trust-required? registry)
                 json
                 (verified-registry-metadata-path
                   registry
                   name-text
                   json
                   cache-path
                   (not offline?))))
             (api (without-trailing-slash (registry-url registry))))
        (registry-json-candidates metadata-path registry api name-text)))

    (define (download-registry-package! registry name version checksum download offline?)
      (let* ((archive (registry-archive-path registry name version checksum))
             (root (registry-package-root registry name version checksum)))
        (cond
          ((file-exists? root) root)
          (offline? (dependency-error "registry dependency cache is missing and offline/frozen mode is active" name version))
          (else
            (run-command (string-append "mkdir -p " (shell-quote (dirname archive))))
            (unless (file-exists? archive)
              (run-command
                (string-append "curl -fsSL " (shell-quote download) " -o " (shell-quote archive))))
            (let ((actual (capture-first-line
                           (string-append "sha256sum " (shell-quote archive) " | awk '{print $1}'"))))
              (unless (string=? actual checksum)
                (dependency-error "registry archive checksum mismatch"
                  name
                  version
                  checksum
                  actual
                  '(diagnostic-code . "checksum-mismatch"))))
            (run-command (string-append "rm -rf " (shell-quote root)))
            (run-command (string-append "mkdir -p " (shell-quote root)))
            (run-command
              (string-append "tar -xf " (shell-quote archive) " -C " (shell-quote root)))
            root))))

    (define (json-string value)
      (let ((port (open-output-string)))
        (json-write value port)
        (get-output-string port)))))
