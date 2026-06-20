(define-library (kons commands)
  (export dispatch)
  (import (scheme base)
          (scheme process-context)
          (args runner)
          (kons util)
          (kons options)
          (kons commands framework)
          (kons commands metadata)
          (kons commands resolve)
          (kons commands update)
          (kons commands fetch)
          (kons commands status)
          (kons commands check)
          (kons commands build)
          (kons commands test)
          (kons commands bench)
          (kons commands run)
          (kons commands repl)
          (kons commands install)
          (kons commands doctor)
          (kons commands tree)
          (kons commands clean)
          (kons commands new)
          (kons commands init)
          (kons commands add)
          (kons commands remove)
          (kons commands registry)
          (kons commands publish))

  (begin
    (define command-makers
      (list
       make-metadata-command
       make-resolve-command
       make-update-command
       make-fetch-command
       make-status-command
       make-check-command
       make-build-command
       make-test-command
       make-bench-command
       make-run-command
       make-repl-command
       make-install-command
       make-doctor-command
       make-tree-command
       make-clean-command
       make-new-command
       make-init-command
       make-add-command
       make-remove-command
       make-registry-command
       make-login-command
       make-logout-command
       make-search-command
       make-info-command
       make-package-command
       make-publish-command
       make-yank-command
       make-unyank-command
       make-owner-command))

    (define (version-flag-callback value)
      (when value
        (display-version)
        (emergency-exit 0)))

    (define (make-kons-runner)
      (let ((runner (make-command-runner "kons" "Scheme package manager")))
        (install-global-grammar! (command-runner-grammar runner) version-flag-callback)
        (for-each (lambda (maker) (command-runner-add-command! runner (maker runner)))
                  command-makers)
        (command-runner-add-command!
         runner
         (command "version"
                  'grammar: (make-kons-command-grammar)
                  'summary: (lambda (ignored) "Print kons version.")
                  'description: "Print kons version."
                  'hidden?: #t
                  'run: (lambda (ignored) (display-version))))
        runner))

    (define kons-runner (make-kons-runner))

    (define (dispatch raw-argv)
      (let* ((top (guard (exn
                          ((error-object? exn)
                           (usage-error (error-object-message exn)))
                          (else
                           (usage-error "invalid command line" exn)))
                     (command-runner-parse kons-runner raw-argv))))
        (configure-logging! top)
        (command-runner-run-command kons-runner top)))))
