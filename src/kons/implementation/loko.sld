(define-library (kons implementation loko)
  (export loko-implementation-modes)
  (import (scheme base))

  (begin
(define loko-implementation-modes
  '(((id . loko)
     (implementation . loko)
     (command . "loko")
     (dialects . (r7rs))
     (standard . r7rs)
     (standard-argv . ("-std=r7rs"))
     (features . (loko r7rs))
     (env-load-path . "LOKO_LIBRARY_PATH")
     (env-load-path-scope . all)
     (script-flag . "--program")
     (compile-kinds . ()))))
  ))
