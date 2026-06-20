(define-library (kons util)
  (export kons-version
          writeln
          displayln
          die
          diagnostic-error
          usage-error
          manifest-error
          lockfile-error
          dependency-error
          internal-error
          warn
          diagnostic-warn
          set-log-level!
          log-level
          log-trace
          log-debug
          log-info
          log-warning
          ui-log-enabled?
          kons-home
          kons-auth-path
          kons-store-root
          shell-quote
          string-suffix?
          dirname
          path-join
          absolute-path?
          absolute-path
          shell-command-status
          run-command
          capture-first-line
          file-content-hash
          path-content-hash
          safe-store-token
          ascii-alphanumeric?
          semver-version?
          semver-requirement?
          read-all-exprs
          temporary-file-path
          write-expr-file
          symbol-list?
          normalize-name
          form-kind
          find-form
          forms-of-kind
          field-ref
          field-rest
          filter
          append-map
          string-split
          non-empty-string?
          dedupe-symbols
          ensure-known-fields)
	  (import (except (scheme base) read-line)
	          (scheme cxr)
	          (scheme char)
	          (scheme file)
	          (scheme read)
	          (scheme time)
          (scheme write)
          (scheme process-context)
          (kons compat files)
          (kons compat threads)
          (kons compat process)
          (kons ui))

  (begin
	(define kons-version 2)
	(define current-log-level 'info)
	(define temporary-counter 0)
    (define temporary-counter-lock (make-lock))

(define (writeln x)
  (pretty-write x (current-output-port))
  (newline))

(define (displayln x)
  (display x)
  (newline))

(define (set-log-level! level)
  (set! current-log-level level))

(define (log-level)
  current-log-level)

(define (log-level-rank level)
  (case level
    ((quiet) 0)
    ((error) 1)
    ((warning warn) 2)
    ((info) 3)
    ((debug) 4)
    ((trace) 5)
    (else 3)))

(define (log-enabled? level)
  (>= (log-level-rank current-log-level)
      (log-level-rank level)))

(define (ui-log-enabled?)
  (log-enabled? 'info))

(define (log-color level)
  (case level
    ((debug) 'dim)
    ((info) 'cyan)
    ((warning warn) 'yellow)
    ((error) 'red)
    (else 'blue)))

(define (diagnostic-color category)
  (case category
    ((warning) 'yellow)
    (else 'red)))

(define (display-log level message details)
  (when (log-enabled? level)
    (ui-fresh-line)
    (if (eq? level 'info)
        (begin
          (display "        " (current-error-port))
          (display (ui-colorize (log-color level) "Info") (current-error-port))
          (display " " (current-error-port))
          (display message (current-error-port))
          (for-each
           (lambda (detail)
             (display " " (current-error-port))
             (pretty-write detail (current-error-port)))
           details)
          (newline (current-error-port)))
        (begin
          (display "kons: " (current-error-port))
          (display (case level
                     ((trace) "TRACE")
                     ((debug) "DEBUG")
                     ((warning warn) "WARNING")
                     ((error) "ERROR")
                     (else "LOG"))
                   (current-error-port))
          (display ": " (current-error-port))
          (display (ui-colorize (log-color level) message) (current-error-port))
          (for-each
           (lambda (detail)
             (display " " (current-error-port))
             (pretty-write detail (current-error-port)))
           details)
          (newline (current-error-port))))))

(define (log-debug message . details)
  (display-log 'debug message details))

(define (log-trace message . details)
  (display-log 'trace message details))

(define (log-info message . details)
  (display-log 'info message details))

(define (log-warning message . details)
  (display-log 'warning message details))

(define (diagnostic-name category)
  (case category
    ((warning) "WARNING")
    ((usage) "USAGE")
    ((manifest) "MANIFEST")
    ((lockfile) "LOCKFILE")
    ((dependency) "DEPENDENCY")
    ((internal) "INTERNAL")
    (else "ERROR")))

(define (display-diagnostic level category message details)
  (ui-fresh-line)
  (display "kons: " (current-error-port))
  (display (diagnostic-name category) (current-error-port))
  (display " " (current-error-port))
  (display level (current-error-port))
  (display ": " (current-error-port))
  (display (ui-colorize (diagnostic-color category) message) (current-error-port))
  (for-each
   (lambda (detail)
     (display " " (current-error-port))
     (pretty-write detail (current-error-port)))
   details)
  (newline (current-error-port)))

(define (diagnostic-error category message . details)
  (display-diagnostic "error" category message details)
  (exit 1))

(define (die message . details)
  (apply diagnostic-error 'error message details))

(define (usage-error message . details)
  (apply diagnostic-error 'usage message details))

(define (manifest-error message . details)
  (apply diagnostic-error 'manifest message details))

(define (lockfile-error message . details)
  (apply diagnostic-error 'lockfile message details))

(define (dependency-error message . details)
  (apply diagnostic-error 'dependency message details))

(define (internal-error message . details)
  (apply diagnostic-error 'internal message details))

(define (diagnostic-warn category message . details)
  (display-diagnostic "warning" category message details))

(define (warn message . details)
  (apply log-warning message details))

(define (kons-home)
  (or (get-environment-variable "KONS_HOME")
      (let ((home (get-environment-variable "HOME")))
        (if home (path-join home ".kons") ".kons"))))

(define (kons-auth-path)
  (path-join (kons-home) "auth.scm"))

(define (kons-store-root)
  (or (get-environment-variable "KONS_STORE")
      (path-join (kons-home) "store")))

(define (shell-quote s)
  (let loop ((chars (string->list s)) (out "'"))
    (cond
     ((null? chars) (string-append out "'"))
     ((char=? (car chars) #\')
      (loop (cdr chars) (string-append out "'\\''")))
     (else
      (loop (cdr chars) (string-append out (string (car chars))))))))

(define (string-suffix? suffix s)
  (let ((sl (string-length s))
        (tl (string-length suffix)))
    (and (>= sl tl)
         (string=? suffix (substring s (- sl tl) sl)))))

(define (last-slash-index s)
  (let loop ((i (- (string-length s) 1)))
    (cond
     ((< i 0) #f)
     ((char=? (string-ref s i) #\/) i)
     (else (loop (- i 1))))))

(define (dirname path)
  (let ((i (last-slash-index path)))
    (cond
     ((not i) ".")
     ((= i 0) "/")
     (else (substring path 0 i)))))

(define (path-join a b)
  (cond
   ((string=? a ".") b)
   ((string=? a "") b)
   ((string=? b "") a)
   ((char=? (string-ref a (- (string-length a) 1)) #\/)
    (string-append a b))
   (else (string-append a "/" b))))

(define (absolute-path? path)
  (and (> (string-length path) 0)
       (char=? (string-ref path 0) #\/)))

(define (absolute-path path)
  (if (absolute-path? path)
      path
      (path-join (current-directory) path)))

	(define (next-temporary-path prefix)
      (let ((counter
             (call-with-lock
              temporary-counter-lock
              (lambda ()
                (set! temporary-counter (+ temporary-counter 1))
                temporary-counter))))
	    (string-append
	     "/tmp/"
	     prefix
	     "-"
	     (number->string (current-jiffy))
	     "-"
	     (number->string counter)
	     ".tmp")))

	(define (delete-file-if-exists path)
	  (when (file-exists? path)
	    (delete-file path)))

	(define (shell-command-status cmd)
	  (let* ((tmp (next-temporary-path "kons-status"))
	         (wrapper (string-append "( " cmd " ); printf '%s\\n' $? > " (shell-quote tmp))))
	    (system wrapper)
	    (let ((status (string->number (call-with-input-file tmp read-line))))
	      (delete-file-if-exists tmp)
	      (if status status 1))))

(define (run-command cmd)
  (let ((status (shell-command-status cmd)))
    (unless (= status 0)
      (die "command failed" cmd status))
    status))

	(define (capture-first-line cmd)
	  (let* ((tmp (next-temporary-path "kons-capture"))
	         (status (shell-command-status (string-append cmd " > " (shell-quote tmp)))))
	    (unless (= status 0)
	      (die "command failed" cmd status))
	    (let ((line (call-with-input-file tmp read-line)))
	      (delete-file-if-exists tmp)
	      line)))

(define (file-content-hash path)
  (unless (file-exists? path)
    (die "cannot hash missing file" path))
  (capture-first-line
   (string-append "cksum " (shell-quote path) " | awk '{print $1 \"-\" $2}'")))

(define (path-content-hash path)
  (unless (file-exists? path)
    (die "cannot hash missing path" path))
  (capture-first-line
   (string-append
    "find " (shell-quote path)
    " -type f -not -path '*/.git/*' -print | LC_ALL=C sort | xargs cksum | cksum")))

(define (ascii-alphanumeric? ch)
  (let ((n (char->integer ch)))
    (or (and (>= n (char->integer #\a)) (<= n (char->integer #\z)))
        (and (>= n (char->integer #\A)) (<= n (char->integer #\Z)))
        (and (>= n (char->integer #\0)) (<= n (char->integer #\9))))))

(define (ascii-digit? ch)
  (let ((n (char->integer ch)))
    (and (>= n (char->integer #\0)) (<= n (char->integer #\9)))))

(define (ascii-semver-id-char? ch)
  (or (ascii-alphanumeric? ch) (char=? ch #\-)))

(define (string-prefix? prefix s)
  (let ((plen (string-length prefix))
        (slen (string-length s)))
    (and (>= slen plen)
         (string=? prefix (substring s 0 plen)))))

(define (string-index-char s target)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (cond
       ((= i len) #f)
       ((char=? (string-ref s i) target) i)
       (else (loop (+ i 1)))))))

(define (string-every pred s)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (or (= i len)
          (and (pred (string-ref s i))
               (loop (+ i 1)))))))

(define (numeric-identifier? s)
  (and (> (string-length s) 0)
       (string-every ascii-digit? s)
       (or (= (string-length s) 1)
           (not (char=? (string-ref s 0) #\0)))))

(define (semver-dot-identifiers? s allow-leading-zero-numbers?)
  (or (string=? s "")
      (let loop ((items (string-split s #\.)))
        (cond
         ((null? items) #t)
         ((string=? (car items) "") #f)
         ((not (string-every ascii-semver-id-char? (car items))) #f)
         ((and (not allow-leading-zero-numbers?)
               (string-every ascii-digit? (car items))
               (> (string-length (car items)) 1)
               (char=? (string-ref (car items) 0) #\0))
          #f)
         (else (loop (cdr items)))))))

(define (semver-core? s)
  (let ((parts (string-split s #\.)))
    (and (= (length parts) 3)
         (numeric-identifier? (car parts))
         (numeric-identifier? (cadr parts))
         (numeric-identifier? (car (cdr (cdr parts)))))))

(define (semver-version? value)
  (and (string? value)
       (let* ((plus (string-index-char value #\+))
              (without-build (if plus (substring value 0 plus) value))
              (build (if plus (substring value (+ plus 1) (string-length value)) ""))
              (dash (string-index-char without-build #\-))
              (core (if dash (substring without-build 0 dash) without-build))
              (pre (if dash (substring without-build (+ dash 1) (string-length without-build)) "")))
         (and (semver-core? core)
              (semver-dot-identifiers? pre #f)
              (semver-dot-identifiers? build #t)))))

(define (partial-semver->full value)
  (let ((parts (string-split value #\.)))
    (cond
     ((and (= (length parts) 1) (numeric-identifier? (car parts)))
      (string-append value ".0.0"))
     ((and (= (length parts) 2)
           (numeric-identifier? (car parts))
           (numeric-identifier? (cadr parts)))
      (string-append value ".0"))
     (else value))))

(define (semver-wildcard? value)
  (let ((parts (string-split value #\.)))
    (or (and (= (length parts) 2)
             (numeric-identifier? (car parts))
             (or (string=? (cadr parts) "x") (string=? (cadr parts) "X") (string=? (cadr parts) "*")))
        (and (= (length parts) 3)
             (numeric-identifier? (car parts))
             (numeric-identifier? (cadr parts))
             (or (string=? (car (cdr (cdr parts))) "x")
                 (string=? (car (cdr (cdr parts))) "X")
                 (string=? (car (cdr (cdr parts))) "*"))))))

(define (trim-leading-space s)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (if (and (< i len) (char-whitespace? (string-ref s i)))
          (loop (+ i 1))
          (substring s i len)))))

(define (semver-requirement? value)
  (and (string? value)
       (let ((req (trim-leading-space value)))
         (cond
          ((or (string=? req "") (string=? req "*")) #t)
          ((or (char=? (string-ref req 0) #\^) (char=? (string-ref req 0) #\~))
           (semver-version? (partial-semver->full (substring req 1 (string-length req)))))
          ((string-prefix? ">=" req)
           (semver-version? (partial-semver->full (trim-leading-space (substring req 2 (string-length req))))))
          ((string-prefix? "<=" req)
           (semver-version? (partial-semver->full (trim-leading-space (substring req 2 (string-length req))))))
          ((or (char=? (string-ref req 0) #\>)
               (char=? (string-ref req 0) #\<)
               (char=? (string-ref req 0) #\=))
           (semver-version? (partial-semver->full (trim-leading-space (substring req 1 (string-length req))))))
          ((semver-wildcard? req) #t)
          (else (semver-version? (partial-semver->full req)))))))

(define (safe-store-token s)
  (list->string
   (map (lambda (ch)
          (cond
           ((ascii-alphanumeric? ch) ch)
           (else #\-)))
        (string->list s))))

(define (read-all-exprs path)
  (call-with-input-file path
    (lambda (in)
      (let loop ((expr (read in)) (out '()))
        (if (eof-object? expr)
            (reverse out)
            (loop (read in) (cons expr out)))))))

	(define (temporary-file-path path)
	  (let ((tmp (next-temporary-path (safe-store-token path))))
	    (delete-file-if-exists tmp)
	    tmp))

	(define (proper-list? value)
	  (let loop ((xs value))
	    (cond
	     ((null? xs) #t)
	     ((pair? xs) (loop (cdr xs)))
	     (else #f))))

	(define (flat-expr? value)
	  (cond
	   ((pair? value)
	    (and (proper-list? value)
	         (let loop ((xs value))
	           (or (null? xs)
	               (and (not (pair? (car xs)))
	                    (loop (cdr xs)))))))
	   (else #t)))

	(define (write-spaces n out)
	  (let loop ((i n))
	    (when (> i 0)
	      (display " " out)
	      (loop (- i 1)))))

	(define (pretty-write expr out)
	  (define (write-expr value indent)
	    (cond
	     ((flat-expr? value) (write value out))
	     ((and (pair? value) (proper-list? value))
	      (display "(" out)
	      (write (car value) out)
	      (let loop ((items (cdr value)))
	        (cond
	         ((null? items)
	          (display ")" out))
	         ((flat-expr? (car items))
	          (display " " out)
	          (write (car items) out)
	          (loop (cdr items)))
	         (else
	          (newline out)
	          (write-spaces (+ indent 2) out)
	          (write-expr (car items) (+ indent 2))
	          (loop (cdr items))))))
	     (else (write value out))))
	  (write-expr expr 0))

	(define (write-expr-file path expr)
	  (let ((tmp (temporary-file-path path)))
	    (call-with-output-file tmp
	      (lambda (out)
	        (pretty-write expr out)
	        (newline out)))
    (run-command
     (string-append "mv -f " (shell-quote tmp) " " (shell-quote path)))))

(define (symbol-list? value)
  (and (list? value)
       (not (null? value))
       (let loop ((xs value))
         (or (null? xs)
             (and (symbol? (car xs)) (loop (cdr xs)))))))

(define (normalize-name value who)
  (cond
   ((symbol? value) (list value))
   ((symbol-list? value) value)
   (else (manifest-error "expected symbol or non-empty list of symbols for" who value))))

(define (form-kind expr)
  (if (and (pair? expr) (symbol? (car expr)))
      (car expr)
      (manifest-error "expected a top-level form" expr)))

(define (find-form kind exprs)
  (let loop ((xs exprs))
    (cond
     ((null? xs) #f)
     ((eq? (form-kind (car xs)) kind) (car xs))
     (else (loop (cdr xs))))))

(define (forms-of-kind kind exprs)
  (let loop ((xs exprs) (out '()))
    (cond
     ((null? xs) (reverse out))
     ((eq? (form-kind (car xs)) kind) (loop (cdr xs) (cons (car xs) out)))
     (else (loop (cdr xs) out)))))

(define (field-ref fields key default)
  (let loop ((xs fields))
    (cond
     ((null? xs) default)
     ((and (pair? (car xs))
           (eq? (caar xs) key)
           (pair? (cdar xs)))
      (cadar xs))
     (else (loop (cdr xs))))))

(define (field-rest fields key default)
  (let loop ((xs fields))
    (cond
     ((null? xs) default)
     ((and (pair? (car xs))
           (eq? (caar xs) key))
      (cdar xs))
     (else (loop (cdr xs))))))

(define (filter pred xs)
  (let loop ((rest xs) (out '()))
    (cond
     ((null? rest) (reverse out))
     ((pred (car rest)) (loop (cdr rest) (cons (car rest) out)))
     (else (loop (cdr rest) out)))))

(define (append-map proc xs)
  (let loop ((rest xs) (out '()))
    (if (null? rest)
        (reverse out)
        (loop (cdr rest) (append (reverse (proc (car rest))) out)))))

(define (string-split s sep)
  (let ((len (string-length s)))
    (let loop ((i 0) (start 0) (out '()))
      (cond
       ((= i len)
        (reverse (cons (substring s start i) out)))
       ((char=? (string-ref s i) sep)
        (loop (+ i 1) (+ i 1) (cons (substring s start i) out)))
       (else (loop (+ i 1) start out))))))

(define (non-empty-string? s)
  (> (string-length s) 0))

(define (dedupe-symbols xs)
  (let loop ((rest xs) (out '()))
    (cond
     ((null? rest) (reverse out))
     ((memq (car rest) out) (loop (cdr rest) out))
     (else (loop (cdr rest) (cons (car rest) out))))))

(define (string-contains? haystack needle)
  (let ((h-len (string-length haystack))
        (n-len (string-length needle)))
    (let loop ((i 0))
      (cond
       ((= n-len 0) #t)
       ((> (+ i n-len) h-len) #f)
       ((string=? (substring haystack i (+ i n-len)) needle) #t)
       (else (loop (+ i 1)))))))

(define (source-context-name context)
  (if (and (pair? context) (symbol? (car context)))
      (car context)
      context))

(define (source-context-path context)
  (if (and (pair? context) (string? (cdr context)))
      (cdr context)
      #f))

(define (source-field-line path field)
  (if (not path)
      #f
      (let ((needle (string-append "(" (symbol->string field))))
        (call-with-input-file path
          (lambda (in)
            (let loop ((line (read-line in)) (n 1))
              (cond
               ((eof-object? line) #f)
               ((string-contains? line needle) n)
               (else (loop (read-line in) (+ n 1))))))))))

(define (source-detail context field)
  (let ((path (source-context-path context)))
    (if path
        `(source ,path ,(source-field-line path field))
        #f)))

(define (ensure-known-fields fields allowed context)
  (for-each
     (lambda (field)
       (unless (and (pair? field) (symbol? (car field)))
       (manifest-error "expected field form in" (source-context-name context) field))
     (unless (memq (car field) allowed)
       (let ((detail (source-detail context (car field))))
         (if detail
             (manifest-error "unknown field in" (source-context-name context) (car field) detail)
             (manifest-error "unknown field in" (source-context-name context) (car field))))))
   fields))
  ))
