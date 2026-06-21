(define-library (kons actions doctor)
  (export cmd-doctor)
  (import (scheme base)
          (scheme file)
          (scheme process-context)
          (scheme write)
          (kons util)
          (kons implementation)
          (kons manifest)
          (kons features)
          (kons lock)
          (kons runner)
          (kons options)
          (kons actions doctor-shared))

  (begin
(define (cmd-doctor cmd)
  (let* ((scheme (command-selected-scheme cmd))
         (schemes
          (list
           (scheme-report 'capy "capy" (eq? scheme 'capy))
           (scheme-report 'gauche "gosh" (eq? scheme 'gauche))
           (scheme-report 'guile "guile" (eq? scheme 'guile))
           (scheme-report 'chibi "chibi-scheme" (eq? scheme 'chibi))
           (scheme-report 'chez "scheme" (eq? scheme 'chez))
           (scheme-report 'mit "scheme" (eq? scheme 'mit))
           (scheme-report 'sagittarius "sash" (eq? scheme 'sagittarius))
           (scheme-report 'mosh "mosh" (eq? scheme 'mosh))
           (scheme-report 'stklos "stklos" (eq? scheme 'stklos))
           (scheme-report 'kawa "kawa" (eq? scheme 'kawa))
           (scheme-report 'loko "loko" (eq? scheme 'loko))
           (scheme-report 'ironscheme "ironscheme" (eq? scheme 'ironscheme))
           (scheme-report 'skint "skint" (eq? scheme 'skint))
           (scheme-report 'cyclone "cyclone" (eq? scheme 'cyclone))))
         (tools
          (list
           (command-report 'git "git" "git dependencies" #t)))
         (selected-record (assq scheme schemes))
         (selected-available? (field-ref (cdr selected-record) 'available #f))
         (ok? (and selected-available? (doctor-ok? tools))))
    (writeln
     `(doctor
       (status ,(if ok? 'ok 'needs-attention))
       (selected-scheme ,scheme)
       (home ,(kons-home))
       (store ,(kons-store-root))
       (environment
        (KONS_HOME ,(or (get-environment-variable "KONS_HOME") #f))
        (KONS_STORE ,(or (get-environment-variable "KONS_STORE") #f))
        (KONS_SCHEME ,(or (get-environment-variable "KONS_SCHEME") #f))
        (SCHEME ,(or (get-environment-variable "SCHEME") #f)))
       (schemes ,@schemes)
       (tools ,@tools)
       (next-actions
        ,@(if selected-available?
              '()
              `((install-selected-scheme ,scheme)))
        ,@(if (doctor-ok? tools)
              '()
              '((install-required-tools))))))))

  ))
