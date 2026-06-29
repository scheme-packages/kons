(import (scheme base)
        (scheme file)
        (scheme write)
        (kons build))

(write-library
 '(ci build-hooks generated)
 '(define-library (ci build-hooks generated)
    (export generated-message)
    (import (scheme base))
    (begin
      (define (generated-message)
        "build-hook generated"))))

(let ((out (open-output-file "build-hook-ran.txt")))
  (display "ran" out)
  (newline out)
  (close-output-port out))
