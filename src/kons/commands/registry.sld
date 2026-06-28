(define-library (kons commands registry)
  (export make-registry-command
    make-login-command
    make-logout-command
    make-search-command
    make-info-command
    make-provides-command
    make-identifier-command
    make-yank-command
    make-unyank-command
    make-owner-command)
  (import (scheme base)
    (args runner)
    (kons options)
    (kons commands framework)
    (kons actions registry))

  (begin
    (define (registry-grammar)
      (make-command-grammar
        (list 'option "registry" 'help: "Registry alias or URL." 'value-help: "REGISTRY")
        (list 'option "index" 'help: "Registry API URL, accepted as a Cargo-compatible alias for --registry." 'value-help: "URL")
        (list 'option "token" 'help: "API token for this operation." 'value-help: "TOKEN")
        (list 'option "limit" 'help: "Limit search results." 'value-help: "N")
        (list 'option "page" 'help: "Search result page." 'value-help: "N")
        (list 'option "type" 'help: "Search type: package, library, identifier, or all." 'value-help: "TYPE")
        (list 'option "format" 'help: "Output format for inspection commands: text or json." 'value-help: "FORMAT")
        (list 'option "version" 'help: "Version to yank or unyank." 'value-help: "VERSION")
        (list 'option "vers" 'help: "Alias for --version." 'value-help: "VERSION")
        (list 'option "add" 'help: "Add an owner." 'value-help: "USER")
        (list 'option "remove" 'help: "Remove an owner." 'value-help: "USER")
        (list 'flag "undo" 'help: "Undo a yank.")
        (list 'flag "trust" 'help: "Trust signing metadata when indexing a registry.")
        (list 'flag "default" 'help: "Make the registry the default.")))

    (define (make-registry-command runner)
      (make-kons-command
        runner
        (kons-command-spec "registry" cmd-registry "Manage registry aliases." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-login-command runner)
      (make-kons-command
        runner
        (kons-command-spec "login" cmd-login "Store a registry API token." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-logout-command runner)
      (make-kons-command
        runner
        (kons-command-spec "logout" cmd-logout "Remove a registry API token." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-search-command runner)
      (make-kons-command
        runner
        (kons-command-spec "search" cmd-search "Search registry packages." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-info-command runner)
      (make-kons-command
        runner
        (kons-command-spec "info" cmd-info "Show registry package information." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-provides-command runner)
      (make-kons-command
        runner
        (kons-command-spec "provides" cmd-provides "Find packages providing a library." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-identifier-command runner)
      (make-kons-command
        runner
        (kons-command-spec "identifier" cmd-identifier "Find packages exporting an identifier." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-yank-command runner)
      (make-kons-command
        runner
        (kons-command-spec "yank" cmd-yank "Yank a published package version." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-unyank-command runner)
      (make-kons-command
        runner
        (kons-command-spec "unyank" cmd-unyank "Unyank a published package version." #f #f #f #f #f)
        (registry-grammar)))

    (define (make-owner-command runner)
      (make-kons-command
        runner
        (kons-command-spec "owner" cmd-owner "Manage package owners." #f #f #f #f #f)
        (registry-grammar)))))
