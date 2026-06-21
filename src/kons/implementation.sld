(define-library (kons implementation)
  (export implementation-command
          implementation-mode
          implementation-mode-for-dialects
          implementation-mode-field
          implementation-mode-id
          implementation-mode-implementation
          implementation-mode-command
          implementation-mode-dialects
          implementation-mode-features
          implementation-mode-compile-kinds
          implementation-command-record
          implementation-repl-command-record
          implementation-compiler-command
          implementation-compiler-available?
          implementation-compile-output-path
          implementation-compile-command
          implementation-probe)
  (import (scheme base)
          (kons implementation capy)
          (kons implementation gauche)
          (kons implementation chibi)
          (kons implementation guile)
          (kons implementation chez)
          (kons implementation mit)
          (kons implementation sagittarius)
          (kons implementation mosh)
          (kons implementation stklos)
          (kons implementation kawa)
          (kons implementation loko)
          (kons implementation ironscheme)
          (kons implementation skint)
          (kons implementation cyclone)
          (kons util))

  (begin
(define implementation-modes
  (append capy-implementation-modes
          gauche-implementation-modes
          chibi-implementation-modes
          guile-implementation-modes
          chez-implementation-modes
          mit-implementation-modes
          sagittarius-implementation-modes
          mosh-implementation-modes
          stklos-implementation-modes
          kawa-implementation-modes
          loko-implementation-modes
          ironscheme-implementation-modes
          skint-implementation-modes
          cyclone-implementation-modes))

(define (mode-ref mode key default)
  (let ((field (assq key mode)))
    (if field (cdr field) default)))

(define (implementation-mode-field mode key default)
  (mode-ref mode key default))

(define (implementation-mode id)
  (let loop ((items implementation-modes))
    (cond
     ((null? items) #f)
     ((eq? (mode-ref (car items) 'id #f) id) (car items))
     (else (loop (cdr items))))))

(define (implementation-mode-id mode)
  (mode-ref mode 'id #f))

(define (implementation-mode-implementation mode)
  (mode-ref mode 'implementation (implementation-mode-id mode)))

(define (implementation-mode-command mode)
  (mode-ref mode 'command #f))

(define (implementation-mode-dialects mode)
  (mode-ref mode 'dialects '()))

(define (implementation-mode-features mode)
  (mode-ref mode 'features (list (implementation-mode-id mode))))

(define (implementation-mode-compile-kinds mode)
  (mode-ref mode 'compile-kinds '()))

(define (implementation-mode-compiler-command mode)
  (mode-ref mode 'compiler-command #f))

(define (implementation-mode-matches? mode implementation dialects)
  (and (eq? (implementation-mode-implementation mode) implementation)
       (let loop ((supported (implementation-mode-dialects mode)))
         (and (pair? supported)
              (or (memq (car supported) dialects)
                  (loop (cdr supported)))))))

(define (implementation-mode-for-dialects implementation dialects)
  (let loop ((items implementation-modes))
    (cond
     ((null? items) #f)
     ((implementation-mode-matches? (car items) implementation dialects) (car items))
     (else (loop (cdr items))))))

(define (implementation-command scheme)
  (let ((mode (implementation-mode scheme)))
    (if mode
        (implementation-mode-command mode)
        (usage-error "unsupported scheme" scheme))))

(define (append-map1 proc xs)
  (let loop ((rest xs) (out '()))
    (if (null? rest)
        (reverse out)
        (loop (cdr rest) (append (reverse (proc (car rest))) out)))))

(define (join-strings items sep)
  (let loop ((rest items) (out ""))
    (cond
     ((null? rest) out)
     ((string=? out "") (loop (cdr rest) (car rest)))
     (else (loop (cdr rest) (string-append out sep (car rest)))))))

(define (path-list-env paths)
  (join-strings paths ":"))

(define (append-suffix suffix value)
  (string-append value suffix))

(define (prepend-source-roots src)
  (if (null? src) '() (list (car src))))

(define (append-source-roots src)
  (if (null? src) '() (cdr src)))

(define (path-option-argv flag paths)
  (append-map1 (lambda (p) (list flag p)) paths))

(define (fresh-auto-mode? mode)
  (eq? mode 'fresh-auto))

(define (compiled-mode? mode)
  (eq? mode 'compiled))

(define (fresh-auto-argv mode runtime-mode)
  (let ((arg (implementation-mode-field mode 'fresh-auto-arg #f)))
    (if (and arg (fresh-auto-mode? runtime-mode)) (list arg) '())))

(define (compiled-load-path-argv mode runtime-mode compiled-roots)
  (let ((flag (implementation-mode-field mode 'compiled-load-path-flag #f)))
    (if (and flag (compiled-mode? runtime-mode))
        (path-option-argv flag compiled-roots)
        '())))

(define (debug-argv mode profile)
  (let ((arg (implementation-mode-field mode 'debug-arg #f)))
    (if (and arg (not (eq? profile 'release))) (list arg) '())))

(define (runtime-load-path-argv mode src prepend append-paths)
  (let ((style (implementation-mode-field mode 'load-path-style 'none)))
    (case style
      ((capy)
       (append
        (if (null? prepend) '() (list "-L" (join-strings prepend ",")))
        (if (null? append-paths) '() (list "-A" (join-strings append-paths ",")))))
      ((prepend-append)
       (append
        (path-option-argv
         (implementation-mode-field mode 'load-path-flag "-I")
         prepend)
        (path-option-argv
         (implementation-mode-field mode 'append-load-path-flag "-A")
         append-paths)))
      ((repeat-all)
       (path-option-argv
        (implementation-mode-field mode 'load-path-flag "-L")
        src))
      ((chez-libdirs)
       (if (null? src) '() (list "--libdirs" (path-list-env src))))
      ((kawa-import-path)
       (if (null? src)
           '()
           (list (string-append "-Dkawa.import.path="
                                (path-list-env
                                 (map (lambda (path)
                                        (append-suffix "/*.sld" path))
                                      src))))))
      (else '()))))

(define (env-load-paths scope src prepend append-paths)
  (case scope
    ((all) src)
    ((append) append-paths)
    (else prepend)))

(define (runtime-env mode src prepend append-paths runtime-mode)
  (let* ((env-name (implementation-mode-field mode 'env-load-path #f))
         (env-scope (implementation-mode-field mode 'env-load-path-scope 'prepend))
         (env-paths (env-load-paths env-scope src prepend append-paths))
         (non-fresh-env (implementation-mode-field mode 'non-fresh-env #f)))
    (append
     (if (and env-name (not (null? env-paths)))
         (list (list env-name (path-list-env env-paths)))
         '())
     (if (and non-fresh-env (not (fresh-auto-mode? runtime-mode)))
         (list non-fresh-env)
         '()))))

(define (script-argv mode script rest)
  (let ((flag (implementation-mode-field mode 'script-flag #f))
        (separator (implementation-mode-field mode 'script-separator #f)))
    (append (if flag (list flag script) (list script))
            (if separator (list separator) '())
            rest)))

(define (cyclone-compile-run-script load-argv)
  (let ((compile-command
         (join-strings
          (append
           (list "cyclone")
           (map shell-quote load-argv)
           (list "-o" "main" "main.scm"))
          " ")))
    (string-append
     "script=$1; shift; "
     "tmp=${TMPDIR:-/tmp}/kons_cyclone_$$; "
     "mkdir -p \"$tmp\"; "
     "trap 'rm -rf \"$tmp\"' 0 1 2 15; "
     "cp \"$script\" \"$tmp/main.scm\"; "
     "(cd \"$tmp\" && "
     compile-command
     ") && \"$tmp/main\" \"$@\"")))

(define (cyclone-compile-run-argv mode src script rest)
  (let* ((prepend (prepend-source-roots src))
         (append-paths (append-source-roots src))
         (load-argv (runtime-load-path-argv mode src prepend append-paths)))
    (append
     (list "sh" "-c" (cyclone-compile-run-script load-argv) "kons-cyclone" script)
     rest)))

(define (scheme-string-char ch out)
  (cond
   ((char=? ch #\\) (cons #\\ (cons #\\ out)))
   ((char=? ch #\") (cons #\" (cons #\\ out)))
   (else (cons ch out))))

(define (scheme-string value)
  (let loop ((i 0) (out (list #\")))
    (if (< i (string-length value))
        (loop (+ i 1) (scheme-string-char (string-ref value i) out))
        (list->string (reverse (cons #\" out))))))

(define (mit-register-command source)
  (string-append
   "if [ -d " (shell-quote source) " ]; then "
   "printf '%s\n' "
   (shell-quote
    (string-append
     "(parameterize ((param:hide-notifications? #t)) "
     "(find-scheme-libraries! (pathname-as-directory "
     (scheme-string source)
     ")))"))
   " >> \"$prelude\"; "
   "fi; "))

(define (mit-library-run-script mode src)
  (string-append
   "script=$1; shift; "
   "tmp=${TMPDIR:-/tmp}/kons_mit_$$; "
   "prelude=\"$tmp/prelude.scm\"; "
   "mkdir -p \"$tmp\"; "
   ": > \"$prelude\"; "
   "trap 'rm -rf \"$tmp\"' 0 1 2 15; "
   (join-strings (map mit-register-command src) "")
   "exec "
   (shell-quote (implementation-mode-command mode))
   " --batch-mode --quiet --load \"$prelude\" --load \"$script\" -- \"$@\""))

(define (mit-library-run-argv mode src script rest)
  (append
   (list "sh" "-c" (mit-library-run-script mode src) "kons-mit" script)
   rest))

(define (runtime-command-argv mode src script rest runtime-mode compiled-roots profile)
  (let ((prepend (prepend-source-roots src))
        (append-paths (append-source-roots src)))
    (case (implementation-mode-field mode 'runtime-command-style 'direct)
      ((cyclone-compile-run)
       (cyclone-compile-run-argv mode src script rest))
      ((mit-library-run)
       (mit-library-run-argv mode src script rest))
      (else
       (append
        (list (implementation-mode-command mode))
        (debug-argv mode profile)
        (implementation-mode-field mode 'standard-argv '())
        (fresh-auto-argv mode runtime-mode)
        (runtime-load-path-argv mode src prepend append-paths)
        (compiled-load-path-argv mode runtime-mode compiled-roots)
        (script-argv mode script rest))))))

(define (runtime-repl-argv mode src runtime-mode compiled-roots profile)
  (let ((prepend (prepend-source-roots src))
        (append-paths (append-source-roots src)))
    (append
     (list (implementation-mode-command mode))
     (debug-argv mode profile)
     (implementation-mode-field mode 'standard-argv '())
     (fresh-auto-argv mode runtime-mode)
     (runtime-load-path-argv mode src prepend append-paths)
     (compiled-load-path-argv mode runtime-mode compiled-roots))))

(define (require-implementation-mode id)
  (let ((mode (implementation-mode id)))
    (if mode mode (usage-error "unsupported scheme" id))))

(define (implementation-command-record id src script rest runtime-mode compiled-roots profile)
  (let* ((mode (require-implementation-mode id))
         (prepend (prepend-source-roots src))
         (append-paths (append-source-roots src)))
    `(command
      (env ,@(runtime-env mode src prepend append-paths runtime-mode))
      (argv ,@(runtime-command-argv mode src script rest runtime-mode compiled-roots profile)))))

(define (implementation-repl-command-record id src runtime-mode compiled-roots profile)
  (let* ((mode (require-implementation-mode id))
         (prepend (prepend-source-roots src))
         (append-paths (append-source-roots src)))
    `(command
      (env ,@(runtime-env mode src prepend append-paths runtime-mode))
      (argv ,@(runtime-repl-argv mode src runtime-mode compiled-roots profile)))))

(define (implementation-compiler-command id)
  (let ((mode (implementation-mode id)))
    (and mode (implementation-mode-compiler-command mode))))

(define (implementation-compiler-available? id)
  (let ((command (implementation-compiler-command id)))
    (and command
         (= (shell-command-status
             (string-append "command -v " (shell-quote command) " >/dev/null 2>&1"))
            0))))

(define (library-name-part->path value)
  (cond
   ((symbol? value) (symbol->string value))
   ((number? value) (number->string value))
   (else (manifest-error "library name part must be a symbol or number" value))))

(define (library-output-path compiled-root name suffix)
  (path-join compiled-root
             (string-append
              (join-strings (map library-name-part->path name) "/")
              suffix)))

(define (kind-alist-ref alist key default)
  (let ((field (assq key alist)))
    (if field (cdr field) default)))

(define (implementation-compile-output-path id compiled-root kind name)
  (let* ((mode (require-implementation-mode id))
         (suffixes (implementation-mode-field mode 'compiler-output-suffixes '()))
         (suffix (kind-alist-ref suffixes kind ".out")))
    (library-output-path compiled-root name suffix)))

(define (compiler-kind-argv mode kind)
  (let ((entry (assq kind (implementation-mode-field mode 'compiler-kind-argvs '()))))
    (if entry (cdr entry) '())))

(define (compiler-load-path-argv mode srcs)
  (let ((style (implementation-mode-field mode 'compiler-load-path-style 'none))
        (flag (implementation-mode-field mode 'compiler-load-path-flag "-L")))
    (case style
      ((comma) (if (null? srcs) '() (list flag (join-strings srcs ","))))
      ((repeat) (path-option-argv flag srcs))
      (else '()))))

(define (implementation-compile-command id kind srcs output source)
  (let* ((mode (require-implementation-mode id))
         (command (implementation-mode-compiler-command mode))
         (subcommand (implementation-mode-field mode 'compiler-subcommand #f))
         (output-flag (implementation-mode-field mode 'compiler-output-flag "-o"))
         (module-argv (implementation-mode-field mode 'compiler-module-argv '())))
    (unless command
      (usage-error "selected implementation does not provide a compiler" id))
    `(command
      (env)
      (argv ,@(append
               (list command)
               (if subcommand (list subcommand) '())
               (compiler-kind-argv mode kind)
               (compiler-load-path-argv mode srcs)
               module-argv
               (list output-flag output source))))))

(define (implementation-version-command scheme command)
  (let* ((mode (implementation-mode scheme))
         (version-argv (and mode (implementation-mode-field mode 'version-argv '()))))
    (if (and version-argv (not (null? version-argv)))
        (string-append command
                       " "
                       (join-strings (map shell-quote version-argv) " ")
                       " 2>&1 | head -1")
        #f)))

(define (implementation-version-output mode command)
  (let ((version-argv (implementation-mode-field mode 'version-argv '())))
    (and (not (null? version-argv))
         (capture-first-line
          (string-append
           "( timeout 2s "
           (shell-quote command)
           " "
           (join-strings (map shell-quote version-argv) " ")
           " || true ) 2>&1")))))

(define (ensure-implementation-version! scheme mode command version)
  (let ((required (implementation-mode-field mode 'version-contains #f)))
    (when (and required
               (not (and version (string-contains? version required))))
      (dependency-error "selected Scheme implementation command did not match expected implementation"
                        scheme
                        command
                        required
                        (if version version "unknown")))))

(define (implementation-probe scheme)
  (let* ((command (implementation-command scheme))
         (mode (implementation-mode scheme)))
    (unless (= (shell-command-status
                (string-append "command -v " (shell-quote command) " >/dev/null 2>&1"))
               0)
      (dependency-error "selected Scheme implementation is not available on PATH" scheme command))
    (let ((version (and mode (implementation-version-output mode command))))
      (ensure-implementation-version! scheme mode command version)
      `(implementation
        (name ,scheme)
        (command ,command)
        (version ,(if version version "unknown"))))))
  ))
