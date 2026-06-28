(define-library (kons implementation cyclone)
  (export cyclone-implementation-modes)
  (import (scheme base))

  (begin
    (define cyclone-implementation-modes
      '(((id . cyclone)
         (implementation . cyclone)
         (command . "cyclone")
         (version-argv . ("-v"))
         (dialects . (r7rs))
         (standard . r7rs)
         (standard-argv . ())
         (features . (cyclone r7rs))
         (load-path-style . prepend-append)
         (runtime-command-style . cyclone-compile-run)
         (compile-kinds . ()))))))
