(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (scheme read)
        (srfi 64)
        (kons compat files)
        (kons compat json)
        (kons util))

(test-begin "kons workspace")

(define repo-root (current-directory))
(define root "/tmp/kons-workspace-test")
(define workspace-root (path-join root "workspace"))
(define lib-root (path-join workspace-root "packages/lib"))
(define app-root (path-join workspace-root "apps/app"))
(define output-path (path-join root "check-plan.out"))
(define error-path (path-join root "check-plan.err"))
(define workspace-test-output-path (path-join root "workspace-test.out"))
(define workspace-test-error-path (path-join root "workspace-test.err"))
(define workspace-lock-path (path-join workspace-root "kons.lock"))
(define member-lock-path (path-join app-root "kons.lock"))
(define local-root (path-join workspace-root "vendor/local"))
(define release-helper-root (path-join workspace-root "profiles/release-helper"))
(define compiled-helper-root (path-join workspace-root "profiles/compiled-helper"))
(define dialect-helper-root (path-join workspace-root "profiles/dialect-helper"))
(define r6rs-helper-root (path-join workspace-root "profiles/r6rs-helper"))
(define capy-implementation-helper-root (path-join workspace-root "profiles/capy-implementation-helper"))
(define guile-implementation-helper-root (path-join workspace-root "profiles/guile-implementation-helper"))
(define lib-helper-root (path-join workspace-root "profiles/lib-helper"))
(define shared-capy-cache-home
  (or (get-environment-variable "KONS_TEST_CAPY_CACHE_HOME")
      (get-environment-variable "XDG_CACHE_HOME")))

(define (capy-cache-home fallback)
  (or shared-capy-cache-home fallback))

(define (detail-member? value details)
  (cond
   ((equal? value details) #t)
   ((pair? details)
    (or (detail-member? value (car details))
        (detail-member? value (cdr details))))
   (else #f)))

(define (write-file path text)
  (call-with-output-file path
    (lambda (port)
      (display text port))))

(define (field-ref fields key default)
  (let ((found (assoc key fields)))
    (if found (cdr found) default)))

(define (json-vector->list value)
  (if (vector? value) (vector->list value) '()))

(define (payload-path-from-plan path)
  (let ((plan (call-with-input-file path read)))
    (let loop ((items (cdr plan)))
      (cond
       ((null? items) #f)
       ((and (pair? (car items))
             (eq? (caar items) 'payload)
             (pair? (cdar items)))
        (cadar items))
       (else (loop (cdr items)))))))

(define (payload-dependencies path)
  (json-vector->list
   (field-ref
    (call-with-input-file (payload-path-from-plan path) json-read)
    'dependencies
    '#())))

(define (command-json-output)
  (call-with-input-file output-path json-read))

(define (dependency-names deps)
  (map (lambda (dep) (field-ref dep 'name "")) deps))

(define (dependency-by-name deps name)
  (let loop ((items deps))
    (cond
     ((null? items) #f)
     ((string=? (field-ref (car items) 'name "") name) (car items))
     (else (loop (cdr items))))))

(define (dependency-has-local-field? dep)
  (or (assoc 'type dep)
      (assoc 'path dep)
      (assoc 'url dep)
      (assoc 'rev dep)
      (assoc 'member dep)))

(define (dependencies-have-local-fields? deps)
  (let loop ((items deps))
    (cond
     ((null? items) #f)
     ((dependency-has-local-field? (car items)) #t)
     (else (loop (cdr items))))))

(define (form-field form key default)
  (let ((found (and (pair? form) (assoc key (cdr form)))))
    (if (and found (pair? (cdr found)))
        (cadr found)
        default)))

(define (replace-form-field fields key value)
  (map (lambda (field)
         (if (and (pair? field) (eq? (car field) key))
             (list key value)
             field))
       fields))

(define (workspace-package-entry? form)
  (and (pair? form)
       (eq? (car form) 'package)
       (eq? (form-field form 'type #f) 'workspace)))

(define (package-entry? form)
  (and (pair? form)
       (eq? (car form) 'package)))

(define (rewrite-workspace-package-path form path)
  (if (workspace-package-entry? form)
      (cons 'package (replace-form-field (cdr form) 'path path))
      form))

(define (rewrite-package-field form name field value)
  (if (and (package-entry? form)
           (equal? (form-field form 'name '()) name))
      (cons 'package (replace-form-field (cdr form) field value))
      form))

(define (rewrite-lock-workspace-path form path)
  (if (and (pair? form) (eq? (car form) 'lockfile))
      (cons
       'lockfile
       (map (lambda (section)
              (if (and (pair? section) (eq? (car section) 'packages))
                  (cons 'packages
                        (map (lambda (entry)
                               (rewrite-workspace-package-path entry path))
                             (cdr section)))
                  section))
            (cdr form)))
      form))

(define (rewrite-lock-package-field form name field value)
  (if (and (pair? form) (eq? (car form) 'lockfile))
      (cons
       'lockfile
       (map (lambda (section)
              (if (and (pair? section) (eq? (car section) 'packages))
                  (cons 'packages
                        (map (lambda (entry)
                               (rewrite-package-field entry name field value))
                             (cdr section)))
                  section))
            (cdr form)))
      form))

(define (corrupt-workspace-lock-path! path)
  (write-expr-file
   workspace-lock-path
   (rewrite-lock-workspace-path
    (call-with-input-file workspace-lock-path read)
    path)))

(define (corrupt-workspace-lock-field! name field value)
  (write-expr-file
   workspace-lock-path
   (rewrite-lock-package-field
    (call-with-input-file workspace-lock-path read)
    name
    field
    value)))

(define (workspace-command/output command stdout stderr)
  (string-append
   "cd " (shell-quote app-root)
   " && "
   "XDG_CACHE_HOME=" (shell-quote (capy-cache-home (path-join root "cache")))
   " KONS_HOME=" (shell-quote (path-join root "home"))
   " KONS_SCHEME=capy"
   " " (shell-quote (path-join repo-root "bin/kons"))
   " " command
   " >" (shell-quote stdout)
   " 2>" (shell-quote stderr)))

(define (workspace-command command)
  (workspace-command/output command output-path error-path))

(define (workspace-root-command command)
  (workspace-root-command/output command output-path error-path))

(define (workspace-root-command/output command stdout stderr)
  (string-append
   "cd " (shell-quote workspace-root)
   " && "
   "XDG_CACHE_HOME=" (shell-quote (capy-cache-home (path-join root "cache")))
   " KONS_HOME=" (shell-quote (path-join root "home"))
   " KONS_SCHEME=capy"
   " " (shell-quote (path-join repo-root "bin/kons"))
   " " command
   " >" (shell-quote stdout)
   " 2>" (shell-quote stderr)))

(define (diagnostic-error-json)
  (call-with-input-file error-path json-read))

(define (diagnostic-error-json-final-line)
  (let ((path (string-append error-path ".json")))
    (run-command
     (string-append
      "tail -n 1 "
      (shell-quote error-path)
      " > "
      (shell-quote path)))
    (call-with-input-file path json-read)))

(define (diagnostic-details diagnostic)
  (json-vector->list (field-ref diagnostic 'details '#())))

(define (diagnostic-detail-value detail key default)
  (field-ref detail key default))

(define (diagnostic-detail-with-field details field)
  (let loop ((items details))
    (cond
     ((null? items) #f)
     ((string=? (diagnostic-detail-value (car items) 'field "") field)
      (car items))
     (else (loop (cdr items))))))

(run-command (string-append "rm -rf " (shell-quote root)))
(run-command (string-append "mkdir -p "
                            (shell-quote (path-join lib-root "src/example"))
                            " "
                            (shell-quote (path-join lib-root "tests"))
                            " "
                            (shell-quote (path-join app-root "src/example"))
                            " "
                            (shell-quote (path-join app-root "tests"))
                            " "
                            (shell-quote (path-join local-root "src/example"))
                            " "
                            (shell-quote (path-join release-helper-root "src/example"))
                            " "
                            (shell-quote (path-join compiled-helper-root "src/example"))
                            " "
                            (shell-quote (path-join dialect-helper-root "src/example"))
                            " "
                            (shell-quote (path-join r6rs-helper-root "src/example"))
                            " "
                            (shell-quote (path-join capy-implementation-helper-root "src/example"))
                            " "
                            (shell-quote (path-join guile-implementation-helper-root "src/example"))
                            " "
                            (shell-quote (path-join lib-helper-root "src/example"))))

(write-file
 (path-join workspace-root "kons.scm")
 "(workspace
  (members \"packages/lib\" \"apps/app\")
  (default-members \"apps/app\")
  (package
    (license \"MIT\")
    (repository \"https://example.invalid/workspace.git\")
    (authors \"Workspace Team\"))
  (dependencies
    (workspace (name (example lib)) (version \"1.0.0\"))))
")

(write-file
 (path-join lib-root "kons.scm")
 "(package
  (name (example lib))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"workspace lib\")
  (source-path \"src\")
  (tests \"tests/main.scm\"))

(dependencies
  (path
    (name (example lib-helper))
    (path \"../../profiles/lib-helper\")
    (version \"1.0.0\")))
(dev-dependencies)
")

(write-file
 (path-join lib-root "src/example/lib.sld")
 "(define-library (example lib)
  (export message)
  (import (scheme base) (example lib-helper))
  (begin (define (message) \"lib\")))
")

(write-file
 (path-join lib-root "tests/main.scm")
 "(import (scheme base)
        (scheme write)
        (example lib)
        (example lib-helper))

(unless (and (string=? (message) \"lib\")
             (eq? value 'lib-helper))
  (error \"workspace lib test failed\"))
(display \"workspace-lib-test-ran\")
(newline)
")

(write-file
 (path-join lib-helper-root "kons.scm")
 "(package
  (name (example lib-helper))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"lib helper\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join lib-helper-root "src/example/lib-helper.sld")
 "(define-library (example lib-helper)
  (export value)
  (import (scheme base))
  (begin (define value 'lib-helper)))
")

(write-file
 (path-join app-root "kons.scm")
 "(package
  (name (example app))
  (owner \"alice\")
  (version \"1.0.0\")
  (description \"workspace app\")
  (source-path \"src\")
  (tests \"tests/main.scm\"))

(dependencies
  (workspace (name (example lib)))
  (path
    (name (example release-helper))
    (path \"../../profiles/release-helper\")
    (version \"1.0.0\")
    (profiles release))
  (path
    (name (example compiled-helper))
    (path \"../../profiles/compiled-helper\")
    (version \"1.0.0\")
    (compile-modes compiled))
  (path
    (name (example dialect-helper))
    (path \"../../profiles/dialect-helper\")
    (version \"1.0.0\")
    (dialects r7rs))
  (path
    (name (example r6rs-helper))
    (path \"../../profiles/r6rs-helper\")
    (version \"1.0.0\")
    (dialects r6rs))
  (path
    (name (example capy-implementation-helper))
    (path \"../../profiles/capy-implementation-helper\")
    (version \"1.0.0\")
    (implementations capy))
  (path
    (name (example guile-implementation-helper))
    (path \"../../profiles/guile-implementation-helper\")
    (version \"1.0.0\")
    (implementations guile)))
(dev-dependencies)
")

(write-file
 (path-join app-root "src/example/app.sld")
 "(define-library (example app)
  (export message)
  (import (scheme base)
          (rename (example lib) (message lib-message)))
  (begin (define (message) (lib-message))))
")

(write-file
 (path-join app-root "tests/main.scm")
 "(import (scheme base)
        (scheme write)
        (example app)
        (example lib-helper))

(unless (and (string=? (message) \"lib\")
             (eq? value 'lib-helper))
  (error \"workspace app test failed\"))
(display \"workspace-app-test-ran\")
(newline)
")

(write-file
 (path-join release-helper-root "kons.scm")
 "(package
  (name (example release-helper))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"release helper\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join release-helper-root "src/example/release-helper.sld")
 "(define-library (example release-helper)
  (export value)
  (import (scheme base))
  (begin (define value 'release)))
")

(write-file
 (path-join compiled-helper-root "kons.scm")
 "(package
  (name (example compiled-helper))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"compiled helper\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join compiled-helper-root "src/example/compiled-helper.sld")
 "(define-library (example compiled-helper)
  (export value)
  (import (scheme base))
  (begin (define value 'compiled)))
")

(write-file
 (path-join dialect-helper-root "kons.scm")
 "(package
  (name (example dialect-helper))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"dialect helper\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join dialect-helper-root "src/example/dialect-helper.sld")
 "(define-library (example dialect-helper)
  (export value)
  (import (scheme base))
  (begin (define value 'r7rs)))
")

(write-file
 (path-join r6rs-helper-root "kons.scm")
 "(package
  (name (example r6rs-helper))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"r6rs helper\")
  (source-path \"src\")
  (dialects r6rs))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join r6rs-helper-root "src/example/r6rs-helper.sld")
 "(define-library (example r6rs-helper)
  (export value)
  (import (scheme base))
  (begin (define value 'r6rs)))
")

(write-file
 (path-join capy-implementation-helper-root "kons.scm")
 "(package
  (name (example capy-implementation-helper))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join capy-implementation-helper-root "src/example/capy-implementation-helper.sld")
 "(define-library (example capy-implementation-helper)
  (export value)
  (import (scheme base))
  (begin (define value 'capy-implementation)))
")

(write-file
 (path-join guile-implementation-helper-root "kons.scm")
 "(package
  (name (example guile-implementation-helper))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join guile-implementation-helper-root "src/example/guile-implementation-helper.sld")
 "(define-library (example guile-implementation-helper)
  (export value)
  (import (scheme base))
  (begin (define value 'guile-implementation)))
")

(test-equal
 "member command discovers containing workspace"
 0
 (shell-command-status (workspace-command "check --plan")))

(test-equal
 "workspace root command uses default member"
 0
 (shell-command-status (workspace-root-command "check --plan")))

(let ((plan (call-with-input-file output-path read)))
  (test-assert
   "workspace root default member has app dependency plan"
   (detail-member? '(member . "packages/lib") plan)))

(test-equal
 "workspace all still visits every member"
 0
 (shell-command-status (workspace-root-command "check --workspace --plan")))

(test-equal
 "workspace all writes two plans"
 2
 (length (read-all-exprs output-path)))

(test-equal
 "member metadata inherits workspace license"
 0
 (shell-command-status (workspace-command "metadata --format json")))

(let ((package (field-ref (command-json-output) 'package '())))
  (test-equal
   "member metadata inherited license"
   "MIT"
   (field-ref package 'license ""))
  (test-equal
   "member metadata inherited repository"
   "https://example.invalid/workspace.git"
   (field-ref package 'repository ""))
  (test-equal
   "member metadata inherited author"
   "Workspace Team"
   (car (json-vector->list (field-ref package 'authors '#())))))

(test-equal
 "member command plan still works after metadata check"
 0
 (shell-command-status (workspace-command "check --plan")))

(let ((plan (call-with-input-file output-path read)))
  (test-assert
   "workspace dependency has member"
   (detail-member? '(member . "packages/lib") plan))
  (test-assert
   "workspace dependency has absolute path"
   (detail-member? `(path . ,(path-join workspace-root "packages/lib")) plan))
  (test-assert
   "default profile excludes release dependency"
   (not (detail-member? `(path . ,release-helper-root) plan)))
  (test-assert
   "default compile mode excludes compiled dependency"
   (not (detail-member? `(path . ,compiled-helper-root) plan)))
  (test-assert
   "default dialect selects r7rs dependency"
   (detail-member? '(name example dialect-helper) plan))
  (test-assert
   "default dialect excludes r6rs dependency"
   (not (detail-member? `(path . ,r6rs-helper-root) plan)))
  (test-assert
   "implementation alias selects capy dependency"
   (detail-member? '(name example capy-implementation-helper) plan))
  (test-assert
   "implementation alias excludes guile dependency"
   (not (detail-member? `(path . ,guile-implementation-helper-root) plan)))
  (test-assert
   "implementation alias records scheme selector"
   (detail-member? '(schemes capy) plan)))

(test-equal
 "release profile selects release dependency"
 0
 (shell-command-status (workspace-command "check --plan --release")))

(let ((plan (call-with-input-file output-path read)))
  (test-assert
   "release dependency is selected"
   (detail-member? '(name example release-helper) plan))
  (test-assert
   "release dependency records profile selector"
   (detail-member? '(profiles release) plan)))

(test-equal
 "compiled mode selects compiled dependency"
 0
 (shell-command-status (workspace-command "check --plan --compile-mode compiled")))

(let ((plan (call-with-input-file output-path read)))
  (test-assert
   "compiled dependency is selected"
   (detail-member? '(name example compiled-helper) plan))
  (test-assert
   "compiled dependency records compile-mode selector"
   (detail-member? '(compile-modes compiled) plan)))

(test-equal
 "member update writes workspace lock"
 0
 (shell-command-status (workspace-command "update")))

(test-assert
 "workspace lock exists"
 (file-exists? workspace-lock-path))

(let ((lock (call-with-input-file workspace-lock-path read)))
  (test-assert
   "workspace lock covers app dependency"
   (detail-member? '(name (example dialect-helper)) lock))
  (test-assert
   "workspace lock covers lib dependency"
   (detail-member? '(name (example lib-helper)) lock)))

(test-assert
 "member lock is not written"
 (not (file-exists? member-lock-path)))

(test-equal
 "member clean gc uses workspace lock"
 0
 (shell-command-status (workspace-command "clean --gc")))

(test-assert
 "member clean gc does not need member lock"
 (not (file-exists? member-lock-path)))

(test-equal
 "member fetch materializes selected dialect dependency"
 0
 (shell-command-status (workspace-command "fetch")))

(test-equal
 "workspace test locked uses shared workspace lock"
 0
 (shell-command-status
  (workspace-root-command/output
   "--message-format json test --workspace --locked"
   workspace-test-output-path
   workspace-test-error-path)))

(test-equal
 "workspace test locked runs lib member tests"
 0
 (shell-command-status
  (string-append "grep -q workspace-lib-test-ran "
                 (shell-quote workspace-test-output-path))))

(test-equal
 "workspace test locked runs app member tests"
 0
 (shell-command-status
  (string-append "grep -q workspace-app-test-ran "
                 (shell-quote workspace-test-output-path))))

(test-assert
 "workspace test locked does not write member lock"
 (not (file-exists? member-lock-path)))

(test-equal
 "member verify uses workspace lock"
 0
 (shell-command-status (workspace-command "verify")))

(test-equal
 "member verify json exits successfully"
 0
 (shell-command-status (workspace-command "verify --format json")))

(let ((verification (command-json-output)))
  (test-equal
   "member verify json kind"
   "verification"
   (field-ref verification 'kind ""))
  (test-equal
   "member verify json status"
   "ok"
   (field-ref verification 'status ""))
  (test-assert
   "member verify json package count"
   (> (field-ref verification 'packages 0) 0)))

(test-equal
 "member verify stale scheme exits with diagnostic"
 1
 (shell-command-status
  (workspace-command "--quiet --scheme guile --message-format json verify")))

(let* ((diagnostic (diagnostic-error-json))
       (details (diagnostic-details diagnostic))
       (scheme-detail (diagnostic-detail-with-field details "scheme")))
  (test-equal
   "member verify stale scheme diagnostic code"
   "stale-lockfile"
   (field-ref diagnostic 'code ""))
  (test-assert
   "member verify stale scheme names field"
   scheme-detail)
  (test-equal
   "member verify stale scheme expected"
   "guile"
   (diagnostic-detail-value scheme-detail 'expected "")))

(corrupt-workspace-lock-field! '(example dialect-helper) 'source-hash "stale-source-hash")

(test-equal
 "member verify stale shared package section exits with diagnostic"
 1
 (shell-command-status
  (workspace-command "--quiet --message-format json verify --locked")))

(let* ((diagnostic (diagnostic-error-json))
       (details (diagnostic-details diagnostic))
       (packages-detail (diagnostic-detail-with-field details "packages")))
  (test-equal
   "member verify stale shared package section diagnostic code"
   "stale-lockfile"
   (field-ref diagnostic 'code ""))
  (test-assert
   "member verify stale shared package section names field"
   packages-detail))

(test-equal
 "member update restores workspace lock after stale package section"
 0
 (shell-command-status (workspace-command "update")))

(let ((missing-root (path-join root "missing-workspace-source")))
  (corrupt-workspace-lock-path! missing-root)
  (test-equal
   "member verify stale shared path exits with diagnostic"
   1
   (shell-command-status
    (workspace-command "--quiet --message-format json verify --offline")))
  (let* ((diagnostic (diagnostic-error-json))
         (details (diagnostic-details diagnostic))
         (packages-detail (diagnostic-detail-with-field details "packages")))
    (test-equal
     "member verify stale shared path diagnostic code"
     "stale-lockfile"
     (field-ref diagnostic 'code ""))
    (test-assert
     "member verify stale shared path names packages field"
     packages-detail)))

(test-equal
 "workspace dependency default allows publish dry-run"
 0
 (shell-command-status (workspace-command "publish --dry-run --registry http://127.0.0.1:9")))

(let* ((deps (payload-dependencies output-path))
       (workspace-dep (dependency-by-name deps "example/lib"))
       (release-dep (dependency-by-name deps "example/release-helper"))
       (compiled-dep (dependency-by-name deps "example/compiled-helper"))
       (dialect-dep (dependency-by-name deps "example/dialect-helper"))
       (r6rs-dep (dependency-by-name deps "example/r6rs-helper")))
  (test-equal
   "workspace dependency inherits publish version"
   "1.0.0"
   (field-ref workspace-dep 'req ""))
  (test-equal
   "publish payload records profile selector"
   '("release")
   (json-vector->list (field-ref release-dep 'profiles '#())))
  (test-equal
   "publish payload records compile-mode selector"
   '("compiled")
   (json-vector->list (field-ref compiled-dep 'compileModes '#())))
  (test-equal
   "publish payload records dialect selector"
   '("r7rs")
   (json-vector->list (field-ref dialect-dep 'dialects '#())))
  (test-equal
   "publish payload records non-selected dialect selector"
   '("r6rs")
   (json-vector->list (field-ref r6rs-dep 'dialects '#()))))

(write-file
 (path-join local-root "kons.scm")
 "(package
  (name (example local))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"local path dependency\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join local-root "src/example/local.sld")
 "(define-library (example local)
  (export value)
  (import (scheme base))
  (begin (define value 1)))
")

(write-file
 (path-join app-root "kons.scm")
 "(package
  (name (example app))
  (owner \"alice\")
  (version \"1.0.0\")
  (description \"workspace app\")
  (source-path \"src\"))

(dependencies
  (workspace (name (example lib)) (version \"1.0.0\"))
  (path (name (example local)) (path \"../../vendor/local\") (version \"^1.0\") (registry \"local\"))
  (git (name (example remote)) (url \"https://example.invalid/remote.git\") (version \"^2.0\")))
(dev-dependencies)
")

(test-equal
 "versioned local dependencies can publish dry-run"
 0
 (shell-command-status (workspace-command "publish --dry-run --registry http://127.0.0.1:9")))

(let* ((deps (payload-dependencies output-path))
       (workspace-dep (dependency-by-name deps "example/lib"))
       (path-dep (dependency-by-name deps "example/local"))
       (git-dep (dependency-by-name deps "example/remote")))
  (test-equal
   "publish payload dependency names"
   '("example/lib" "example/local" "example/remote")
   (dependency-names deps))
  (test-equal
   "workspace dependency becomes registry requirement"
   "1.0.0"
   (field-ref workspace-dep 'req ""))
  (test-equal
   "path dependency keeps publish registry"
   "local"
   (field-ref path-dep 'registry ""))
  (test-equal
   "git dependency becomes registry requirement"
   "^2.0"
   (field-ref git-dep 'req ""))
  (test-assert
   "publish payload omits local-only dependency fields"
   (not (dependencies-have-local-fields? deps))))

(write-file
 (path-join app-root "kons.scm")
 "(package
  (name (example app))
  (owner \"alice\")
  (version \"1.0.0\")
  (license \"MIT\")
  (description \"workspace app\")
  (source-path \"src\"))

(dependencies
  (path (name (example local)) (path \"../../vendor/local\")))
(dev-dependencies)
")

(test-equal
 "unversioned path dependency cannot publish"
 1
 (shell-command-status
  (workspace-command "--message-format json publish --dry-run --registry http://127.0.0.1:9")))

(let ((diagnostic (diagnostic-error-json-final-line)))
  (test-equal
   "unversioned path publish diagnostic"
   "publish cannot include unversioned path, workspace, or git dependencies"
   (field-ref diagnostic 'message "")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons workspace")
  (exit (if (= failures 0) 0 1)))
