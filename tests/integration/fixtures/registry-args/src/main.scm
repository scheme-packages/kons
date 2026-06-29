(import (scheme base)
        (scheme write)
        (args grammar))

(display "registry:args:")
(write (grammar? (make-grammar)))
(newline)
