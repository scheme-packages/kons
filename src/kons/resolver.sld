(define-library (kons resolver)
  (export resolve-dependencies
          resolve-dependencies/failure-details
          resolution-packages
          resolution-edges
          candidate-id)
  (import (scheme base)
          (kons util)
          (kons names)
          (kons semver)
          (kons manifest)
          (kons dep shared))

  (begin
(define (resolver-ref alist key default)
  (let ((found (assoc key alist)))
    (if found (cdr found) default)))

(define (resolver-field-ref fields key default)
  (let ((found (assoc key fields)))
    (if found (cdr found) default)))

(define-record-type <resolution>
  (make-resolution packages edges)
  resolution?
  (packages resolution-record-packages)
  (edges resolution-record-edges))

(define (requirement-name req) (resolver-ref req 'name '()))
(define (requirement-version req) (resolver-ref req 'version (resolver-ref req 'req "*")))
(define (requirement-registry req) (resolver-ref req 'registry "default"))
(define (requirement-kind req) (resolver-ref req 'kind (resolver-ref req 'scope 'runtime)))
(define (requirement-optional? req) (resolver-ref req 'optional #f))
(define (requirement-activated-optional? req) (resolver-ref req 'activated-optional #f))
(define (requirement-features req) (resolver-ref req 'features '()))

(define (candidate-name candidate) (resolver-ref candidate 'name '()))
(define (candidate-version candidate) (resolver-ref candidate 'version "0.0.0"))
(define (candidate-registry candidate) (resolver-ref candidate 'registry "default"))
(define (candidate-yanked? candidate) (resolver-ref candidate 'yanked #f))
(define (candidate-dependencies candidate) (resolver-ref candidate 'dependencies '()))
(define (candidate-feature-dependencies candidate) (resolver-ref candidate 'feature-dependencies '()))
(define (candidate-resolved-features candidate) (resolver-ref candidate 'resolved-features '()))

(define (resolution-packages resolution)
  (if (resolution? resolution)
      (resolution-record-packages resolution)
      (resolver-ref resolution 'packages '())))

(define (resolution-edges resolution)
  (if (resolution? resolution)
      (resolution-record-edges resolution)
      (resolver-ref resolution 'edges '())))

(define (satisfies? version req)
  (semver-satisfies? version req))

(define (candidate-matches? candidate name registry req)
  (and (equal? (candidate-name candidate) name)
       (string=? (candidate-registry candidate) registry)
       (not (candidate-yanked? candidate))
       (satisfies? (candidate-version candidate) req)))

(define (candidate-matches-preferred? candidate name registry req preferred)
  (and (equal? (candidate-name candidate) name)
       (string=? (candidate-registry candidate) registry)
       (string=? (candidate-version candidate) (resolver-ref preferred 'version ""))
       (satisfies? (candidate-version candidate) req)))

(define (insert-candidate candidate sorted)
  (cond
   ((null? sorted) (list candidate))
   ((> (compare-semver (candidate-version candidate)
                       (candidate-version (car sorted)))
       0)
    (cons candidate sorted))
   (else (cons (car sorted) (insert-candidate candidate (cdr sorted))))))

(define (sort-candidates candidates)
  (let loop ((items candidates) (out '()))
    (if (null? items)
        out
        (loop (cdr items) (insert-candidate (car items) out)))))

(define (matching-candidates universe name registry req)
  (sort-candidates
   (filter (lambda (candidate)
             (candidate-matches? candidate name registry req))
           universe)))

(define (preferred-ref-matches? preferred name registry)
  (and (equal? (resolver-ref preferred 'name '()) name)
       (string=? (resolver-ref preferred 'registry "default") registry)))

(define (preferred-ref preferred-refs name registry)
  (let loop ((items preferred-refs))
    (cond
     ((null? items) #f)
     ((preferred-ref-matches? (car items) name registry) (car items))
     (else (loop (cdr items))))))

(define (preferred-candidate universe name registry req preferred-refs)
  (let ((preferred (preferred-ref preferred-refs name registry)))
    (and preferred
         (let loop ((items universe))
           (cond
            ((null? items) #f)
            ((candidate-matches-preferred? (car items) name registry req preferred)
             (car items))
            (else (loop (cdr items))))))))

(define (candidate-same-version? a b)
  (and (equal? (candidate-name a) (candidate-name b))
       (string=? (candidate-registry a) (candidate-registry b))
       (string=? (candidate-version a) (candidate-version b))))

(define (candidate-choices universe name registry req preferred-refs)
  (let ((preferred (preferred-candidate universe name registry req preferred-refs))
        (matches (matching-candidates universe name registry req)))
    (if preferred
        (cons preferred
              (filter (lambda (candidate)
                        (not (candidate-same-version? candidate preferred)))
                      matches))
        matches)))

(define (selection-key name registry)
  (string-append registry ":" (name->string name)))

(define (candidate-id candidate)
  (string-append
   "registry:"
   (candidate-registry candidate)
   ":"
   (name->string (candidate-name candidate))
   ":"
   (candidate-version candidate)))

(define (alist-set-local alist key value)
  (let loop ((items alist) (out '()) (done? #f))
    (cond
     ((null? items)
      (reverse (if done? out (cons (cons key value) out))))
     ((equal? (caar items) key)
      (loop (cdr items) (cons (cons key value) out) #t))
     (else
      (loop (cdr items) (cons (car items) out) done?)))))

(define-record-type <pending-requirement>
  (make-pending-requirement from requirement)
  pending-requirement?
  (from pending-from)
  (requirement pending-req))

(define-record-type <feature-update>
  (make-feature-update features changed? selected-features)
  feature-update?
  (features feature-update-features)
  (changed? feature-update-changed?)
  (selected-features feature-update-selected-features))

(define-record-type <resolver-conflict>
  (make-resolver-conflict package selected-version requirements)
  resolver-conflict?
  (package resolver-conflict-package)
  (selected-version resolver-conflict-selected-version)
  (requirements resolver-conflict-requirements))

(define (feature-key feature)
  (cond
   ((symbol? feature) (symbol->string feature))
   ((string? feature) feature)
   (else "")))

(define (feature-list-contains? features feature)
  (let ((key (feature-key feature)))
    (let loop ((items features))
      (cond
       ((null? items) #f)
       ((string=? key (feature-key (car items))) #t)
       (else (loop (cdr items)))))))

(define (merge-features left right)
  (let loop ((items right) (out left))
    (cond
     ((null? items) out)
     ((feature-list-contains? out (car items))
      (loop (cdr items) out))
     (else
      (loop (cdr items) (append out (list (car items))))))))

(define (name-last-part name)
  (let loop ((items name) (last #f))
    (cond
     ((null? items) last)
     (else (loop (cdr items) (car items))))))

(define (feature-activates-dependency? feature dep)
  (let ((feature (feature-key feature))
        (name (requirement-name dep)))
    (or (string=? feature (name->string name))
        (let ((last (name-last-part name)))
          (and last (string=? feature (feature-key last)))))))

(define (optional-dependency-active? dep features)
  (or (not (requirement-optional? dep))
      (let loop ((items features))
        (cond
         ((null? items) #f)
         ((feature-activates-dependency? (car items) dep) #t)
         (else (loop (cdr items)))))))

(define (candidate-with-resolved-features candidate features)
  (alist-set-local candidate 'resolved-features features))

(define (selected-candidate selected key)
  (resolver-ref selected key #f))

(define (replace-selected selected key candidate)
  (let loop ((items selected) (out '()) (done? #f))
    (cond
     ((null? items) (reverse (if done? out (cons (cons key candidate) out))))
     ((string=? (caar items) key)
      (loop (cdr items) (cons (cons key candidate) out) #t))
     (else (loop (cdr items) (cons (car items) out) done?)))))

(define (make-pending from req)
  (make-pending-requirement from req))

(define (dependency-edge from candidate req)
  (append
   `((from . ,from)
     (to . ,(candidate-id candidate))
     (name . ,(requirement-name req))
     (req . ,(requirement-version req))
     (kind . ,(requirement-kind req))
     (features . ,(requirement-features req))
     (optional . ,(requirement-optional? req)))
   (dependency-selector-fields req)))

(define (feature-dependency-feature item)
  (resolver-ref item 'feature #f))

(define (feature-dependency-requirements item)
  (resolver-ref item 'dependencies '()))

(define (feature-dependency-active? item features)
  (let ((feature (feature-dependency-feature item)))
    (and feature (feature-list-contains? features feature))))

(define (candidate-active-feature-dependencies candidate features)
  (append-map
   feature-dependency-requirements
   (filter (lambda (item) (feature-dependency-active? item features))
           (candidate-feature-dependencies candidate))))

(define (candidate-active-dependencies candidate features)
  (append (candidate-dependencies candidate)
          (candidate-active-feature-dependencies candidate features)))

(define (candidate-pending-dependencies candidate features)
  (map (lambda (dep)
         (make-pending
          (candidate-id candidate)
          (if (requirement-optional? dep)
              (alist-set-local dep 'activated-optional #t)
              dep)))
       (filter (lambda (dep) (optional-dependency-active? dep features))
               (candidate-active-dependencies candidate features))))

(define (feature-update-for-requirement selected-features key req)
  (let* ((old-features (resolver-ref selected-features key '()))
         (new-features (merge-features old-features (requirement-features req)))
         (changed? (not (equal? old-features new-features))))
    (make-feature-update
     new-features
     changed?
     (if changed?
         (alist-set-local selected-features key new-features)
         selected-features))))

(define (candidate-with-feature-update candidate update)
  (candidate-with-resolved-features candidate (feature-update-features update)))

(define (additional-pending-for-feature-update candidate update)
  (if (feature-update-changed? update)
      (candidate-pending-dependencies candidate (feature-update-features update))
      '()))

(define (pending-for-new-candidate candidate update)
  (candidate-pending-dependencies candidate (feature-update-features update)))

(define (requirement-record from req)
  (append
   `((from . ,from)
     (req . ,(requirement-version req))
     (kind . ,(requirement-kind req))
     (features . ,(requirement-features req))
     (optional . ,(requirement-optional? req)))
   (dependency-selector-fields req)))

(define (constraints-for-key constraints key)
  (resolver-ref constraints key '()))

(define (add-constraint constraints key from req)
  (let ((record (requirement-record from req)))
    (let loop ((items constraints) (out '()) (done? #f))
      (cond
       ((null? items)
        (reverse
         (if done?
             out
             (cons (cons key (list record)) out))))
       ((string=? (caar items) key)
        (loop (cdr items)
              (cons (cons key (append (cdar items) (list record))) out)
              #t))
       (else
        (loop (cdr items) (cons (car items) out) done?))))))

(define (conflict-details constraints key . selected-version)
  (list
   (resolver-conflict->detail
    (make-resolver-conflict
     key
     (if (and (pair? selected-version) (car selected-version))
         (car selected-version)
         #f)
     (constraints-for-key constraints key)))))

(define (selector-list record key)
  (let ((value (resolver-field-ref record key '())))
    (cond
     ((null? value) '())
     ((pair? value) value)
     (else (list value)))))

(define (requirement-detail record)
  `((from . ,(resolver-field-ref record 'from 'root))
    (req . ,(resolver-field-ref record 'req "*"))
    (kind . ,(resolver-field-ref record 'kind 'runtime))
    (features . ,(list->vector (selector-list record 'features)))
    (optional . ,(resolver-field-ref record 'optional #f))
    (schemes . ,(list->vector (selector-list record 'schemes)))
    (targets . ,(list->vector (selector-list record 'targets)))
    (profiles . ,(list->vector (selector-list record 'profiles)))
    (compile-modes . ,(list->vector (selector-list record 'compile-modes)))))

(define (resolver-conflict->detail conflict)
  `((reason . resolver-conflict)
    (package . ,(resolver-conflict-package conflict))
    ,@(if (resolver-conflict-selected-version conflict)
          `((selected-version . ,(resolver-conflict-selected-version conflict)))
          '())
    (requirements . ,(list->vector
                      (map requirement-detail
                           (resolver-conflict-requirements conflict))))))

(define (resolve-dependencies/result root-requirements universe preferred-refs)
  (let ((last-failure #f))
    (define (record-failure! message name . details)
      (set! last-failure (append (list message (name->string name)) details))
      #f)
    (define (solve pending selected edges constraints selected-features)
      (cond
       ((null? pending)
        (make-resolution (map cdr selected) (reverse edges)))
       (else
        (let* ((item (car pending))
               (from (pending-from item))
               (req (pending-req item))
               (name (requirement-name req))
               (registry (requirement-registry req))
               (range (requirement-version req))
               (key (selection-key name registry))
               (next-constraints (add-constraint constraints key from req))
               (existing (selected-candidate selected key))
               (feature-update (feature-update-for-requirement selected-features key req)))
          (cond
           ((and (requirement-optional? req)
                 (not (requirement-activated-optional? req)))
            (solve (cdr pending) selected edges constraints selected-features))
           ((and existing (satisfies? (candidate-version existing) range))
            (solve (append (additional-pending-for-feature-update existing feature-update)
                           (cdr pending))
                   (replace-selected selected key (candidate-with-feature-update existing feature-update))
                   (cons (dependency-edge from existing req) edges)
                   next-constraints
                   (feature-update-selected-features feature-update)))
           (existing
            (apply record-failure!
                   "dependency version conflict"
                   name
                   (conflict-details next-constraints key (candidate-version existing))))
           (else
            (let try ((choices (candidate-choices universe name registry range preferred-refs))
                      (attempted? #f))
              (cond
               ((null? choices)
                (if attempted?
                    #f
                    (apply record-failure!
                           "no matching package version"
                           name
                           (conflict-details next-constraints key))))
               (else
                (let* ((candidate (car choices))
                       (candidate-with-features
                        (candidate-with-feature-update candidate feature-update))
                       (next-selected
                        (replace-selected selected key candidate-with-features))
                       (next-edges
                        (cons (dependency-edge from candidate req) edges))
                       (next-pending
                        (append (pending-for-new-candidate candidate feature-update)
                                (cdr pending)))
                       (result
                        (solve next-pending
                               next-selected
                               next-edges
                               next-constraints
                               (feature-update-selected-features feature-update))))
                  (if result
                      result
                      (try (cdr choices) #t))))))))))))
    (let ((result (solve (map (lambda (req) (make-pending 'root req))
                              root-requirements)
                         '()
                         '()
                         '()
                         '())))
      (if result
          (cons 'ok result)
          (cons 'error
                (if last-failure
                    last-failure
                    (list "dependency resolution failed")))))))

(define (resolve-dependencies root-requirements universe . maybe-preferred-refs)
  (let ((result (resolve-dependencies/result
                 root-requirements
                 universe
                 (if (null? maybe-preferred-refs) '() (car maybe-preferred-refs)))))
    (if (eq? (car result) 'ok)
        (cdr result)
        (apply dependency-error
               (append (cdr result)
                       (list '(diagnostic-code . "resolver-conflict")))))))

(define (resolve-dependencies/failure-details root-requirements universe . maybe-preferred-refs)
  (let ((result (resolve-dependencies/result
                 root-requirements
                 universe
                 (if (null? maybe-preferred-refs) '() (car maybe-preferred-refs)))))
    (if (eq? (car result) 'error)
        (cdr result)
        #f)))

  ))
