(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (srfi 64)
        (kons lock)
        (kons runner)
        (kons util))

(test-begin "kons Akku materialization")

(define root "/tmp/kons-akku-materialization-test")
(define home (or (get-environment-variable "KONS_HOME")
                 (path-join root "home")))
(define cache (path-join root "cache"))
(define project-root (path-join root "project"))
(define output-path (path-join root "fetch.out"))
(define repo-root (current-directory))
(define load-path (string-append repo-root "/vendor/scm-args/src,"
                                  repo-root "/vendor/conduit/src,"
                                  repo-root "/src"))
(define capy (or (get-environment-variable "CAPY") "capy"))
(define selected-scheme-name (or (get-environment-variable "KONS_SCHEME") "capy"))
(define selected-scheme (string->symbol selected-scheme-name))

(define (write-text path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (read-text path)
  (call-with-input-file path
    (lambda (in)
      (let loop ((chars '()))
        (let ((ch (read-char in)))
          (if (eof-object? ch)
              (list->string (reverse chars))
              (loop (cons ch chars))))))))

(define (reset-dir path)
  (run-command (string-append "rm -rf " (shell-quote path)))
  (run-command (string-append "mkdir -p " (shell-quote path))))

(define (sha256-file path)
  (capture-first-line
   (string-append "sha256sum " (shell-quote path) " | awk '{print $1}'")))

(define (git-head path)
  (capture-first-line
   (string-append "git -C " (shell-quote path) " rev-parse HEAD")))

(define (entry-by-name entries name)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((equal? (lock-entry-ref (car items) 'name #f) name) (car items))
     (else (loop (cdr items))))))

(define (runtime-akku-count entries)
  (let loop ((items entries) (count 0))
    (cond
     ((null? items) count)
     ((and (eq? (lock-entry-type (car items)) 'akku)
           (eq? (lock-entry-ref (car items) 'scope 'runtime) 'runtime))
      (loop (cdr items) (+ count 1)))
     (else (loop (cdr items) count)))))

(define (source-cache-path kind key token)
  (path-join
   (path-join (path-join home "store/akku/sources") kind)
   (path-join key token)))

(define (write-project-with-dependencies! dependencies)
  (write-text
   (path-join project-root "kons.scm")
   (string-append
    "(package
  (name (fixture app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies"
    dependencies
    ")
(dev-dependencies)
"))
  (write-text
   (path-join project-root "src/fixture/app.sld")
   "(define-library (fixture app) (export value) (import (scheme base)) (begin (define value 1)))\n"))

(define (write-project!)
  (write-project-with-dependencies! ""))

(define (prepare-git-repo!)
  (let ((repo (path-join root "git-src")))
    (reset-dir repo)
    (write-text (path-join repo "kons.scm")
                "(package (name (akku git-dep)) (version \"1.0.0\") (source-path \"src\"))\n(dependencies)\n(dev-dependencies)\n")
    (write-text (path-join repo "src/akku/git-dep.sld")
                "(define-library (akku git-dep) (export git-value) (import (scheme base)) (begin (define git-value 7)))\n")
    (run-command (string-append "git -C " (shell-quote repo) " init --quiet"))
    (run-command (string-append "git -C " (shell-quote repo) " config user.email test@example.invalid"))
    (run-command (string-append "git -C " (shell-quote repo) " config user.name 'Kons Test'"))
    (run-command (string-append "git -C " (shell-quote repo) " add ."))
    (run-command (string-append "git -C " (shell-quote repo) " commit --quiet -m init"))
    (run-command (string-append "git -C " (shell-quote repo) " tag v1.0.0"))
    (cons repo (git-head repo))))

(define (prepare-url-archive!)
  (let ((payload (path-join root "url-payload"))
        (archive (path-join root "url-source.tar.gz")))
    (reset-dir payload)
    (write-text (path-join payload "kons.scm")
                "(package (name (akku url-dep)) (version \"1.0.0\") (source-path \"src\"))\n(dependencies)\n(dev-dependencies)\n")
    (write-text (path-join payload "src/akku/url-dep.sld")
                "(define-library (akku url-dep) (export url-value) (import (scheme base)) (begin (define url-value 8)))\n")
    (run-command
     (string-append "cd " (shell-quote payload)
                    " && tar -czf " (shell-quote archive) " ."))
    (cons archive (sha256-file archive))))

(define (prepare-directory!)
  (let ((dir (path-join project-root "vendor/dir-dep")))
    (write-text (path-join dir "kons.scm")
                "(package (name (akku dir-dep)) (version \"1.0.0\") (source-path \"src\"))\n(dependencies)\n(dev-dependencies)\n")
    (write-text (path-join dir "src/akku/dir-dep.sld")
                "(define-library (akku dir-dep) (export dir-value) (import (scheme base)) (begin (define dir-value 9)))\n")
    dir))

(define (prepare-traversal-archive!)
  (let ((archive (path-join root "bad-traversal.tar")))
    (run-command
     (string-append "tar -cf " (shell-quote archive)
                    " --transform='s|hosts|../escape|g' /etc/hosts >/dev/null 2>&1"))
    (cons archive (sha256-file archive))))

(define (lock-form git-pair url-pair dir-path traversal-pair)
  (let* ((git-repo (car git-pair))
         (git-revision (cdr git-pair))
         (url-archive (car url-pair))
         (url-sha (cdr url-pair))
         (bad-archive (car traversal-pair))
         (bad-sha (cdr traversal-pair)))
    `(lockfile
      (version 2)
      (root
       (name (fixture app))
       (version "0.1.0")
       (scheme ,selected-scheme)
       (dialect r7rs)
       (target #f)
       (profile debug)
       (compile-mode fresh-auto)
       (features default))
      (packages
       (package
        (id "registry:fixture:akku/string/git-dep:1.0.0")
        (scope runtime)
        (type akku)
        (name "git-dep")
        (resolver-name (akku string "git-dep"))
        (key "akku/string/git-dep")
        (version "1.0.0")
        (source "fixture")
        (source-url "file:///tmp/fixture/")
        (source-kind git)
        (remote ,git-repo)
        (tag "v1.0.0")
        (revision ,git-revision)
        (source-cache-path ,(source-cache-path "git" "akku/string/git-dep" git-revision))
        (optional #f))
       (package
        (id "registry:fixture:akku/string/url-dep:1.0.0")
        (scope runtime)
        (type akku)
        (name "url-dep")
        (resolver-name (akku string "url-dep"))
        (key "akku/string/url-dep")
        (version "1.0.0")
        (source "fixture")
        (source-url "file:///tmp/fixture/")
        (source-kind url)
        (url ,(string-append "file://" url-archive))
        (url-sha256 ,url-sha)
        (source-cache-path ,(source-cache-path "url" "akku/string/url-dep" url-sha))
        (optional #f))
       (package
        (id "registry:fixture:akku/string/dir-dep:1.0.0")
        (scope runtime)
        (type akku)
        (name "dir-dep")
        (resolver-name (akku string "dir-dep"))
        (key "akku/string/dir-dep")
        (version "1.0.0")
        (source "fixture")
        (source-url "file:///tmp/fixture/")
        (source-kind directory)
        (path "vendor/dir-dep")
        (source-cache-path ,(source-cache-path "directory" "akku/string/dir-dep" "1.0.0"))
        (optional #f))
       (package
        (id "registry:fixture:akku/string/bad-url:1.0.0")
        (scope dev)
        (type akku)
        (name "bad-url")
        (resolver-name (akku string "bad-url"))
        (key "akku/string/bad-url")
        (version "1.0.0")
        (source "fixture")
        (source-url "file:///tmp/fixture/")
        (source-kind url)
        (url ,(string-append "file://" url-archive))
        (url-sha256 "0000000000000000000000000000000000000000000000000000000000000000")
        (source-cache-path ,(source-cache-path "url" "akku/string/bad-url" "bad"))
        (optional #f))
       (package
        (id "registry:fixture:akku/string/bad-git:1.0.0")
        (scope dev)
        (type akku)
        (name "bad-git")
        (resolver-name (akku string "bad-git"))
        (key "akku/string/bad-git")
        (version "1.0.0")
        (source "fixture")
        (source-url "file:///tmp/fixture/")
        (source-kind git)
        (remote ,git-repo)
        (tag "v1.0.0")
        (revision "0000000000000000000000000000000000000000")
        (source-cache-path ,(source-cache-path "git" "akku/string/bad-git" "bad"))
        (optional #f))
       (package
        (id "registry:fixture:akku/string/traversal:1.0.0")
        (scope dev)
        (type akku)
        (name "traversal")
        (resolver-name (akku string "traversal"))
        (key "akku/string/traversal")
        (version "1.0.0")
        (source "fixture")
        (source-url "file:///tmp/fixture/")
        (source-kind url)
        (url ,(string-append "file://" bad-archive))
        (url-sha256 ,bad-sha)
        (source-cache-path ,(source-cache-path "url" "akku/string/traversal" "traversal"))
        (optional #f)))
      (edges)
      (overrides))))

(define (archive-cache-path entry)
  (path-join
   (path-join (dirname (lock-entry-ref entry 'source-cache-path "")) ".archives")
   (string-append (safe-store-token (lock-entry-ref entry 'url "source"))
                  "-"
                  (safe-store-token (lock-entry-ref entry 'url-sha256 ""))
                  ".tar")))

(define (copy-archive-to-entry-cache! entry archive)
  (let ((cached (archive-cache-path entry)))
    (run-command (string-append "mkdir -p " (shell-quote (dirname cached))))
    (run-command (string-append "cp " (shell-quote archive) " " (shell-quote cached)))))

(define (copy-output! artifact)
  (run-command
   (string-append "cp " (shell-quote output-path)
                  " " (shell-quote (path-join root artifact)))))

(define (run-fetch command)
  (shell-command-status
   (string-append
    "KONS_HOME=" (shell-quote home)
    " XDG_CACHE_HOME=" (shell-quote cache)
    " KONS_SCHEME=" (shell-quote selected-scheme-name)
    " "
    (shell-quote capy)
    " -L " (shell-quote load-path)
    " -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join project-root "kons.scm"))
    " --no-color "
    command
    " >" (shell-quote output-path)
    " 2>&1")))

(define (fetch-status command artifact)
  (let ((status (run-fetch command)))
    (copy-output! artifact)
    status))

(define (test-manifest)
  `((path . ,(path-join project-root "kons.scm"))
    (package (source-path . "src"))))

(define (write-lock-with-packages! lock-path packages)
  (write-expr-file
   lock-path
   `(lockfile
     (version 2)
     (root
      (name (fixture app))
      (version "0.1.0")
      (scheme ,selected-scheme)
      (dialect r7rs)
      (target #f)
      (profile debug)
      (compile-mode fresh-auto)
      (features default))
     (packages ,@packages)
     (edges)
     (overrides))))

(define (negative-dependency name)
  (string-append "\n  (akku (name " (call-with-output-string
                                      (lambda (out) (write name out)))
                 ") (version \"1.0.0\") (source \"fixture\"))"))

(define (fetch-fails-with? command expected artifact)
  (and (not (= 0 (fetch-status command artifact)))
       (let ((output (read-text output-path)))
         (and (string-contains? output expected)
              (not (string-contains? output "kons.lock is stale"))))))

(reset-dir root)
(reset-dir home)
(reset-dir cache)
(reset-dir project-root)
(write-project!)

(let* ((git-pair (prepare-git-repo!))
       (url-pair (prepare-url-archive!))
       (dir-path (prepare-directory!))
       (traversal-pair (prepare-traversal-archive!))
       (lock-path (path-join project-root "kons.lock")))
  (write-expr-file lock-path (lock-form git-pair url-pair dir-path traversal-pair))
  (let* ((lock (read-lockfile lock-path))
         (entries (lock-package-entries lock))
         (git-entry (entry-by-name entries "git-dep"))
         (url-entry (entry-by-name entries "url-dep"))
         (dir-entry (entry-by-name entries "dir-dep"))
         (bad-url-entry (entry-by-name entries "bad-url"))
         (bad-git-entry (entry-by-name entries "bad-git"))
         (traversal-entry (entry-by-name entries "traversal")))
    (test-equal "lock has runtime Akku entries" 3 (runtime-akku-count entries))
    (let ((materialized (materialize-lock-sources
                         (test-manifest)
                         lock
                         #f
                         #f)))
      (write-text (path-join root "materialized.scm")
                  (call-with-output-string
                   (lambda (out)
                     (write materialized out)
                     (newline out))))
      (test-equal "locked Akku materialization creates runtime roots"
                  3
                  (length materialized)))
    (test-assert "git checkout exists"
                 (file-exists? (path-join (lock-entry-ref git-entry 'source-cache-path "") "src/akku/git-dep.sld")))
    (test-equal "git checkout uses locked revision"
                (cdr git-pair)
                (git-head (lock-entry-ref git-entry 'source-cache-path "")))
    (test-assert "URL archive extracts after checksum"
                 (file-exists? (path-join (lock-entry-ref url-entry 'source-cache-path "") "src/akku/url-dep.sld")))
    (test-assert "directory source copies into Akku store"
                 (file-exists? (path-join (lock-entry-ref dir-entry 'source-cache-path "") "src/akku/dir-dep.sld")))
    (write-lock-with-packages! lock-path (list git-entry url-entry dir-entry))
    (write-text (path-join root "selected-scheme.txt") selected-scheme-name)
    (test-equal "lock root uses selected fetch scheme"
                selected-scheme
                (lock-root-scheme (read-lockfile lock-path)))
    (test-equal "offline source reuse"
                0
                (fetch-status "fetch --locked --offline" "offline-reuse.out"))
    (test-assert "URL checksum failure raises from Akku materialization"
                 (begin
                   (write-project-with-dependencies! (negative-dependency "bad-url"))
                   (write-lock-with-packages! lock-path (list bad-url-entry))
                   (copy-archive-to-entry-cache! bad-url-entry (car url-pair))
                   (fetch-fails-with? "fetch --frozen"
                                      "Akku URL source checksum mismatch"
                                      "checksum-mismatch.out")))
    (test-assert "git revision mismatch raises from Akku materialization"
                 (begin
                   (write-project-with-dependencies! (negative-dependency "bad-git"))
                   (write-lock-with-packages! lock-path (list bad-git-entry))
                   (fetch-fails-with? "fetch --frozen"
                                      "Akku git source revision mismatch"
                                      "revision-mismatch.out")))
    (test-assert "URL traversal archive raises from Akku materialization"
                 (begin
                   (write-project-with-dependencies! (negative-dependency "traversal"))
                   (write-lock-with-packages! lock-path (list traversal-entry))
                   (copy-archive-to-entry-cache! traversal-entry (car traversal-pair))
                   (fetch-fails-with? "fetch --frozen"
                                      "Akku URL source archive contains unsafe entries"
                                      "traversal-rejection.out")))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku materialization")
  (exit (if (= failures 0) 0 1)))
