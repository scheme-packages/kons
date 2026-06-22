(define-library (kons lock)
  (export dependency-lock-entry
          read-lockfile
          lock-root-name
          lock-root-version
          lock-root-scheme
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
  `((name . ,(alist-ref dep 'name '()))
    (version . ,(alist-ref dep 'version "*"))
    (registry . ,(registry-ref (alist-ref dep 'registry #f)))
    (kind . ,(alist-ref dep 'scope 'runtime))
    (optional . ,(alist-ref dep 'optional #f))
    (features . ,(alist-ref dep 'features '()))))

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

(define (requirement-known? req seen)
  (let ((key (requirement-key req)))
    (let loop ((items seen))
      (cond
       ((null? items) #f)
       ((string=? key (car items)) #t)
       (else (loop (cdr items)))))))

(define (collect-registry-universe requirements offline?)
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
              (filter (lambda (candidate)
                        (not (candidate-known? candidate out)))
                      candidates))
             (candidate-deps
              (append-map
               (lambda (candidate)
                 (filter (lambda (dep)
                           (not (alist-ref dep 'optional #f)))
                         (alist-ref candidate 'dependencies '())))
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
      (features ,@(alist-ref candidate 'features '())))))

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
    (kind ,(edge-ref edge 'kind 'runtime))))

(define (registry-resolution-lock-data deps offline? preferred-refs)
  (let ((requirements (map registry-requirement deps)))
    (if (null? requirements)
        (cons '() '())
        (let* ((universe (collect-registry-universe requirements offline?))
               (resolution (resolve-dependencies requirements universe preferred-refs))
               (edges (resolution-edges resolution)))
          (cons
           (map (lambda (candidate)
                  (registry-candidate-lock-entry candidate edges))
                (resolution-packages resolution))
           (map lock-edge-entry edges))))))

(define (make-lock manifest features cmd . maybe-args)
  (let* ((include-dev? (if (null? maybe-args) #t (car maybe-args)))
         (previous-lock (if (or (null? maybe-args) (null? (cdr maybe-args)))
                            #f
                            (cadr maybe-args)))
         (deps (all-dependencies-for manifest include-dev? features cmd))
         (offline? (or (command-flag? cmd "offline")
                       (command-flag? cmd "frozen")))
         (preferred-refs (if (command-flag? cmd "upgrade")
                             '()
                             (locked-registry-refs previous-lock)))
         (registry-data (registry-resolution-lock-data
                         (filter selected-registry-dependency? deps)
                         offline?
                         preferred-refs))
         (registry-entries (car registry-data))
         (registry-edges (cdr registry-data))
         (package-entries
          (sort-lock-entries
           (append
            (map (lambda (dep) (dependency-lock-entry manifest dep))
                                   (filter non-registry-dependency? deps))
            registry-entries)))
        (override-entries
         (sort-lock-entries
          (map (lambda (dep) (dependency-lock-entry manifest dep))
               (alist-ref manifest 'overrides '())))))
    `(lockfile
      (version ,kons-version)
      (root
       (name ,(package-name manifest))
       (version ,(package-version manifest))
       (features ,@features))
      (packages
       ,@package-entries)
      (edges
       ,@registry-edges)
      (overrides
       ,@override-entries))))
  ))
