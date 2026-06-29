(import (scheme base)
  (scheme process-context)
  (srfi 64)
  (kons conditions)
  (kons manifest))

(test-begin "kons conditions")

(define linux-condition
  (condition-options "x86_64-unknown-linux-gnu" 'debug '(tls)))

(test-assert "linux has unix flag"
  (condition-predicate-true? 'unix linux-condition))
(test-assert "linux target-os key/value"
  (condition-predicate-true? '(target-os linux) linux-condition))
(test-assert "linux target-env"
  (condition-predicate-true? '(target-env gnu) linux-condition))
(test-assert "linux empty target-abi"
  (condition-predicate-true? '(target-abi "") linux-condition))
(test-assert "active feature flag"
  (condition-predicate-true? 'tls linux-condition))
(test-assert "active feature key/value"
  (condition-predicate-true? '(feature tls) linux-condition))
(test-assert "and/or/not predicates"
  (condition-predicate-true?
    '(and unix (or windows (target-arch x86_64)) (not windows))
    linux-condition))
(test-assert "windows is false on linux"
  (not (condition-predicate-true? 'windows linux-condition)))
(test-assert "release removes debug-assertions"
  (not
    (condition-predicate-true?
      'debug-assertions
      (condition-options "x86_64-unknown-linux-gnu" 'release '()))))

(define r6rs-command-condition
  (condition-options #f 'release '(tls) 'capy 'r6rs 'compiled))

(test-assert "selected scheme bare flag"
  (condition-predicate-true? 'capy r6rs-command-condition))
(test-assert "selected scheme key/value"
  (condition-predicate-true? '(scheme capy) r6rs-command-condition))
(test-assert "selected implementation key/value"
  (condition-predicate-true? '(implementation capy) r6rs-command-condition))
(test-assert "selected dialect bare flag"
  (condition-predicate-true? 'r6rs r6rs-command-condition))
(test-assert "selected dialect key/value"
  (condition-predicate-true? '(dialect r6rs) r6rs-command-condition))
(test-assert "unselected dialect is false"
  (not (condition-predicate-true? 'r7rs r6rs-command-condition)))
(test-assert "selected profile key/value"
  (condition-predicate-true? '(profile release) r6rs-command-condition))
(test-assert "selected compile mode key/value"
  (condition-predicate-true? '(compile-mode compiled) r6rs-command-condition))

(define windows-condition
  (condition-options "x86_64-pc-windows-msvc" 'release '()))

(test-assert "windows has windows flag"
  (condition-predicate-true? 'windows windows-condition))
(test-assert "windows target-os key/value"
  (condition-predicate-true? '(target-os windows) windows-condition))
(test-assert "windows is not unix"
  (not (condition-predicate-true? 'unix windows-condition)))

(define wasm-condition
  (condition-options "wasm32-unknown-unknown" 'release '()))

(test-assert "wasm target family"
  (condition-predicate-true? '(target-family wasm) wasm-condition))

(define arm-condition
  (condition-options "armv7-unknown-linux-gnueabihf" 'release '()))

(test-assert "arm target-env is normalized"
  (condition-predicate-true? '(target-env gnu) arm-condition))
(test-assert "arm target-abi is normalized"
  (condition-predicate-true? '(target-abi eabihf) arm-condition))

(test-assert "valid condition predicate"
  (condition-predicate? '(and unix (target-os linux) (not windows))))
(test-assert "invalid condition predicate"
  (not (condition-predicate? '(target-os linux extra))))
(test-assert "old all/any condition operators are invalid"
  (not (condition-predicate? '(all unix (any windows unix)))))
(test-assert "equals condition form is invalid"
  (not (condition-predicate? '(target-os = linux))))
(test-assert "condition wrapper predicate is invalid"
  (not (condition-predicate? '(condition (target-os linux)))))

(define condition-manifest
  (parse-manifest-exprs
    "/tmp/kons-condition-test/kons.scm"
    '((package
        (name (example condition))
        (version "0.1.0"))
      (dependencies
        (cond-expand
          ((target-os linux)
            (system (scheme base)))
          (else
            (system (scheme fallback))))
        (cond-expand
          (unix
            (system (scheme file))))
        (cond-expand
          ((and unix (target-arch x86_64))
            (system (scheme cxr))))
        (cond-expand
          (unix
            (cond-expand
              ((target-arch x86_64)
                (system (scheme write))))))
        (cond-expand
          (r6rs
            (system (scheme r6rs-only)))))
      (cond-expand
        ((target-os windows)
          (dependencies
            (system (scheme process-context)))))
      (cond-expand
        (unix
          (cond-expand
            ((target-arch x86_64)
              (dependencies
                (system (scheme case-lambda)))))))
      (cond-expand
        ((target-os linux)
          (dev-dependencies
            (system (scheme eval)))))
      (workspace
        (members "member")
        (dependencies
          (cond-expand
            (unix
              (system (scheme lazy)))))))))

(define condition-deps
  (alist-ref condition-manifest 'dependencies '()))

(define (system-dependency-by-name name)
  (let loop ((deps condition-deps))
    (cond
      ((null? deps) #f)
      ((member name (alist-ref (car deps) 'names '())) (car deps))
      (else (loop (cdr deps))))))

(test-equal "dependency cond-expand condition"
  '(target-os linux)
  (alist-ref (system-dependency-by-name '(scheme base)) 'condition #f))
(test-equal "dependency cond-expand else guard"
  '(not (target-os linux))
  (alist-ref (system-dependency-by-name '(scheme fallback)) 'condition #f))
(test-equal "bare dependency cond-expand condition"
  'unix
  (alist-ref (system-dependency-by-name '(scheme file)) 'condition #f))
(test-equal "compound dependency cond-expand condition"
  '(and unix (target-arch x86_64))
  (alist-ref (system-dependency-by-name '(scheme cxr)) 'condition #f))
(test-equal "top-level cond-expand dependency condition"
  '(target-os windows)
  (alist-ref (system-dependency-by-name '(scheme process-context)) 'condition #f))
(test-equal "nested dependency cond-expand combines predicates"
  '(and unix (target-arch x86_64))
  (alist-ref (system-dependency-by-name '(scheme write)) 'condition #f))
(test-equal "selected dialect dependency cond-expand condition"
  'r6rs
  (alist-ref (system-dependency-by-name '(scheme r6rs-only)) 'condition #f))
(test-equal "nested top-level cond-expand combines predicates"
  '(and unix (target-arch x86_64))
  (alist-ref (system-dependency-by-name '(scheme case-lambda)) 'condition #f))

(define condition-dev-deps
  (alist-ref condition-manifest 'dev-dependencies '()))

(test-equal "top-level cond-expand dev dependency"
  '(target-os linux)
  (alist-ref (car condition-dev-deps) 'condition #f))

(define condition-workspace-deps
  (alist-ref
    (alist-ref condition-manifest 'workspace '())
    'dependencies
    '()))

(test-equal "workspace dependency cond-expand"
  'unix
  (alist-ref (car condition-workspace-deps) 'condition #f))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons conditions")
  (exit (if (= failures 0) 0 1)))
