(define-library (kons actions package-edit)
  (export write-manifest-edit-and-refresh-lock!
          display-name-list
          write-new-manifest
          write-new-library
          write-new-main
          write-new-test
          write-new-bench
          write-new-example
          write-new-gitignore
          write-exprs-file
          starter-command-directory
          name-parts-from-cli
          dependency-name=?
          system-dependency-has-name?
          ensure-dependency-absent
          make-add-dependency-expr
          replace-or-add-dependency-block
          dependency-expr-name
          system-name-field?
          system-expr-names
          system-expr-selectors
          name-list-member?
          remove-name-from-list
          remove-from-system-expr
          remove-from-dependency-expr
          remove-from-dependency-block
          remove-from-blocks
          remove-blocks-from-manifest
          starter-name-parts
          last-path-segment
          starter-default-name
          starter-spec
          starter-spec-ref
          starter-file-paths
          starter-plan
          ensure-starter-files-absent
          write-starter-package)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons compat files)
          (kons util)
          (kons manifest)
          (kons features)
          (kons lock)
          (kons runner)
          (kons options)
          (kons actions paths)
          (kons actions lock-shared))

  (begin
(define (write-manifest-edit-and-refresh-lock! manifest-path* new-exprs cmd log-message)
  (when (command-locked-mode? cmd)
    (lockfile-error "add/remove would modify kons.lock, but --locked/--frozen was supplied"))
  (let* ((manifest (parse-manifest-exprs manifest-path* new-exprs))
         (features (active-features manifest cmd))
         (lock-path (project-lock-path manifest))
         (new-lock (make-lock manifest features cmd)))
    (ensure-supported-active-features manifest features cmd)
    (materialize-local-sources manifest features #t #f cmd)
    (write-exprs-file manifest-path* new-exprs)
    (write-expr-file lock-path new-lock)
    (log-info log-message)))

(define (display-name-list parts out)
  (display "(" out)
  (let loop ((rest parts) (first? #t))
    (cond
     ((null? rest) (display ")" out))
     (first?
      (display (car rest) out)
      (loop (cdr rest) #f))
     (else
      (display " " out)
      (display (car rest) out)
      (loop (cdr rest) #f)))))

(define (write-new-manifest path name-parts lib?)
  (call-with-output-file path
    (lambda (out)
      (display "(package" out)
      (newline out)
      (display "  (name " out)
      (display-name-list name-parts out)
      (display ")" out)
      (newline out)
      (display "  (version \"0.1.0\")" out)
      (newline out)
      (display "  (license \"MIT\")" out)
      (newline out)
      (display "  (description \"A new Scheme package\")" out)
      (newline out)
      (display "  (keywords)" out)
      (newline out)
      (display "  (authors)" out)
      (newline out)
      (display "  (site \"\")" out)
      (newline out)
      (display "  (repo \"\")" out)
      (newline out)
      (display "  (docs \"\")" out)
      (newline out)
      (display "  (readme \"README.md\")" out)
      (newline out)
      (display "  (dialects r7rs)" out)
      (newline out)
      (display "  (source-path \"src\")" out)
      (newline out)
      (display "  (main " out)
      (display (if lib? "#f" "\"main.scm\"") out)
      (display ")" out)
      (newline out)
      (display "  (tests \"tests/main.scm\")" out)
      (newline out)
      (display "  (benches \"benches/main.scm\")" out)
      (newline out)
      (display "  (examples \"examples/main.scm\"))" out)
      (newline out)
      (newline out)
      (if lib?
          (begin
            (display "(dependencies" out)
            (newline out)
            (display "  (system (scheme base)))" out)
            (newline out)
            (newline out)
            (display "(dev-dependencies" out)
            (newline out)
            (display "  (system (scheme write)))" out))
          (begin
            (display "(dependencies" out)
            (newline out)
            (display "  (system (scheme base) (scheme write)))" out)
            (newline out)
            (newline out)
            (display "(dev-dependencies)" out)))
      (newline out)
      (newline out)
      (display "(overrides)" out)
      (newline out))))

(define (write-new-library path name-parts)
  (call-with-output-file path
    (lambda (out)
      (display "(define-library " out)
      (display-name-list name-parts out)
      (newline out)
      (display "  (export message)" out)
      (newline out)
      (display "  (import (scheme base))" out)
      (newline out)
      (display "  (begin" out)
      (newline out)
      (display "    (define (message) \"new package ok\")))" out)
      (newline out))))

(define (write-new-main path name-parts)
  (call-with-output-file path
    (lambda (out)
      (display "(import (scheme base)" out)
      (newline out)
      (display "        (scheme write)" out)
      (newline out)
      (display "        " out)
      (display-name-list name-parts out)
      (display ")" out)
      (newline out)
      (newline out)
      (display "(display (message))" out)
      (newline out)
      (display "(newline)" out)
      (newline out))))

	(define (write-new-test path name-parts)
	  (call-with-output-file path
	    (lambda (out)
	      (display "(import (scheme base)" out)
      (newline out)
      (display "        (scheme write)" out)
      (newline out)
      (display "        " out)
      (display-name-list name-parts out)
      (display ")" out)
      (newline out)
      (newline out)
      (display "(unless (string=? (message) \"new package ok\")" out)
      (newline out)
      (display "  (display \"unexpected message\")" out)
      (newline out)
      (display "  (newline)" out)
      (newline out)
      (display "  (car '()))" out)
      (newline out)
      (newline out)
      (display "(display \"new package test ok\")" out)
      (newline out)
	      (display "(newline)" out)
	      (newline out))))

	(define (write-new-bench path name-parts)
	  (call-with-output-file path
	    (lambda (out)
	      (display "(import (scheme base)" out)
      (newline out)
      (display "        (scheme write)" out)
      (newline out)
      (display "        " out)
      (display-name-list name-parts out)
      (display ")" out)
      (newline out)
      (newline out)
      (display "(let loop ((n 1000) (last \"\"))" out)
      (newline out)
      (display "  (if (= n 0)" out)
      (newline out)
      (display "      (begin" out)
      (newline out)
      (display "        (display \"new package bench ok\")" out)
      (newline out)
      (display "        (newline))" out)
      (newline out)
      (display "      (loop (- n 1) (message))))" out)
      (newline out))))

	(define (write-new-example path name-parts)
	  (call-with-output-file path
	    (lambda (out)
	      (display "(import (scheme base)" out)
      (newline out)
      (display "        (scheme write)" out)
      (newline out)
      (display "        " out)
      (display-name-list name-parts out)
      (display ")" out)
      (newline out)
      (newline out)
      (display "(display (message))" out)
      (newline out)
      (display "(newline)" out)
      (newline out))))

(define (write-new-gitignore path)
  (call-with-output-file path
    (lambda (out)
      (display ".kons/" out)
      (newline out)
      (display "kons.lock" out)
      (newline out))))
	
	(define (write-exprs-file path exprs)
	  (let ((tmp (temporary-file-path path)))
	    (call-with-output-file tmp
	      (lambda (out)
	        (let loop ((items exprs) (first? #t))
	          (unless (null? items)
	            (unless first? (newline out))
	            (write (car items) out)
	            (newline out)
	            (loop (cdr items) #f)))))
	    (run-command
	     (string-append "mv -f " (shell-quote tmp) " " (shell-quote path)))))
	
	(define (starter-command-directory cmd command default-dir)
	  (let ((positionals (command-rest cmd)))
	    (command-option cmd "directory"
	                  (if (pair? positionals)
	                      (car positionals)
	                      default-dir))))
	
	(define (name-parts-from-cli raw-name)
	  (let ((parts (filter non-empty-string? (string-split raw-name #\/))))
	    (when (null? parts)
	      (usage-error "dependency name must contain at least one path segment" raw-name))
	    (map string->symbol parts)))
	
	(define (dependency-name=? dep name)
	  (equal? (alist-ref dep 'name '()) name))
	
	(define (system-dependency-has-name? dep name)
	  (and (eq? (alist-ref dep 'type #f) 'system)
	       (member name (alist-ref dep 'names '()))))
	
	(define (ensure-dependency-absent manifest block name dep-type)
	  (let ((deps (alist-ref manifest block '())))
	    (let loop ((items deps))
	      (unless (null? items)
	        (when (if (eq? dep-type 'system)
	                  (system-dependency-has-name? (car items) name)
	                  (dependency-name=? (car items) name))
	          (manifest-error "dependency is already present" name block))
	        (loop (cdr items))))))
	
	(define (make-add-dependency-expr raw-name cmd)
	  (let* ((name (name-parts-from-cli raw-name))
	         (path (command-option cmd "path" #f))
	         (git (command-option cmd "git" #f))
	         (rev (command-option cmd "rev" #f))
	         (subpath (command-option cmd "subpath" #f))
	         (system? (command-flag? cmd "system"))
	         (raw? (command-flag? cmd "raw"))
         (version (command-option cmd "version" #f))
         (registry (command-option cmd "registry" #f))
         (source-count (+ (if path 1 0) (if git 1 0) (if system? 1 0))))
	    (when (> source-count 1)
	      (usage-error "choose only one dependency source" raw-name))
	    (when (and (> source-count 0) registry (not version))
	      (usage-error "--registry on a local dependency requires --version" raw-name))
	    (when (and raw? (not path))
	      (usage-error "--raw is only valid with --path" raw-name))
	    (when (and subpath (or path system?))
	      (usage-error "--subpath is only valid with git dependencies" raw-name))
	    (cond
	     (path
	      (append `(path (name ,name) (path ,path))
	              (if raw? '((raw #t)) '())
	              (if version `((version ,version)) '())
	              (if registry `((registry ,registry)) '())))
	     (git
	      (append `(git (name ,name) (url ,git))
	              (if rev `((rev ,rev)) '())
	              (if subpath `((subpath ,subpath)) '())
	              (if version `((version ,version)) '())
	              (if registry `((registry ,registry)) '())))
	     (system?
	      `(system ,name))
         (else
          (append `(registry (name ,name) (version ,(if version version "*")))
                  (if registry `((registry ,registry)) '()))))))
	
	(define (replace-or-add-dependency-block exprs block dep-expr)
	  (let loop ((items exprs) (out '()) (done? #f))
	    (cond
	     ((null? items)
	      (reverse
	       (if done?
	           out
	           (cons `(,block ,dep-expr) out))))
	     ((and (pair? (car items)) (eq? (car (car items)) block))
	      (loop (cdr items)
	            (cons (append (car items) (list dep-expr)) out)
	            #t))
	     (else (loop (cdr items) (cons (car items) out) done?)))))
	
	(define (dependency-expr-name expr)
	  (let ((field (and (pair? expr) (assq 'name (cdr expr)))))
	    (and field
	         (pair? (cdr field))
	         (cadr field))))
	
	(define (system-name-field? item)
	  (and (pair? item)
	       (memq (car item) '(names schemes implementations targets))))
	
	(define (system-expr-names expr)
	  (let loop ((items (cdr expr)) (out '()))
	    (cond
	     ((null? items) (reverse out))
	     ((and (pair? (car items)) (eq? (car (car items)) 'names))
	      (loop (cdr items) (append (reverse (cdr (car items))) out)))
	     ((system-name-field? (car items))
	      (loop (cdr items) out))
	     (else (loop (cdr items) (cons (car items) out))))))
	
	(define (system-expr-selectors expr)
	  (let loop ((items (cdr expr)) (out '()))
	    (cond
	     ((null? items) (reverse out))
	     ((and (pair? (car items)) (memq (car (car items)) '(schemes implementations targets)))
	      (loop (cdr items) (cons (car items) out)))
	     (else (loop (cdr items) out)))))
	
	(define (name-list-member? name names)
	  (let loop ((items names))
	    (cond
	     ((null? items) #f)
	     ((equal? name (car items)) #t)
	     (else (loop (cdr items))))))
	
	(define (remove-name-from-list name names)
	  (let loop ((items names) (out '()) (removed? #f))
	    (cond
	     ((null? items) (cons (reverse out) removed?))
	     ((equal? name (car items)) (loop (cdr items) out #t))
	     (else (loop (cdr items) (cons (car items) out) removed?)))))
	
	(define (remove-from-system-expr expr name)
	  (let* ((result (remove-name-from-list name (system-expr-names expr)))
	         (remaining (car result))
	         (removed? (cdr result)))
	    (cond
	     ((not removed?) (cons expr #f))
	     ((null? remaining) (cons #f #t))
	     (else (cons (append `(system ,@remaining) (system-expr-selectors expr)) #t)))))
	
	(define (remove-from-dependency-expr expr name)
	  (cond
	   ((not (pair? expr)) (cons expr #f))
	   ((eq? (car expr) 'system)
	    (remove-from-system-expr expr name))
	   ((equal? (dependency-expr-name expr) name)
	    (cons #f #t))
	   (else (cons expr #f))))
	
	(define (remove-from-dependency-block block-expr name)
	  (let loop ((items (cdr block-expr)) (out '()) (removed? #f))
	    (cond
     ((null? items) (cons (cons (car block-expr) (reverse out)) removed?))
	     (else
	      (let* ((result (remove-from-dependency-expr (car items) name))
	             (expr (car result))
	             (removed-entry? (cdr result)))
	        (loop (cdr items)
	              (if expr (cons expr out) out)
	              (or removed? removed-entry?)))))))
	
	(define (remove-from-blocks exprs blocks name)
	  (let loop ((items exprs) (out '()) (removed-blocks '()))
	    (cond
	     ((null? items) (cons (reverse out) (reverse removed-blocks)))
	     ((and (pair? (car items)) (memq (car (car items)) blocks))
	      (let* ((block (car (car items)))
	             (result (remove-from-dependency-block (car items) name))
	             (new-block (car result))
	             (removed? (cdr result)))
	        (loop (cdr items)
	              (cons new-block out)
	              (if removed? (cons block removed-blocks) removed-blocks))))
	     (else (loop (cdr items) (cons (car items) out) removed-blocks)))))
	
	(define (remove-blocks-from-manifest manifest blocks name)
	  (let loop ((items blocks) (removed '()))
	    (if (null? items)
	        (reverse removed)
	        (let ((deps (alist-ref manifest (car items) '())))
	          (if (let dep-loop ((rest deps))
	                (cond
	                 ((null? rest) #f)
	                 ((if (eq? (alist-ref (car rest) 'type #f) 'system)
	                      (system-dependency-has-name? (car rest) name)
	                      (dependency-name=? (car rest) name))
	                  #t)
	                 (else (dep-loop (cdr rest)))))
	              (loop (cdr items) (cons (car items) removed))
	              (loop (cdr items) removed))))))
	
			
			
	(define (starter-name-parts raw-name)
	  (filter non-empty-string? (string-split raw-name #\/)))

	(define (last-path-segment path fallback)
	  (let ((parts (filter non-empty-string? (string-split path #\/))))
	    (if (null? parts)
	        fallback
	        (symbol->string (car (reverse (map string->symbol parts)))))))

	(define (starter-default-name dir)
	  (if (or (string=? dir ".") (string=? dir ""))
	      (last-path-segment (current-directory) "app")
	      (last-path-segment dir "app")))

	(define (starter-spec dir raw-name command lib?)
	  (let ((name-parts (starter-name-parts raw-name)))
	    (when (null? name-parts)
	      (usage-error
	       (string-append command " package name must contain at least one path segment")
	       raw-name))
	    (let* ((src-dir (path-join dir "src"))
	           (library-dir (path-join src-dir (string-join (reverse (cdr (reverse name-parts))) "/")))
	           (library-leaf (car (reverse name-parts)))
	           (library-path (path-join library-dir (string-append library-leaf ".sld")))
	           (manifest-path (path-join dir "kons.scm"))
	           (gitignore-path (and (string=? command "new")
	                                (path-join dir ".gitignore")))
	           (main-path (path-join src-dir "main.scm"))
	           (test-dir (path-join dir "tests"))
	           (test-path (path-join test-dir "main.scm"))
	           (bench-dir (path-join dir "benches"))
	           (bench-path (path-join bench-dir "main.scm"))
	           (example-dir (path-join dir "examples"))
	           (example-path (path-join example-dir "main.scm")))
	      `((directory . ,dir)
	        (name . ,name-parts)
	        (source-directory . ,src-dir)
	        (library-directory . ,library-dir)
	        (library-path . ,library-path)
	        (manifest-path . ,manifest-path)
	        (gitignore-path . ,gitignore-path)
	        (main-path . ,main-path)
	        (kind . ,(if lib? 'lib 'bin))
	        (test-directory . ,test-dir)
	        (test-path . ,test-path)
	        (bench-directory . ,bench-dir)
	        (bench-path . ,bench-path)
	        (example-directory . ,example-dir)
	        (example-path . ,example-path)))))

	(define (starter-spec-ref spec key)
	  (alist-ref spec key #f))

	(define (starter-gitignore-file-path spec)
	  (let ((path (starter-spec-ref spec 'gitignore-path)))
	    (if path (list path) '())))

	(define (starter-file-paths spec)
	  (if (eq? (starter-spec-ref spec 'kind) 'lib)
	      (append
	       (list (starter-spec-ref spec 'manifest-path))
	       (starter-gitignore-file-path spec)
	       (list (starter-spec-ref spec 'library-path)
	             (starter-spec-ref spec 'test-path)
	             (starter-spec-ref spec 'bench-path)
	             (starter-spec-ref spec 'example-path)))
	      (append
	       (list (starter-spec-ref spec 'manifest-path))
	       (starter-gitignore-file-path spec)
	       (list (starter-spec-ref spec 'library-path)
	             (starter-spec-ref spec 'main-path)
	             (starter-spec-ref spec 'test-path)
	             (starter-spec-ref spec 'bench-path)
	             (starter-spec-ref spec 'example-path)))))

	(define (starter-plan command spec)
	  `(,(string->symbol (string-append command "-plan"))
	    (directory ,(starter-spec-ref spec 'directory))
	    (kind ,(starter-spec-ref spec 'kind))
	    (name ,@(map string->symbol (starter-spec-ref spec 'name)))
	    (files ,@(starter-file-paths spec))))

	(define (ensure-starter-files-absent spec command)
	  (for-each
	   (lambda (path)
	     (when (file-exists? path)
	       (usage-error
	        (string-append command " refuses to overwrite existing starter file")
	        path)))
	   (starter-file-paths spec)))

	(define (write-starter-package spec)
	  (let ((name-parts (starter-spec-ref spec 'name)))
	    (run-command (string-append "mkdir -p " (shell-quote (starter-spec-ref spec 'library-directory))))
	    (run-command (string-append "mkdir -p " (shell-quote (starter-spec-ref spec 'test-directory))))
	    (run-command (string-append "mkdir -p " (shell-quote (starter-spec-ref spec 'bench-directory))))
	    (run-command (string-append "mkdir -p " (shell-quote (starter-spec-ref spec 'example-directory))))
	    (write-new-manifest
	     (starter-spec-ref spec 'manifest-path)
	     name-parts
	     (eq? (starter-spec-ref spec 'kind) 'lib))
	    (when (starter-spec-ref spec 'gitignore-path)
	      (write-new-gitignore (starter-spec-ref spec 'gitignore-path)))
	    (write-new-library (starter-spec-ref spec 'library-path) name-parts)
	    (unless (eq? (starter-spec-ref spec 'kind) 'lib)
	      (write-new-main (starter-spec-ref spec 'main-path) name-parts))
	    (write-new-test (starter-spec-ref spec 'test-path) name-parts)
	    (write-new-bench (starter-spec-ref spec 'bench-path) name-parts)
	    (write-new-example (starter-spec-ref spec 'example-path) name-parts)))


  ))
