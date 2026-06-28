(define-library (kons akku format)
  (export read-akku-manifest
    read-akku-lock
    read-akku-index
    make-akku-package
    akku-package?
    akku-package-name
    akku-package-versions
    make-akku-version
    akku-version?
    akku-version-number
    akku-version-synopsis
    akku-version-description
    akku-version-authors
    akku-version-homepage
    akku-version-license
    akku-version-scripts
    akku-version-lock
    akku-version-source
    akku-version-depends
    akku-version-depends/dev
    akku-version-conflicts
    akku-version-properties
    make-akku-lock-project
    akku-lock-project?
    akku-lock-project-name
    akku-lock-project-location
    akku-lock-project-install
    akku-lock-project-installer
    akku-lock-project-scripts
    akku-lock-project-tag
    akku-lock-project-revision
    akku-lock-project-content)
  (import (scheme base)
    (kons akku format-common)
    (kons akku records))

  (begin
    (define (parse-version-fields path context fields default-number allowed)
      (ensure-known-fields path context fields allowed)
      (let ((number (if (memq 'version allowed)
                     (require-field-one path context fields 'version)
                     default-number)))
        (unless (valid-version-string? number)
          (akku-format-error path "version must be a non-empty string" context number))
        (make-akku-version
          number
          (validate-string-list-field path context fields 'synopsis)
          (validate-string-list-field path context fields 'description)
          (validate-string-list-field path context fields 'authors)
          (validate-string-list-field path context fields 'homepage)
          (field-rest fields 'license '())
          (validate-script-list path context (field-rest fields 'scripts '()))
          (field-rest fields 'lock '())
          (field-rest fields 'source '())
          (validate-dependency-list path context 'depends
            (field-rest fields 'depends '()))
          (validate-dependency-list path context 'depends/dev
            (field-rest fields 'depends/dev '()))
          (validate-dependency-list path context 'conflicts
            (field-rest fields 'conflicts '()))
          fields)))

    (define (parse-manifest-package path form)
      (unless (eq? (top-form-kind path form) 'akku-package)
        (akku-format-error path "expected akku-package form" form))
      (unless (and (pair? (cdr form))
               (list? (cadr form))
               (= (length (cadr form)) 2))
        (akku-format-error path "malformed akku-package header" form))
      (let ((name (car (cadr form)))
            (version (cadr (cadr form)))
            (fields (cddr form)))
        (unless (valid-package-name? name)
          (akku-format-error path "malformed package name" name))
        (make-akku-package
          name
          (list (parse-version-fields path 'akku-package fields version
                 manifest-version-fields)))))

    (define (read-akku-manifest path)
      (map (lambda (form) (parse-manifest-package path form))
        (read-akku-file path manifest-import)))

    (define (parse-index-version path package-name fields)
      (unless (list? fields)
        (akku-format-error path "malformed version record" package-name fields))
      (parse-version-fields path 'package-version fields #f index-version-fields))

    (define (parse-index-package path form)
      (unless (eq? (top-form-kind path form) 'package)
        (akku-format-error path "expected package form" form))
      (let ((fields (cdr form)))
        (ensure-known-fields path 'package fields '(name versions))
        (let ((name (require-field-one path 'package fields 'name))
              (versions (field-rest fields 'versions #f)))
          (unless (valid-package-name? name)
            (akku-format-error path "malformed package name" name))
          (unless versions
            (akku-format-error path "missing required field" 'package 'versions))
          (make-akku-package
            name
            (map (lambda (version-fields)
                  (parse-index-version path name version-fields))
              versions)))))

    (define (read-akku-index path)
      (map (lambda (form) (parse-index-package path form))
        (read-akku-file path index-import)))

    (define (validate-location path location)
      (unless (and (list? location)
               (pair? location)
               (memq (car location) '(git directory url))
               (pair? (cdr location))
               (string? (cadr location))
               (null? (cddr location)))
        (akku-format-error path "malformed lock project location" location))
      location)

    (define (validate-content path content)
      (for-each
        (lambda (item)
          (unless (and (list? item)
                   (= (length item) 2)
                   (memq (car item) '(sha256))
                   (string? (cadr item)))
            (akku-format-error path "malformed lock project content" item)))
        content)
      content)

    (define (parse-lock-project path project)
      (unless (list? project)
        (akku-format-error path "malformed lock project" project))
      (ensure-known-fields path 'project project lock-project-fields)
      (let ((name (require-field-one path 'project project 'name))
            (location (require-field-one path 'project project 'location))
            (install (field-rest project 'install #f))
            (installer (field-rest project 'installer '()))
            (scripts (field-rest project 'scripts '()))
            (tag (field-one path 'project project 'tag #f))
            (revision (field-one path 'project project 'revision #f))
            (content (field-rest project 'content '())))
        (unless (valid-package-name? name)
          (akku-format-error path "malformed lock project name" name))
        (when (and tag (not (string? tag)))
          (akku-format-error path "lock project tag must be a string" tag))
        (when (and revision (not (string? revision)))
          (akku-format-error path "lock project revision must be a string" revision))
        (validate-script-list path 'project scripts)
        (make-akku-lock-project
          name
          (validate-location path location)
          install
          installer
          scripts
          tag
          revision
          (validate-content path content))))

    (define (parse-projects-form path form)
      (unless (eq? (top-form-kind path form) 'projects)
        (akku-format-error path "expected projects form" form))
      (map (lambda (project) (parse-lock-project path project))
        (cdr form)))

    (define (read-akku-lock path)
      (let ((forms (read-akku-file path lockfile-import)))
        (unless (= (length forms) 1)
          (akku-format-error path "Akku.lock requires exactly one projects form"))
        (parse-projects-form path (car forms))))))
