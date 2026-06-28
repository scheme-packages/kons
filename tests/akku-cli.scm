(import (scheme base)
  (srfi 64)
  (kons manifest))

(test-begin "kons Akku CLI")

(define (field-ref fields key default)
  (let ((found (assoc key fields)))
    (if found (cdr found) default)))

(let ((dep (parse-dependency
             '(akku (name "flat-name") (version "^1.0") (source "sample"))
             'runtime)))
  (test-equal "Akku dependency type" 'akku (field-ref dep 'type #f))
  (test-equal "Akku dependency scope" 'runtime (field-ref dep 'scope #f))
  (test-equal "Akku dependency name" "flat-name" (field-ref dep 'name #f))
  (test-equal "Akku dependency version" "^1.0" (field-ref dep 'version #f))
  (test-equal "Akku dependency source" "sample" (field-ref dep 'source #f))
  (test-equal "Akku dependency optional default" #f (field-ref dep 'optional #t)))

(let ((dep (parse-dependency
             '(akku (name (chibi match)) (version "0.7.0") (optional #t))
             'dev)))
  (test-equal "list-shaped Akku dependency name"
    '(chibi match)
    (field-ref dep 'name #f))
  (test-equal "dev Akku dependency scope" 'dev (field-ref dep 'scope #f))
  (test-equal "optional Akku dependency" #t (field-ref dep 'optional #f)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku CLI")
  (exit (if (= failures 0) 0 1)))
