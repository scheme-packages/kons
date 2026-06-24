(define-library (kons actions license-scan)
  (export cmd-license-scan)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons util)
          (kons names)
          (kons manifest)
          (kons features)
          (kons lock)
          (kons options)
          (kons compat json)
          (kons dep git)
          (kons actions paths)
          (kons actions lock-shared)
          (kons actions tree-clean))

  (begin
(define (json-format? value)
  (and value (string=? value "json")))

(define (name-value->string value)
  (cond
   ((null? value) "")
   ((and (pair? value)
         (let loop ((items value))
           (cond
            ((null? items) #t)
            ((symbol? (car items)) (loop (cdr items)))
            ((string? (car items)) (loop (cdr items)))
            (else #f))))
    (name->string value))
   ((pair? value)
    (let loop ((items value) (out ""))
      (cond
       ((null? items) out)
       ((string=? out "") (loop (cdr items) (name-value->string (car items))))
       (else (loop (cdr items)
                   (string-append out ", " (name-value->string (car items))))))))
   ((symbol? value) (symbol->string value))
   ((string? value) value)
   (else "")))

(define (license-status license fallback)
  (cond
   ((and (string? license) (not (string=? license ""))) 'known)
   (else fallback)))

(define (license-entry type scope name version license status source path)
  `(package
    (type ,type)
    (scope ,scope)
    (name ,name)
    (version ,version)
    (license ,license)
    (status ,status)
    (source ,source)
    (path ,path)))

(define (root-license-entry manifest)
  (let ((license (package-license manifest)))
    (license-entry
     'root
     'runtime
     (package-name manifest)
     (package-version manifest)
     license
     (license-status license 'missing)
     'manifest
     (manifest-root manifest))))

(define (dependency-root-from-path base path)
  (if (absolute-path? path) path (path-join base path)))

(define (manifest-at-root root)
  (let ((path (and root (path-join root "kons.scm"))))
    (and path
         (file-exists? path)
         (parse-manifest path))))

(define (license-entry-from-manifest type scope name source root fallback-version)
  (let ((manifest (manifest-at-root root)))
    (if manifest
        (let ((license (package-license manifest)))
          (license-entry
           type
           scope
           (package-name manifest)
           (package-version manifest)
           license
           (license-status license 'missing)
           source
           root))
        (license-entry
         type
         scope
         name
         fallback-version
         ""
         'unknown
         source
         (or root "")))))

(define (live-git-root dep)
  (let* ((base (alist-ref dep 'parent-root "."))
         (url (alist-ref dep 'url ""))
         (candidate (cond
                     ((file-exists? url) url)
                     ((file-exists? (path-join base url)) (path-join base url))
                     (else #f)))
         (subpath (alist-ref dep 'subpath #f)))
    (and candidate
         (if subpath (path-join candidate subpath) candidate))))

(define (entry-from-live-dependency dep)
  (let ((type (alist-ref dep 'type #f))
        (scope (alist-ref dep 'scope 'runtime))
        (name (alist-ref dep 'name (alist-ref dep 'names '()))))
    (case type
      ((path workspace)
       (license-entry-from-manifest
        type
        scope
        name
        type
        (dependency-root-from-path
         (alist-ref dep 'parent-root ".")
         (alist-ref dep 'path ""))
        (alist-ref dep 'version #f)))
      ((git)
       (license-entry-from-manifest
        'git
        scope
        name
        'git
        (live-git-root dep)
        (alist-ref dep 'version #f)))
      ((registry)
       (license-entry
        'registry
        scope
        name
        (alist-ref dep 'version "*")
        ""
        'unknown
        (alist-ref dep 'registry "default")
        ""))
      ((system)
       (license-entry
        'system
        scope
        (alist-ref dep 'names '())
        #f
        "system"
        'system
        'implementation
        ""))
      (else
       (license-entry
        (or type 'dependency)
        scope
        name
        #f
        ""
        'unknown
        'dependency
        "")))))

(define (locked-entry-type entry)
  (or (lock-entry-type entry)
      (and (pair? entry) (car entry))
      'dependency))

(define (locked-path-root manifest entry)
  (dependency-root-from-path
   (manifest-root manifest)
   (lock-entry-ref entry 'path "")))

(define (locked-git-root entry)
  (let* ((root (locked-git-entry-root entry))
         (subpath (lock-entry-ref entry 'subpath #f)))
    (if subpath (path-join root subpath) root)))

(define (entry-from-lock-entry manifest entry)
  (let ((type (locked-entry-type entry))
        (scope (lock-entry-ref entry 'scope 'runtime))
        (name (lock-entry-ref entry 'name (lock-entry-rest entry 'names))))
    (case type
      ((path workspace)
       (license-entry-from-manifest
        type
        scope
        name
        type
        (locked-path-root manifest entry)
        #f))
      ((git)
       (license-entry-from-manifest
        'git
        scope
        name
        'git
        (locked-git-root entry)
        #f))
      ((registry)
       (license-entry
        'registry
        scope
        name
        (lock-entry-ref entry 'version "")
        ""
        'unknown
        (lock-entry-ref entry 'registry "default")
        ""))
      ((system)
       (license-entry
        'system
        scope
        (lock-entry-rest entry 'names)
        #f
        "system"
        'system
        'implementation
        ""))
      (else
       (license-entry
        type
        scope
        name
        #f
        ""
        'unknown
        'lockfile
        "")))))

(define (license-report manifest features entries source)
  `(license-scan
    (root
     (name ,(package-name manifest))
     (version ,(package-version manifest))
     (features ,@features)
     (source ,source))
    (packages
     ,(root-license-entry manifest)
     ,@entries)))

(define (locked-license-report manifest features lock)
  (license-report
   manifest
   features
   (map (lambda (entry) (entry-from-lock-entry manifest entry))
        (lock-package-entries lock))
   'lockfile))

(define (candidate-license-report manifest features cmd)
  (license-report
   manifest
   features
   (map entry-from-live-dependency
        (all-dependencies-for manifest #t features cmd))
   'candidate))

(define (field-values form key)
  (let ((found (and (pair? form) (assq key (cdr form)))))
    (if found (cdr found) '())))

(define (field-value form key default)
  (let ((values (field-values form key)))
    (cond
     ((null? values) default)
     ((null? (cdr values)) (car values))
     (else values))))

(define (scan-value->json value)
  (cond
   ((symbol? value) (symbol->string value))
   ((or (string? value) (number? value) (boolean? value)) value)
   ((null? value) '#())
   ((pair? value) (list->vector (map scan-value->json value)))
   (else #f)))

(define (package-entry->json entry)
  (map
   (lambda (key)
     (cons key (scan-value->json (field-value entry key #f))))
   '(type scope name version license status source path)))

(define (package-entries->json entries)
  (list->vector (map package-entry->json entries)))

(define (report->json report)
  (let ((root (assq 'root (cdr report)))
        (packages (assq 'packages (cdr report))))
    `((formatVersion . 1)
      (root . ((name . ,(scan-value->json (field-value root 'name '())))
               (version . ,(scan-value->json (field-value root 'version #f)))
               (features . ,(scan-value->json (field-values root 'features)))
               (source . ,(scan-value->json (field-value root 'source #f)))))
      (packages . ,(package-entries->json (if packages (cdr packages) '()))))))

(define (write-report-json report)
  (json-write (report->json report) (current-output-port))
  (newline))

(define (notices-path manifest cmd)
  (let ((dir (command-option cmd "directory" #f)))
    (and dir
         (path-join
          (if (absolute-path? dir) dir (path-join (manifest-root manifest) dir))
          "THIRD_PARTY_NOTICES.txt"))))

(define (write-package-notice out entry)
  (display (name-value->string (field-value entry 'name '())) out)
  (let ((version (field-value entry 'version #f)))
    (when version
      (display " " out)
      (display version out)))
  (display " - " out)
  (display (field-value entry 'license "") out)
  (display " (" out)
  (display (field-value entry 'status 'unknown) out)
  (display ")" out)
  (newline out))

(define (write-notices-file! manifest report cmd)
  (let ((path (notices-path manifest cmd)))
    (when path
      (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
      (call-with-output-file path
        (lambda (out)
          (display "Third Party Notices" out)
          (newline out)
          (display "Generated by kons license-scan." out)
          (newline out)
          (newline out)
          (let ((packages (assq 'packages (cdr report))))
            (for-each (lambda (entry) (write-package-notice out entry))
                      (if packages (cdr packages) '()))))))))

(define (write-license-report cmd manifest report)
  (write-notices-file! manifest report cmd)
  (if (json-format? (command-option cmd "format" "sexp"))
      (write-report-json report)
      (writeln report)))

(define (cmd-license-scan cmd)
  (let* ((manifest (parse-manifest (command-manifest-path cmd)))
         (features (active-features manifest cmd))
         (lock (matching-lock manifest features cmd)))
    (ensure-supported-active-features manifest features cmd)
    (when (and (not lock) (command-locked-mode? cmd))
      (if (file-exists? (command-lock-path manifest cmd))
          (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`")
          (lockfile-error "kons.lock missing; run `kons update` first")))
    (write-license-report
     cmd
     manifest
     (if lock
         (locked-license-report manifest features lock)
         (candidate-license-report manifest features cmd)))))

  ))
