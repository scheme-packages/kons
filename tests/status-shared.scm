(import (scheme base)
  (scheme process-context)
  (srfi 64)
  (kons actions status-shared))

(test-begin "kons status shared")

(test-equal
  "current status has no follow-up actions"
  '()
  (status-action-list 'current 'complete #t "/tmp/main.scm"))

(test-equal
  "missing lock fetches dependencies"
  '(run-fetch)
  (status-action-list 'missing 'complete #t "/tmp/main.scm"))

(test-equal
  "missing main asks for runnable target"
  '(add-main-or-bin)
  (status-action-list 'current 'complete #t #f))

(test-equal
  "missing lock and main reports both actions"
  '(run-fetch add-main-or-bin)
  (status-action-list 'missing 'complete #t #f))

(test-equal
  "incomplete lock fetches dependencies"
  '(run-fetch)
  (status-action-list 'current 'incomplete #t "/tmp/main.scm"))

(test-equal
  "unmaterialized store fetches dependencies"
  '(run-fetch)
  (status-action-list 'current 'complete #f "/tmp/main.scm"))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons status shared")
  (exit (if (= failures 0) 0 1)))
