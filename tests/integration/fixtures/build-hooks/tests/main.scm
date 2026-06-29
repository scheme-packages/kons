(import (scheme base)
        (scheme file)
        (scheme write)
        (ci build-hooks generated))

(unless (string=? (generated-message) "build-hook generated")
  (error "generated library did not load"))

(unless (file-exists? "build-hook-ran.txt")
  (error "build hook marker was not written"))

(display "build hook test ok")
(newline)
