(define-library (kons actions registry)
  (export cmd-registry
          cmd-login
          cmd-logout
          cmd-search
          cmd-info
          cmd-provides
          cmd-identifier
          cmd-yank
          cmd-unyank
          cmd-owner)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme process-context)
          (scheme write)
          (kons util)
          (kons names)
          (kons manifest)
          (kons options)
          (kons registry)
          (kons compat json))

  (begin
(define (registry-option cmd)
  (or (command-string-option cmd "index")
      (command-string-option cmd "registry")
      default-registry-alias))

(define (token-option cmd)
  (command-string-option cmd "token"))

(define (json-format? value)
  (and value (string=? value "json")))

(define (command-string-option cmd name)
  (let ((value (command-option cmd name #f)))
    (if (string? value) value #f)))

(define (second xs) (car (cdr xs)))
(define (third xs) (car (cdr (cdr xs))))

(define (write-text-file path text)
  (call-with-output-file path
    (lambda (out)
      (display text out))))

(define (registry-trust-key-relative-path key-id)
  (path-join "keys" (string-append (safe-store-token key-id) ".pem")))

(define (registry-trust-key-path key-id)
  (path-join
   (path-join (kons-home) "config")
   (registry-trust-key-relative-path key-id)))

(define (write-registry-trust-key! key-id public-key)
  (let ((path (registry-trust-key-path key-id)))
    (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
    (write-text-file path public-key)
    (run-command (string-append "chmod 600 " (shell-quote path)))
    path))

(define (indexed-registry-trust-fields name index-data cmd)
  (if (command-flag? cmd "trust")
      (let* ((signing (json-ref index-data 'signing '()))
             (key-id (json-string-ref signing 'keyId ""))
             (public-key (json-string-ref signing 'publicKey "")))
        (when (or (string=? key-id "") (string=? public-key ""))
          (dependency-error
           "registry index response is missing signing key metadata"
           name))
        (write-registry-trust-key! key-id public-key)
        `((trust . required)
          (key-id . ,key-id)
          (key-file . ,(registry-trust-key-relative-path key-id))))
      '()))

(define (string-join xs sep)
  (let loop ((rest xs) (out ""))
    (cond
     ((null? rest) out)
     ((string=? out "") (loop (cdr rest) (car rest)))
     (else (loop (cdr rest) (string-append out sep (car rest)))))))

(define (default-package-name cmd)
  (name->string (package-name (parse-manifest (command-manifest-path cmd)))))

(define (string-index s ch)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (cond
       ((= i len) #f)
       ((char=? (string-ref s i) ch) i)
       (else (loop (+ i 1)))))))

(define (string-trim-spaces text)
  (let ((len (string-length text)))
    (let find-start ((start 0))
      (if (and (< start len) (char-whitespace? (string-ref text start)))
          (find-start (+ start 1))
          (let find-end ((end len))
            (if (and (> end start)
                     (char-whitespace? (string-ref text (- end 1))))
                (find-end (- end 1))
                (substring text start end)))))))

(define (string-starts-with? text ch)
  (and (> (string-length text) 0)
       (char=? (string-ref text 0) ch)))

(define (string-ends-with? text ch)
  (let ((len (string-length text)))
    (and (> len 0)
         (char=? (string-ref text (- len 1)) ch))))

(define (string-contains-char? text ch)
  (let ((len (string-length text)))
    (let loop ((index 0))
      (cond
       ((= index len) #f)
       ((char=? (string-ref text index) ch) #t)
       (else (loop (+ index 1)))))))

(define (split-whitespace text)
  (let ((len (string-length text)))
    (let loop ((index 0) (start #f) (parts '()))
      (cond
       ((= index len)
        (reverse
         (if start
             (cons (substring text start index) parts)
             parts)))
       ((char-whitespace? (string-ref text index))
        (loop (+ index 1)
              #f
              (if start
                  (cons (substring text start index) parts)
                  parts)))
       (start
        (loop (+ index 1) start parts))
       (else
        (loop (+ index 1) index parts))))))

(define (display-library-name? text)
  (and (string-starts-with? text #\()
       (string-ends-with? text #\))))

(define (library-route-key text)
  (let ((trimmed (string-trim-spaces text)))
    (cond
     ((display-library-name? trimmed)
      (let ((inner (substring trimmed 1 (- (string-length trimmed) 1))))
        (string-join (split-whitespace inner) "/")))
     ((not (string-contains-char? trimmed #\/))
      (let ((parts (split-whitespace trimmed)))
        (cond
         ((null? parts) trimmed)
         ((null? (cdr parts)) trimmed)
         (else (string-join parts "/")))))
     (else trimmed))))

(define (rest-strings cmd)
  (filter string? (command-rest cmd)))

(define (first-rest cmd label)
  (let ((items (rest-strings cmd)))
    (if (pair? items)
        (car items)
        (usage-error (string-append label " requires an argument")))))

(define (second-rest cmd label)
  (let ((items (rest-strings cmd)))
    (if (and (pair? items) (pair? (cdr items)))
        (second items)
        (usage-error (string-append label " requires another argument")))))

(define (take-list items limit)
  (let loop ((items items) (limit limit) (out '()))
    (if (or (zero? limit) (null? items))
        (reverse out)
        (loop (cdr items) (- limit 1) (cons (car items) out)))))

(define (json-string-list value)
  (filter non-empty-string? (map (lambda (item) (if (string? item) item "")) (json-array->list value))))

(define (json-object-list value)
  (filter pair? (json-array->list value)))

(define (json-version-label value)
  (if (string=? value "") "" (string-append "v" value)))

(define (display-package-result p)
  (let* ((latest (json-ref p 'latest '()))
         (latest-version (json-string-ref latest 'version ""))
         (version (if (string=? latest-version "") "unpublished" (json-version-label latest-version)))
         (description (let ((value (json-string-ref p 'description "")))
                        (if (string=? value "") "No description" value)))
         (owners (json-string-list
                  (list->vector
                   (map (lambda (owner) (json-string-ref owner 'username ""))
                        (json-object-list (json-ref p 'owners '#()))))))
         (keywords (take-list (json-string-list (json-ref p 'keywords '#())) 6))
         (repository (json-string-ref p 'repository (json-string-ref p 'repo "")))
         (homepage (json-string-ref p 'homepage (json-string-ref p 'site "")))
         (documentation (json-string-ref p 'documentation (json-string-ref p 'docs "")))
         (meta (filter non-empty-string?
                       (list
                        (if (null? owners) "" (string-append "by " (string-join owners ", ")))
                        (if (null? keywords) "" (string-append "#" (string-join keywords " #")))))))
    (display (json-string-ref p 'name ""))
    (display "  ")
    (displayln version)
    (display "  ")
    (displayln description)
    (unless (null? meta)
      (display "  ")
      (displayln (string-join meta "  ")))
    (unless (string=? repository "") (display "  repo ") (displayln repository))
    (unless (string=? homepage "") (display "  site ") (displayln homepage))
    (unless (string=? documentation "") (display "  docs ") (displayln documentation))))

(define (display-search-result item)
  (let ((type (json-string-ref item 'type "package")))
    (cond
     ((string=? type "package")
      (display (let ((package (json-string-ref item 'package "")))
                 (if (string=? package "") (json-string-ref item 'name "") package)))
      (display "  ")
      (displayln (json-version-label (json-string-ref item 'version "")))
      (let ((description (json-string-ref item 'description "")))
        (unless (string=? description "") (display "  ") (displayln description))))
     ((string=? type "library")
      (display (json-string-ref item 'name ""))
      (display "  ")
      (displayln (string-join
                  (filter non-empty-string?
                          (list (json-string-ref item 'kind "")
                                (json-string-ref item 'dialect "")
                                (json-string-ref item 'implementation "")))
                  " "))
      (display "  package ")
      (display (json-string-ref item 'package ""))
      (let ((version (json-version-label (json-string-ref item 'version ""))))
        (unless (string=? version "") (display " ") (display version)))
      (newline)
      (let ((description (json-string-ref item 'description "")))
        (unless (string=? description "") (display "  ") (displayln description))))
     ((string=? type "identifier")
      (displayln (let ((identifier (json-string-ref item 'identifier "")))
                   (if (string=? identifier "") (json-string-ref item 'name "") identifier)))
      (display "  library ")
      (displayln (json-string-ref item 'library ""))
      (display "  package ")
      (display (json-string-ref item 'package ""))
      (let ((version (json-version-label (json-string-ref item 'version ""))))
        (unless (string=? version "") (display " ") (display version)))
      (newline)))))

(define (display-separated items display-one)
  (let loop ((items items) (first? #t))
    (unless (null? items)
      (unless first? (newline))
      (display-one (car items))
      (loop (cdr items) #f))))

(define (json-with-format-version value)
  (if (and (pair? value) (not (assq 'formatVersion value)))
      (cons (cons 'formatVersion 1) value)
      value))

(define (display-json-file path)
  (json-write
   (json-with-format-version (registry-json-read path))
   (current-output-port))
  (newline))

(define (display-json-or cmd json display-text)
  (if (json-format? (command-option cmd "format" "text"))
      (display-json-file json)
      (display-text json)))

(define (display-search-json json)
  (let* ((data (registry-json-read json))
         (results (json-object-list (json-ref data 'results '#())))
         (packages (json-object-list (json-ref data 'packages '#()))))
    (cond
     ((pair? results) (display-separated results display-search-result))
     ((pair? packages) (display-separated packages display-package-result))
     (else (displayln "No results found.")))))

(define (library-tags lib)
  (string-join
   (filter non-empty-string?
           (list (json-string-ref lib 'kind "")
                 (json-string-ref lib 'dialect "")
                 (json-string-ref lib 'implementation "")))
   " "))

(define (display-library-line lib)
  (display "  ")
  (display (json-string-ref lib 'name ""))
  (display " ")
  (displayln (library-tags lib))
  (let ((exports (take-list (json-string-list (json-ref lib 'exports '#())) 12)))
    (unless (null? exports)
      (display "    exports: ")
      (displayln (string-join exports ", ")))))

(define (display-trust-line latest trust)
  (let ((checksum (json-string-ref latest 'checksum ""))
        (published-by (json-ref latest 'publishedBy '()))
        (signed? (json-bool-ref trust 'signedMetadata)))
    (unless (string=? checksum "")
      (display "checksum: ")
      (displayln checksum))
    (unless (null? published-by)
      (display "published by: ")
      (displayln (json-string-ref published-by 'username "")))
    (display "signed metadata: ")
    (if signed?
        (begin
          (display "available")
          (let ((key-id (json-string-ref trust 'keyId "")))
            (unless (string=? key-id "")
              (display " ")
              (display key-id)))
          (newline))
        (displayln "not configured"))))

(define (display-package-info-json json)
  (let* ((data (registry-json-read json))
         (p (json-ref data 'package '()))
         (latest (json-ref p 'latest '()))
         (trust (json-ref p 'trust '()))
         (versions (json-object-list (json-ref p 'versions '#()))))
    (display (json-string-ref p 'name ""))
    (display " ")
    (displayln (json-string-ref latest 'version ""))
    (let ((description (json-string-ref p 'description "")))
      (unless (string=? description "") (displayln description)))
    (let ((repository (json-string-ref p 'repository "")))
      (unless (string=? repository "") (display "repository: ") (displayln repository)))
    (display-trust-line latest trust)
    (display "versions: ")
    (displayln
     (string-join
      (map (lambda (version)
             (string-append
              (json-string-ref version 'version "")
              (if (json-bool-ref version 'yanked) " (yanked)" "")))
           versions)
      ", "))
    (let ((libraries (json-object-list (json-ref latest 'libraries '#()))))
      (when (pair? libraries)
        (displayln "libraries:")
        (for-each display-library-line libraries)))))

(define (display-library-provider lib)
  (display (json-string-ref lib 'name ""))
  (display "  ")
  (displayln (library-tags lib))
  (display "  package ")
  (display (json-string-ref lib 'package ""))
  (let ((version (json-version-label (json-string-ref lib 'version ""))))
    (unless (string=? version "") (display " ") (display version)))
  (newline)
  (let ((path (json-string-ref lib 'path "")))
    (unless (string=? path "") (display "  path ") (displayln path)))
  (let ((exports (take-list (json-string-list (json-ref lib 'exports '#())) 12)))
    (unless (null? exports)
      (display "  exports: ")
      (displayln (string-join exports ", ")))))

(define (display-library-providers-json json)
  (let ((libraries (json-object-list (json-ref (registry-json-read json) 'libraries '#()))))
    (if (null? libraries)
        (displayln "No providers found.")
        (display-separated libraries display-library-provider))))

(define (display-identifier-result item)
  (displayln (let ((identifier (json-string-ref item 'identifier "")))
               (if (string=? identifier "") (json-string-ref item 'name "") identifier)))
  (display "  library ")
  (displayln (json-string-ref item 'library ""))
  (display "  package ")
  (display (json-string-ref item 'package ""))
  (let ((version (json-version-label (json-string-ref item 'version ""))))
    (unless (string=? version "") (display " ") (display version)))
  (newline))

(define (display-identifiers-json json)
  (let* ((data (registry-json-read json))
         (identifiers (let ((items (json-object-list (json-ref data 'identifiers '#()))))
                        (if (null? items)
                            (json-object-list (json-ref data 'results '#()))
                            items))))
    (if (null? identifiers)
        (displayln "No identifiers found.")
        (display-separated identifiers display-identifier-result))))

(define (display-owner-list-json json)
  (let* ((data (registry-json-read json))
         (p (json-ref data 'package '()))
         (owners (json-object-list (json-ref p 'owners '#()))))
    (for-each
     (lambda (owner)
       (display (json-string-ref owner 'username ""))
       (display " ")
       (displayln (json-string-ref owner 'displayName "")))
     owners)))

(define (display-registry-entry entry)
  (display (field-ref (cdr entry) 'name ""))
  (display " ")
  (display (field-ref (cdr entry) 'url ""))
  (when (field-ref (cdr entry) 'default #f)
    (display " (default)"))
  (newline))

(define (cmd-registry cmd)
  (let ((items (rest-strings cmd)))
    (if (null? items)
        (usage-error "registry requires a subcommand: list, add, remove, default, index")
        (let ((action (car items)))
          (cond
           ((string=? action "list")
            (let ((items (registry-list)))
              (if (null? items)
                  (displayln "no registries configured")
                  (for-each display-registry-entry items))))
           ((string=? action "add")
            (unless (and (pair? (cdr items)) (pair? (cdr (cdr items))))
              (usage-error "registry add requires NAME URL"))
            (registry-add! (second items) (third items) (command-flag? cmd "default"))
            (displayln "registry added"))
           ((string=? action "remove")
            (unless (pair? (cdr items)) (usage-error "registry remove requires NAME"))
            (registry-remove! (second items))
            (displayln "registry removed"))
           ((string=? action "default")
            (unless (pair? (cdr items)) (usage-error "registry default requires NAME"))
            (registry-default! (second items))
            (displayln "default registry updated"))
           ((string=? action "index")
            (unless (pair? (cdr items)) (usage-error "registry index requires INDEX-URL"))
            (let* ((index-url (second items))
                   (name (if (pair? (cdr (cdr items))) (third items) default-registry-alias))
                   (json (registry-http-json index-url ""))
                   (index-data (registry-json-read json))
                   (api (json-string-ref index-data 'api ""))
                   (trust-fields (indexed-registry-trust-fields name index-data cmd)))
              (when (string=? api "")
                (dependency-error "registry index response is missing api" index-url))
              (registry-add! name api (command-flag? cmd "default") trust-fields)
              (display "registry indexed ")
              (display name)
              (display " ")
              (display api)
              (when (command-flag? cmd "trust")
                (display " (trust required)"))
              (newline)))
           (else (usage-error "unknown registry subcommand" action)))))))

(define (cmd-login cmd)
  (let* ((registry (registry-option cmd))
         (token (or (command-option cmd "token" #f)
                    (get-environment-variable "KONS_REGISTRY_TOKEN")
                    (first-rest cmd "login"))))
    (registry-login! registry token)
    (display "logged in to ")
    (displayln registry)))

(define (cmd-logout cmd)
  (let ((registry (registry-option cmd)))
    (registry-logout! registry)
    (display "logged out of ")
    (displayln registry)))

(define (cmd-search cmd)
  (let* ((query (string-join (rest-strings cmd) " "))
         (registry (registry-option cmd))
         (limit (command-string-option cmd "limit"))
         (page (command-string-option cmd "page"))
         (type (command-string-option cmd "type"))
         (json (registry-http-json registry
                                   (string-append "/api/v1/search?q="
                                                  (url-encode query)
                                                  (if limit
                                                      (string-append "&per_page=" (url-encode limit))
                                                      "")
                                                  (if page
                                                      (string-append "&page=" (url-encode page))
                                                      "")
                                                  (if type
                                                      (string-append "&type=" (url-encode type))
                                                      "")))))
    (when (string=? query "")
      (usage-error "search requires a query"))
    (display-json-or cmd json display-search-json)))

(define (cmd-info cmd)
  (let* ((name (first-rest cmd "info"))
         (registry (registry-option cmd))
         (json (registry-http-json registry
                                   (string-append "/api/v1/packages/" (url-encode name)))))
    (display-json-or cmd json display-package-info-json)))

(define (cmd-provides cmd)
  (let* ((library (first-rest cmd "provides"))
         (registry (registry-option cmd))
         (json (registry-http-json registry
                                   (string-append "/api/v1/libraries/"
                                                  (url-encode (library-route-key library))))))
    (display-json-or cmd json display-library-providers-json)))

(define (cmd-identifier cmd)
  (let* ((query (string-join (rest-strings cmd) " "))
         (registry (registry-option cmd))
         (limit (command-string-option cmd "limit"))
         (json (registry-http-json registry
                                   (string-append "/api/v1/identifiers?q="
                                                  (url-encode query)
                                                  (if limit
                                                      (string-append "&limit=" (url-encode limit))
                                                      "")))))
    (when (string=? query "")
      (usage-error "identifier requires a query"))
    (display-json-or cmd json display-identifiers-json)))

(define (yank-parts cmd unyank?)
  (let* ((items (rest-strings cmd))
         (first (and (pair? items) (car items)))
         (at (and first (string-index first #\@)))
         (version (or (command-string-option cmd "version")
                      (command-string-option cmd "vers")
                      (and at (substring first (+ at 1) (string-length first)))
                      (and (pair? items) (pair? (cdr items)) (second items)))))
    (unless version
      (usage-error (string-append (if unyank? "unyank" "yank") " requires a version")))
    (cons (cond
           (at (substring first 0 at))
           (first first)
           (else (default-package-name cmd)))
          version)))

(define (cmd-yank* cmd unyank?)
  (let* ((parts (yank-parts cmd unyank?))
         (name (car parts))
         (version (cdr parts))
         (registry (registry-option cmd)))
    (registry-http-action/token
     (if unyank? "PUT" "DELETE")
     registry
     (string-append "/api/v1/packages/" name "/" version "/" (if unyank? "unyank" "yank"))
     (token-option cmd))
    (display (if unyank? "unyanked " "yanked "))
    (display name)
    (display " ")
    (displayln version)))

(define (cmd-yank cmd) (cmd-yank* cmd (command-flag? cmd "undo")))
(define (cmd-unyank cmd) (cmd-yank* cmd #t))

(define (cmd-owner cmd)
  (let* ((items (rest-strings cmd))
         (flag-add (command-string-option cmd "add"))
         (flag-remove (command-string-option cmd "remove"))
         (legacy-action (and (pair? items) (car items)))
         (action (cond
                  (flag-add "add")
                  (flag-remove "remove")
                  (legacy-action legacy-action)
                  (else "list")))
         (name (cond
                ((or flag-add flag-remove)
                 (if (pair? items) (car items) (usage-error "owner add/remove requires package name")))
                ((pair? (cdr items)) (second items))
                ((string=? action "list") (usage-error "owner list requires package name"))
                (else (usage-error "owner add/remove requires package name"))))
         (user (cond
                (flag-add flag-add)
                (flag-remove flag-remove)
                ((pair? (cdr (cdr items))) (third items))
                (else #f)))
         (registry (registry-option cmd)))
    (cond
     ((string=? action "list")
      (let ((json (registry-http-json registry
                                      (string-append "/api/v1/packages/" (url-encode name)))))
        (display-owner-list-json json)))
     ((or (string=? action "add") (string=? action "remove"))
      (unless user (usage-error "owner add/remove requires username"))
      (registry-http-action/token
       (if (string=? action "add") "PUT" "DELETE")
       registry
       (string-append "/api/v1/packages/" name "/owners/" user)
       (token-option cmd))
      (displayln "owner updated"))
     (else (usage-error "unknown owner subcommand" action)))))

  ))
