(import (scheme base)
        (scheme file)
        (srfi 64)
        (kons compat json)
        (kons util)
        (kons manifest)
        (kons runner)
        (kons library-discovery)
        (kons actions activation translate))

(test-begin "kons R7RS to R6RS translation")

(define root "/tmp/kons-translation-test")
(define source-root (path-join root "src"))
(define build-root (path-join root "build"))
(define runtime-root "/tmp/kons-translation-runtime-test")
(define runtime-source-root (path-join runtime-root "src"))
(define runtime-build-root (path-join runtime-root "build"))
(define install-root "/tmp/kons-translation-install-root")
(define bad-root "/tmp/kons-translation-bad-test")
(define bad-source-root (path-join bad-root "src"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (activation-source-roots metadata)
  (let ((entry (assoc 'source-roots (cdr metadata))))
    (if entry (cdr entry) '())))

(define (translated-library-installed? roots name)
  (let loop ((items roots))
    (and (pair? items)
         (or (file-exists? (r6rs-library-source-path (car items) name))
             (loop (cdr items))))))

(define (json-field object key default)
  (let ((entry (assoc key object)))
    (if entry (cdr entry) default)))

(define (diagnostic-details diagnostic)
  (let ((details (json-field diagnostic 'details '#())))
    (if (vector? details) (vector->list details) '())))

(define (translation-diagnostic-detail diagnostic)
  (let loop ((items (diagnostic-details diagnostic)))
    (cond
     ((null? items) #f)
     ((and (pair? (car items)) (assoc 'translation (car items)))
      (cdr (assoc 'translation (car items))))
     (else (loop (cdr items))))))

(define (unsupported-message-member? unsupported text)
  (let loop ((items unsupported))
    (cond
     ((null? items) #f)
     ((string-contains? (unsupported-translation-form-message (car items)) text) #t)
     (else (loop (cdr items))))))

(define documented-standard-import-mappings
  '(((scheme base) ((rnrs base)))
    ((scheme case-lambda) ((rnrs control)))
    ((scheme char) ((rnrs unicode)))
    ((scheme complex) ((rnrs base)))
    ((scheme cxr) ((rnrs lists)))
    ((scheme eval) ((rnrs eval)))
    ((scheme file) ((rnrs files)))
    ((scheme inexact) ((rnrs arithmetic flonums)))
    ((scheme process-context) ((rnrs programs)))
    ((scheme read) ((rnrs io simple)))
    ((scheme write) ((rnrs io simple)))
    ((scheme r5rs) ((rnrs r5rs)))))

(define unmapped-standard-imports
  '((scheme lazy)
    (scheme time)
    (scheme load)
    (scheme repl)))

(for-each
 (lambda (mapping)
   (test-equal
    (string-append
     "standard import mapping "
     (call-with-output-string
      (lambda (out) (write (car mapping) out))))
    (cadr mapping)
    (r7rs-standard-library->r6rs-imports (car mapping))))
 documented-standard-import-mappings)

(for-each
 (lambda (name)
   (test-equal
    (string-append
     "standard import intentionally unmapped "
     (call-with-output-string
      (lambda (out) (write name out))))
    #f
    (r7rs-standard-library->r6rs-imports name)))
 unmapped-standard-imports)

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "rm -rf " (shell-quote runtime-root)))
(run-command (string-append "rm -rf " (shell-quote install-root)))
(run-command (string-append "rm -rf " (shell-quote bad-root)))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example translated))
  (version \"0.1.0\")
  (dialects r7rs)
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join source-root "example/decls.scm")
 "(export extra)
(begin
  (define extra 'included-declaration))
")

(write-file
 (path-join source-root "example/body.scm")
 "(define body-value 'included-body)
")

(write-file
 (path-join source-root "example/case-body.scm")
 "(DEFINE CASE-FOLDED-VALUE 'INCLUDED-BODY)
")

(write-file
 (path-join source-root "example/translated.sld")
"(define-library (example translated)
  (export main (rename hidden public-hidden))
  (import (scheme base)
          (only (scheme write) write)
          (except (scheme base) string?)
          (prefix (scheme write) out:)
          (rename (scheme base) (car first))
          (scheme read)
          (scheme file)
          (scheme process-context)
          (scheme cxr)
          (scheme complex)
          (scheme case-lambda)
          (only (scheme lazy) delay force)
          (example dep))
  (include-library-declarations \"decls.scm\")
  (cond-expand
    (r7rs (begin (define target 'wrong)))
    ((library (example missing-translation-branch))
     (begin (define target 'missing-library-branch)))
    ((library (scheme base))
     (begin (define target 'standard-library-branch)))
    (r6rs (begin (define target 'r6rs)))
    (else (begin (define target 'else))))
  (include \"body.scm\")
  (include-ci \"case-body.scm\")
  (begin
    (define hidden 'renamed-export)
    (define (main) target)))
")

(let ((manifest (parse-manifest (path-join root "kons.scm"))))
  (test-assert
   "R6RS-only implementation activates translation"
   (r7rs->r6rs-translation-active-for-scheme? manifest 'mosh))
  (test-equal
   "adapter falls back to R6RS implementation mode"
   'mosh
   (adapter-scheme manifest 'mosh))
  (let ((report (r7rs->r6rs-translation-report manifest '(default) 'mosh build-root)))
    (test-assert "translation report is active" (translation-report-active? report))
    (test-equal
     "translation report has one library"
     1
     (length (translation-report-libraries report)))
    (let ((library (car (translation-report-libraries report))))
      (test-equal
       "translation report source"
       (path-join source-root "example/translated.sld")
       (translation-library-report-source library))
      (test-equal
       "translation report output"
       (r6rs-library-source-path build-root '(example translated))
       (translation-library-report-output library))
      (test-equal
       "translation report has no unsupported forms"
       '()
       (translation-library-report-unsupported library))))
  (write-r7rs->r6rs-translations-for-scheme! manifest '(default) 'mosh build-root)
  (let* ((output (r6rs-library-source-path build-root '(example translated)))
         (forms (read-all-exprs output)))
    (test-assert "translated output exists" (file-exists? output))
    (test-equal
     "translated library form"
     '((library (example translated)
         (export main (rename (hidden public-hidden)) extra)
         (import (rnrs base)
                 (only (rnrs io simple) write)
                 (except (rnrs base) string?)
                 (prefix (rnrs io simple) out:)
                 (rename (rnrs base) (car first))
                 (rnrs io simple)
                 (rnrs files)
                 (rnrs programs)
                 (rnrs lists)
                 (rnrs control)
                 (only (rnrs r5rs) delay force)
                 (example dep))
         (define extra 'included-declaration)
         (define target 'standard-library-branch)
         (define body-value 'included-body)
         (define case-folded-value 'included-body)
         (define hidden 'renamed-export)
         (define (main) target)))
     forms)))

(write-file
 (path-join runtime-root "kons.scm")
 "(package
  (name (example runnable-translation))
  (version \"0.1.0\")
  (dialects r7rs)
  (source-path \"src\")
  (main \"run.sps\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join runtime-source-root "example/runnable-translation.sld")
 "(define-library (example runnable-translation)
  (export (rename private-main main))
  (import (except (scheme base) =)
          (rename (scheme base) (= same-number?))
          (only (scheme lazy) delay force)
          (scheme complex))
  (begin
    (define (private-main)
      (let ((result (delay (real-part (make-rectangular 7 3)))))
        (if (same-number? (force result) 7)
            7
            0)))))
")

(write-file
 (path-join runtime-source-root "main.scm")
 "(import (scheme base) (example runnable-translation))
(unless (= (main) 7)
  (exit 1))
")

(write-file
 (path-join runtime-root "run.sps")
 "#!r6rs
(import (rnrs) (example runnable-translation))
(unless (= (main) 7)
  (exit 1))
")

(write-file
 (path-join runtime-source-root "run.sps")
 "#!r6rs
(import (rnrs) (example runnable-translation))
(unless (= (main) 7)
  (exit 1))
")

(let ((manifest (parse-manifest (path-join runtime-root "kons.scm"))))
  (write-r7rs->r6rs-translations-for-scheme! manifest '(default) 'mosh runtime-build-root)
  (test-equal
   "translated R6RS library runs on Sagittarius when available"
   0
   (shell-command-status
    (string-append
     "if command -v sash >/dev/null 2>&1; then "
     "sash -r6 -L "
     (shell-quote runtime-build-root)
     " "
     (shell-quote (path-join runtime-root "run.sps"))
     "; else exit 0; fi"))))

(let ((manifest (parse-manifest (path-join runtime-root "kons.scm"))))
  (write-r7rs->r6rs-translations-for-scheme! manifest '(default) 'chez runtime-build-root)
  (test-equal
   "translated R6RS library runs on Chez when available"
   0
   (shell-command-status
    (string-append
     "if command -v chez >/dev/null 2>&1 || command -v chezscheme >/dev/null 2>&1; then "
     (command->shell
      (adapter-command
       'chez
       (list runtime-build-root)
       (path-join runtime-root "run.sps")
       '()))
     "; else exit 0; fi"))))

(let* ((command (string-append
                 "if command -v chez >/dev/null 2>&1 || command -v chezscheme >/dev/null 2>&1; then "
                 "XDG_CACHE_HOME=" (shell-quote (path-join runtime-root "cache"))
                 " KONS_HOME=" (shell-quote (path-join runtime-root "home"))
                 " KONS_SCHEME=capy"
                 " capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --quiet --scheme chez --manifest "
                 (shell-quote (path-join runtime-root "kons.scm"))
                 " run"
                 "; else exit 0; fi")))
  (test-equal
   "kons run uses generated Chez translation"
   0
   (shell-command-status command)))

(let* ((tmp (temporary-file-path "kons-translation-check-plan"))
       (command (string-append
                 "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --quiet --scheme mosh --manifest "
                 (shell-quote (path-join root "kons.scm"))
                 " check --plan >"
                 (shell-quote tmp))))
  (test-equal "check plan reports translation" 0 (shell-command-status command))
  (let ((plan (call-with-input-file tmp read)))
    (test-assert
     "check plan includes translation section"
     (assoc 'translation (cdr plan)))))

(let* ((command (string-append
                 "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --quiet --scheme chez --manifest "
                 (shell-quote (path-join runtime-root "kons.scm"))
                 " install --root "
                 (shell-quote install-root)
                 " --directory "
                 (shell-quote (path-join install-root "bin"))
                 " --name translated-runtime >/tmp/kons-translation-install.out"))
       (activation-path (path-join install-root "bin/translated-runtime.activation.scm"))
       (launcher-path (path-join install-root "bin/translated-runtime"))
       (status (shell-command-status command)))
  (test-equal "install with Chez translation succeeds" 0 status)
  (when (= status 0)
    (let* ((metadata (call-with-input-file activation-path read))
           (roots (activation-source-roots metadata)))
      (test-assert
       "install metadata includes copied translation source root"
       (translated-library-installed? roots '(example runnable-translation))))
    (test-equal
     "installed Chez launcher uses copied translation"
     0
     (shell-command-status
      (string-append
       "if command -v chez >/dev/null 2>&1 || command -v chezscheme >/dev/null 2>&1; then "
       (shell-quote launcher-path)
       "; else exit 0; fi")))))

(write-file
 (path-join bad-root "kons.scm")
 "(package
  (name (example bad-translation))
  (version \"0.1.0\")
  (dialects r7rs)
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join bad-source-root "example/bad-translation.sld")
 "(define-library (example bad-translation)
  (export value (prefix value bad:))
  (import (scheme base) (scheme lazy) (scheme time) (scheme load) (scheme repl))
  (unsupported-declaration value)
  (begin (define value 1)))
")

(let* ((manifest (parse-manifest (path-join bad-root "kons.scm")))
       (report (r7rs->r6rs-translation-report manifest '(default) 'mosh (path-join bad-root "build")))
       (library (car (translation-report-libraries report)))
       (unsupported (translation-library-report-unsupported library)))
  (test-equal "unsupported translation report count" 6 (length unsupported))
  (test-assert
   "unsupported translation report message"
   (unsupported-message-member?
    unsupported
    "R7RS import set has no R6RS translation mapping"))
  (test-assert
   "unsupported export report message"
   (unsupported-message-member?
    unsupported
    "unsupported R7RS export spec"))
  (test-assert
   "unsupported declaration report message"
   (unsupported-message-member?
    unsupported
    "unsupported R7RS library declaration")))

(let* ((raw-error-path (path-join bad-root "check-json.err.raw"))
       (error-path (path-join bad-root "check-json.err"))
       (command
        (string-append
         "capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --quiet --scheme mosh --manifest "
         (shell-quote (path-join bad-root "kons.scm"))
         " --message-format json check >/dev/null 2>"
         (shell-quote raw-error-path))))
  (test-assert
   "check json unsupported translation exits with diagnostic"
   (not (= 0 (shell-command-status command))))
  (test-equal
   "extract check json diagnostic"
   0
   (shell-command-status
    (string-append "tail -n 1 "
                   (shell-quote raw-error-path)
                   " > "
                   (shell-quote error-path))))
  (let* ((diagnostic (call-with-input-file error-path json-read))
         (translation (translation-diagnostic-detail diagnostic))
         (libraries (and translation (json-field translation 'libraries '#())))
         (library (and (vector? libraries)
                       (> (vector-length libraries) 0)
                       (vector-ref libraries 0)))
         (unsupported (and library (json-field library 'unsupported '#()))))
    (test-equal
     "check json unsupported translation category"
     "manifest"
     (json-field diagnostic 'category ""))
    (test-equal
     "check json unsupported translation code"
     "unsupported-translation"
     (json-field diagnostic 'code ""))
    (test-equal
     "check json unsupported translation count"
     6
     (json-field translation 'unsupported-count 0))
    (test-assert
     "check json unsupported translation lists library"
     (and library #t))
    (test-equal
     "check json unsupported translation forms count"
     6
     (if (vector? unsupported) (vector-length unsupported) 0))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons R7RS to R6RS translation")
  (exit (if (= failures 0) 0 1)))
