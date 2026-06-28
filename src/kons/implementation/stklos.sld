(define-library (kons implementation stklos)
  (export stklos-implementation-modes)
  (import (scheme base))

  (begin
    (define stklos-implementation-modes
      '(((id . stklos)
         (implementation . stklos)
         (command . "stklos")
         (version-argv . ("-v"))
         (dialects . (r7rs))
         (standard . r7rs)
         (standard-argv . ("-Q"))
         (features . (stklos r7rs))
         (load-path-style . prepend-append)
         (script-flag . "-f")
         (compile-kinds . ()))))))
