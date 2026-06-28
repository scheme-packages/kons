(define-library (kons implementation chibi)
  (export chibi-implementation-modes)
  (import (scheme base))

  (begin
    (define chibi-implementation-modes
      '(((id . chibi)
         (implementation . chibi)
         (command . "chibi-scheme")
         (version-argv . ("-V"))
         (dialects . (r7rs))
         (standard . r7rs)
         (standard-argv . ())
         (features . (chibi r7rs))
         (load-path-style . prepend-append)
         (env-load-path . "CHIBI_MODULE_PATH")
         (env-load-path-scope . prepend)
         (compile-kinds . ()))))))
