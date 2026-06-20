(define-library (kons actions lock-shared)
  (export lock-entry-rest
          lock-entry-scope
          lock-entry-summary-key
          short-token
          lock-entry-summary-label
          lock-entry-summary-token
          find-lock-summary-entry
          display-update-change
          display-added-lock-entries
          display-changed-lock-entries
          display-removed-lock-entries
          display-update-summary
          lock-value-key
          dependency-lock-key
          lock-entry-key-for-coverage
          lock-entry-key-present?
          direct-dependencies-for-lock-coverage
          ensure-lock-covers-direct-dependencies
          lock-root-matches?
          lock-resolution-current?
          root-source-hash
          activation-lock-compatible?
          activation-lock-fast-ready?
          stored-lockfile
          lock-status
          lock-completeness-status)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons util)
          (kons manifest)
          (kons features)
          (kons lock)
          (kons runner)
          (kons options)
          (kons actions paths))

  (begin
(define (lock-entry-rest entry key)
  (let ((field (and (pair? entry) (assq key (cdr entry)))))
    (if field (cdr field) '())))

(define (lock-entry-scope entry)
  (lock-entry-ref entry 'scope 'runtime))

(define (lock-entry-summary-key entry)
  (cond
   ((and (pair? entry) (eq? (car entry) 'system))
    (string-append
     "system:"
     (lock-value-key (lock-entry-scope entry))
     ":"
     (lock-value-key (lock-entry-rest entry 'names))))
   ((lock-entry-type entry)
    (string-append
     (symbol->string (lock-entry-type entry))
     ":"
     (lock-value-key (lock-entry-scope entry))
     ":"
     (lock-value-key (lock-entry-ref entry 'name '()))))
   (else (lock-value-key entry))))

(define (short-token value)
  (let ((text (lock-value-key value)))
    (if (> (string-length text) 12)
        (substring text 0 12)
        text)))

(define (lock-entry-summary-label entry)
  (cond
   ((and (pair? entry) (eq? (car entry) 'system))
    (string-append
     "system "
     (lock-value-key (lock-entry-scope entry))
     " "
     (lock-value-key (lock-entry-rest entry 'names))))
   ((lock-entry-type entry)
    (string-append
     (symbol->string (lock-entry-type entry))
     " "
     (lock-value-key (lock-entry-scope entry))
     " "
     (lock-value-key (lock-entry-ref entry 'name '()))))
   (else (lock-value-key entry))))

(define (lock-entry-summary-token entry)
  (cond
   ((and (pair? entry) (eq? (car entry) 'system))
    "")
   ((eq? (lock-entry-type entry) 'path)
    (short-token (lock-entry-ref entry 'source-hash #f)))
   ((eq? (lock-entry-type entry) 'workspace)
    (short-token (lock-entry-ref entry 'source-hash #f)))
   ((eq? (lock-entry-type entry) 'git)
    (short-token (lock-entry-ref entry 'commit #f)))
   (else "")))

(define (find-lock-summary-entry key entries)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((equal? key (lock-entry-summary-key (car items))) (car items))
     (else (loop (cdr items))))))

(define (display-update-change action entry . old-entry)
  (let ((token (lock-entry-summary-token entry)))
    (display action)
    (display " ")
    (display (lock-entry-summary-label entry))
    (unless (string=? token "")
      (display " ")
      (display token))
    (when (and (pair? old-entry) (car old-entry))
      (let ((old-token (lock-entry-summary-token (car old-entry))))
        (unless (or (string=? old-token "")
                    (string=? old-token token))
          (display " from ")
          (display old-token)))))
  (newline))

(define (display-added-lock-entries old-entries new-entries)
  (let loop ((items new-entries) (count 0))
    (cond
     ((null? items) count)
     ((find-lock-summary-entry (lock-entry-summary-key (car items)) old-entries)
      (loop (cdr items) count))
     (else
      (display-update-change "added" (car items))
      (loop (cdr items) (+ count 1))))))

(define (display-changed-lock-entries old-entries new-entries)
  (let loop ((items new-entries) (count 0))
    (cond
     ((null? items) count)
     (else
      (let ((old (find-lock-summary-entry (lock-entry-summary-key (car items)) old-entries)))
        (if (and old (not (equal? old (car items))))
            (begin
              (display-update-change "changed" (car items) old)
              (loop (cdr items) (+ count 1)))
            (loop (cdr items) count)))))))

(define (display-removed-lock-entries old-entries new-entries)
  (let loop ((items old-entries) (count 0))
    (cond
     ((null? items) count)
     ((find-lock-summary-entry (lock-entry-summary-key (car items)) new-entries)
      (loop (cdr items) count))
     (else
      (display-update-change "removed" (car items))
      (loop (cdr items) (+ count 1))))))

(define (display-update-summary old-lock new-lock)
  (let* ((old-entries (if old-lock (lock-package-entries old-lock) '()))
         (new-entries (lock-package-entries new-lock))
         (added (display-added-lock-entries old-entries new-entries))
         (changed (display-changed-lock-entries old-entries new-entries))
         (removed (display-removed-lock-entries old-entries new-entries)))
    (when (= (+ added changed removed) 0)
      (displayln "lockfile unchanged"))))


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

(define (dependency-lock-key dep)
  (let ((type (alist-ref dep 'type #f)))
    (string-append
     (symbol->string type)
     ":"
     (cond
      ((alist-ref dep 'name #f) (lock-value-key (alist-ref dep 'name '())))
      ((alist-ref dep 'names #f) (lock-value-key (alist-ref dep 'names '())))
      (else "")))))

(define (lock-entry-key-for-coverage entry)
  (cond
   ((and (pair? entry) (eq? (car entry) 'system))
    (string-append "system:" (lock-value-key (lock-entry-rest entry 'names))))
   ((lock-entry-type entry)
    (string-append
     (symbol->string (lock-entry-type entry))
     ":"
     (lock-value-key (lock-entry-ref entry 'name '()))))
   (else "")))

(define (lock-entry-key-present? key entries)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((equal? key (lock-entry-key-for-coverage (car items))) #t)
     (else (loop (cdr items))))))

(define (direct-dependencies-for-lock-coverage manifest features cmd)
  (let* ((root (manifest-root manifest))
         (overrides (applicable-overrides manifest root cmd))
         (direct-deps
          (filter
           (lambda (dep) (dependency-applies? dep cmd))
           (append (alist-ref manifest 'dependencies '())
                   (feature-dependencies manifest features)
                   (alist-ref manifest 'dev-dependencies '())))))
    (map (lambda (dep) (apply-overrides-to-dep dep overrides))
         direct-deps)))

(define (ensure-lock-covers-direct-dependencies manifest features cmd lock)
  (let ((entries (lock-package-entries lock)))
    (for-each
     (lambda (dep)
       (let ((key (dependency-lock-key dep)))
         (unless (lock-entry-key-present? key entries)
           (lockfile-error "kons.lock is incomplete; run `kons update`" key))))
     (direct-dependencies-for-lock-coverage manifest features cmd))))

(define (root-source-hash manifest)
  (path-content-hash (manifest-source-root manifest)))

(define (lock-root-matches? manifest features cmd lock)
  (and (equal? (lock-root-name lock) (package-name manifest))
	       (equal? (lock-root-version lock) (package-version manifest))
	       (equal? (lock-root-features lock) features)))

(define (lock-section lock name)
  (let ((section (and (pair? lock) (assq name (cdr lock)))))
    (if section (cdr section) '())))

(define (lock-resolution-equivalent? old-lock new-lock)
  (and (equal? (lock-package-entries old-lock)
               (lock-package-entries new-lock))
       (equal? (lock-section old-lock 'overrides)
               (lock-section new-lock 'overrides))))

(define (lock-resolution-current? manifest features cmd lock)
  (and (lock-root-matches? manifest features cmd lock)
       (lock-resolution-equivalent? lock (make-lock manifest features cmd #t))))

(define (activation-lock-compatible? manifest features include-dev? cmd lock)
  (and (lock-root-matches? manifest features cmd lock)
       (or (lock-resolution-equivalent? lock (make-lock manifest features cmd include-dev?))
           (and (not include-dev?)
                (lock-resolution-equivalent? lock (make-lock manifest features cmd #t))))))

(define (activation-lock-fast-ready? manifest features include-dev? cmd lock offline?)
  (and (lock-root-matches? manifest features cmd lock)
       (lock-materialized? lock include-dev?)
       (or offline?
           (guard (exn
                   ((error-object? exn) #f)
                   (else #f))
             (ensure-lock-covers-direct-dependencies manifest features cmd lock)
             #t))))

(define (stored-lockfile lock-path)
  (and (file-exists? lock-path)
       (let ((exprs (read-all-exprs lock-path)))
         (if (null? exprs) #f (car exprs)))))

(define (lock-status manifest features cmd lock)
  (cond
   ((not lock) 'missing)
   ((lock-resolution-current? manifest features cmd lock) 'current)
   (else 'stale)))

(define (lock-completeness-status manifest features cmd lock)
  (cond
   ((not lock) 'missing)
   ((not (lock-root-matches? manifest features cmd lock)) 'unknown)
   ((guard (exn
            ((error-object? exn) #f)
            (else #f))
      (ensure-lock-covers-direct-dependencies manifest features cmd lock)
      #t)
    'complete)
   (else 'incomplete)))

  ))
