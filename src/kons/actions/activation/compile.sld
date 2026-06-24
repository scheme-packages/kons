(define-library (kons actions activation compile)
  (export module-name-string
          compile-implementation-libraries
          command-runtime-compile-mode
          command-compiled-output-dirs
          adapter-command-for-cmd
          adapter-repl-command-for-cmd
          launcher-command-for-cmd
          ensure-implementation-compiled!)
  (import (scheme base)
          (scheme cxr)
          (scheme file)
          (scheme write)
          (kons compat files)
          (kons util)
          (kons ui)
          (kons names)
          (kons implementation)
          (kons manifest)
          (kons library-discovery)
          (kons features)
          (kons lock)
          (kons runner)
          (kons jobs)
          (kons options)
          (kons actions paths)
          (kons actions lock-shared)
          (kons commands framework)
          (kons actions activation core)
          (kons actions activation build-hooks))

(begin
(define (job-event-field event key default)
  (let loop ((items (cdr event)))
    (cond
     ((null? items) default)
     ((and (pair? (car items))
           (eq? (caar items) key)
           (pair? (cdar items)))
      (cadar items))
     (else (loop (cdr items))))))

(define (module-name-string name)
  (let loop ((items name) (out "("))
    (cond
     ((null? items) (string-append out ")"))
     ((string=? out "(")
      (loop (cdr items) (string-append out (lock-value-key (car items)))))
     (else
      (loop (cdr items) (string-append out " " (lock-value-key (car items))))))))

(define (compiler-source-roots manifest features cmd . maybe-srcs)
  (if (pair? maybe-srcs)
      (car maybe-srcs)
      (activation-source-roots-with-dependency-builds manifest #f features cmd)))

(define (library-source-path-for-kind source-root kind name entry)
  (if entry
      (library-entry-path source-root entry)
      (case kind
        ((r7rs) (library-source-path source-root name))
        ((r6rs) (r6rs-library-source-path source-root name))
        ((guile) (module-source-path source-root name))
        (else (manifest-error "unknown compilation library kind" kind)))))

(define (compile-library-entry compiled-root mode-id source-root kind name entry srcs)
  (let* ((source (library-source-path-for-kind source-root kind name entry))
         (output (implementation-compile-output-path mode-id compiled-root kind name))
         (log (string-append output ".log"))
         (command (implementation-compile-command mode-id kind srcs output source)))
    (unless (file-exists? source)
      (manifest-error "declared library source not found" name source))
    (unless (file-exists? output)
      (run-command (string-append "mkdir -p " (shell-quote (dirname output))))
      (run-command (string-append (command->shell command)
                                  " > " (shell-quote log)
                                  " 2>&1")))
    output))

(define (compile-spec-source-manifest spec) (list-ref spec 0))
(define (compile-spec-source-root spec) (list-ref spec 1))
(define (compile-spec-kind spec) (list-ref spec 2))
(define (compile-spec-name spec) (list-ref spec 3))
(define (compile-spec-entry spec) (list-ref spec 4))
(define (compile-spec-output spec) (list-ref spec 5))
(define (compile-spec-id spec) (list-ref spec 6))

(define (compile-spec-import-deps spec kind name specs)
  (let loop ((items specs) (out '()))
    (cond
     ((null? items) (reverse out))
     ((and (not (equal? (compile-spec-id spec) (compile-spec-id (car items))))
           (eq? kind (compile-spec-kind (car items)))
           (equal? name (compile-spec-name (car items))))
      (loop (cdr items) (cons (compile-spec-id (car items)) out)))
     (else (loop (cdr items) out)))))

(define (compile-spec-deps spec specs)
  (let ((kind (compile-spec-kind spec))
        (imports (library-entry-imports (compile-spec-entry spec))))
    (let loop ((items imports) (out '()))
      (cond
       ((null? items) (reverse out))
       (else
        (loop (cdr items)
              (append (reverse (compile-spec-import-deps spec kind (car items) specs))
                      out)))))))

(define (compile-job-done-label name)
  (string-append "compiled " (module-name-string name)))

(define (compile-job-label name)
  (string-append "compiling " (module-name-string name)))

(define (compile-job-results-values results)
  (map job-result-value results))

(define (compile-spec-resources spec)
  (list (compile-spec-output spec)))

(define (compile-specs->jobs compiled-root mode-id specs srcs)
  (let loop ((items specs) (jobs '()))
    (if (null? items)
        (reverse jobs)
        (let* ((spec (car items))
               (kind (compile-spec-kind spec))
               (name (compile-spec-name spec)))
          (loop
           (cdr items)
           (cons
            (make-job
             (compile-spec-id spec)
             'compile
             (compile-job-label name)
             (compile-spec-deps spec specs)
             `((ui . #t)
               (done-label . ,(compile-job-done-label name))
               (library . ,name)
               (kind . ,kind))
             (compile-spec-resources spec)
             #t
             (lambda ()
               (compile-library-entry
                compiled-root
                mode-id
                (compile-spec-source-root spec)
                kind
                name
                (compile-spec-entry spec)
                srcs)))
            jobs))))))

(define (active-compile-message active)
  (if (null? active)
      #f
      (let loop ((items (reverse active)) (count 0) (shown '()))
        (cond
         ((null? items) (string-join (reverse shown) ", "))
         ((>= count 4) (string-join (reverse (cons "..." shown)) ", "))
         (else (loop (cdr items) (+ count 1) (cons (car items) shown)))))))

(define (display-padding count)
  (let loop ((n count))
    (when (> n 0)
      (display " " (current-error-port))
      (loop (- n 1)))))

(define (display-compile-status label color message)
  (when (ui-enabled?)
    (ui-clear-active-line)
    (display-padding (max 1 (- 12 (string-length label))))
    (display (ui-colorize color label) (current-error-port))
    (when message
      (display " " (current-error-port))
      (display message (current-error-port)))
    (newline (current-error-port))))

(define (remove-string item items)
  (let loop ((xs items) (out '()) (removed? #f))
    (cond
     ((null? xs) (reverse out))
     ((and (not removed?) (string=? item (car xs)))
      (loop (cdr xs) out #t))
     (else (loop (cdr xs) (cons (car xs) out) removed?)))))

(define (make-compile-job-event-handler total)
  (let ((done 0)
        (active '()))
    (lambda (event)
      (let* ((status (job-event-field event 'status #f))
             (metadata (job-event-field event 'metadata '()))
             (name (alist-ref metadata 'library #f))
             (message-name (and name (module-name-string name))))
        (case status
          ((started)
           (when message-name
             (set! active (cons message-name active)))
           (ui-progress "Compiling" done total (active-compile-message active)))
          ((done planned)
           (when message-name
             (set! active (remove-string message-name active)))
           (set! done (+ done 1))
           (display-compile-status "Compiled" 'green message-name)
           (if (= done total)
               (display-compile-status
                "Finished"
                'bold
                (string-append "compiled "
                               (number->string total)
                               " libraries"))
               (when (not (null? active))
                 (ui-progress "Compiling" done total (active-compile-message active)))))
          ((failed)
           (ui-status-fail "Failed" message-name))
          (else #f))))))

(define (run-compile-specs! cmd compiled-root mode-id specs srcs)
  (if (null? specs)
      '()
      (let ((total (length specs)))
        (run-command (string-append "mkdir -p " (shell-quote compiled-root)))
        (compile-job-results-values
         (run-job-graph!
          (make-job-graph
           (compile-specs->jobs compiled-root mode-id specs srcs)
           (map compile-spec-id specs))
          (make-job-runner-options
           (command-job-count cmd)
           #f
           #t
           #f
           (make-compile-job-event-handler total)))))))

(define (implementation-compile-specs mode-id compiled-root records)
  (let loop-records ((items records) (index 0) (out '()))
    (if (null? items)
        (reverse out)
        (let ((source-manifest (car (car items)))
              (source-root (cadr (car items)))
              (entries (list-ref (car items) 4)))
          (log-trace "planning implementation compile record"
                     mode-id
                     (package-name source-manifest)
                     source-root
                     (length entries))
          (let loop-entries ((entries entries) (index index) (out out))
            (if (null? entries)
                (loop-records (cdr items) index out)
                (let* ((entry (car entries))
                       (kind (car entry))
                       (name (cadr entry))
                       (output (implementation-compile-output-path mode-id compiled-root kind name)))
                  (loop-entries
                   (cdr entries)
                   (+ index 1)
                   (if (file-exists? output)
                       out
                       (cons `(,source-manifest
                               ,source-root
                               ,kind
                               ,name
                               ,entry
                               ,output
                               (compile ,mode-id ,kind ,index ,name))
                             out))))))))))

(define (compile-implementation-libraries manifest features cmd . maybe-srcs)
  (let* ((mode-id (adapter-scheme manifest (command-selected-scheme cmd)))
         (records (apply compilable-source-root-records manifest features cmd maybe-srcs)))
    (log-trace "planning implementation compilation" mode-id (package-name manifest))
    (cond
     ((not (implementation-compiler-command mode-id)) '())
     ((null? records) '())
     ((not (implementation-compiler-available? mode-id)) '())
     (else
      (let* ((compiled-root (compiled-output-dir manifest features cmd))
             (specs (implementation-compile-specs mode-id compiled-root records))
             (srcs (apply compiler-source-roots manifest features cmd maybe-srcs)))
        (log-trace "running implementation compile specs"
                   mode-id
                   (length specs)
                   (command-job-count cmd))
        (run-compile-specs! cmd compiled-root mode-id specs srcs))))))

(define (command-runtime-compile-mode manifest features cmd . maybe-install?)
  (let* ((install? (and (pair? maybe-install?) (car maybe-install?)))
         (mode-id (adapter-scheme manifest (command-selected-scheme cmd))))
    (cond
     ((not (implementation-compiler-command mode-id)) 'normal)
     ((not (has-compiled-artifacts? manifest cmd))
      (if (and (not install?) (eq? (command-selected-compile-mode cmd) 'fresh-auto))
          'fresh-auto
          'normal))
     ((and install? (eq? (command-selected-compile-mode cmd) 'fresh-auto))
      'normal)
     ((and (not install?) (eq? (command-selected-compile-mode cmd) 'fresh-auto))
      'fresh-auto)
     ((implementation-compiler-available? mode-id) 'compiled)
     (install? 'normal)
     (else 'fresh-auto))))

(define (command-compiled-output-dirs manifest features cmd . maybe-install?)
  (if (eq? (apply command-runtime-compile-mode manifest features cmd maybe-install?) 'compiled)
      (list (compiled-output-dir manifest features cmd))
      '()))

(define (adapter-command-for-cmd manifest cmd scheme src script rest . maybe-install?)
  (let* ((features (active-features manifest cmd))
         (mode (apply command-runtime-compile-mode manifest features cmd maybe-install?))
         (compiled-roots (apply command-compiled-output-dirs manifest features cmd maybe-install?))
         (command (adapter-command scheme src script rest mode compiled-roots (command-selected-profile cmd))))
    (command-with-runtime-build-env manifest features cmd command)))

(define (adapter-repl-command-for-cmd manifest cmd scheme src . maybe-install?)
  (let ((mode (apply command-runtime-compile-mode manifest (active-features manifest cmd) cmd maybe-install?))
        (compiled-roots (apply command-compiled-output-dirs manifest (active-features manifest cmd) cmd maybe-install?)))
    (adapter-repl-command scheme src mode compiled-roots (command-selected-profile cmd))))

(define (launcher-command-for-cmd manifest cmd scheme src script . maybe-compiled-roots)
  (let* ((features (active-features manifest cmd))
         (compiled-roots (if (pair? maybe-compiled-roots)
                             (car maybe-compiled-roots)
                             (command-compiled-output-dirs manifest features cmd #t)))
         (mode (if (null? compiled-roots) 'normal 'compiled)))
    (launcher-command scheme src script mode compiled-roots (command-selected-profile cmd))))

(define (ensure-implementation-compiled! manifest features cmd)
  (let ((mode (command-runtime-compile-mode manifest features cmd)))
    (cond
     ((eq? mode 'compiled)
      (compile-implementation-libraries manifest features cmd))
     ((and (eq? mode 'fresh-auto)
           (eq? (command-selected-compile-mode cmd) 'compiled)
           (has-compiled-artifacts? manifest cmd))
      (log-info "compiler not found; using fresh auto compile"
                (command-selected-scheme cmd))
      '())
     (else '()))))

  ))
