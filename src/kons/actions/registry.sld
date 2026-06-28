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
    (scheme process-context)
    (kons util)
    (kons options)
    (kons registry)
    (kons compat json)
    (kons actions registry display)
    (kons actions registry request)
    (kons actions registry route)
    (kons actions registry trust))

  (begin
    (define (second xs) (car (cdr xs)))
    (define (third xs) (car (cdr (cdr xs))))

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
                       (trust-fields (indexed-registry-trust-fields
                                      name
                                      index-data
                                      (command-flag? cmd "trust"))))
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
      (let* ((parts (owner-parts cmd))
             (action (field-ref parts 'action "list"))
             (name (field-ref parts 'name #f))
             (user (field-ref parts 'user #f))
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
          (else (usage-error "unknown owner subcommand" action)))))))
