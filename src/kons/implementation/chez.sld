(define-library (kons implementation chez)
  (export chez-implementation-modes)
  (import (scheme base))

  (begin
(define chez-implementation-modes
  '(((id . chez)
     (implementation . chez)
     (commands . ("chez" "chezscheme" "scheme"))
     (version-argv . ("--version"))
     (version-reject-contains . ("MIT/GNU Scheme"))
     (dialects . (chez r6rs))
     (standard . r6rs)
     (standard-argv . ())
     (features . (chez r6rs))
     (load-path-style . chez-libdirs)
     (script-flag . "--program")
     (compile-kinds . ()))))
  ))
