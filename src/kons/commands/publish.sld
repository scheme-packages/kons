(define-library (kons commands publish)
  (export make-publish-command
    make-package-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions publish))

  (begin
    (define (publish-grammar)
      (make-command-grammar
        (list 'option "registry"
          'help:
          "Registry alias or URL."
          'value-help:
          "REGISTRY")
        (list 'option "index"
          'help:
          "Registry API URL, accepted as a Cargo-compatible alias for --registry."
          'value-help:
          "URL")
        (list 'option "token"
          'help:
          "API token for this operation."
          'value-help:
          "TOKEN")
        (list 'flag "dry-run"
          'help:
          "Build and validate the publish payload without uploading.")
        (list 'flag "no-verify"
          'help:
          "Accepted for Cargo workflow compatibility.")
        (list 'flag "no-metadata"
          'help:
          "Do not require human-facing metadata.")
        (list 'flag "exclude-lockfile"
          'help:
          "Do not include kons.lock in the archive.")
        (list 'flag "allow-dirty"
          'help:
          "Allow publishing from a dirty git worktree.")))

    (define (package-grammar)
      (make-command-grammar
        (list 'option "registry"
          'help:
          "Registry alias or URL used for package planning."
          'value-help:
          "REGISTRY")
        (list 'option "index"
          'help:
          "Registry API URL, accepted as a Cargo-compatible alias for --registry."
          'value-help:
          "URL")
        (list 'flag "list"
          'help:
          "Print files included in the package.")
        (list 'flag "no-verify"
          'help:
          "Accepted for Cargo workflow compatibility.")
        (list 'flag "no-metadata"
          'help:
          "Do not require human-facing metadata.")
        (list 'flag "exclude-lockfile"
          'help:
          "Do not include kons.lock in the archive.")
        (list 'flag "allow-dirty"
          'help:
          "Allow packaging from a dirty git worktree.")))

    (define (make-publish-command runner)
      (make-kons-command
        runner
        (kons-command-spec "publish" cmd-publish "Package and publish the current project." #t #t #t #t #f)
        (publish-grammar)))

    (define (make-package-command runner)
      (make-kons-command
        runner
        (kons-command-spec "package" cmd-package "Assemble the current project into a distributable archive." #t #t #t #t #f)
        (package-grammar)))))
