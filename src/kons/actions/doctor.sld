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
           (scheme-report 'chez "chez" (eq? scheme 'chez))))
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
