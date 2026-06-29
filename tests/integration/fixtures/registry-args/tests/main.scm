(import (scheme base)
        (args grammar))

(unless (grammar? (make-grammar))
  (error "args grammar did not load"))
