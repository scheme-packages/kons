(import (scheme base)
        (scheme write)
        (ci build-hooks generated))

(display (generated-message))
(newline)
