(import (scheme base)
  (scheme process-context)
  (srfi 64)
  (kons resolver)
  (kons snow format)
  (kons snow resolver))

(test-begin "kons Snow resolver")

(define (field-ref fields key default)
  (let ((found (assoc key fields)))
    (if found (cdr found) default)))

(define (names-and-versions resolution)
  (map (lambda (candidate)
        (list (field-ref candidate 'snow-name #f)
          (field-ref candidate 'version "")))
    (resolution-packages resolution)))

(define (candidate-for-name name candidates)
  (let loop ((items candidates))
    (cond
      ((null? items) #f)
      ((equal? (field-ref (car items) 'snow-name #f) name) (car items))
      (else (loop (cdr items))))))

(define (requirement name range)
  `((type . snow)
    (scope . runtime)
    (name . ,name)
    (version . ,range)
    (source . "snow")))

(define packages
  (list
    (make-snow-package
      '(foreign c)
      "1.0.0"
      "foreign-c.tgz"
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      #f
      ""
      (list
        (make-snow-library '(foreign c) "foreign/c.sld" '((scheme base)))))
    (make-snow-package
      '(retropikzel system)
      "1.0.0"
      "retropikzel-system.tgz"
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      #f
      ""
      (list
        (make-snow-library
          '(retropikzel system)
          "retropikzel/system.sld"
          '((scheme base) (foreign c)))))))

(define candidates (snow-packages->resolver-candidates packages "snow"))

(test-equal
  "Snow package creates a list-name candidate"
  '(snow list retropikzel system)
  (field-ref
    (candidate-for-name '(retropikzel system) candidates)
    'name
    #f))

(test-equal
  "Snow library dependencies resolve"
  '(((retropikzel system) "1.0.0")
    ((foreign c) "1.0.0"))
  (names-and-versions
    (resolve-snow-dependencies
      (map snow-dependency->resolver-requirement
        (list (requirement '(retropikzel system) "^1.0")))
      candidates)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Snow resolver")
  (exit (if (= failures 0) 0 1)))
