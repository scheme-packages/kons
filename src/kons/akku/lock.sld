(define-library (kons akku lock)
  (export locked-akku-refs
          akku-resolution-lock-data)
  (import (scheme base)
          (scheme cxr)
          (kons util)
          (kons resolver)
          (kons akku config)
          (kons akku format)
          (kons akku registry)
          (kons akku resolver)
          (kons dep shared))

  (begin
(define (akku-lock-ref alist key default)
  (let ((found (assoc key alist)))
    (if found (cdr found) default)))

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

(define (lock-entry-akku? entry)
  (and (pair? entry)
       (eq? (car entry) 'package)
       (eq? (lock-entry-ref entry 'type #f) 'akku)))

(define (locked-akku-ref entry)
  `((name . ,(lock-entry-ref
              entry
              'resolver-name
              (akku-package-name->resolver-name
               (lock-entry-ref entry 'name '()))))
    (version . ,(lock-entry-ref entry 'version ""))
    (registry . ,(lock-entry-ref entry 'source default-akku-source-alias))))

(define (locked-akku-refs lock)
  (if lock
      (map locked-akku-ref
           (filter lock-entry-akku? (lock-package-entries lock)))
      '()))

(define (edge-ref edge key default)
  (akku-lock-ref edge key default))

(define (edge-for-candidate id edges)
  (let loop ((items edges))
    (cond
     ((null? items) #f)
     ((equal? id (edge-ref (car items) 'to #f)) (car items))
     (else (loop (cdr items))))))

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

(define (akku-requirement-source req)
  (akku-lock-ref req 'registry default-akku-source-alias))

(define (source-known? source sources)
  (let loop ((items sources))
    (cond
     ((null? items) #f)
     ((string=? source (car items)) #t)
     (else (loop (cdr items))))))

(define (unique-akku-sources requirements)
  (let loop ((items requirements) (out '()))
    (cond
     ((null? items) (reverse out))
     (else
      (let ((source (akku-requirement-source (car items))))
        (if (source-known? source out)
            (loop (cdr items) out)
            (loop (cdr items) (cons source out))))))))

(define (akku-source-candidates source offline?)
  (let* ((archive-url (akku-source-url source))
         (metadata (akku-fetch-index! archive-url #f offline?))
         (packages (read-akku-index (akku-index-metadata-index-path metadata))))
    (akku-packages->resolver-candidates packages source)))

(define (akku-key-component value)
  (cond
   ((symbol? value) (symbol->string value))
   ((string? value) value)
   ((number? value) (number->string value))
   (else (lock-value-key value))))

(define (akku-resolver-name->key name)
  (cond
   ((and (pair? name)
         (eq? (car name) 'akku)
         (pair? (cdr name))
         (eq? (cadr name) 'string)
         (pair? (cddr name)))
    (string-append "akku/string/" (safe-store-token (akku-key-component (caddr name)))))
   ((and (pair? name)
         (eq? (car name) 'akku)
         (pair? (cdr name))
         (eq? (cadr name) 'list))
    (let loop ((items (cddr name)) (out "akku/list"))
      (if (null? items)
          out
          (loop (cdr items)
                (string-append out "/" (safe-store-token (akku-key-component (car items))))))))
   (else (safe-store-token (lock-value-key name)))))

(define (akku-field-one fields key default)
  (let ((found (assq key fields)))
    (if (and found (pair? (cdr found)))
        (cadr found)
        default)))

(define (akku-direct-location fields)
  (cond
   ((akku-field-one fields 'git #f)
    => (lambda (remote) `(git ,remote)))
   ((akku-field-one fields 'url #f)
    => (lambda (url) `(url ,url)))
   ((akku-field-one fields 'directory #f)
    => (lambda (path) `(directory ,path)))
   (else #f)))

(define (akku-location-from-fields fields)
  (or (akku-field-one fields 'location #f)
      (akku-direct-location fields)))

(define (akku-candidate-location candidate)
  (let ((location
         (or (akku-location-from-fields (akku-lock-ref candidate 'akku-lock '()))
             (akku-location-from-fields (akku-lock-ref candidate 'akku-source '())))))
    (unless (and (pair? location)
                 (memq (car location) '(git directory url))
                 (pair? (cdr location))
                 (string? (cadr location))
                 (null? (cddr location)))
      (dependency-error "Akku package version is missing a supported source location"
                        (akku-lock-ref candidate 'akku-name '())
                        (akku-lock-ref candidate 'version "")))
    location))

(define (akku-candidate-field candidate key default)
  (or (akku-field-one (akku-lock-ref candidate 'akku-lock '()) key #f)
      (akku-field-one (akku-lock-ref candidate 'akku-source '()) key default)))

(define (akku-candidate-content candidate)
  (or (let ((found (assq 'content (akku-lock-ref candidate 'akku-lock '()))))
        (and found (cdr found)))
      (let ((found (assq 'content (akku-lock-ref candidate 'akku-source '()))))
        (and found (cdr found)))
      '()))

(define (akku-content-sha256 content)
  (let loop ((items content))
    (cond
     ((null? items) #f)
     ((and (pair? (car items))
           (eq? (caar items) 'sha256)
           (pair? (cdar items)))
      (cadar items))
     (else (loop (cdr items))))))

(define (maybe-lock-field key value)
  (if value `((,key ,value)) '()))

(define (akku-source-cache-path key version kind ref tag revision sha256)
  (path-join
   (path-join
    (path-join (akku-sources-root) (symbol->string kind))
    (safe-store-token key))
   (safe-store-token
    (string-append version
                   "-"
                   (or revision tag sha256 ref)))))

(define (akku-source-kind-fields kind ref)
  (case kind
    ((git) `((remote ,ref)))
    ((url) `((url ,ref)))
    ((directory) `((path ,ref)))
    (else '())))

(define (akku-candidate-lock-entry candidate edges)
  (let* ((id (candidate-id candidate))
         (edge (edge-for-candidate id edges))
         (resolver-name (akku-lock-ref candidate 'name '()))
         (key (akku-resolver-name->key resolver-name))
         (version (akku-lock-ref candidate 'version ""))
         (source (akku-lock-ref candidate 'registry default-akku-source-alias))
         (source-url (akku-source-url source))
         (location (akku-candidate-location candidate))
         (source-kind (car location))
         (source-ref (cadr location))
         (tag (akku-candidate-field candidate 'tag #f))
         (revision (akku-candidate-field candidate 'revision #f))
         (sha256 (akku-content-sha256 (akku-candidate-content candidate))))
    (append
     `(package
       (id ,id)
       (scope ,(if edge (edge-ref edge 'kind 'runtime) 'runtime))
       (type akku)
       (name ,(akku-lock-ref candidate 'akku-name '()))
       (resolver-name ,resolver-name)
       (key ,key)
       (req ,(if edge (edge-ref edge 'req "*") "*"))
       (version ,version)
       (source ,source)
       (source-url ,source-url)
       (source-kind ,source-kind))
     (akku-source-kind-fields source-kind source-ref)
     (maybe-lock-field 'tag tag)
     (maybe-lock-field 'revision revision)
     (maybe-lock-field 'url-sha256 sha256)
     `((depends ,(akku-lock-ref candidate 'akku-depends '()))
       (depends/dev ,(akku-lock-ref candidate 'akku-depends/dev '()))
       (conflicts ,(akku-lock-ref candidate 'akku-conflicts '()))
       (source-cache-path
        ,(akku-source-cache-path key version source-kind source-ref tag revision sha256))
       (optional #f)))))

(define (akku-resolution-lock-data deps offline? preferred-refs manifest cmd)
  (let ((requirements (map akku-dependency->resolver-requirement deps)))
    (if (null? requirements)
        (cons '() '())
        (let* ((sources (unique-akku-sources requirements))
               (candidates (append-map
                            (lambda (source)
                              (akku-source-candidates source offline?))
                            sources))
               (resolution (resolve-akku-dependencies
                            requirements
                            candidates
                            preferred-refs))
               (edges (resolution-edges resolution)))
          (cons
           (map (lambda (candidate)
                  (akku-candidate-lock-entry candidate edges))
                (resolution-packages resolution))
           (map lock-edge-entry edges))))))

  ))
