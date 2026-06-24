(import (scheme base)
        (scheme file)
        (scheme process-context)
        (srfi 64)
        (kons util))

(test-begin "kons dev dependencies")

(define root "/tmp/kons-dev-dependencies-test")
(define runtime-root (path-join root "deps/runtime"))
(define dev-root (path-join root "deps/dev"))
(define output-path (path-join root "plan.out"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (field-ref fields key default)
  (let ((found (assoc key fields)))
    (if found (cdr found) default)))

(define (plan-dependencies plan)
  (let ((section (assoc 'dependencies (cdr plan))))
    (if section (cdr section) '())))

(define (dependency-named? dependency name scope)
  (and (equal? (field-ref dependency 'name '()) name)
       (eq? (field-ref dependency 'scope #f) scope)))

(define (dependency-present? dependencies name scope)
  (let loop ((items dependencies))
    (cond
     ((null? items) #f)
     ((dependency-named? (car items) name scope) #t)
     (else (loop (cdr items))))))

(define (run-plan command)
  (let ((status
         (shell-command-status
          (string-append
           "KONS_HOME="
           (shell-quote (path-join root "home"))
           " XDG_CACHE_HOME="
           (shell-quote (path-join root "cache"))
           " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
           (shell-quote (path-join root "kons.scm"))
           " "
           command
           " --plan >"
           (shell-quote output-path)))))
    (and (= status 0)
         (call-with-input-file output-path read))))

(define (assert-plan-dev-scope command expected-dev?)
  (let* ((plan (run-plan command))
         (dependencies (and plan (plan-dependencies plan))))
    (test-assert (string-append command " plan exists") plan)
    (test-assert
     (string-append command " includes runtime dependency")
     (dependency-present? dependencies '(example runtime-helper) 'runtime))
    (test-equal
     (string-append command " dev dependency inclusion")
     expected-dev?
     (dependency-present? dependencies '(example dev-helper) 'dev))))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example dev-scope))
  (version \"0.1.0\")
  (source-path \"src\")
  (main \"main.scm\")
  (tests \"tests/main.scm\"))

(dependencies
  (path (name (example runtime-helper)) (path \"deps/runtime\")))
(dev-dependencies
  (path (name (example dev-helper)) (path \"deps/dev\")))
")

(write-file
 (path-join root "src/main.scm")
 "(display \"run\")
")

(write-file
 (path-join root "tests/main.scm")
 "(display \"test\")
")

(write-file
 (path-join runtime-root "kons.scm")
 "(package
  (name (example runtime-helper))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join runtime-root "src/example/runtime-helper.sld")
 "(define-library (example runtime-helper)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")

(write-file
 (path-join dev-root "kons.scm")
 "(package
  (name (example dev-helper))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join dev-root "src/example/dev-helper.sld")
 "(define-library (example dev-helper)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")

(assert-plan-dev-scope "run" #f)
(assert-plan-dev-scope "check" #t)
(assert-plan-dev-scope "build" #t)
(assert-plan-dev-scope "test" #t)

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons dev dependencies")
  (exit (if (= failures 0) 0 1)))
