(define-library (kons runner)
  (export adapter-command
          adapter-repl-command
          command-env
          command-argv
          command->shell
          run-command-record
          scheme-command
          launcher-command
          string-join
          dependency-source-roots
          activation-source-roots
          locked-activation-source-roots
          effective-activation-source-roots
          locked-entry-in-scope?
          lock-materialized?
          materializable-dependency?
          materialize-local-sources
          materialize-lock-sources
          check-system-dependencies
          run-script
          collect-scheme-files
          collect-test-files
          adapter-scheme)
  (import (scheme base)
          (scheme cxr)
          (scheme file)
          (scheme process-context)
          (scheme write)
          (kons compat files)
          (kons util)
          (kons names)
          (kons implementation)
          (kons manifest)
          (kons features)
          (kons options)
          (kons lock)
          (kons registry)
          (kons jobs)
          (kons ui)
          (kons dep store)
          (kons dep git)
          (kons dep path)
          (kons dep registry)
          (kons dep workspace))

(begin
(define (adapter-scheme manifest scheme)
  (let* ((dialects (package-dialects manifest))
         (mode (implementation-mode-for-dialects scheme dialects)))
    (if mode
        (implementation-mode-id mode)
      (manifest-error "unsupported dialect for selected implementation"
           (package-name manifest)
           dialects
           scheme))))

(define (compile-mode-arg maybe index default)
  (let loop ((items maybe) (n index))
    (cond
     ((null? items) default)
     ((= n 0) (car items))
     (else (loop (cdr items) (- n 1))))))

	(define (adapter-command scheme src script rest . maybe-compile)
	  (let ((mode (compile-mode-arg maybe-compile 0 'normal))
            (compiled-roots (compile-mode-arg maybe-compile 1 '()))
            (profile (compile-mode-arg maybe-compile 2 'release)))
        (implementation-command-record scheme src script rest mode compiled-roots profile)))

(define (adapter-repl-command scheme src . maybe-compile)
  (let ((mode (compile-mode-arg maybe-compile 0 'normal))
        (compiled-roots (compile-mode-arg maybe-compile 1 '()))
        (profile (compile-mode-arg maybe-compile 2 'release)))
    (implementation-repl-command-record scheme src mode compiled-roots profile)))

(define (command-env command)
  (let ((field (assq 'env (cdr command))))
    (if field (cdr field) '())))

(define (command-argv command)
  (let ((field (assq 'argv (cdr command))))
    (if field (cdr field) '())))

(define (shell-join xs)
  (string-join (map shell-quote xs) " "))

(define (command-env->shell env)
  (string-join
   (map (lambda (entry)
          (string-append (car entry) "=" (shell-quote (cadr entry))))
        env)
   " "))

(define (command->shell command)
  (let ((env (command-env command))
        (argv (command-argv command)))
    (string-append
     (if (null? env) "" (string-append (command-env->shell env) " "))
     (shell-join argv))))

(define (run-command-record command)
  (run-command (command->shell command)))

(define (scheme-command scheme src script rest)
  (command->shell (adapter-command scheme src script rest)))

(define (launcher-command scheme src script . maybe-compile)
  (let* ((mode (compile-mode-arg maybe-compile 0 'normal))
         (compiled-roots (compile-mode-arg maybe-compile 1 '()))
         (profile (compile-mode-arg maybe-compile 2 'release))
         (command (adapter-command scheme src script '() mode compiled-roots profile))
         (env (command-env command))
         (argv (command-argv command)))
    (string-append
     (if (null? env)
         ""
         (string-append (command-env->shell env) " "))
     "exec "
     (shell-join argv)
     " \"$@\"")))

(define (string-join xs sep)
  (let loop ((rest xs) (out ""))
    (cond
     ((null? rest) out)
     ((string=? out "") (loop (cdr rest) (car rest)))
     (else (loop (cdr rest) (string-append out sep (car rest)))))))

(define (source-root-from-package-root package-root)
  (let ((manifest-path (path-join package-root "kons.scm")))
    (if (file-exists? manifest-path)
        (let ((package-manifest (parse-manifest manifest-path)))
          (path-join package-root (package-source-path package-manifest)))
        package-root)))

(define (locked-entry-source-root entry)
  (let ((root (case (lock-entry-type entry)
                 ((path) (locked-path-entry-root entry))
                 ((workspace) (locked-workspace-entry-root entry))
                 ((git) (locked-git-entry-root entry))
                 ((registry) (locked-registry-entry-root entry))
                (else #f))))
    (if root
        (begin
          (unless (file-exists? root)
            (dependency-error "locked dependency is not materialized; run `kons fetch` first"
                 (lock-entry-ref entry 'name '())))
          (source-root-from-package-root
           (subpath-package-root root (lock-entry-ref entry 'subpath #f))))
        #f)))

(define (locked-entry-materialized? entry)
  (let ((root (case (lock-entry-type entry)
                ((path) (locked-path-entry-root entry))
                ((workspace) (locked-workspace-entry-root entry))
                ((git) (locked-git-entry-root entry))
                ((registry) (locked-registry-entry-root entry))
                (else #f))))
    (case (lock-entry-type entry)
      ((git) (and root (git-checkout-ready? root (lock-entry-ref entry 'commit ""))))
      (else
       (or (not root)
           (file-exists? root))))))

(define (locked-entry-in-scope? entry include-dev?)
  (let ((scope (lock-entry-ref entry 'scope 'runtime)))
    (or include-dev? (not (eq? scope 'dev)))))

(define (lock-materialized? lock include-dev?)
  (let loop ((entries (lock-package-entries lock)))
    (cond
     ((null? entries) #t)
     ((not (locked-entry-in-scope? (car entries) include-dev?))
      (loop (cdr entries)))
     ((locked-entry-materialized? (car entries))
      (loop (cdr entries)))
     (else #f))))

(define (locked-dependency-source-roots lock include-dev?)
  (let loop ((entries (lock-package-entries lock)) (out '()))
    (cond
     ((null? entries) (reverse out))
     ((not (locked-entry-in-scope? (car entries) include-dev?))
      (loop (cdr entries) out))
     (else
      (let ((root (locked-entry-source-root (car entries))))
        (if root
            (loop (cdr entries) (cons root out))
            (loop (cdr entries) out)))))))

(define (project-config-path manifest)
  (path-join (manifest-root manifest) ".kons/config.scm"))

(define (scheme-load-path-form scheme)
  (string->symbol
   (string-append (symbol->string scheme) "-load-paths")))

(define (config-load-path-form? form scheme)
  (and (pair? form)
       (symbol? (car form))
       (or (eq? (car form) 'load-paths)
           (eq? (car form) (scheme-load-path-form scheme)))))

(define (config-load-path manifest path)
  (if (absolute-path? path)
      path
      (path-join (manifest-root manifest) path)))

(define (config-form-load-paths manifest config-path form)
  (for-each
   (lambda (path)
     (unless (string? path)
       (manifest-error "config load paths must be strings" config-path form)))
   (cdr form))
  (map (lambda (path) (config-load-path manifest path)) (cdr form)))

(define (project-config-load-paths manifest scheme)
  (let ((config-path (project-config-path manifest)))
    (if (file-exists? config-path)
        (let loop ((forms (read-all-exprs config-path)) (out '()))
          (cond
           ((null? forms) (reverse out))
           ((config-load-path-form? (car forms) scheme)
            (loop (cdr forms)
                  (append (reverse (config-form-load-paths manifest config-path (car forms)))
                          out)))
           ((and (pair? (car forms)) (symbol? (caar forms)))
            (manifest-error "unknown project config form" config-path (caar forms)))
           (else
            (manifest-error "expected project config form" config-path (car forms)))))
        '())))

(define (with-project-config-load-paths manifest cmd srcs)
  (append srcs
          (project-config-load-paths manifest (command-selected-scheme cmd))))

(define (dependency-source-roots manifest include-dev? features cmd)
  (let ((root (manifest-root manifest)))
    (let loop ((deps (all-dependencies-for manifest include-dev? features cmd)) (out '()))
      (cond
       ((null? deps) (reverse out))
       ((eq? (alist-ref (car deps) 'type #f) 'path)
        (loop (cdr deps) (cons (path-dependency-source-root root (car deps)) out)))
       ((eq? (alist-ref (car deps) 'type #f) 'workspace)
        (loop (cdr deps) (cons (workspace-dependency-source-root root (car deps)) out)))
       ((eq? (alist-ref (car deps) 'type #f) 'git)
        (loop (cdr deps) (cons (git-dependency-source-root root (car deps)) out)))
        ((eq? (alist-ref (car deps) 'type #f) 'registry)
         (loop (cdr deps)
               (cons (registry-dependency-source-root (car deps)) out)))
        (else (loop (cdr deps) out))))))

(define (activation-source-roots manifest include-dev? features cmd)
  (with-project-config-load-paths
   manifest
   cmd
   (cons (manifest-source-root manifest)
         (dependency-source-roots manifest include-dev? features cmd))))

(define (locked-activation-source-roots manifest lock include-dev?)
  (cons (manifest-source-root manifest)
        (locked-dependency-source-roots lock include-dev?)))

	(define (lock-matches-activation? manifest features include-dev? cmd lock)
	  (and (equal? (lock-root-name lock) (package-name manifest))
	       (equal? (lock-root-version lock) (package-version manifest))
	       (equal? (lock-root-features lock) features)
	       (or (command-flag? cmd "offline")
	           (command-flag? cmd "frozen")
	           (lock-resolution-equivalent? lock (make-lock manifest features cmd include-dev? lock))
	           (and (not include-dev?)
	                (lock-resolution-equivalent? lock (make-lock manifest features cmd #t lock))))))

  (define (lock-section lock name)
    (let ((section (and (pair? lock) (assq name (cdr lock)))))
      (if section (cdr section) '())))

  (define (lock-resolution-equivalent? old-lock new-lock)
    (and (equal? (lock-package-entries old-lock)
                 (lock-package-entries new-lock))
         (equal? (lock-section old-lock 'edges)
                 (lock-section new-lock 'edges))
         (equal? (lock-section old-lock 'overrides)
                 (lock-section new-lock 'overrides))))

	(define (activation-lock-path manifest)
	  (path-join (manifest-root manifest) "kons.lock"))

	(define (matching-activation-lock manifest features include-dev? cmd)
	  (let ((path (activation-lock-path manifest)))
	    (and (file-exists? path)
	         (let ((lock (read-lockfile path)))
	           (and (lock-matches-activation? manifest features include-dev? cmd lock)
	                lock)))))

	(define (activation-lock-or-live manifest features include-dev? cmd)
	  (let ((lock (matching-activation-lock manifest features include-dev? cmd)))
	    (cond
	     ((and lock (lock-materialized? lock include-dev?)) lock)
	     ((and lock (command-locked-mode? cmd))
	      (dependency-error "locked dependency is not materialized; run `kons fetch` first"
	           (package-name manifest)))
	     (lock #f)
	     ((command-locked-mode? cmd)
	      (if (file-exists? (activation-lock-path manifest))
	          (lockfile-error "kons.lock is stale or belongs to another manifest; run `kons update`")
	          (lockfile-error "kons.lock missing; run `kons update` first")))
	     (else #f))))

	(define (effective-activation-source-roots manifest include-dev? features cmd)
	  (let ((lock (activation-lock-or-live manifest features include-dev? cmd)))
	    (if lock
	        (with-project-config-load-paths
             manifest
             cmd
             (locked-activation-source-roots manifest lock include-dev?))
	        (activation-source-roots manifest include-dev? features cmd))))

(define (value-token value)
  (cond
   ((symbol? value) (symbol->string value))
   ((string? value) value)
   ((number? value) (number->string value))
   ((null? value) "")
   ((pair? value)
    (let loop ((items value) (out ""))
      (cond
       ((null? items) out)
       ((string=? out "") (loop (cdr items) (value-token (car items))))
       (else (loop (cdr items) (string-append out "-" (value-token (car items))))))))
   (else "value")))

(define (scheme-library-name? name)
  (or (symbol? name)
      (and (pair? name)
           (let loop ((items name))
             (or (null? items)
                 (and (symbol? (car items))
                      (loop (cdr items))))))))

(define (library-name-form name)
  (if (symbol? name) (list name) name))

(define (live-system-dependency-names manifest include-dev? features cmd)
  (append-map
   (lambda (dep)
     (if (eq? (alist-ref dep 'type #f) 'system)
         (alist-ref dep 'names '())
         '()))
   (all-dependencies-for manifest include-dev? features cmd)))

(define (locked-system-entry-names lock include-dev?)
  (append-map
   (lambda (entry)
     (if (and (pair? entry)
              (eq? (car entry) 'system)
              (locked-entry-in-scope? entry include-dev?))
         (let ((names-form (assq 'names (cdr entry))))
           (if names-form (cdr names-form) '()))
         '()))
   (lock-package-entries lock)))

	(define (effective-system-dependency-names manifest include-dev? features cmd)
	  (let ((lock (activation-lock-or-live manifest features include-dev? cmd)))
	    (if lock
	        (locked-system-entry-names lock include-dev?)
	        (live-system-dependency-names manifest include-dev? features cmd))))

(define (write-system-check-script path library-name)
  (call-with-output-file path
    (lambda (out)
      (write `(import (scheme base) ,(library-name-form library-name)) out)
      (newline out)
      (write '(define kons-system-check #t) out)
      (newline out))))

(define (check-system-library scheme srcs library-name)
  (let* ((script (path-join "/tmp"
                            (string-append
                             "kons-system-check-"
                             (symbol->string scheme)
                             "-"
                             (safe-store-token (value-token library-name))
                             ".scm")))
         (cmd #f))
    (when (file-exists? script)
      (delete-file script))
    (write-system-check-script script library-name)
    (set! cmd (scheme-command scheme srcs script '()))
    (unless (= (shell-command-status (string-append cmd " >/dev/null 2>/dev/null")) 0)
      (dependency-error "system Scheme library is not available for selected implementation"
           library-name
           scheme))
    (when (file-exists? script)
      (delete-file script))))

(define (check-system-dependencies manifest cmd include-dev? features srcs)
  (let ((scheme (adapter-scheme manifest (command-selected-scheme cmd)))
        (available-srcs (filter file-exists? srcs)))
    (ui-status "checking system dependencies")
    (for-each
     (lambda (name)
       (when (scheme-library-name? name)
         (check-system-library scheme available-srcs name)))
     (effective-system-dependency-names manifest include-dev? features cmd))
    (ui-status-done "checked system dependencies")))

(define (dependency-progress-label dep)
  (let ((type (alist-ref dep 'type #f)))
    (string-append
     (if type (symbol->string type) "dependency")
     " "
     (cond
      ((alist-ref dep 'name #f) (name->string (alist-ref dep 'name '())))
      ((alist-ref dep 'names #f) (string-join (map symbol->string (alist-ref dep 'names '())) " "))
      (else "")))))

(define (materializable-dependency? dep)
  (memq (alist-ref dep 'type #f) '(path git registry)))

(define (runner-job-event-field event key default)
  (let loop ((items (cdr event)))
    (cond
     ((null? items) default)
     ((and (pair? (car items))
           (eq? (caar items) key)
           (pair? (cdar items)))
      (cadar items))
     (else (loop (cdr items))))))

(define (make-materialize-job-event-handler total)
  (let ((done 0)
        (active '()))
    (lambda (event)
      (let* ((status (runner-job-event-field event 'status #f))
             (label (runner-job-event-field event 'label #f))
             (metadata (runner-job-event-field event 'metadata '()))
             (done-label (alist-ref metadata 'done-label label))
             (entry-name (and label (let ((parts (string-split label #\space)))
                                      (if (> (length parts) 1)
                                          (string-join (cdr parts) " ")
                                          #f)))))
        (when (and label (alist-ref metadata 'ui #f))
          (case status
            ((started)
             (when entry-name
               (set! active (cons entry-name active)))
             (ui-progress "Materializing" done total (active-materialize-message active)))
            ((done planned)
             (when entry-name
               (set! active (remove-string entry-name active)))
             (set! done (+ done 1))
             (ui-display-status "Materialized" 'green entry-name)
             (if (= done total)
                 (ui-display-status
                  "Finished"
                  'bold
                  (string-append "materialized "
                                 (number->string total)
                                 " dependencies"))
                 (when (not (null? active))
                   (ui-progress "Materializing" done total (active-materialize-message active)))))
            ((failed)
             (ui-status-fail "Failed" entry-name))
            (else #f)))))))

(define (active-materialize-message active)
  (if (null? active)
      #f
      (let loop ((items (reverse active)) (count 0) (shown '()))
        (cond
         ((null? items) (string-join (reverse shown) ", "))
         ((>= count 4) (string-join (reverse (cons "..." shown)) ", "))
         (else (loop (cdr items) (+ count 1) (cons (car items) shown)))))))

(define (materialize-job-event-handler event)
  (let* ((status (runner-job-event-field event 'status #f))
         (label (runner-job-event-field event 'label #f))
         (metadata (runner-job-event-field event 'metadata '()))
         (done-label (alist-ref metadata 'done-label label)))
    (when (and label (alist-ref metadata 'ui #f))
      (case status
        ((started) (ui-status label))
        ((done planned) (ui-status-done done-label))
        ((failed) (ui-status-fail label))
        (else #f)))))

(define (job-results-values results)
  (map job-result-value results))

(define (remove-string item items)
  (let loop ((xs items) (out '()) (removed? #f))
    (cond
     ((null? xs) (reverse out))
     ((and (not removed?) (string=? item (car xs)))
      (loop (cdr xs) out #t))
     (else (loop (cdr xs) (cons (car xs) out) removed?)))))

(define (materialize-runner-options cmd total)
  (make-job-runner-options
   (if cmd (command-job-count cmd) 1)
   #f
   #t
   #f
   (make-materialize-job-event-handler total)))

(define (dependency-resource dep)
  `(dependency
    ,(alist-ref dep 'type #f)
    ,(alist-ref dep 'name (alist-ref dep 'names '()))
    ,(alist-ref dep 'path (alist-ref dep 'url (alist-ref dep 'ref "")))))

(define (dependency-resources dep)
  (let ((type (alist-ref dep 'type #f)))
    (append
     (list (dependency-resource dep))
     (case type
       ((git) `((git-cache ,(alist-ref dep 'url ""))))
       ((registry) `((registry-cache ,(alist-ref dep 'registry default-registry-alias))))
       (else '())))))

(define (lock-entry-resource entry)
  `(locked-dependency
    ,(lock-entry-type entry)
    ,(lock-entry-ref entry 'name (lock-entry-ref entry 'names '()))
    ,(lock-entry-ref entry 'path (lock-entry-ref entry 'url (lock-entry-ref entry 'ref "")))))

(define (lock-entry-resources entry)
  (let ((type (lock-entry-type entry)))
    (append
     (list (lock-entry-resource entry))
     (case type
       ((git) `((git-cache ,(lock-entry-ref entry 'url ""))))
       ((registry) `((registry-cache ,(lock-entry-ref entry 'registry default-registry-alias))))
       (else '())))))

(define (lock-entry-progress-label entry)
  (let ((type (lock-entry-type entry)))
    (string-append
     (if type (symbol->string type) "dependency")
     " "
     (cond
      ((lock-entry-ref entry 'name #f) (name->string (lock-entry-ref entry 'name '())))
      ((lock-entry-ref entry 'names #f) (string-join (map symbol->string (lock-entry-ref entry 'names '())) " "))
      (else "")))))

(define (materialize-local-job manifest offline? index dep)
  (let* ((type (alist-ref dep 'type #f))
         (label (string-append "materializing " (dependency-progress-label dep)))
         (done-label (string-append "materialized " (dependency-progress-label dep))))
    (make-job
     `(materialize ,index)
     'dependency
     label
     '()
     `((ui . #t)
       (done-label . ,done-label)
       (dependency ,dep))
     (dependency-resources dep)
     #t
       (lambda ()
         (case type
           ((path) (materialize-path-dependency manifest dep))
           ((git) (materialize-git-dependency manifest dep offline?))
           ((registry) (materialize-registry-dependency manifest dep offline?))
           (else (dependency-error "unsupported materializable dependency" type)))))))

(define (materialize-local-sources manifest features include-dev? offline? cmd)
  (let ((deps (filter materializable-dependency?
                      (all-dependencies-for manifest include-dev? features cmd))))
    (if (null? deps)
        '()
        (let ((total (length deps)))
          (let loop ((items deps) (index 0) (jobs '()) (roots '()))
            (if (null? items)
                (job-results-values
                 (run-job-graph!
                  (make-job-graph (reverse jobs) (reverse roots))
                  (materialize-runner-options cmd total)))
                (let ((job (materialize-local-job manifest offline? index (car items))))
                  (loop (cdr items)
                        (+ index 1)
                        (cons job jobs)
                        (cons (job-id job) roots)))))))))

(define (materialize-lock-job manifest offline? index entry)
  (let* ((type (lock-entry-type entry))
         (label (string-append "materializing " (lock-entry-progress-label entry)))
         (done-label (string-append "materialized " (lock-entry-progress-label entry))))
    (make-job
     `(materialize-lock ,index)
     'dependency
     label
     '()
     `((ui . #t)
       (done-label . ,done-label)
       (lock-entry ,entry))
     (lock-entry-resources entry)
     #t
       (lambda ()
         (case type
           ((path) (materialize-locked-path-entry manifest entry))
           ((git) (materialize-locked-git-entry manifest entry offline?))
           ((registry) (materialize-locked-registry-entry manifest entry offline?))
           (else (dependency-error "unsupported materializable locked dependency" type)))))))

(define (materialize-lock-sources manifest lock include-dev? offline? . maybe-cmd)
  (let ((entries (filter (lambda (entry)
                           (and (locked-entry-in-scope? entry include-dev?)
                                (memq (lock-entry-type entry) '(path git registry))))
                         (lock-package-entries lock)))
        (cmd (and (pair? maybe-cmd) (car maybe-cmd))))
    (if (null? entries)
        '()
        (let ((total (length entries)))
          (let loop ((items entries) (index 0) (jobs '()) (roots '()))
            (if (null? items)
                (job-results-values
                 (run-job-graph!
                  (make-job-graph (reverse jobs) (reverse roots))
                  (materialize-runner-options cmd total)))
                (let ((job (materialize-lock-job manifest offline? index (car items))))
                  (loop (cdr items)
                        (+ index 1)
                        (cons job jobs)
                        (cons (job-id job) roots)))))))))

(define (run-script manifest cmd script include-dev? rest)
  (let* ((scheme (command-selected-scheme cmd))
         (adapted-scheme (adapter-scheme manifest scheme))
         (features (active-features manifest cmd))
         (srcs (effective-activation-source-roots manifest include-dev? features cmd))
         (command (adapter-command adapted-scheme srcs script rest 'normal '() (command-selected-profile cmd))))
    (check-system-dependencies manifest cmd include-dev? features srcs)
    (when include-dev?
      (log-info "dev dependencies are available when materialized"))
    (log-debug "command" (command->shell command))
    (log-debug "argv" (command-argv command))
    (run-command-record command)))

		(define (collect-scheme-files dir label)
		  (define (directory? path)
		    (= (shell-command-status
		        (string-append "test -d " (shell-quote path) " >/dev/null 2>/dev/null"))
		       0))
		  (define (scheme-test-file? path)
		    (or (string-suffix? ".scm" path)
		        (string-suffix? ".sps" path)
		        (string-suffix? ".sld" path)
		        (string-suffix? ".sls" path)))
          (define (hidden-entry? entry)
            (and (> (string-length entry) 0)
                 (char=? (string-ref entry 0) #\.)))
		  (define (collect-dir dir out)
		    (let loop ((entries (directory-list dir)) (out out))
		      (cond
	       ((null? entries) out)
	       (else
	        (let ((path (path-join dir (car entries))))
	          (cond
		           ((and (file-directory? path)
                     (not (hidden-entry? (car entries))))
		            (loop (cdr entries) (collect-dir path out)))
		           ((and (file-exists? path)
		                 (scheme-test-file? path))
		            (loop (cdr entries) (cons path out)))
		           (else (loop (cdr entries) out))))))))
		  (cond
		   ((not (file-exists? dir))
		    (usage-error (string-append label " directory not found") dir))
		   ((not (file-directory? dir))
		    (usage-error (string-append label " path is not a directory") dir))
		   (else
		    (reverse (collect-dir dir '())))))

		(define (collect-test-files tests-dir)
		  (collect-scheme-files tests-dir "tests"))
	  ))
