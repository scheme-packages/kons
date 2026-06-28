(import (scheme base)
  (scheme process-context)
  (scheme file)
  (scheme write)
  (scheme cxr)
  (srfi 64)
  (kons compat json)
  (kons names)
  (kons util)
  (kons resolver))

(test-begin "kons resolver")

(define-record-type <resolver-sample>
  (make-resolver-sample candidates cases)
  resolver-sample?
  (candidates resolver-sample-candidates)
  (cases resolver-sample-cases))

(define-record-type <resolver-sample-case>
  (make-resolver-sample-case name requirements selected-packages scheme-packages scheme-edges)
  resolver-sample-case?
  (name resolver-sample-case-name)
  (requirements resolver-sample-case-requirements)
  (selected-packages resolver-sample-case-selected-packages)
  (scheme-packages resolver-sample-case-scheme-packages)
  (scheme-edges resolver-sample-case-scheme-edges))

(define (sample-ref object key default)
  (let ((entry (assoc key object)))
    (if entry (cdr entry) default)))

(define (json-vector->list value)
  (if (vector? value) (vector->list value) '()))

(define (json-string-list value)
  (json-vector->list value))

(define (json-symbol-list value)
  (map string->symbol (json-string-list value)))

(define (json-optional-symbol-list object key)
  (let ((values (json-symbol-list (sample-ref object key '#()))))
    (if (null? values) '() values)))

(define (json-optional-string-list object key)
  (let ((values (json-string-list (sample-ref object key '#()))))
    (if (null? values) '() values)))

(define (json-package-name text)
  (map string->symbol (filter non-empty-string? (string-split text #\/))))

(define (sample-dependency->alist dep)
  `((name . ,(json-package-name (sample-ref dep 'name "")))
    (version . ,(sample-ref dep 'req (sample-ref dep 'version "*")))
    (registry . ,(sample-ref dep 'registry "default"))
    (kind . ,(string->symbol (sample-ref dep 'kind "normal")))
    ,@(if (sample-ref dep 'optional #f) '((optional . #t)) '())
    ,@(let ((features (json-symbol-list (sample-ref dep 'features '#()))))
       (if (null? features) '() `((features . ,features))))
    ,@(let ((schemes (append (json-optional-symbol-list dep 'schemes)
                      (json-optional-symbol-list dep 'implementations))))
       (if (null? schemes) '() `((schemes . ,schemes))))
    ,@(let ((dialects (json-optional-symbol-list dep 'dialects)))
       (if (null? dialects) '() `((dialects . ,dialects))))
    ,@(let ((targets (json-optional-string-list dep 'targets)))
       (if (null? targets) '() `((targets . ,targets))))
    ,@(let ((profiles (json-optional-symbol-list dep 'profiles)))
       (if (null? profiles) '() `((profiles . ,profiles))))
    ,@(let ((compile-modes (json-optional-symbol-list dep 'compileModes)))
       (if (null? compile-modes) '() `((compile-modes . ,compile-modes))))))

(define (sample-feature-dependency->alist item)
  `((feature . ,(string->symbol (sample-ref item 'feature "")))
    (dependencies . ,(map sample-dependency->alist
                      (json-vector->list (sample-ref item 'dependencies '#()))))))

(define (sample-candidate->alist candidate)
  `((name . ,(json-package-name (sample-ref candidate 'name "")))
    (version . ,(sample-ref candidate 'version "0.0.0"))
    (registry . ,(sample-ref candidate 'registry "default"))
    ,@(if (sample-ref candidate 'yanked #f) '((yanked . #t)) '())
    (feature-dependencies
     .
     ,(map sample-feature-dependency->alist
       (json-vector->list (sample-ref candidate 'featureDependencies '#()))))
    (dependencies . ,(map sample-dependency->alist
                      (json-vector->list (sample-ref candidate 'dependencies '#()))))))

(define (sample-case->record row)
  (make-resolver-sample-case
    (sample-ref row 'name "")
    (map sample-dependency->alist
      (json-vector->list (sample-ref row 'requirements '#())))
    (json-string-list (sample-ref row 'selectedPackages '#()))
    (json-string-list (sample-ref row 'schemePackages '#()))
    (json-string-list (sample-ref row 'schemeEdges '#()))))

(define (read-resolver-sample path)
  (let ((data (call-with-input-file path json-read)))
    (make-resolver-sample
      (map sample-candidate->alist
        (json-vector->list (sample-ref data 'candidates '#())))
      (map sample-case->record
        (json-vector->list (sample-ref data 'cases '#()))))))

(define (candidate-name-strings candidates)
  (map (lambda (candidate)
        (name->string (cdr (assoc 'name candidate))))
    candidates))

(define (edge-name-strings edges)
  (map (lambda (edge)
        (name->string (cdr (assoc 'name edge))))
    edges))

(define (insert-string value sorted)
  (cond
    ((null? sorted) (list value))
    ((string<? value (car sorted)) (cons value sorted))
    (else (cons (car sorted) (insert-string value (cdr sorted))))))

(define (sort-strings values)
  (let loop ((items values) (out '()))
    (if (null? items)
      out
      (loop (cdr items) (insert-string (car items) out)))))

(define shared-resolver-sample
  (read-resolver-sample "tests/samples/resolver/shared.json"))

(define (test-shared-resolver-case sample-case)
  (let ((resolution (resolve-dependencies
                     (resolver-sample-case-requirements sample-case)
                     (resolver-sample-candidates shared-resolver-sample))))
    (test-equal
      (string-append (resolver-sample-case-name sample-case) " selected packages")
      (sort-strings (candidate-name-strings (resolution-packages resolution)))
      (resolver-sample-case-selected-packages sample-case))
    (test-equal
      (string-append (resolver-sample-case-name sample-case) " packages")
      (candidate-name-strings (resolution-packages resolution))
      (resolver-sample-case-scheme-packages sample-case))
    (test-equal
      (string-append (resolver-sample-case-name sample-case) " edges")
      (edge-name-strings (resolution-edges resolution))
      (resolver-sample-case-scheme-edges sample-case))))

(define (detail-member? value details)
  (cond
    ((equal? value details) #t)
    ((vector? details)
      (detail-member? value (vector->list details)))
    ((pair? details)
      (or (detail-member? value (car details))
        (detail-member? value (cdr details))))
    (else #f)))

(define (field-ref fields key default)
  (let ((found (assoc key fields)))
    (if found (cdr found) default)))

(define (first-conflict-requirement conflict)
  (let ((requirements (field-ref conflict 'requirements '#())))
    (if (and (vector? requirements)
         (> (vector-length requirements) 0))
      (vector-ref requirements 0)
      '())))

(define universe
  (list
    `((name . (example a))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example a))
      (version . "1.1.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example a))
      (version . "2.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example b))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example a)) (version . "^1.0") (registry . "default")))))
    `((name . (example c))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example b)) (version . "^1.0") (registry . "default")))))
    `((name . (example yanked))
      (version . "2.0.0")
      (registry . "default")
      (yanked . #t)
      (dependencies . ()))
    `((name . (example yanked))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example shared))
      (version . "2.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example shared))
      (version . "1.5.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example narrow))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example shared)) (version . "<2.0.0") (registry . "default")))))
    `((name . (example root))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example shared)) (version . ">=1.0.0") (registry . "default"))
                       ((name . (example narrow)) (version . "^1.0") (registry . "default")))))
    `((name . (example impossible-left))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example shared)) (version . ">=2.0.0") (registry . "default")))))
    `((name . (example impossible-right))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example shared)) (version . "<2.0.0") (registry . "default")))))
    `((name . (example impossible-root))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example impossible-left)) (version . "^1.0") (registry . "default"))
                       ((name . (example impossible-right)) (version . "^1.0") (registry . "default")))))
    `((name . (example impossible-a))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example zero))
      (version . "0.3.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example zero))
      (version . "0.2.5")
      (registry . "default")
      (dependencies . ()))
    `((name . (example tiny))
      (version . "0.0.4")
      (registry . "default")
      (dependencies . ()))
    `((name . (example tiny))
      (version . "0.0.3")
      (registry . "default")
      (dependencies . ()))
    `((name . (example optional-root))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example a)) (version . "^1.0") (registry . "default") (optional . #t)))))
    `((name . (example optional-activator))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example optional-leaf)) (version . "^1.0") (registry . "default") (optional . #t)))))
    `((name . (example optional-leaf))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example feature-left))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example feature-target)) (version . "^1.0") (registry . "default") (features . (alpha))))))
    `((name . (example feature-right))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example feature-target)) (version . "^1.0") (registry . "default") (features . (beta))))))
    `((name . (example feature-root))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example feature-left)) (version . "^1.0") (registry . "default"))
                       ((name . (example feature-right)) (version . "^1.0") (registry . "default")))))
    `((name . (example feature-target))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example forwarded-leaf))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . ()))
    `((name . (example forwarder))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example forwarded-leaf)) (version . "^1.0") (registry . "default"))))
      (feature-dependencies . (((feature . tls)
                                (dependencies . (((name . (example forwarded-leaf))
                                                  (version . "^1.0")
                                                  (registry . "default")
                                                  (features . (tls)))))))))
    `((name . (example forwarding-root))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example forwarder)) (version . "^1.0") (registry . "default") (features . (tls))))))
    `((name . (example forwarding-root-disabled))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . (((name . (example forwarder)) (version . "^1.0") (registry . "default")))))
    `((name . (example forwarding-root-dev))
      (version . "1.0.0")
      (registry . "default")
      (dependencies . ()))))

(define resolution
  (resolve-dependencies
    '(((name . (example c)) (version . "^1.0") (registry . "default")))
    universe))

(test-equal
  "transitive packages"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages resolution))
  '(((example c) "1.0.0")
    ((example b) "1.0.0")
    ((example a) "1.1.0")))

(test-equal
  "transitive edges"
  (map (lambda (edge) (cdr (assoc 'name edge))) (resolution-edges resolution))
  '((example c) (example b) (example a)))

(test-equal
  "resolution accessors still accept legacy alists"
  (resolution-packages '((packages . (legacy-package))
                         (edges . (legacy-edge))))
  '(legacy-package))

(test-equal
  "ignores yanked candidates"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example yanked)) (version . "*") (registry . "default")))
        universe)))
  '(((example yanked) "1.0.0")))

(test-equal
  "preserves preferred compatible candidate"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example a)) (version . "^1.0") (registry . "default")))
        universe
        '(((name . (example a)) (version . "1.0.0") (registry . "default"))))))
  '(((example a) "1.0.0")))

(test-equal
  "ignores preferred candidate outside range"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example a)) (version . "^2.0") (registry . "default")))
        universe
        '(((name . (example a)) (version . "1.0.0") (registry . "default"))))))
  '(((example a) "2.0.0")))

(test-equal
  "preserves preferred yanked candidate"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example yanked)) (version . "*") (registry . "default")))
        universe
        '(((name . (example yanked)) (version . "2.0.0") (registry . "default"))))))
  '(((example yanked) "2.0.0")))

(test-equal
  "backtracks to satisfy combined constraints"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example root)) (version . "^1.0") (registry . "default")))
        universe)))
  '(((example root) "1.0.0")
    ((example shared) "1.5.0")
    ((example narrow) "1.0.0")))

(test-equal
  "caret zero minor excludes next minor"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example zero)) (version . "^0.2") (registry . "default")))
        universe)))
  '(((example zero) "0.2.5")))

(test-equal
  "caret zero patch excludes next patch"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example tiny)) (version . "^0.0.3") (registry . "default")))
        universe)))
  '(((example tiny) "0.0.3")))

(test-equal
  "skips optional requirements without activated feature"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example optional-activator)) (version . "^1.0") (registry . "default")))
        universe)))
  '(((example optional-activator) "1.0.0")))

(test-equal
  "activates optional dependency by feature"
  (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
          (cdr (assoc 'version candidate))
          (cdr (assoc 'resolved-features candidate))))
    (resolution-packages
      (resolve-dependencies
        '(((name . (example optional-activator)) (version . "^1.0") (registry . "default") (features . (optional-leaf))))
        universe)))
  '(((example optional-activator) "1.0.0" (optional-leaf))
    ((example optional-leaf) "1.0.0" ())))

(test-equal
  "unifies requested dependency features"
  (cdr (assoc 'resolved-features
        (car (filter (lambda (candidate)
                      (equal? (cdr (assoc 'name candidate)) '(example feature-target)))
              (resolution-packages
                (resolve-dependencies
                  '(((name . (example feature-root)) (version . "^1.0") (registry . "default")))
                  universe))))))
  '(alpha beta))

(define (resolved-feature-list package-name resolution)
  (cdr (assoc 'resolved-features
        (car (filter (lambda (candidate)
                      (equal? (cdr (assoc 'name candidate)) package-name))
              (resolution-packages resolution))))))

(test-equal
  "forwards selected feature to dependency"
  (resolved-feature-list
    '(example forwarded-leaf)
    (resolve-dependencies
      '(((name . (example forwarding-root)) (version . "^1.0") (registry . "default")))
      universe))
  '(tls))

(test-equal
  "does not forward unselected feature"
  (resolved-feature-list
    '(example forwarded-leaf)
    (resolve-dependencies
      '(((name . (example forwarding-root-disabled)) (version . "^1.0") (registry . "default")))
      universe))
  '())

(for-each test-shared-resolver-case
  (resolver-sample-cases shared-resolver-sample))

(define conflict-details
  (resolve-dependencies/failure-details
    '(((name . (example impossible-root)) (version . "^1.0") (registry . "default")))
    universe))

(define selector-conflict-details
  (resolve-dependencies/failure-details
    '(((name . (example shared))
       (version . ">=2.0.0")
       (registry . "default")
       (kind . runtime)
       (features . (tls))
       (schemes . (capy))
       (targets . ("linux-x86_64")))
      ((name . (example shared))
       (version . "<2.0.0")
       (registry . "default")
       (kind . dev)
       (features . (docs))
       (schemes . (guile))
       (targets . ("linux-aarch64"))))
    universe))

(define selector-conflict (caddr selector-conflict-details))
(define selector-requirement (first-conflict-requirement selector-conflict))

(test-equal "conflict message" "dependency version conflict" (car conflict-details))
(test-equal "conflict names package" "example/shared" (cadr conflict-details))
(test-equal "conflict detail reason" 'resolver-conflict (field-ref (caddr conflict-details) 'reason #f))
(test-equal "conflict detail package" "default:example/shared" (field-ref (caddr conflict-details) 'package ""))
(test-assert "conflict includes selected version" (detail-member? "2.0.0" conflict-details))
(test-assert "conflict includes lower bound" (detail-member? ">=2.0.0" conflict-details))
(test-assert "conflict includes upper bound" (detail-member? "<2.0.0" conflict-details))
(test-assert "conflict includes left dependent"
  (detail-member? "registry:default:example/impossible-left:1.0.0" conflict-details))
(test-assert "conflict includes right dependent"
  (detail-member? "registry:default:example/impossible-right:1.0.0" conflict-details))
(test-equal "selector conflict selected version"
  "2.0.0"
  (field-ref selector-conflict 'selected-version ""))
(test-equal "selector conflict requirement kind"
  'runtime
  (field-ref selector-requirement 'kind #f))
(test-equal "selector conflict requirement features"
  '#(tls)
  (field-ref selector-requirement 'features '#()))
(test-equal "selector conflict requirement schemes"
  '#(capy)
  (field-ref selector-requirement 'schemes '#()))
(test-equal "selector conflict requirement targets"
  '#("linux-x86_64")
  (field-ref selector-requirement 'targets '#()))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons resolver")
  (exit (if (= failures 0) 0 1)))
