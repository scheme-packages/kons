(define-library (kons implementation kawa)
  (export kawa-implementation-modes)
  (import (scheme base))

  (begin
    (define kawa-implementation-modes
      '(((id . kawa)
         (implementation . kawa)
         (command . "kawa")
         (version-argv . ("--version"))
         (dialects . (r7rs))
         (standard . r7rs)
         (standard-argv . ("--r7rs"))
         (features . (kawa r7rs))
         (load-path-style . kawa-import-path)
         (script-flag . "-f")
         (compile-kinds . ()))))))
