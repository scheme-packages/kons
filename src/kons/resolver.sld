(define-library (kons resolver)
  (export resolve-dependencies
          resolve-dependencies/failure-details
          resolution-packages
          resolution-edges
          candidate-id)
  (import (scheme base)
          (kons util)
          (kons names)
          (kons manifest))

  (begin
(define (resolver-ref alist key default)
  (let ((found (assoc key alist)))
    (if found (cdr found) default)))

(define (requirement-name req) (resolver-ref req 'name '()))
(define (requirement-version req) (resolver-ref req 'version (resolver-ref req 'req "*")))
(define (requirement-registry req) (resolver-ref req 'registry "default"))
(define (requirement-kind req) (resolver-ref req 'kind (resolver-ref req 'scope 'runtime)))
(define (requirement-optional? req) (resolver-ref req 'optional #f))

(define (candidate-name candidate) (resolver-ref candidate 'name '()))
(define (candidate-version candidate) (resolver-ref candidate 'version "0.0.0"))
(define (candidate-registry candidate) (resolver-ref candidate 'registry "default"))
(define (candidate-yanked? candidate) (resolver-ref candidate 'yanked #f))
(define (candidate-dependencies candidate) (resolver-ref candidate 'dependencies '()))

(define (resolution-packages resolution)
  (resolver-ref resolution 'packages '()))

(define (resolution-edges resolution)
  (resolver-ref resolution 'edges '()))

(define (version-core version)
  (let* ((dash (string-index version #\-))
         (plus (string-index version #\+))
         (end (cond
               ((and dash plus) (min dash plus))
               (dash dash)
               (plus plus)
               (else (string-length version)))))
    (substring version 0 end)))

(define (string-index s ch)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (cond
       ((= i len) #f)
       ((char=? (string-ref s i) ch) i)
       (else (loop (+ i 1)))))))

(define (string->integer/default text default)
  (let ((value (string->number text)))
    (if (and value (integer? value)) value default)))

(define (semver-parts version)
  (let ((parts (string-split (version-core version) #\.)))
    (list
     (if (pair? parts) (string->integer/default (car parts) 0) 0)
     (if (and (pair? parts) (pair? (cdr parts))) (string->integer/default (cadr parts) 0) 0)
     (if (and (pair? parts) (pair? (cdr parts)) (pair? (cddr parts)))
         (string->integer/default (car (cddr parts)) 0)
         0))))

(define (compare-number a b)
  (cond
   ((< a b) -1)
   ((> a b) 1)
   (else 0)))

(define (compare-semver a b)
  (let loop ((as (semver-parts a)) (bs (semver-parts b)))
    (cond
     ((null? as) 0)
     ((= (compare-number (car as) (car bs)) 0) (loop (cdr as) (cdr bs)))
     (else (compare-number (car as) (car bs))))))

(define (partial-version->full value)
  (let ((parts (string-split value #\.)))
    (cond
     ((= (length parts) 1) (string-append value ".0.0"))
     ((= (length parts) 2) (string-append value ".0"))
     (else value))))

(define (semver-major parts) (car parts))
(define (semver-minor parts) (cadr parts))
(define (semver-patch parts) (car (cddr parts)))

(define (caret-upper-bound base-parts)
  (cond
   ((> (semver-major base-parts) 0)
    (string-append (number->string (+ (semver-major base-parts) 1)) ".0.0"))
   ((> (semver-minor base-parts) 0)
    (string-append "0." (number->string (+ (semver-minor base-parts) 1)) ".0"))
   (else
    (string-append "0.0." (number->string (+ (semver-patch base-parts) 1))))))

(define (trim-leading-space s)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (if (and (< i len)
               (let ((ch (string-ref s i)))
                 (or (char=? ch #\space)
                     (char=? ch #\tab)
                     (char=? ch #\newline)
                     (char=? ch #\return))))
          (loop (+ i 1))
          (substring s i len)))))

(define (string-prefix? prefix s)
  (let ((plen (string-length prefix)))
    (and (>= (string-length s) plen)
         (string=? prefix (substring s 0 plen)))))

(define (satisfies? version req)
  (let ((req (trim-leading-space req)))
    (cond
     ((or (string=? req "") (string=? req "*")) #t)
     ((char=? (string-ref req 0) #\^)
      (let* ((base (partial-version->full (substring req 1 (string-length req))))
             (base-parts (semver-parts base))
             (upper (caret-upper-bound base-parts)))
        (and (>= (compare-semver version base) 0)
             (< (compare-semver version upper) 0))))
     ((string-prefix? ">=" req)
      (>= (compare-semver version (partial-version->full (trim-leading-space (substring req 2 (string-length req))))) 0))
     ((string-prefix? "<=" req)
      (<= (compare-semver version (partial-version->full (trim-leading-space (substring req 2 (string-length req))))) 0))
     ((char=? (string-ref req 0) #\>)
      (> (compare-semver version (partial-version->full (trim-leading-space (substring req 1 (string-length req))))) 0))
     ((char=? (string-ref req 0) #\<)
      (< (compare-semver version (partial-version->full (trim-leading-space (substring req 1 (string-length req))))) 0))
     ((char=? (string-ref req 0) #\=)
      (= (compare-semver version (partial-version->full (trim-leading-space (substring req 1 (string-length req))))) 0))
     (else (= (compare-semver version (partial-version->full req)) 0)))))

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
  (cons from req))

(define (pending-from pending)
  (car pending))

(define (pending-req pending)
  (cdr pending))

(define (dependency-edge from candidate req)
  `((from . ,from)
    (to . ,(candidate-id candidate))
    (name . ,(requirement-name req))
    (req . ,(requirement-version req))
    (kind . ,(requirement-kind req))))

(define (candidate-pending-dependencies candidate)
  (map (lambda (dep) (make-pending (candidate-id candidate) dep))
       (filter (lambda (dep) (not (requirement-optional? dep)))
               (candidate-dependencies candidate))))

(define (requirement-record from req)
  `((from . ,from)
    (req . ,(requirement-version req))
    (kind . ,(requirement-kind req))))

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
  (append
   (if (and (pair? selected-version) (car selected-version))
       (list (list 'selected-version (car selected-version)))
       '())
   (list (cons 'requirements (constraints-for-key constraints key)))))

(define (resolve-dependencies/result root-requirements universe preferred-refs)
  (let ((last-failure #f))
    (define (record-failure! message name . details)
      (set! last-failure (append (list message (name->string name)) details))
      #f)
    (define (solve pending selected edges constraints)
      (cond
       ((null? pending)
        `((packages . ,(map cdr selected))
          (edges . ,(reverse edges))))
       (else
        (let* ((item (car pending))
               (from (pending-from item))
               (req (pending-req item))
               (name (requirement-name req))
               (registry (requirement-registry req))
               (range (requirement-version req))
               (key (selection-key name registry))
               (next-constraints (add-constraint constraints key from req))
               (existing (selected-candidate selected key)))
          (cond
           ((requirement-optional? req)
            (solve (cdr pending) selected edges constraints))
           ((and existing (satisfies? (candidate-version existing) range))
            (solve (cdr pending)
                   selected
                   (cons (dependency-edge from existing req) edges)
                   next-constraints))
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
                       (next-selected (replace-selected selected key candidate))
                       (next-edges (cons (dependency-edge from candidate req) edges))
                       (next-pending
                        (append (candidate-pending-dependencies candidate)
                                (cdr pending)))
                       (result (solve next-pending next-selected next-edges next-constraints)))
                  (if result
                      result
                      (try (cdr choices) #t))))))))))))
    (let ((result (solve (map (lambda (req) (make-pending 'root req))
                              root-requirements)
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
        (apply dependency-error (cdr result)))))

(define (resolve-dependencies/failure-details root-requirements universe . maybe-preferred-refs)
  (let ((result (resolve-dependencies/result
                 root-requirements
                 universe
                 (if (null? maybe-preferred-refs) '() (car maybe-preferred-refs)))))
    (if (eq? (car result) 'error)
        (cdr result)
        #f)))

  ))
