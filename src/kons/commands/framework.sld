(define-library (kons commands framework)
  (export display-version
          kons-command-spec
          make-kons-command-grammar
          make-kons-command
          workspace-requested?
          workspace-member-manifest-path
          workspace-member-record
          workspace-member-records-from-manifest
          workspace-member-matches?
          workspace-member-records
          selected-workspace-member-records
          workspace-member-argv
          run-workspace-member!
          guard-workspace-root-package-command!
          explicit-manifest-or-path?
          find-package-root-from-current-directory
          find-workspace-record-for-package
          find-containing-workspace-selection
          autodiscovered-workspace-argv
          workspace-install-all?
          workspace-member-has-default-install-target?
          workspace-install-all-records
          dispatch-workspace
          command-spec-name
          command-spec-proc
          command-spec-summary
          command-spec-workspace?
          command-spec-package-manifest?
          command-spec-autodiscover?
          command-spec-requires-package?
          command-spec-install?
          run-command-spec
          command-job
          command-job-graph
          run-command-job-graph!
          command-job-event-handler
          job-event-field)
  (import (scheme base)
          (scheme cxr)
          (scheme file)
          (scheme write)
          (args grammar)
          (args runner)
          (args results)
          (kons compat files)
          (kons util)
          (kons ui)
          (kons names)
          (kons manifest)
          (kons options)
          (kons jobs)
          (kons actions paths))

  (begin
(define (activation-job-runner-options cmd)
  (make-job-runner-options (command-job-count cmd) #f #t #f command-job-event-handler))

(define (job-event-field event key default)
  (let loop ((items (cdr event)))
    (cond
     ((null? items) default)
     ((and (pair? (car items))
           (eq? (caar items) key)
           (pair? (cdar items)))
      (cadar items))
     (else (loop (cdr items))))))

(define (command-job-event-handler event)
  (let ((status (job-event-field event 'status #f))
        (label (job-event-field event 'label #f))
        (metadata (job-event-field event 'metadata '())))
    (when (and label (alist-ref metadata 'ui #f))
      (let ((done-label (alist-ref metadata 'done-label label)))
        (case status
          ((started) (ui-status label))
          ((done planned) (ui-status-done done-label))
          ((failed) (ui-status-fail label))
          (else #f))))))

(define (command-job id kind label deps metadata resources parallel-safe? thunk)
  (make-job id kind label deps metadata resources parallel-safe? thunk))

(define (command-job-graph id kind label metadata thunk)
  (make-job-graph
   (list
    (command-job id
                 kind
                 label
                 '()
                 metadata
                 '(ui)
                 #f
                 thunk))
   (list id)))

(define (run-command-job-graph! graph cmd)
  (run-job-graph!
   graph
   (make-job-runner-options
    (command-job-count cmd)
    #f
    #t
    #f
    command-job-event-handler)))

(define (workspace-requested? cmd)
  (or (command-flag? cmd "workspace")
      (command-option cmd "package" #f)))

(define (workspace-member-manifest-path workspace member)
  (path-join (path-join (manifest-root workspace) member) "kons.scm"))

(define (workspace-member-record workspace member)
  (let* ((manifest-path (workspace-member-manifest-path workspace member))
         (manifest (parse-manifest manifest-path)))
    `((member . ,member)
      (manifest-path . ,manifest-path)
      (name . ,(package-name manifest)))))

(define (workspace-member-records-from-manifest workspace)
  (map (lambda (member) (workspace-member-record workspace member))
       (workspace-members workspace)))

(define (workspace-member-matches? record selector)
  (or (string=? selector (alist-ref record 'member ""))
      (string=? selector (alist-ref record 'manifest-path ""))
      (string=? selector (name->string (alist-ref record 'name '())))))

(define (workspace-member-records cmd)
  (let ((workspace (parse-manifest (command-manifest-path cmd))))
    (unless (manifest-workspace? workspace)
      (usage-error "selected manifest is not a workspace" (command-manifest-path cmd)))
    (let ((members (workspace-members workspace)))
      (when (null? members)
        (manifest-error "workspace has no members" (command-manifest-path cmd)))
      (workspace-member-records-from-manifest workspace))))

(define (selected-workspace-member-records cmd)
  (let ((selector (command-option cmd "package" #f)))
    (if selector
        (let ((matches (filter (lambda (record)
                                 (workspace-member-matches? record selector))
                               (workspace-member-records cmd))))
          (cond
           ((null? matches) (usage-error "workspace package not found" selector))
           ((not (null? (cdr matches))) (usage-error "workspace package selector is ambiguous" selector))
           (else matches)))
        (workspace-member-records cmd))))

(define (workspace-member-argv cmd record)
  (let* ((top (command-global-results cmd))
         (original (argument-results-arguments top))
         (stripped (strip-workspace-argv original)))
    (append (list "--manifest" (alist-ref record 'manifest-path "")
                  "--workspace-root" (command-manifest-path cmd))
            stripped)))

(define (run-workspace-member! runner cmd record)
  (guard (exn
          ((error-object? exn)
           (usage-error (error-object-message exn)))
          (else
           (usage-error "invalid command line" exn)))
    (command-runner-run runner (workspace-member-argv cmd record))))

(define (guard-workspace-root-package-command! name package-manifest? cmd)
  (when (and package-manifest?
             (not (workspace-requested? cmd)))
    (let ((manifest (parse-manifest (command-manifest-path cmd))))
      (when (manifest-workspace? manifest)
        (usage-error
         "selected manifest is a workspace; use --workspace or --package NAME"
         name)))))

(define (explicit-manifest-or-path? cmd)
  (or (command-option cmd "manifest" #f)
      (command-option cmd "path" #f)
      (command-option cmd "workspace-root" #f)))

(define (find-package-root-from-current-directory)
  (find-package-root-for-source-root (current-directory)))

(define (find-workspace-record-for-package workspace package-manifest-path)
  (let loop ((records (workspace-member-records-from-manifest workspace)))
    (cond
     ((null? records) #f)
     ((same-path? (alist-ref (car records) 'manifest-path "")
                  package-manifest-path)
      (car records))
     (else (loop (cdr records))))))

(define (find-containing-workspace-selection package-root)
  (let ((package-manifest-path (path-join package-root "kons.scm")))
    (let loop ((dir (parent-path package-root)))
      (if (not dir)
          #f
          (let ((workspace-path (path-join dir "kons.scm")))
            (if (file-exists? workspace-path)
                (let ((workspace (parse-manifest workspace-path)))
                  (if (manifest-workspace? workspace)
                      (let ((record (find-workspace-record-for-package
                                     workspace
                                     package-manifest-path)))
                        (if record
                            `((workspace-path . ,workspace-path)
                              (record . ,record))
                            (loop (parent-path dir))))
                      (loop (parent-path dir))))
                (loop (parent-path dir))))))))

(define (insert-command-option argv command-name option-name option-value)
  (let loop ((items argv) (out '()))
    (cond
     ((null? items)
      (append (reverse out) (list option-name option-value)))
     ((string=? (car items) command-name)
      (append (reverse (cons (car items) out))
              (list option-name option-value)
              (cdr items)))
     (else (loop (cdr items) (cons (car items) out))))))

(define (autodiscovered-workspace-argv spec cmd)
  (let ((argv (argument-results-arguments (command-global-results cmd))))
    (if (or (not (command-spec-autodiscover? spec))
            (workspace-requested? cmd)
            (explicit-manifest-or-path? cmd))
        argv
        (let ((package-root (find-package-root-from-current-directory)))
          (if package-root
              (let ((selection (find-containing-workspace-selection package-root)))
                (if selection
                    (let ((record (alist-ref selection 'record '())))
                      (append
                       (list "--manifest"
                             (alist-ref selection 'workspace-path ""))
                       (insert-command-option
                        argv
                        (command-spec-name spec)
                        "--package"
                        (alist-ref record 'member ""))))
                    argv))
              argv)))))

(define (workspace-install-all? install? cmd)
  (and install?
       (command-flag? cmd "workspace")
       (command-flag? cmd "all")
       (not (command-option cmd "package" #f))))

(define (workspace-member-has-default-install-target? record)
  (let ((manifest (parse-manifest (alist-ref record 'manifest-path ""))))
    (and (package-main manifest) #t)))

(define (workspace-install-all-records cmd)
  (filter workspace-member-has-default-install-target?
          (selected-workspace-member-records cmd)))

(define (dispatch-workspace runner name proc workspace? requires-package? install? cmd)
  (unless workspace?
    (usage-error "command does not support workspace selection yet" name))
  (when (and requires-package?
             (command-flag? cmd "workspace")
             (not (command-option cmd "package" #f)))
    (usage-error (string-append "workspace " name " requires --package NAME")))
  (when (and install?
             (command-flag? cmd "workspace")
             (not (command-option cmd "package" #f))
             (not (command-flag? cmd "all")))
    (usage-error "workspace install requires --package NAME or --all"))
  (when (and (workspace-install-all? install? cmd)
             (or (command-option cmd "name" #f)
                 (command-option cmd "bin" #f)))
    (usage-error "workspace install --all installs default runnable members; use --package with --name or --bin"))
  (when (workspace-install-all? install? cmd)
    (for-each
     (lambda (record)
       (unless (workspace-member-has-default-install-target? record)
         (log-info "workspace member has no default install target; skipping"
                   (alist-ref record 'member ""))))
     (selected-workspace-member-records cmd)))
  (for-each
   (lambda (record)
     (log-info "workspace member" (alist-ref record 'member ""))
     (run-workspace-member! runner cmd record))
   (if (workspace-install-all? install? cmd)
       (workspace-install-all-records cmd)
       (selected-workspace-member-records cmd))))

(define (display-version)
  (display "kons ")
  (displayln kons-version))

(define (kons-command-spec name proc summary workspace? package-manifest? autodiscover? requires-package? install?)
  (list name proc summary workspace? package-manifest? autodiscover? requires-package? install?))

(define (make-kons-command-grammar)
  (copy-grammar! (make-grammar) kons-command-grammar))

(define (command-spec-name spec) (car spec))
(define (command-spec-proc spec) (car (cdr spec)))
(define (command-spec-summary spec) (car (cdr (cdr spec))))
(define (command-spec-workspace? spec) (car (cdr (cdr (cdr spec)))))
(define (command-spec-package-manifest? spec) (list-ref spec 4))
(define (command-spec-autodiscover? spec) (list-ref spec 5))
(define (command-spec-requires-package? spec) (list-ref spec 6))
(define (command-spec-install? spec) (list-ref spec 7))

(define (run-command-spec runner spec cmd)
  (let* ((name (command-spec-name spec))
         (proc (command-spec-proc spec))
         (argv (autodiscovered-workspace-argv spec cmd))
         (raw (argument-results-arguments (command-global-results cmd))))
    (if (not (equal? argv raw))
        (guard (exn
                ((error-object? exn)
                 (usage-error (error-object-message exn)))
                (else
                 (usage-error "invalid command line" exn)))
          (command-runner-run runner argv))
        (begin
    (guard-workspace-root-package-command!
     name
     (command-spec-package-manifest? spec)
     cmd)
    (run-command-job-graph!
     (command-job-graph
      (string->symbol name)
      'command
      name
      `((command ,name))
      (lambda ()
        (if (workspace-requested? cmd)
            (dispatch-workspace runner
                                name
                                proc
                                (command-spec-workspace? spec)
                                (command-spec-requires-package? spec)
                                (command-spec-install? spec)
                                cmd)
            (proc cmd))))
     cmd)))))

(define (make-kons-command runner spec . maybe-grammar)
  (let ((grammar (if (null? maybe-grammar)
                     (make-kons-command-grammar)
                     (car maybe-grammar))))
    (command (command-spec-name spec)
             'grammar: grammar
             'summary: (lambda (ignored) (command-spec-summary spec))
             'description: (command-spec-summary spec)
             'run: (lambda (cmd) (run-command-spec runner spec cmd)))))

  ))
