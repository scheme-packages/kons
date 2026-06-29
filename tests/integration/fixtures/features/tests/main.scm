(import (scheme base)
        (scheme write)
        (ci features kons features))

(unless (feature-enabled? 'tls)
  (error "tls feature should be active"))

(display "feature test ok")
(newline)
