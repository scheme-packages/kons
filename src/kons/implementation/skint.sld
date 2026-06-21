(define-library (kons implementation skint)
  (export skint-implementation-modes)
  (import (scheme base))

  (begin
(define skint-implementation-modes
  '(((id . skint)
     (implementation . skint)
     (command . "skint")
     (version-argv . ("--version"))
     (dialects . (r7rs))
     (standard . r7rs)
     (standard-argv . ())
     (features . (skint r7rs))
     (load-path-style . prepend-append)
     (script-flag . "--script")
     (compile-kinds . ()))))
  ))
