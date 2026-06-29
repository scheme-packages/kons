(define-library (kons semver)
  (export compare-semver
    semver-satisfies?)
  (import (scheme base)
    (kons util))

  (begin
    (define (version-core version)
      (let* ((dash (string-index version #\-))
             (plus (string-index version #\+))
             (end (cond
                   ((and dash plus) (min dash plus))
                   (dash dash)
                   (plus plus)
                   (else (string-length version)))))
        (substring version 0 end)))

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

    (define (tilde-upper-bound value)
      (let* ((parts (string-split value #\.))
             (base (semver-parts (partial-version->full value))))
        (if (= (length parts) 1)
          (string-append (number->string (+ (semver-major base) 1)) ".0.0")
          (string-append (number->string (semver-major base))
            "."
            (number->string (+ (semver-minor base) 1))
            ".0"))))

    (define (wildcard-part? value)
      (or (string=? value "x")
        (string=? value "X")
        (string=? value "*")))

    (define (wildcard-requirement? value)
      (let ((parts (string-split value #\.)))
        (or (and (= (length parts) 2)
             (not (wildcard-part? (car parts)))
             (wildcard-part? (cadr parts)))
          (and (= (length parts) 3)
            (not (wildcard-part? (car parts)))
            (not (wildcard-part? (cadr parts)))
            (wildcard-part? (car (cddr parts)))))))

    (define (wildcard-lower-bound value)
      (let ((parts (string-split value #\.)))
        (if (= (length parts) 2)
          (string-append (car parts) ".0.0")
          (string-append (car parts) "." (cadr parts) ".0"))))

    (define (wildcard-upper-bound value)
      (let* ((parts (string-split value #\.))
             (major (string->integer/default (car parts) 0)))
        (if (= (length parts) 2)
          (string-append (number->string (+ major 1)) ".0.0")
          (string-append (car parts)
            "."
            (number->string (+ (string->integer/default (cadr parts) 0) 1))
            ".0"))))

    (define (semver-satisfies-single? version req)
      (and (not (string=? req ""))
        (cond
          ((string=? req "*") #t)
          ((char=? (string-ref req 0) #\^)
            (let* ((base (partial-version->full (substring req 1 (string-length req))))
                   (base-parts (semver-parts base))
                   (upper (caret-upper-bound base-parts)))
              (and (>= (compare-semver version base) 0)
                (< (compare-semver version upper) 0))))
          ((char=? (string-ref req 0) #\~)
            (let* ((base-value (substring req 1 (string-length req)))
                   (base (partial-version->full base-value))
                   (upper (tilde-upper-bound base-value)))
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
          ((wildcard-requirement? req)
            (and (>= (compare-semver version (wildcard-lower-bound req)) 0)
              (< (compare-semver version (wildcard-upper-bound req)) 0)))
          (else (= (compare-semver version (partial-version->full req)) 0)))))

    (define (semver-satisfies-compound? version req)
      (let ((parts (split-whitespace req)))
        (and (pair? parts)
          (let loop ((items parts))
            (cond
              ((null? items) #t)
              ((semver-satisfies-single? version (car items)) (loop (cdr items)))
              (else #f))))))

    (define (semver-satisfies-disjunctive? version req)
      (let ((parts (split-whitespace req)))
        (let loop ((items parts) (clause '()) (saw-or? #f))
          (cond
            ((null? items)
              (and saw-or?
                (pair? clause)
                (semver-satisfies-compound?
                  version
                  (string-join (reverse clause) " "))))
            ((string=? (car items) "||")
              (or (and (pair? clause)
                   (semver-satisfies-compound?
                     version
                     (string-join (reverse clause) " ")))
                (loop (cdr items) '() #t)))
            (else (loop (cdr items) (cons (car items) clause) saw-or?))))))

    (define (semver-satisfies? version req)
      (let ((req (trim-space req)))
        (cond
          ((string=? req "") #t)
          ((semver-satisfies-single? version req) #t)
          ((semver-satisfies-compound? version req) #t)
          (else (semver-satisfies-disjunctive? version req)))))))
