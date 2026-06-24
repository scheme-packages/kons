(define-library (kons lock)
  (export dependency-lock-entry
          read-lockfile
          lock-root-name
          lock-root-version
          lock-root-scheme
          lock-root-dialect
          lock-root-target
          lock-root-profile
          lock-root-compile-mode
          lock-root-source-hash
          lock-root-features
          lock-package-entries
          lock-edge-entries
          lock-entry-type
          lock-entry-ref
          make-lock)
  (import (scheme base)
          (kons util)
          (kons names)
          (kons implementation)
          (kons manifest)
          (kons features)
          (kons options)
          (kons registry)
          (kons resolver)
          (kons dep shared)
          (kons dep git)
          (kons dep path)
          (kons dep registry)
          (kons dep workspace)
          (kons dep system))

  (begin
(define (dependency-lock-entry manifest dep)
  (let ((type (alist-ref dep 'type #f)))
    (case type
      ((path) (path-lock-entry manifest dep))
      ((workspace) (workspace-lock-entry manifest dep))
      ((git) (git-lock-entry manifest dep))
      ((registry) (registry-lock-entry manifest dep))
      ((system) (system-lock-entry manifest dep))
      (else (dependency-error "cannot lock unknown dependency type" type)))))

(define (read-lockfile path)
  (let ((exprs (read-all-exprs path)))
    (if (null? exprs)
        (lockfile-error "lockfile is empty" path)
        (car exprs))))

(define (lock-root-name lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (name-form (and root-form (assq 'name (cdr root-form)))))
    (if name-form (cadr name-form) '())))

(define (lock-root-version lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (version-form (and root-form (assq 'version (cdr root-form)))))
    (and version-form (cadr version-form))))

(define (lock-root-scheme lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (scheme-form (and root-form (assq 'scheme (cdr root-form)))))
    (and scheme-form (cadr scheme-form))))

(define (lock-root-dialect lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (dialect-form (and root-form (assq 'dialect (cdr root-form)))))
    (and dialect-form (cadr dialect-form))))

(define (lock-root-target lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (target-form (and root-form (assq 'target (cdr root-form)))))
    (and target-form (cadr target-form))))

(define (lock-root-profile lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (profile-form (and root-form (assq 'profile (cdr root-form)))))
    (if profile-form (cadr profile-form) 'debug)))

(define (lock-root-compile-mode lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (mode-form (and root-form (assq 'compile-mode (cdr root-form)))))
    (and mode-form (cadr mode-form))))

(define (lock-root-source-hash lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (hash-form (and root-form (assq 'source-hash (cdr root-form)))))
    (and hash-form (cadr hash-form))))

(define (lock-root-features lock)
  (let* ((root-form (assq 'root (cdr lock)))
         (features-form (and root-form (assq 'features (cdr root-form)))))
    (if features-form (cdr features-form) '())))

(define (lock-edge-entries lock)
  (let ((edges-form (and (pair? lock) (assq 'edges (cdr lock)))))
    (if edges-form (cdr edges-form) '())))

(define (lock-value-key value)
  (cond
   ((symbol? value) (symbol->string value))
   ((string? value) value)
   ((number? value) (number->string value))
   ((null? value) "")
   ((pair? value)
    (let loop ((items value) (out ""))
      (cond
       ((null? items) out)
       ((string=? out "") (loop (cdr items) (lock-value-key (car items))))
       (else
        (loop (cdr items)
              (string-append out "/" (lock-value-key (car items))))))))
   (else "value")))

(define (lock-entry-sort-key entry)
  (cond
   ((and (pair? entry) (eq? (car entry) 'package))
    (string-append
     "package:"
     (lock-value-key (lock-entry-ref entry 'type 'unknown))
     ":"
     (lock-value-key (lock-entry-ref entry 'name '()))))
   ((and (pair? entry) (eq? (car entry) 'system))
    (let ((names-form (assq 'names (cdr entry))))
      (string-append
       "system:"
       (lock-value-key (if names-form (cdr names-form) '())))))
   (else (lock-value-key entry))))

(define (lock-entry<? a b)
  (string<? (lock-entry-sort-key a) (lock-entry-sort-key b)))

(define (insert-lock-entry entry sorted)
  (cond
   ((null? sorted) (list entry))
   ((lock-entry<? entry (car sorted)) (cons entry sorted))
   (else (cons (car sorted) (insert-lock-entry entry (cdr sorted))))))

(define (sort-lock-entries entries)
  (let loop ((rest entries) (out '()))
    (if (null? rest)
        out
        (loop (cdr rest) (insert-lock-entry (car rest) out)))))

(define (registry-dependency? dep)
  (eq? (alist-ref dep 'type #f) 'registry))

(define (selected-registry-dependency? dep)
  (and (registry-dependency? dep)
       (not (alist-ref dep 'optional #f))))

(define (non-registry-dependency? dep)
  (not (registry-dependency? dep)))

(define (registry-requirement dep)
  (append
   `((name . ,(alist-ref dep 'name '()))
     (version . ,(alist-ref dep 'version "*"))
     (registry . ,(registry-ref (alist-ref dep 'registry #f)))
     (kind . ,(alist-ref dep 'scope 'runtime))
     (optional . ,(alist-ref dep 'optional #f))
     (features . ,(alist-ref dep 'features '())))
   (dependency-selector-fields dep)))

(define (requirement-key req)
  (string-append
   (alist-ref req 'registry default-registry-alias)
   ":"
   (name->string (alist-ref req 'name '()))))

(define (candidate-known? candidate candidates)
  (let ((id (candidate-id candidate)))
    (let loop ((items candidates))
      (cond
       ((null? items) #f)
       ((string=? id (candidate-id (car items))) #t)
       (else (loop (cdr items)))))))

(define (replace-candidate-field candidate key value)
  (let loop ((items candidate) (out '()) (done? #f))
    (cond
     ((null? items)
      (reverse (if done? out (cons (cons key value) out))))
     ((eq? (caar items) key)
      (loop (cdr items) (cons (cons key value) out) #t))
     (else
      (loop (cdr items) (cons (car items) out) done?)))))

(define (feature-dependency-with-applicable-dependencies feature-dep manifest cmd)
  (let ((deps (filter (lambda (dep) (dependency-applies? dep manifest cmd))
                      (alist-ref feature-dep 'dependencies '()))))
    (replace-candidate-field feature-dep 'dependencies deps)))

(define (candidate-with-applicable-dependencies candidate manifest cmd)
  (let ((deps (filter (lambda (dep) (dependency-applies? dep manifest cmd))
                      (alist-ref candidate 'dependencies '())))
        (feature-deps
         (map (lambda (feature-dep)
                (feature-dependency-with-applicable-dependencies
                 feature-dep
                 manifest
                 cmd))
              (alist-ref candidate 'feature-dependencies '()))))
    (replace-candidate-field
     (replace-candidate-field candidate 'dependencies deps)
     'feature-dependencies
     feature-deps)))

(define (candidate-feature-dependencies-for-universe candidate)
  (append-map
   (lambda (item)
     (alist-ref item 'dependencies '()))
   (alist-ref candidate 'feature-dependencies '())))

(define (candidate-dependencies-for-universe candidate)
  (append (alist-ref candidate 'dependencies '())
          (candidate-feature-dependencies-for-universe candidate)))

(define (requirement-known? req seen)
  (let ((key (requirement-key req)))
    (let loop ((items seen))
      (cond
       ((null? items) #f)
       ((string=? key (car items)) #t)
       (else (loop (cdr items)))))))

(define (collect-registry-universe requirements offline? manifest cmd)
  (let loop ((pending requirements) (seen '()) (out '()))
    (cond
     ((null? pending) out)
     ((requirement-known? (car pending) seen)
      (loop (cdr pending) seen out))
     (else
      (let* ((req (car pending))
             (registry (alist-ref req 'registry default-registry-alias))
             (name (alist-ref req 'name '()))
             (candidates (registry-package-candidates registry name offline?))
             (new-candidates
              (map (lambda (candidate)
                     (candidate-with-applicable-dependencies candidate manifest cmd))
                   (filter (lambda (candidate)
                             (not (candidate-known? candidate out)))
                           candidates)))
             (candidate-deps
              (append-map
               (lambda (candidate)
                 (candidate-dependencies-for-universe candidate))
               new-candidates)))
        (loop (append (cdr pending) candidate-deps)
              (cons (requirement-key req) seen)
              (append out new-candidates)))))))

(define (edge-ref edge key default)
  (alist-ref edge key default))

(define (edge-for-candidate id edges)
  (let loop ((items edges))
    (cond
     ((null? items) #f)
     ((equal? id (edge-ref (car items) 'to #f)) (car items))
     (else (loop (cdr items))))))

(define (registry-candidate-lock-entry candidate edges)
  (let* ((id (candidate-id candidate))
         (edge (edge-for-candidate id edges)))
    `(package
      (id ,id)
      (scope ,(if edge (edge-ref edge 'kind 'runtime) 'runtime))
      (type registry)
      (name ,(alist-ref candidate 'name '()))
      (req ,(if edge (edge-ref edge 'req "*") "*"))
      (version ,(alist-ref candidate 'version ""))
      (registry ,(alist-ref candidate 'registry default-registry-alias))
      (checksum ,(alist-ref candidate 'checksum ""))
      (download ,(alist-ref candidate 'download ""))
      (optional #f)
      (features ,@(alist-ref candidate 'resolved-features '())))))

(define (lock-entry-registry? entry)
  (and (pair? entry)
       (eq? (car entry) 'package)
       (eq? (lock-entry-ref entry 'type #f) 'registry)))

(define (locked-registry-ref entry)
  `((name . ,(lock-entry-ref entry 'name '()))
    (version . ,(lock-entry-ref entry 'version ""))
    (registry . ,(lock-entry-ref entry 'registry default-registry-alias))))

(define (locked-registry-refs lock)
  (if lock
      (map locked-registry-ref
           (filter lock-entry-registry? (lock-package-entries lock)))
      '()))

(define (lock-edge-entry edge)
  `(edge
    (from ,(edge-ref edge 'from 'root))
    (to ,(edge-ref edge 'to ""))
    (name ,(edge-ref edge 'name '()))
    (req ,(edge-ref edge 'req "*"))
    (kind ,(edge-ref edge 'kind 'runtime))
    (features ,@(edge-ref edge 'features '()))
    (optional ,(edge-ref edge 'optional #f))
    ,@(dependency-selector-fields edge)))

(define (registry-resolution-lock-data deps offline? preferred-refs manifest cmd)
  (let ((requirements (map registry-requirement deps)))
    (if (null? requirements)
        (cons '() '())
        (let* ((universe (collect-registry-universe requirements offline? manifest cmd))
               (resolution (resolve-dependencies requirements universe preferred-refs))
               (edges (resolution-edges resolution)))
          (cons
           (map (lambda (candidate)
                  (registry-candidate-lock-entry candidate edges))
                (resolution-packages resolution))
           (map lock-edge-entry edges))))))

(define (workspace-root-manifest-path cmd)
  (command-option cmd "workspace-root" #f))

(define (workspace-member-manifest-path workspace member)
  (path-join (path-join (manifest-root workspace) member) "kons.scm"))

(define (workspace-member-manifests cmd)
  (let ((workspace-path (workspace-root-manifest-path cmd)))
    (if workspace-path
        (let ((workspace (parse-manifest workspace-path)))
          (if (manifest-workspace? workspace)
              (map
               (lambda (member)
                 (parse-manifest
                  (workspace-member-manifest-path workspace member)))
               (workspace-members workspace))
              '()))
        '())))

(define (workspace-lock-dependencies manifest include-dev? features cmd)
  (let ((members (workspace-member-manifests cmd)))
    (if (null? members)
        (all-dependencies-for manifest include-dev? features cmd)
        (append-map
         (lambda (member-manifest)
           (all-dependencies-for member-manifest include-dev? features cmd))
         members))))

(define (entry-present? entry entries)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((equal? entry (car items)) #t)
     (else (loop (cdr items))))))

(define (dedupe-lock-entries entries)
  (let loop ((items entries) (out '()))
    (cond
     ((null? items) (reverse out))
     ((entry-present? (car items) out) (loop (cdr items) out))
     (else (loop (cdr items) (cons (car items) out))))))

(define (make-lock manifest features cmd . maybe-args)
  (let* ((include-dev? (if (null? maybe-args) #t (car maybe-args)))
         (previous-lock (if (or (null? maybe-args) (null? (cdr maybe-args)))
                            #f
                            (cadr maybe-args)))
         (deps (workspace-lock-dependencies manifest include-dev? features cmd))
         (offline? (or (command-flag? cmd "offline")
                       (command-flag? cmd "frozen")))
         (preferred-refs (if (command-flag? cmd "upgrade")
                             '()
                             (locked-registry-refs previous-lock)))
         (registry-data (registry-resolution-lock-data
                         (filter selected-registry-dependency? deps)
                         offline?
                         preferred-refs
                         manifest
                         cmd))
         (registry-entries (car registry-data))
         (registry-edges (cdr registry-data))
         (package-entries
          (sort-lock-entries
           (dedupe-lock-entries
            (append
             (map (lambda (dep) (dependency-lock-entry manifest dep))
                  (filter non-registry-dependency? deps))
             registry-entries))))
        (override-entries
         (sort-lock-entries
          (map (lambda (dep) (dependency-lock-entry manifest dep))
               (alist-ref manifest 'overrides '())))))
    `(lockfile
      (version ,kons-version)
      (root
       (name ,(package-name manifest))
       (version ,(package-version manifest))
       (scheme ,(command-selected-scheme cmd))
       (dialect ,(command-selected-dialect manifest cmd))
       (target ,(command-option cmd "target" #f))
       (profile ,(command-selected-profile cmd))
       (compile-mode ,(command-selected-compile-mode cmd))
       (features ,@features))
      (packages
       ,@package-entries)
      (edges
       ,@registry-edges)
      (overrides
       ,@override-entries))))
  ))
