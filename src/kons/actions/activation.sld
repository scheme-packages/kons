(define-library (kons actions activation)
  (export ensure-activation-ready!
    build-token
    build-output-dir
    has-build-hooks?
    implicit-build-hooks
    effective-build-hooks
    activation-source-roots-with-build
    dependency-build-output-dir
    dependency-build-output-for-source-root
    activation-source-roots-with-dependency-builds
    implementation-field
    cache-record-hash
    compiled-cache-record
    compiled-cache-token
    compiled-output-dir
    command-compiled-output-dirs
    command-runtime-compile-mode
    adapter-command-for-cmd
    adapter-repl-command-for-cmd
    launcher-command-for-cmd
    compiled-artifact-records
    build-record
    build-hook-script
    build-hook-watch-paths
    build-hook-watch-hashes
    build-hook-cache-record
    build-hook-marker-dir
    build-hook-marker-path
    build-hook-directives-path
    stored-hook-record
    stored-hook-directives
    run-build-hook-with-source-roots
    run-build-hook
    run-build-hooks
    run-build-hooks-if-needed!
    feature-library-name
    feature-helper-library-name
    write-feature-libraries!
    dependency-build-hook-source-roots
    run-dependency-build-hooks-for-source-root!
    run-dependency-build-hooks-if-needed!
    ensure-build-hooks-ready!
    ensure-runtime-activation-ready!
    ensure-dev-activation-ready!
    activation-job-graph
    run-activation-job-graph!
    run-activated-script
    module-name-string
    compile-implementation-libraries
    ensure-implementation-compiled!)
  (import (scheme base)
    (scheme cxr)
    (scheme file)
    (scheme write)
    (kons util)
    (kons ui)
    (kons names)
    (kons implementation)
    (kons manifest)
    (kons features)
    (kons lock)
    (kons runner)
    (kons jobs)
    (kons options)
    (kons actions paths)
    (kons actions lock-shared)
    (kons commands framework)
    (kons actions activation core)
    (kons actions activation build-hooks)
    (kons actions activation compile))

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

    (define (activation-job-graph manifest features cmd include-dev? root-build-output?)
      (let* ((activation-id 'activation)
             (dep-hooks-id 'dependency-build-hooks)
             (root-hooks-id 'root-build-hooks)
             (lock-path (command-lock-path manifest cmd))
             (activation
               (make-job
                 activation-id
                 'activation
                 "prepare activation"
                 '()
                 `((root ,(package-name manifest))
                   (features ,@features)
                   (includes-dev-dependencies ,include-dev?)
                   (lockfile ,lock-path))
                 `(ui ,lock-path ,(kons-store-root))
                 #f
                 (lambda ()
                   (ensure-activation-ready-core! manifest features include-dev? cmd))))
             (dep-hooks
               (make-job
                 dep-hooks-id
                 'build-hooks
                 "prepare dependency build hooks"
                 (list activation-id)
                 `((root ,(package-name manifest))
                   (features ,@features)
                   (includes-dev-dependencies ,include-dev?))
                 `(ui ,(kons-store-root))
                 #f
                 (lambda ()
                   (run-dependency-build-hooks-if-needed! manifest include-dev? features cmd))))
             (root-hooks
               (make-job
                 root-hooks-id
                 'build-hooks
                 "prepare root build hooks"
                 (list dep-hooks-id)
                 `((root ,(package-name manifest))
                   (features ,@features)
                   (build-root ,(build-output-dir manifest features cmd)))
                 `(ui ,(build-output-dir manifest features cmd))
                 #f
                 (lambda ()
                   (run-build-hooks-if-needed! manifest features cmd)))))
        (if root-build-output?
          (make-job-graph (list activation dep-hooks root-hooks) (list root-hooks-id))
          (make-job-graph (list activation dep-hooks) (list dep-hooks-id)))))

    (define (run-activation-job-graph! graph cmd)
      (run-job-graph! graph (activation-job-runner-options cmd)))

    (define (ensure-activation-ready! manifest features include-dev? cmd)
      (run-activation-job-graph!
        (make-job-graph
          (list
            (make-job
              'activation
              'activation
              "prepare activation"
              '()
              `((root ,(package-name manifest))
                (features ,@features)
                (includes-dev-dependencies ,include-dev?)
                (lockfile ,(command-lock-path manifest cmd)))
              `(ui ,(command-lock-path manifest cmd) ,(kons-store-root))
              #f
              (lambda ()
                (ensure-activation-ready-core! manifest features include-dev? cmd))))
          '(activation))
        cmd))

    (define (ensure-build-hooks-ready! manifest features cmd)
      (when (has-build-hooks? manifest)
        (ui-status "preparing build hooks")
        (run-activation-job-graph!
          (activation-job-graph manifest features cmd #t (build-output-needed? manifest))
          cmd)
        (ui-status-done "prepared build hooks")))

    (define (ensure-runtime-activation-ready! manifest features cmd)
      (ui-status "preparing runtime activation")
      (run-activation-job-graph!
        (activation-job-graph manifest
          features
          cmd
          (if (has-build-hooks? manifest) #t #f)
          (build-output-needed? manifest))
        cmd)
      (ui-status-done "prepared runtime activation"))

    (define (ensure-dev-activation-ready! manifest features cmd)
      (ui-status "preparing dev activation")
      (run-activation-job-graph!
        (activation-job-graph manifest features cmd #t (build-output-needed? manifest))
        cmd)
      (ui-status-done "prepared dev activation"))

    (define (run-activated-script manifest cmd script include-dev? rest)
      (let* ((adapted-scheme (command-adapter-scheme manifest cmd))
             (features (active-features manifest cmd))
             (srcs (activation-source-roots-with-build manifest include-dev? features cmd))
             (command (adapter-command-for-cmd manifest cmd adapted-scheme srcs script rest)))
        (check-system-dependencies manifest cmd include-dev? features srcs)
        (when include-dev?
          (log-info "dev dependencies are available when materialized"))
        (log-debug "command" (command->shell command))
        (log-debug "argv" (command-argv command))
        (ui-status-done "running" script)
        (run-command-record command)))))
