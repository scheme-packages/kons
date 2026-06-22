(import (scheme base)
        (scheme process-context)
        (srfi 64)
        (kons resolver))

(test-begin "kons resolver")

(define (detail-member? value details)
  (cond
   ((equal? value details) #t)
   ((pair? details)
    (or (detail-member? value (car details))
        (detail-member? value (cdr details))))
   (else #f)))

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
   `((name . (example optional-leaf))
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
 "skips root optional requirements"
 '()
 (resolution-packages
  (resolve-dependencies
   '(((name . (example optional-leaf)) (version . "^1.0") (registry . "default") (optional . #t)))
   universe)))

(test-equal
 "skips transitive optional requirements"
 (map (lambda (candidate)
        (list (cdr (assoc 'name candidate))
              (cdr (assoc 'version candidate))))
      (resolution-packages
       (resolve-dependencies
        '(((name . (example optional-root)) (version . "^1.0") (registry . "default")))
        universe)))
 '(((example optional-root) "1.0.0")))

(define conflict-details
  (resolve-dependencies/failure-details
   '(((name . (example impossible-root)) (version . "^1.0") (registry . "default")))
   universe))

(test-equal "conflict message" "dependency version conflict" (car conflict-details))
(test-equal "conflict names package" "example/shared" (cadr conflict-details))
(test-assert "conflict includes selected version" (detail-member? "2.0.0" conflict-details))
(test-assert "conflict includes lower bound" (detail-member? ">=2.0.0" conflict-details))
(test-assert "conflict includes upper bound" (detail-member? "<2.0.0" conflict-details))
(test-assert "conflict includes left dependent"
             (detail-member? "registry:default:example/impossible-left:1.0.0" conflict-details))
(test-assert "conflict includes right dependent"
             (detail-member? "registry:default:example/impossible-right:1.0.0" conflict-details))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons resolver")
  (exit (if (= failures 0) 0 1)))
