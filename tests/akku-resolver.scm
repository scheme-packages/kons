(import (scheme base)
        (scheme file)
        (scheme write)
        (srfi 64)
        (kons manifest)
        (kons names)
        (kons resolver)
        (kons akku format)
        (kons akku resolver))

(test-begin "kons Akku resolver")

(define root "/tmp/kons-akku-resolver-test")
(define index-path (string-append root "/Akku-index.scm"))

(define (ensure-directory path)
  (unless (file-exists? path)
    (create-directory path)))

(define (write-file path text)
  (when (file-exists? path)
    (delete-file path))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (field-ref fields key default)
  (let ((found (assoc key fields)))
    (if found (cdr found) default)))

(define (packages->name-version resolution)
  (map (lambda (candidate)
         (list (field-ref candidate 'akku-name #f)
               (field-ref candidate 'version "")))
       (resolution-packages resolution)))

(define (candidate-for-akku-name name candidates)
  (let loop ((items candidates))
    (cond
     ((null? items) #f)
     ((equal? (field-ref (car items) 'akku-name #f) name) (car items))
     (else (loop (cdr items))))))

(define (requirement name range . maybe-kind)
  `((type . akku)
    (scope . ,(if (null? maybe-kind) 'runtime (car maybe-kind)))
    (name . ,name)
    (version . ,range)
    (source . "akku")))

(define (failure-message details)
  (if (pair? details) (car details) ""))

(ensure-directory root)

(write-file
 index-path
 "(import (akku format index))

(package (name \"flat-name\")
  (versions
    ((version \"1.0.0\")
     (depends)
     (depends/dev)
     (conflicts))
    ((version \"1.2.0\")
     (depends (direct-leaf (version \">=1.0.0\")))
     (depends/dev (dev-only \">=1.0.0\"))
     (conflicts))))

(package (name (chibi match))
  (versions
    ((version \"0.7.0\")
     (depends)
     (depends/dev)
     (conflicts))))

(package (name \"direct-leaf\")
  (versions
    ((version \"1.0.0\")
     (depends)
     (depends/dev)
     (conflicts))))

(package (name \"transitive-root\")
  (versions
    ((version \"1.0.0\")
     (depends (transitive-mid \"^1.0\"))
     (depends/dev)
     (conflicts))))

(package (name \"transitive-mid\")
  (versions
    ((version \"1.0.0\")
     (depends (transitive-leaf \"^1.0\"))
     (depends/dev)
     (conflicts))))

(package (name \"transitive-leaf\")
  (versions
    ((version \"1.0.0\")
     (depends)
     (depends/dev)
     (conflicts))))

(package (name \"dev-root\")
  (versions
    ((version \"1.0.0\")
     (depends)
     (depends/dev (dev-only \"^1.0\"))
     (conflicts))))

(package (name \"dev-only\")
  (versions
    ((version \"1.0.0\")
     (depends)
     (depends/dev)
     (conflicts))))

(package (name \"conflict-root\")
  (versions
    ((version \"1.0.0\")
     (depends (conflicting-leaf \"^1.0\"))
     (depends/dev)
     (conflicts (conflicting-leaf \">=1.0.0\")))))

(package (name \"conflicting-leaf\")
  (versions
    ((version \"1.0.0\")
     (depends)
     (depends/dev)
     (conflicts))))
")

(define packages (read-akku-index index-path))
(define candidates (akku-packages->resolver-candidates packages "akku"))

(test-equal
 "manifest parses flat Akku dependency"
 '((type . akku)
   (scope . runtime)
   (name . "flat-name")
   (version . "^1.0")
   (source . "akku")
   (optional . #f))
 (parse-dependency '(akku (name "flat-name") (version "^1.0") (source "akku")) 'runtime))

(test-equal
 "manifest parses list-shaped Akku dependency without string collapse"
 '(chibi match)
 (field-ref
  (parse-dependency '(akku (name (chibi match)) (version "0.7.0")) 'runtime)
  'name
  #f))

(test-equal
 "flat-name package resolves highest matching version"
 '(("flat-name" "1.2.0") ("direct-leaf" "1.0.0"))
 (packages->name-version
  (resolve-akku-dependencies
   (map akku-dependency->resolver-requirement
        (list (requirement "flat-name" "^1.0")))
   candidates)))

(test-equal
 "list-name package keeps original list name"
 '(((chibi match) "0.7.0"))
 (packages->name-version
  (resolve-akku-dependencies
   (map akku-dependency->resolver-requirement
        (list (requirement '(chibi match) "0.7.0")))
   candidates)))

(test-equal
 "candidate id is namespaced by Akku name shape"
 "registry:akku:akku/list/chibi/match:0.7.0"
 (candidate-id (candidate-for-akku-name '(chibi match) candidates)))

(test-equal
 "Akku tilde range uses resolver semantics"
 '(("flat-name" "1.0.0"))
 (packages->name-version
  (resolve-akku-dependencies
   (map akku-dependency->resolver-requirement
        (list (requirement "flat-name" "~1.0")))
   candidates)))

(test-equal
 "Akku wildcard range uses resolver semantics"
 '(("flat-name" "1.2.0") ("direct-leaf" "1.0.0"))
 (packages->name-version
  (resolve-akku-dependencies
   (map akku-dependency->resolver-requirement
        (list (requirement "flat-name" "1.x")))
   candidates)))

(test-equal
 "transitive Akku dependencies resolve"
 '(("transitive-root" "1.0.0")
   ("transitive-mid" "1.0.0")
   ("transitive-leaf" "1.0.0"))
 (packages->name-version
  (resolve-akku-dependencies
   (map akku-dependency->resolver-requirement
        (list (requirement "transitive-root" "^1.0")))
   candidates)))

(test-equal
 "depends/dev is not pulled transitively"
 '(("dev-root" "1.0.0"))
 (packages->name-version
  (resolve-akku-dependencies
   (map akku-dependency->resolver-requirement
        (list (requirement "dev-root" "^1.0" 'dev)))
   candidates)))

(test-equal
 "unsatisfied Akku version range reports resolver failure"
 "no matching package version"
 (failure-message
  (resolve-akku-dependencies/failure-details
   (map akku-dependency->resolver-requirement
        (list (requirement "flat-name" ">=9.0.0")))
   candidates)))

(test-equal
 "conflicting Akku packages report Akku conflict"
 "Akku package conflict"
 (failure-message
  (resolve-akku-dependencies/failure-details
   (map akku-dependency->resolver-requirement
        (list (requirement "conflict-root" "^1.0")))
   candidates)))

(test-equal
 "registry git path and Akku dependencies coexist in manifest parsing"
 '(registry git path akku)
 (map (lambda (dep) (field-ref dep 'type #f))
      (parse-dependency-block
       '((dependencies
          (registry (name (example registry)) (version "^1.0"))
          (git (name (example git)) (url "https://example.invalid/git.git"))
          (path (name (example path)) (path "vendor/path") (raw #t))
          (akku (name "flat-name") (version "^1.0"))))
       'dependencies
       'runtime)))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku resolver")
  (exit (if (= failures 0) 0 1)))
