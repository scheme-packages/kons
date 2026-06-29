(define-library (kons actions registry request)
  (export registry-option
    token-option
    command-string-option
    rest-strings
    first-rest
    yank-parts
    owner-parts)
  (import (scheme base)
    (scheme process-context)
    (kons util)
    (kons names)
    (kons manifest)
    (kons options)
    (kons registry))

  (begin
    (define (registry-option cmd)
      (or (command-string-option cmd "index")
        (command-string-option cmd "registry")
        default-registry-alias))

    (define (token-option cmd)
      (command-string-option cmd "token"))

    (define (command-string-option cmd name)
      (let ((value (command-option cmd name #f)))
        (if (string? value) value #f)))

    (define (second xs) (car (cdr xs)))
    (define (third xs) (car (cdr (cdr xs))))

    (define (rest-strings cmd)
      (filter string? (command-rest cmd)))

    (define (first-rest cmd label)
      (let ((items (rest-strings cmd)))
        (if (pair? items)
          (car items)
          (usage-error (string-append label " requires an argument")))))

    (define (default-package-name cmd)
      (name->string (package-name (parse-manifest (command-manifest-path cmd)))))

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

    (define (owner-parts cmd)
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
                    (else #f))))
        `((action . ,action)
          (name . ,name)
          (user . ,user))))))
