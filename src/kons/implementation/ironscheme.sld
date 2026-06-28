(define-library (kons implementation ironscheme)
  (export ironscheme-implementation-modes)
  (import (scheme base))

  (begin
    (define ironscheme-implementation-modes
      '(((id . ironscheme)
         (implementation . ironscheme)
         (command . "ironscheme")
         (dialects . (r6rs))
         (standard . r6rs)
         (standard-argv . ())
         (features . (ironscheme r6rs))
         (env-load-path . "IRONSCHEME_LIBRARY_PATH")
         (env-load-path-scope . all)
         (compile-kinds . ()))))))
