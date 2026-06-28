(import (scheme base)
  (scheme process-context)
  (kons core))

(dispatch (cdr (command-line)))
