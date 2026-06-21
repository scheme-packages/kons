(define-library (kons actions targets)
  (export library-entry-files
          validate-file-exists
          validate-r7rs-libraries
          validate-declared-libraries
          package-main-path
          package-bin-path
          selected-bin-script
          selected-install-script
          selected-install-main-path
          package-test-files
          package-bench-files
          package-example-files
          selected-files
          selected-test-files
          selected-bench-files
          selected-path-filters
          test-file-matches-filters?
          package-script-path
          package-example-path
          selected-run-script
          run-targets-form
          test-targets-form
          bench-targets-form
          validate-entrypoints
          matching-lock-present?
          activation-metadata
          install-root-prefix
          install-bin-dir
          install-lib-dir
          install-manifest-path
          copy-source-root
          installed-dependency-root
          install-dependency-root
          write-launcher)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons compat files)
          (kons util)
          (kons implementation)
          (kons manifest)
          (kons library-discovery)
          (kons features)
          (kons lock)
          (kons runner)
          (kons options)
          (kons actions paths)
          (kons actions lock-shared))

  (begin
(define (library-entry-files manifest)
  (let ((source-root (manifest-source-root manifest)))
    (let loop ((entries (effective-package-libraries manifest)) (out '()))
      (cond
       ((null? entries) (reverse out))
       ((r7rs-library-entry-name (car entries))
        => (lambda (name)
             (loop (cdr entries)
                   (cons `(r7rs ,name ,(library-entry-path source-root (car entries))) out))))
       ((r6rs-library-entry-name (car entries))
        => (lambda (name)
             (loop (cdr entries)
                   (cons `(r6rs ,name ,(library-entry-path source-root (car entries))) out))))
       ((guile-library-entry-name (car entries))
        => (lambda (name)
             (loop (cdr entries)
                   (cons `(guile ,name ,(library-entry-path source-root (car entries))) out))))
       ((gauche-library-entry-name (car entries))
        => (lambda (name)
             (loop (cdr entries)
                   (cons `(gauche ,name ,(library-entry-path source-root (car entries))) out))))
       ((and (pair? (car entries)) (not (symbol? (caar entries))))
        (loop (append (car entries) (cdr entries)) out))
       (else (loop (cdr entries) out))))))

(define (validate-file-exists label path)
  (unless (file-exists? path)
    (manifest-error (string-append label " not found") path)))

(define (validate-r7rs-libraries manifest)
  (for-each
   (lambda (name)
     (validate-file-exists
      "declared R7RS library"
      (library-source-path (manifest-source-root manifest) name)))
   (r7rs-library-names manifest)))

(define (validate-declared-libraries manifest)
  (for-each
   (lambda (entry)
     (validate-file-exists
      (case (car entry)
        ((r7rs) "declared R7RS library")
        ((r6rs) "declared R6RS library")
        ((guile) "declared Guile module")
        ((gauche) "declared Gauche module")
        (else "declared library"))
      (car (cdr (cdr entry)))))
   (library-entry-files manifest)))

(define (package-main-path manifest)
  (let ((main (package-main manifest)))
    (and main (manifest-source-path manifest main))))

(define (package-bin-path manifest name)
  (let ((found (assoc name (package-bins manifest))))
    (and found (manifest-source-path manifest (cdr found)))))

(define (selected-bin-script manifest raw-name)
  (let* ((name (string->symbol raw-name))
         (bin-path (package-bin-path manifest name)))
    (cond
     (bin-path bin-path)
     ((string=? raw-name (default-binary-name manifest))
      (or (package-main-path manifest)
          (usage-error
           "package has no default binary target; add (main \"...\") or declare (bins ...)")))
     (else
      (let ((path (package-script-path manifest name)))
        (unless path
          (manifest-error "binary target not found" raw-name))
        path)))))

(define (selected-install-script manifest cmd)
  (let ((bin-name (command-option cmd "bin" #f))
        (script-name (command-option cmd "script" #f)))
    (when script-name
      (usage-error "install uses --bin for binary targets, not --script"))
    (cond
     ((not bin-name)
      (or (package-main-path manifest)
          (usage-error
           "package has no default install target; add (main \"...\") or use --bin")))
     ((package-bin-path manifest (string->symbol bin-name)))
     ((string=? bin-name (default-binary-name manifest))
      (or (package-main-path manifest)
          (usage-error
           "package has no default install target; add (main \"...\") or use --bin")))
     (else (manifest-error "binary target not found" bin-name)))))

(define (selected-install-main-path manifest cmd installed-root-source)
  (let ((bin-name (command-option cmd "bin" #f)))
    (path-join
     installed-root-source
     (if bin-name
         (let ((found (assoc (string->symbol bin-name) (package-bins manifest))))
           (if found
               (cdr found)
               (or (package-main manifest)
                   (usage-error
                    "package has no default install target; add (main \"...\") or use --bin"))))
         (or (package-main manifest)
             (usage-error
              "package has no default install target; add (main \"...\") or use --bin"))))))

	(define (package-test-files manifest)
	  (let ((declared (package-tests manifest)))
	    (if (null? declared)
	        (let ((dir (path-join (manifest-root manifest) "tests")))
	          (if (and (file-exists? dir) (file-directory? dir))
	              (collect-test-files dir)
	              '()))
	        (map (lambda (path) (manifest-root-path manifest path)) declared))))

	(define (package-bench-files manifest)
	  (let ((declared (package-benches manifest)))
	    (if (null? declared)
	        (let ((dir (path-join (manifest-root manifest) "benches")))
	          (if (and (file-exists? dir) (file-directory? dir))
	              (collect-scheme-files dir "benches")
	              '()))
	        (map (lambda (path) (manifest-root-path manifest path)) declared))))

	(define (path-last-segment path)
	  (let ((parts (filter non-empty-string? (string-split path #\/))))
	    (if (null? parts) path (car (reverse parts)))))

	(define (path-without-scheme-extension path)
	  (let ((file (path-last-segment path)))
	    (cond
	     ((string-suffix? ".scm" file)
	      (substring file 0 (- (string-length file) 4)))
	     ((string-suffix? ".sps" file)
	      (substring file 0 (- (string-length file) 4)))
	     ((string-suffix? ".sld" file)
	      (substring file 0 (- (string-length file) 4)))
	     ((string-suffix? ".sls" file)
	      (substring file 0 (- (string-length file) 4)))
	     (else file))))

	(define (discovered-example-files manifest)
	  (let ((dir (path-join (manifest-root manifest) "examples")))
	    (if (and (file-exists? dir) (file-directory? dir))
	        (map (lambda (path)
	               (cons (string->symbol (path-without-scheme-extension path)) path))
	             (collect-scheme-files dir "examples"))
	        '())))

	(define (package-example-files manifest)
	  (let ((declared (package-examples manifest)))
	    (if (null? declared)
	        (discovered-example-files manifest)
	        (map (lambda (example)
	               (cons (car example)
	                     (manifest-root-path manifest (cdr example))))
	             declared))))

	(define (selected-files manifest cmd command file-provider label no-match-message)
	  (let* ((dir (command-option cmd "directory" #f))
	         (files (if dir
	                    (collect-scheme-files (manifest-root-path manifest dir) label)
	                    (file-provider manifest)))
	         (filters (selected-path-filters cmd command)))
	    (if (null? filters)
	        files
	        (let ((matched (filter (lambda (file)
	                                 (test-file-matches-filters? file filters))
	                               files)))
	          (when (null? matched)
	            (usage-error no-match-message filters))
	          matched))))

	(define (selected-test-files manifest cmd)
	  (selected-files manifest cmd "test" package-test-files "tests" "no tests matched filter"))

	(define (selected-bench-files manifest cmd)
	  (selected-files manifest cmd "bench" package-bench-files "benches" "no benchmarks matched filter"))

	(define (selected-path-filters cmd command)
	  (command-rest cmd))

	(define (test-file-matches-filters? file filters)
	  (let loop ((items filters))
	    (cond
	     ((null? items) #f)
	     ((string-contains? file (car items)) #t)
	     (else (loop (cdr items))))))

(define (package-script-path manifest name)
  (let ((found (assoc name (package-scripts manifest))))
    (and found (manifest-root-path manifest (cdr found)))))

(define (package-example-path manifest name)
  (let ((found (assoc name (package-example-files manifest))))
    (and found (cdr found))))

		(define (selected-run-script manifest cmd)
		  (let ((script-name (command-option cmd "script" #f))
		        (bin-name (command-option cmd "bin" #f))
		        (example-name (command-option cmd "example" #f)))
	    (when (> (+ (if script-name 1 0)
	                (if bin-name 1 0)
	                (if example-name 1 0))
	             1)
	      (usage-error "choose only one of --script, --bin, or --example"))
	    (cond
	     (script-name
	      (let ((path (package-script-path manifest (string->symbol script-name))))
	        (unless path
	          (manifest-error "script not found" script-name))
	        path))
	     (bin-name
	      (selected-bin-script manifest bin-name))
	     (example-name
	      (let ((path (package-example-path manifest (string->symbol example-name))))
	        (unless path
	          (manifest-error "example target not found" example-name))
	        path))
	     ((package-main-path manifest) (package-main-path manifest))
	     (else
	      (usage-error
	       "package has no default run target; add (main \"...\") or use --bin/--script/--example")))))

	(define (run-targets-form manifest)
	  (append
	   `(run-targets
	     (root ,(package-name manifest)))
	   (if (package-main-path manifest)
	       `((default
	          (name ,(default-binary-name manifest))
	          (path ,(package-main-path manifest))))
	       '((default #f)))
	   `((scripts
	      ,@(map (lambda (script)
	               `(,(car script) ,(manifest-root-path manifest (cdr script))))
	             (package-scripts manifest)))
	     (bins
	      ,@(map (lambda (bin)
	               `(,(car bin) ,(manifest-source-path manifest (cdr bin))))
	             (package-bins manifest)))
	     (examples
	      ,@(map (lambda (example)
	               `(,(car example) ,(cdr example)))
	             (package-example-files manifest))))))

	(define (test-targets-form manifest cmd features)
	  `(test-targets
	    (root ,(package-name manifest))
	    (features ,@features)
	    (tests ,@(selected-test-files manifest cmd))))

	(define (bench-targets-form manifest cmd features)
	  `(bench-targets
	    (root ,(package-name manifest))
	    (features ,@features)
	    (benchmarks ,@(selected-bench-files manifest cmd))))
	
	(define (validate-entrypoints manifest)
	  (when (package-main-path manifest)
	    (validate-file-exists "main script" (package-main-path manifest)))
  (for-each
   (lambda (path)
     (validate-file-exists "test script" path))
   (package-test-files manifest))
  (for-each
   (lambda (path)
     (validate-file-exists "benchmark script" path))
   (package-bench-files manifest))
  (for-each
   (lambda (example)
     (validate-file-exists "example script" (cdr example)))
   (package-example-files manifest))
  (for-each
   (lambda (script)
     (validate-file-exists
      "manifest script"
      (manifest-root-path manifest (cdr script))))
   (package-scripts manifest))
  (for-each
   (lambda (bin)
     (validate-file-exists
      "binary target"
      (manifest-source-path manifest (cdr bin))))
   (package-bins manifest)))


	



(define (matching-lock-present? manifest features cmd)
  (let ((path (project-lock-path manifest)))
    (and (file-exists? path)
         (let ((lock (read-lockfile path)))
           (lock-resolution-current? manifest features cmd lock)))))

(define (activation-metadata manifest cmd launcher main src features scheme . maybe-compiled-roots)
  (let* ((compiled-roots (if (pair? maybe-compiled-roots) (car maybe-compiled-roots) '()))
         (mode (if (null? compiled-roots) 'normal 'compiled))
         (command (adapter-command scheme src main '() mode compiled-roots (command-selected-profile cmd))))
    `(activation
      (root ,(package-name manifest))
      (version ,(package-version manifest))
	      (scheme ,scheme)
	      ,(implementation-probe scheme)
	      (target ,(command-option cmd "target" #f))
	      (profile ,(command-selected-profile cmd))
          (compile-mode ,mode)
	      (features ,@features)
      (launcher ,launcher)
      (main ,main)
      (lockfile ,(if (matching-lock-present? manifest features cmd)
                     (project-lock-path manifest)
                     #f))
      (source-roots ,@src)
      (load-paths ,@src)
      (compiled-load-paths ,@compiled-roots)
      (command ,command))))

(define (install-root-prefix cmd)
  (absolute-path
   (or (command-option cmd "root" #f)
       (kons-home)
       ".kons")))

(define (install-bin-dir cmd)
  (absolute-path
   (command-option cmd "directory"
                 (path-join (install-root-prefix cmd) "bin"))))

(define (install-lib-dir cmd)
  (path-join (install-root-prefix cmd) "lib"))

(define (install-manifest-path cmd)
  (or (command-option cmd "manifest" #f)
      (let ((path (command-option cmd "path" #f)))
        (and path (path-join path "kons.scm")))
      (command-manifest-path cmd)))

(define (copy-source-root source dest)
  (unless (and (file-exists? dest)
               (equal? (path-content-hash source) (path-content-hash dest)))
    (run-command (string-append "rm -rf " (shell-quote dest)))
    (run-command (string-append "mkdir -p " (shell-quote (dirname dest))))
    (run-command (string-append "cp -pR " (shell-quote source) " " (shell-quote dest))))
  dest)

(define (installed-dependency-root cmd source)
  (path-join
   (path-join (install-lib-dir cmd) "dependencies")
   (string-append
    (safe-store-token (absolute-path source))
    "-"
    (safe-store-token (path-content-hash source)))))

(define (install-dependency-root cmd source)
  (let ((dest (installed-dependency-root cmd source)))
    (copy-source-root source dest)))

(define (write-launcher bin-path cmd)
  (call-with-output-file bin-path
    (lambda (out)
      (display "#!/bin/sh" out)
      (newline out)
      (display cmd out)
      (newline out))))

  ))
