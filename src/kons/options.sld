(define-library (kons options)
  (export kons-global-grammar
          kons-command-grammar
          kons-base-grammar
          make-command-grammar
          copy-grammar-option!
          copy-grammar-entry!
          copy-grammar!
          install-global-grammar!
          deepest-command-results
          command-leaf-results
          command-flag?
          command-option
          command-rest
          command-manifest-path
          command-selected-scheme
          command-selected-hook-scheme
          profile-value->symbol
          command-selected-profile
          command-selected-compile-mode
          command-job-count
          command-locked-mode?
          string->log-level
          configure-logging!
          strip-workspace-argv)
  (import (scheme base)
          (scheme file)
          (scheme process-context)
          (args grammar)
          (args option)
          (args parser)
          (args results)
          (args runner)
          (kons util)
          (kons ui))

  (begin
(define-grammar kons-global-grammar
  (separator "Manifest selection:")
  (option "manifest"
    'help: "Path to kons.scm manifest file."
    'value-help: "FILE")
  (option "path"  
    'help: "Package directory; kons.scm is read from PATH/kons.scm."
    'value-help: "DIR")
  (option "workspace-root"
    'help: "Workspace root manifest path (set internally for workspace members)."
    'value-help: "FILE"
    'hide?: #t)
  (separator "Implementation:")
  (option "scheme"
    'help: "Scheme implementation to use."
    'value-help: "NAME"
    'allowed: '("capy" "gauche" "gosh" "chibi" "chibi-scheme" "guile" "chez" "chezscheme" "sagittarius" "sash" "mosh" "stklos" "kawa" "loko" "ironscheme" "skint" "cyclone" "mit"))
  (option "features"
    'help: "Comma-separated feature names to enable."
    'value-help: "NAMES")
  (option "target"
    'help: "Target triple or platform identifier."
    'value-help: "TRIPLE")
  (option "profile"
    'help: "Build profile."
    'value-help: "NAME"
    'allowed: '("debug" "release"))
  (option "compile-mode"
    'help: "Compilation mode for Capy and Guile."
    'value-help: "MODE"
    'allowed: '("compiled" "fresh-auto"))
  (option "hook-scheme"
    'help: "Scheme implementation for build hooks (overridden by per-hook scheme-impl)."
    'value-help: "NAME"
    'allowed: '("capy" "gauche" "gosh" "chibi" "chibi-scheme" "guile" "chez" "chezscheme" "sagittarius" "sash" "mosh" "stklos" "kawa" "loko" "ironscheme" "skint" "cyclone" "mit"))
  (option "log-level"
    'help: "Log level."
    'value-help: "LEVEL"
    'allowed: '("quiet" "error" "warn" "warning" "info" "debug" "trace" "verbose"))
  (option "jobs"
    'abbr: "j"
    'help: "Maximum parallel jobs to run."
    'value-help: "N")
  (flag "no-default-features"
    'help: "Disable default features.")
  (flag "offline"
    'help: "Do not fetch missing dependencies.")
  (flag "locked"
    'help: "Require an existing lockfile.")
  (flag "frozen"
    'help: "Alias for --locked and --offline.")
  (flag "release"
    'help: "Use release profile.")
  (flag "debug"
    'help: "Use debug profile.")
  (flag "verbose"
    'abbr: "v"
    'help: "Enable verbose logging.")
  (flag "quiet"
    'help: "Suppress non-error output.")
  (flag "no-color"
    'help: "Disable decorative colors and progress output."
    'negatable?: #f))

(define-grammar kons-command-grammar
  (separator "Manifest selection:")
  (option "manifest"
    'help: "Path to kons.scm manifest file."
    'value-help: "FILE")
  (option "path"
    'help: "Package directory; kons.scm is read from PATH/kons.scm."
    'value-help: "DIR")
  (option "workspace-root"
    'help: "Workspace root manifest path."
    'value-help: "FILE"
    'hide?: #t)
  (option "package"
    'help: "Workspace member package name or path."
    'value-help: "NAME")
  (separator "Implementation:")
  (option "scheme"
    'help: "Scheme implementation to use."
    'value-help: "NAME"
    'allowed: '("capy" "gauche" "gosh" "chibi" "chibi-scheme" "guile" "chez" "chezscheme" "sagittarius" "sash" "mosh" "stklos" "kawa" "loko" "ironscheme" "skint" "cyclone" "mit"))
  (option "features"
    'help: "Comma-separated feature names to enable."
    'value-help: "NAMES")
  (option "target"
    'help: "Target triple or platform identifier."
    'value-help: "TRIPLE")
  (option "profile"
    'help: "Build profile."
    'value-help: "NAME"
    'allowed: '("debug" "release"))
  (option "compile-mode"
    'help: "Compilation mode for Capy and Guile."
    'value-help: "MODE"
    'allowed: '("compiled" "fresh-auto"))
  (option "hook-scheme"
    'help: "Scheme implementation for build hooks (overridden by per-hook scheme-impl)."
    'value-help: "NAME"
    'allowed: '("capy" "gauche" "gosh" "chibi" "chibi-scheme" "guile" "chez" "chezscheme" "sagittarius" "sash" "mosh" "stklos" "kawa" "loko" "ironscheme" "skint" "cyclone" "mit"))
  (option "log-level"
    'help: "Log level."
    'value-help: "LEVEL"
    'allowed: '("quiet" "error" "warn" "warning" "info" "debug" "trace" "verbose"))
  (option "jobs"
    'abbr: "j"
    'help: "Maximum parallel jobs to run."
    'value-help: "N")
  (option "directory"
    'help: "Directory path for scoped operations."
    'value-help: "DIR")
  (option "root"
    'help: "Installation root directory."
    'value-help: "DIR")
  (option "name"
    'help: "Package, dependency, or install name."
    'value-help: "NAME")
  (option "script"
    'help: "Manifest script target name."
    'value-help: "NAME")
  (option "bin"
    'help: "Binary target name."
    'value-help: "NAME")
  (separator "Dependencies:")
  (option "git"
    'help: "Git repository URL for git dependencies."
    'value-help: "URL")
  (option "rev"
    'help: "Git revision for git dependencies."
    'value-help: "REV")
  (option "subpath"
    'help: "Subpath within a git dependency."
    'value-help: "PATH")
  (flag "no-default-features"
    'help: "Disable default features.")
  (flag "offline"
    'help: "Do not fetch missing dependencies.")
  (flag "locked"
    'help: "Require an existing lockfile.")
  (flag "frozen"
    'help: "Alias for --locked and --offline.")
  (flag "release"
    'help: "Use release profile.")
  (flag "debug"
    'help: "Use debug profile.")
  (flag "verbose"
    'abbr: "v"
    'help: "Enable verbose logging.")
  (flag "quiet"
    'help: "Suppress non-error output.")
  (flag "no-color"
    'help: "Disable decorative colors and progress output."
    'negatable?: #f)
  (flag "workspace"
    'help: "Operate on workspace members.")
  (flag "plan"
    'help: "Print the planned action without executing.")
  (flag "list"
    'help: "List available targets instead of running.")
  (flag "all"
    'help: "Apply to all workspace members.")
  (flag "gc"
    'help: "Garbage-collect store artifacts.")
  (flag "store"
    'help: "Clean store artifacts.")
  (flag "dev"
    'help: "Use dev-dependencies scope.")
  (flag "system"
    'help: "Add or remove a system dependency.")
  (flag "lib"
    'help: "Create a library package starter.")
  (flag "raw"
    'help: "Add a raw dependency expression."))

(define-grammar kons-base-grammar
  (separator "Manifest selection:")
  (option "manifest"
    'help: "Path to kons.scm manifest file."
    'value-help: "FILE")
  (option "path"
    'help: "Package directory; kons.scm is read from PATH/kons.scm."
    'value-help: "DIR")
  (option "workspace-root"
    'help: "Workspace root manifest path."
    'value-help: "FILE"
    'hide?: #t)
  (option "package"
    'help: "Workspace member package name or path."
    'value-help: "NAME")
  (separator "Implementation:")
  (option "scheme"
    'help: "Scheme implementation to use."
    'value-help: "NAME"
    'allowed: '("capy" "gauche" "gosh" "chibi" "chibi-scheme" "guile" "chez" "chezscheme" "sagittarius" "sash" "mosh" "stklos" "kawa" "loko" "ironscheme" "skint" "cyclone" "mit"))
  (option "features"
    'help: "Comma-separated feature names to enable."
    'value-help: "NAMES")
  (option "target"
    'help: "Target triple or platform identifier."
    'value-help: "TRIPLE")
  (option "profile"
    'help: "Build profile."
    'value-help: "NAME"
    'allowed: '("debug" "release"))
  (option "compile-mode"
    'help: "Compilation mode for Capy and Guile."
    'value-help: "MODE"
    'allowed: '("compiled" "fresh-auto"))
  (option "hook-scheme"
    'help: "Scheme implementation for build hooks (overridden by per-hook scheme-impl)."
    'value-help: "NAME"
    'allowed: '("capy" "gauche" "gosh" "chibi" "chibi-scheme" "guile" "chez" "chezscheme" "sagittarius" "sash" "mosh" "stklos" "kawa" "loko" "ironscheme" "skint" "cyclone" "mit"))
  (option "log-level"
    'help: "Log level."
    'value-help: "LEVEL"
    'allowed: '("quiet" "error" "warn" "warning" "info" "debug" "trace" "verbose"))
  (option "jobs"
    'abbr: "j"
    'help: "Maximum parallel jobs to run."
    'value-help: "N")
  (flag "no-default-features"
    'help: "Disable default features.")
  (flag "offline"
    'help: "Do not fetch missing dependencies.")
  (flag "locked"
    'help: "Require an existing lockfile.")
  (flag "frozen"
    'help: "Alias for --locked and --offline.")
  (flag "release"
    'help: "Use release profile.")
  (flag "debug"
    'help: "Use debug profile.")
  (flag "verbose"
    'abbr: "v"
    'help: "Enable verbose logging.")
  (flag "quiet"
    'help: "Suppress non-error output.")
  (flag "no-color"
    'help: "Disable decorative colors and progress output."
    'negatable?: #f))

(define (copy-grammar-option! target option)
  (case (option-type option)
    ((flag)
     (apply grammar-add-flag! target (option-name option)
            (append
             (if (option-abbr option) (list 'abbr: (option-abbr option)) '())
             (if (option-help option) (list 'help: (option-help option)) '())
             (if (option-hide? option) (list 'hide?: (option-hide? option)) '())
             (if (option-hide-negated-usage? option) (list 'hide-negated-usage?: (option-hide-negated-usage? option)) '())
             (if (option-callback option) (list 'callback: (option-callback option)) '())
             (if (option-aliases option) (list 'aliases: (option-aliases option)) '())
             (list 'negatable?: (option-negatable? option)))))
    ((single)
     (apply grammar-add-option! target (option-name option)
            (append
             (if (option-abbr option) (list 'abbr: (option-abbr option)) '())
             (if (option-help option) (list 'help: (option-help option)) '())
             (if (option-value-help option) (list 'value-help: (option-value-help option)) '())
             (if (option-allowed option) (list 'allowed: (option-allowed option)) '())
             (if (option-allowed-help option) (list 'allowed-help: (option-allowed-help option)) '())
             (if (option-defaults-to option) (list 'defaults-to: (option-defaults-to option)) '())
             (if (option-mandatory? option) (list 'mandatory?: (option-mandatory? option)) '())
             (if (option-hide? option) (list 'hide?: (option-hide? option)) '())
             (if (option-aliases option) (list 'aliases: (option-aliases option)) '()))))
    ((multi)
     (apply grammar-add-multi-option! target (option-name option)
            (append
             (if (option-abbr option) (list 'abbr: (option-abbr option)) '())
             (if (option-help option) (list 'help: (option-help option)) '())
             (if (option-value-help option) (list 'value-help: (option-value-help option)) '())
             (if (option-allowed option) (list 'allowed: (option-allowed option)) '())
             (if (option-split-commas? option) (list 'split-commas?: (option-split-commas? option)) '())
             (if (option-hide? option) (list 'hide?: (option-hide? option)) '())
             (if (option-aliases option) (list 'aliases: (option-aliases option)) '()))))
    (else (error "unknown option type" (option-type option)))))

(define (copy-grammar-entry! target entry)
  (cond
   ((string? entry) (grammar-add-separator! target entry))
   ((option? entry) (copy-grammar-option! target entry))
   (else (error "unknown grammar entry" entry))))

(define (copy-grammar! target source)
  (for-each
   (lambda (entry) (copy-grammar-entry! target entry))
   (reverse (grammar-options-and-separators source)))
  (grammar-allow-trailing?-set! target (grammar-allow-trailing? source))
  (grammar-allow-anything?-set! target (grammar-allow-anything? source))
  target)

(define (make-command-grammar . entries)
  (let ((grammar (copy-grammar! (make-grammar) kons-base-grammar)))
    (for-each
     (lambda (entry)
       (if (string? entry)
           (grammar-add-separator! grammar entry)
           (let ((type (car entry))
                 (name (cadr entry))
                 (args (cddr entry)))
             (case type
               ((flag) (apply grammar-add-flag! grammar name args))
               ((option) (apply grammar-add-option! grammar name args))
               (else (error "unknown grammar entry type" type))))))
     entries)
    grammar))

(define (install-global-grammar! grammar . maybe-version-callback)
  (let ((version-callback (if (null? maybe-version-callback) #f (car maybe-version-callback))))
    (copy-grammar! grammar kons-global-grammar)
    (grammar-add-flag! grammar "version"
                       'abbr: "V"
                       'help: "Print kons version and exit."
                       'hide-negated-usage?: #t
                       'callback: version-callback)
    grammar))

(define (deepest-command-results results)
  (let ((command (argument-results-command results)))
    (if command
        (deepest-command-results command)
        results)))

(define (command-leaf-results cmd)
  (let ((results (command-results cmd)))
    (and results (deepest-command-results results))))

(define (results-flag? results name)
  (and results
       (argument-results-has-option? results name)
       ((argument-results-flags results) name)))

(define (results-option results name default)
  (if (and results (argument-results-has-option? results name))
      (let ((value ((argument-results-options results) name)))
        (if value value default))
      default))

(define (command-flag? cmd name)
  (let ((global (command-global-results cmd))
        (leaf (command-leaf-results cmd)))
    (or (results-flag? leaf name)
        (results-flag? global name))))

(define (command-option cmd name default)
  (let ((global (command-global-results cmd))
        (leaf (command-leaf-results cmd)))
    (let ((value (results-option leaf name #f)))
      (if value
          value
          (results-option global name default)))))

(define (drop-argument-separator rest)
  (if (and (pair? rest) (string=? (car rest) "--"))
      (cdr rest)
      rest))

(define (command-rest cmd)
  (let ((leaf (command-leaf-results cmd)))
    (if leaf
        (drop-argument-separator (argument-results-rest leaf))
        '())))

(define (find-nearest-manifest-path)
  (let loop ((dir (absolute-path "")))
    (let ((candidate (path-join dir "kons.scm"))
          (parent (dirname dir)))
      (cond
       ((file-exists? candidate) candidate)
       ((string=? parent dir) #f)
       (else (loop parent))))))

(define (default-manifest-path)
  (if (file-exists? "kons.scm")
      "kons.scm"
      (or (find-nearest-manifest-path) "kons.scm")))

(define (command-manifest-path cmd)
  (let ((manifest (command-option cmd "manifest" #f))
        (path (command-option cmd "path" #f)))
    (cond
     (manifest manifest)
     (path (path-join path "kons.scm"))
     (else (default-manifest-path)))))

(define (string->scheme-symbol value)
  (cond
   ((string=? value "capy") 'capy)
   ((or (string=? value "gauche") (string=? value "gosh")) 'gauche)
   ((or (string=? value "chibi") (string=? value "chibi-scheme")) 'chibi)
   ((string=? value "guile") 'guile)
   ((or (string=? value "chez") (string=? value "chezscheme")) 'chez)
   ((or (string=? value "sagittarius") (string=? value "sash")) 'sagittarius)
   ((string=? value "mosh") 'mosh)
   ((string=? value "stklos") 'stklos)
   ((string=? value "kawa") 'kawa)
   ((string=? value "loko") 'loko)
   ((string=? value "ironscheme") 'ironscheme)
   ((string=? value "skint") 'skint)
   ((string=? value "cyclone") 'cyclone)
   ((string=? value "mit") 'mit)
   (else (usage-error "unknown scheme" value))))

(define (command-selected-scheme cmd)
  (let ((value (command-option cmd "scheme"
                               (or (get-environment-variable "KONS_SCHEME")
                                   (get-environment-variable "SCHEME")
                                   "capy"))))
    (string->scheme-symbol value)))

(define (command-selected-hook-scheme cmd)
  (let ((value (command-option cmd "hook-scheme" #f)))
    (and value (string->scheme-symbol value))))

(define (profile-value->symbol value)
  (cond
   ((or (not value) (string=? value "debug")) 'debug)
   ((string=? value "release") 'release)
   (else (usage-error "unknown profile" value))))

(define (command-selected-profile cmd)
  (when (and (command-flag? cmd "release")
             (command-flag? cmd "debug"))
    (usage-error "choose either --release or --debug"))
  (let ((profile (profile-value->symbol (command-option cmd "profile" #f))))
    (cond
     ((command-flag? cmd "release") 'release)
     ((command-flag? cmd "debug") 'debug)
     (else profile))))

(define (compile-mode-value->symbol value)
  (cond
   ((not value) 'fresh-auto)
   ((string=? value "compiled") 'compiled)
   ((string=? value "fresh-auto") 'fresh-auto)
   (else (usage-error "unknown compile mode" value))))

(define (command-selected-compile-mode cmd)
  (compile-mode-value->symbol
   (command-option cmd "compile-mode"
                   (get-environment-variable "KONS_COMPILE_MODE"))))

(define (command-job-count cmd)
  (let* ((raw (command-option cmd "jobs"
                              (get-environment-variable "KONS_JOBS")))
         (n (and raw (string->number raw))))
    (cond
     ((not raw) 1)
     ((and n (integer? n) (> n 0)) n)
     (else (usage-error "--jobs expects a positive integer" raw)))))

(define (command-locked-mode? cmd)
  (or (command-flag? cmd "locked")
      (command-flag? cmd "frozen")))

(define (string->log-level value)
  (cond
   ((string=? value "quiet") 'quiet)
   ((string=? value "error") 'error)
   ((or (string=? value "warn") (string=? value "warning")) 'warning)
   ((string=? value "info") 'info)
   ((string=? value "debug") 'debug)
   ((or (string=? value "trace") (string=? value "verbose")) 'trace)
   (else (usage-error "unknown log level" value))))

(define (configure-logging! top-results)
  (let* ((leaf-results (deepest-command-results top-results))
         (top-flags (argument-results-flags top-results))
         (leaf-flags (argument-results-flags leaf-results))
         (top-options (argument-results-options top-results))
         (leaf-options (argument-results-options leaf-results))
         (no-color?
          (or (get-environment-variable "NO_COLOR")
              (get-environment-variable "KONS_NO_COLOR")
              (and (argument-results-has-option? leaf-results "no-color")
                   (leaf-flags "no-color"))
              (and (argument-results-has-option? top-results "no-color")
                   (top-flags "no-color"))))
         (level (cond
                 ((argument-results-has-option? leaf-results "log-level")
                  (leaf-options "log-level"))
                 ((argument-results-has-option? top-results "log-level")
                  (top-options "log-level"))
                 (else (get-environment-variable "KONS_LOG")))))
    (cond
     ((or (and (argument-results-has-option? leaf-results "verbose")
               (leaf-flags "verbose"))
          (and (argument-results-has-option? top-results "verbose")
               (top-flags "verbose")))
      (set-log-level! 'trace))
     ((or (and (argument-results-has-option? leaf-results "quiet")
               (leaf-flags "quiet"))
          (and (argument-results-has-option? top-results "quiet")
               (top-flags "quiet")))
      (set-log-level! 'quiet))
     (level (set-log-level! (string->log-level level)))
     (else (set-log-level! 'info)))
    (set-ui-enabled!
     (and (not no-color?)
          (not (eq? (log-level) 'quiet))))))

(define (workspace-assignment-prefix? arg prefix)
  (let ((full (string-append prefix "=")))
    (and (> (string-length arg) (string-length full))
         (string=? (substring arg 0 (string-length full)) full))))

(define (strip-workspace-argv argv)
  (let loop ((items argv) (out '()))
    (cond
     ((null? items) (reverse out))
     ((and (member (car items) '("--manifest" "--path" "--package"))
           (pair? (cdr items))
           (not (char=? (string-ref (cadr items) 0) #\-)))
      (loop (cddr items) out))
     ((or (string=? (car items) "--workspace")
          (workspace-assignment-prefix? (car items) "--manifest")
          (workspace-assignment-prefix? (car items) "--path")
          (workspace-assignment-prefix? (car items) "--package"))
      (loop (cdr items) out))
     (else (loop (cdr items) (cons (car items) out))))))

  ))
