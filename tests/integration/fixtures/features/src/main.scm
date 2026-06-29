(import (scheme base)
        (scheme write)
        (ci features kons features))

(feature-cond
  (tls (display "feature-cond:tls"))
  (else (display "feature-cond:plain")))
(newline)

(cond-expand
  ((and r7rs (not r6rs)) (display "cond-expand:r7rs"))
  (else (display "cond-expand:other")))
(newline)
