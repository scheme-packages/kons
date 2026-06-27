(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (srfi 64)
        (kons util))

(test-begin "kons Akku CLI")

(define root
  (or (get-environment-variable "KONS_AKKU_CLI_TEST_ROOT")
      "/tmp/kons-akku-cli-test"))
(define repo-root (current-directory))
(define load-path (string-append repo-root "/vendor/scm-args/src,"
                                  repo-root "/vendor/conduit/src,"
                                  repo-root "/src"))
(define capy (or (get-environment-variable "CAPY") "capy"))
(define selected-scheme (or (get-environment-variable "KONS_SCHEME") "gauche"))

(define (write-text path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (when (file-exists? path)
    (delete-file path))
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

(define (sha1-file path)
  (capture-first-line
   (string-append "sha1sum " (shell-quote path) " | awk '{print $1}'")))

(define (sha256-file path)
  (capture-first-line
   (string-append "sha256sum " (shell-quote path) " | awk '{print $1}'")))

(define (scheme-string value)
  (let ((out (open-output-string)))
    (write value out)
    (get-output-string out)))

(define (generate-key! gnupg email)
  (let ((batch (path-join gnupg "key.batch")))
    (write-text
     batch
     (string-append
      "%no-protection\n"
      "Key-Type: RSA\n"
      "Key-Length: 2048\n"
      "Key-Usage: sign\n"
      "Name-Real: Kons Akku CLI Test\n"
      "Name-Email: " email "\n"
      "Expire-Date: 0\n"
      "%commit\n"))
    (run-command
     (string-append
      "GNUPGHOME=" (shell-quote gnupg)
      " gpg --batch --quiet --generate-key "
      (shell-quote batch)))))

(define (export-keyring! gnupg email keyring)
  (run-command (string-append "mkdir -p " (shell-quote (dirname keyring))))
  (run-command
   (string-append
    "GNUPGHOME=" (shell-quote gnupg)
    " gpg --batch --quiet --export " (shell-quote email)
    " > " (shell-quote keyring))))

(define (sign-file! gnupg email payload signature)
  (run-command
   (string-append
    "GNUPGHOME=" (shell-quote gnupg)
    " gpg --batch --yes --quiet --pinentry-mode loopback"
    " --local-user " (shell-quote email)
    " --detach-sign --output " (shell-quote signature)
    " " (shell-quote payload))))

(define (write-signed-index! archive-root gnupg email index-text)
  (let ((index (path-join archive-root "Akku-index.scm")))
    (reset-dir archive-root)
    (write-text index index-text)
    (let* ((sha1 (sha1-file index))
           (sig-dir (path-join archive-root
                               (string-append "by-sha1/"
                                              (substring sha1 0 2))))
           (sig (path-join sig-dir (string-append sha1 ".sig"))))
      (run-command (string-append "mkdir -p " (shell-quote sig-dir)))
      (sign-file! gnupg email index sig))))

(define (archive-url archive-root)
  (string-append "file://" archive-root "/"))

(define (write-akku-config! home archive-root)
  (write-text
   (path-join home "config/akku-sources.scm")
   (string-append
    "(akku-sources\n"
    "  (source (name \"akku\") (url " (scheme-string (archive-url archive-root)) ")))\n")))

(define (write-project! project-root)
  (write-text
   (path-join project-root "kons.scm")
   "(package
  (name (fixture app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")
  (write-text
   (path-join project-root "src/fixture/app.sld")
   "(define-library (fixture app) (export value) (import (scheme base)) (begin (define value 1)))\n"))

(define (write-directory-package! root name library)
  (write-text
   (path-join root "kons.scm")
   (string-append
    "(package (name " name ") (version \"1.0.0\") (source-path \"src\"))\n"
    "(dependencies)\n(dev-dependencies)\n"))
  (write-text
   (path-join root library)
   "(define-library (fixture dep) (export value) (import (scheme base)) (begin (define value 1)))\n"))

(define (command-status home cache project args out err)
  (shell-command-status
   (string-append
    "KONS_HOME=" (shell-quote home)
    " XDG_CACHE_HOME=" (shell-quote cache)
    " KONS_SCHEME=" (shell-quote selected-scheme)
    " " (shell-quote capy)
    " -L " (shell-quote load-path)
    " -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join project "kons.scm"))
    " --no-color "
    args
    " >" (shell-quote out)
    " 2>" (shell-quote err))))

(define (run-ok label home cache project args token)
  (let* ((base (path-join root (safe-store-token label)))
         (out (string-append base ".out"))
         (err (string-append base ".err"))
         (status (command-status home cache project args out err)))
    (when (not (= status 0))
      (display (read-text err)))
    (test-equal label 0 status)
    (test-assert (string-append label " output mentions " token)
                 (string-contains? (read-text out) token))
    out))

(define (run-fail label home cache project args token)
  (let* ((base (path-join root (safe-store-token label)))
         (out (string-append base ".out"))
         (err (string-append base ".err"))
         (status (command-status home cache project args out err)))
    (test-assert label (not (= status 0)))
    (test-assert (string-append label " error mentions " token)
                 (string-contains? (read-text err) token))
    err))

(define (prepare-keyrings!)
  (let* ((good-gnupg (path-join root "good-gnupg"))
         (bad-gnupg (path-join root "bad-gnupg"))
         (good-email "akku-cli-good@example.invalid")
         (bad-email "akku-cli-bad@example.invalid"))
    (reset-dir good-gnupg)
    (reset-dir bad-gnupg)
    (run-command (string-append "chmod 700 " (shell-quote good-gnupg)))
    (run-command (string-append "chmod 700 " (shell-quote bad-gnupg)))
    (generate-key! good-gnupg good-email)
    (generate-key! bad-gnupg bad-email)
    `((good-gnupg . ,good-gnupg)
      (bad-gnupg . ,bad-gnupg)
      (good-email . ,good-email)
      (bad-email . ,bad-email))))

(define (key-ref keys key)
  (cdr (assoc key keys)))

(define (install-trusted-key! keys home)
  (export-keyring!
   (key-ref keys 'good-gnupg)
   (key-ref keys 'good-email)
   (path-join home "config/akku/keys.d/trusted.gpg")))

(define (happy-index)
  "(import (akku format index))

(package (name \"flat-name\")
  (versions
    ((version \"1.0.0\")
     (lock (location (directory \"vendor/flat-name\")))
     (depends)
     (depends/dev)
     (conflicts))))

(package (name (chibi match))
  (versions
    ((version \"1.0.0\")
     (lock (location (directory \"vendor/chibi-match\")))
     (depends)
     (depends/dev)
     (conflicts))))
")

(define (checksum-index tar-url)
  (string-append
   "(import (akku format index))\n\n"
   "(package (name \"bad-url\")\n"
   "  (versions\n"
   "    ((version \"1.0.0\")\n"
   "     (lock (location (url " (scheme-string tar-url) "))\n"
   "           (content (sha256 \"0000000000000000000000000000000000000000000000000000000000000000\")))\n"
   "     (depends)\n"
   "     (depends/dev)\n"
   "     (conflicts))))\n"))

(define (write-tarball! path)
  (let ((payload (path-join root "payload")))
    (reset-dir payload)
    (write-text (path-join payload "kons.scm")
                "(package (name (fixture bad-url)) (version \"1.0.0\") (source-path \"src\"))\n(dependencies)\n(dev-dependencies)\n")
    (write-text (path-join payload "src/fixture/bad-url.sld")
                "(define-library (fixture bad-url) (export value) (import (scheme base)) (begin (define value 1)))\n")
    (run-command (string-append "tar -cf " (shell-quote path) " -C " (shell-quote payload) " ."))
    (sha256-file path)))

(reset-dir root)
(let ((keys (prepare-keyrings!)))
  (let* ((home (path-join root "home"))
         (cache (path-join root "cache"))
         (archive (path-join root "archive"))
         (project (path-join root "project")))
    (reset-dir home)
    (reset-dir cache)
    (reset-dir project)
    (install-trusted-key! keys home)
    (write-signed-index! archive (key-ref keys 'good-gnupg) (key-ref keys 'good-email) (happy-index))
    (write-akku-config! home archive)
    (write-project! project)
    (write-directory-package! (path-join project "vendor/flat-name") "(fixture flat-name)" "src/fixture/flat-name.sld")
    (write-directory-package! (path-join project "vendor/chibi-match") "(chibi match)" "src/chibi/match.sld")

    (run-ok "plan Akku package from source alias" home cache project
            "add --akku flat-name --registry akku --plan"
            "(source \"akku\")")
    (let ((flat-out (run-ok "add flat Akku package" home cache project
                            "add --akku flat-name"
                            "Akku package flat-name")))
      (test-assert "add flat Akku package output mentions version"
                   (string-contains? (read-text flat-out) "1.0.0"))
      (test-assert "add flat Akku package output mentions source kind"
                   (string-contains? (read-text flat-out) "directory"))
      (test-assert "add flat Akku package output mentions verified index"
                   (string-contains? (read-text flat-out) "verified-index"))
      (test-assert "add flat Akku package output mentions cache state"
                   (string-contains? (read-text flat-out) "cache-missing")))
    (let ((list-out (run-ok "add list Akku package" home cache project
                            (string-append "add --akku " (shell-quote "(chibi match)"))
                            "Akku package (chibi match)")))
      (test-assert "add list Akku package output mentions source kind"
                   (string-contains? (read-text list-out) "directory"))
      (test-assert "add list Akku package output mentions verified index"
                   (string-contains? (read-text list-out) "verified-index")))
    (delete-file (path-join project "kons.lock"))
    (run-ok "update displays Akku diagnostics" home cache project "update --offline" "verified-index")
    (run-ok "fetch displays Akku diagnostics" home cache project "fetch --locked --offline" "cache-ready")
    (run-ok "tree displays Akku source kind" home cache project "tree --offline" "source-kind directory")
    (run-ok "status displays Akku source kind" home cache project "status --offline" "source-kind directory")
    (run-ok "resolve displays locked Akku dependencies" home cache project "resolve --offline" "locked-dependencies")
    (run-ok "vendor displays Akku diagnostics" home cache project "vendor --plan --offline" "akku-sources")
    (run-command (string-append "rm -rf " (shell-quote (path-join home "store/akku/sources"))))
    (run-ok "status reports missing Akku cache" home cache project "status --offline" "cache missing")
    (run-ok "tree reports missing Akku cache" home cache project "tree --offline" "cache missing")
    (run-ok "resolve reports missing Akku cache" home cache project "resolve --offline" "cache missing")
    (run-ok "vendor reports missing Akku cache" home cache project "vendor --plan --offline" "cache missing")
    (run-fail "ambiguous Akku name syntax" home cache project
              "add --akku chibi/match --plan"
              "ambiguous Akku package name syntax")
    (write-project! project)
    (let* ((base (path-join root "stale-resolve"))
           (out (string-append base ".out"))
           (err (string-append base ".err"))
           (status (command-status home cache project "resolve --offline" out err)))
      (test-equal "resolve with stale lock exits" 0 status)
      (test-assert "resolve with stale lock hides locked dependencies"
                   (not (string-contains? (read-text out) "locked-dependencies"))))
    (let* ((base (path-join root "stale-resolve-json"))
           (out (string-append base ".out"))
           (err (string-append base ".err"))
           (status (command-status home cache project "resolve --offline --format json" out err)))
      (test-equal "resolve json with stale lock exits" 0 status)
      (test-assert "resolve json with stale lock hides locked dependencies"
                   (not (string-contains? (read-text out) "locked-dependencies")))))

  (let* ((home (path-join root "unknown-home"))
         (cache (path-join root "unknown-cache"))
         (project (path-join root "unknown-project")))
    (reset-dir home)
    (reset-dir cache)
    (reset-dir project)
    (install-trusted-key! keys home)
    (write-akku-config! home (path-join root "archive"))
    (write-project! project)
    (write-text
     (path-join project "kons.scm")
     "(package (name (fixture unknown)) (version \"0.1.0\") (source-path \"src\"))\n(dependencies (akku (name \"missing\") (version \"*\")))\n(dev-dependencies)\n")
    (run-command
     (string-append "cp -pR "
                    (shell-quote (path-join root "home/store"))
                    " "
                    (shell-quote (path-join home "store"))))
    (let ((err (run-fail "unknown Akku package" home cache project
                         "update --offline"
                         "unknown Akku package")))
      (test-assert "unknown Akku package hides internal string key"
                   (not (string-contains? (read-text err) "akku/string")))
      (test-assert "unknown Akku package hides internal package key"
                   (not (string-contains? (read-text err) "akku:akku")))))

  (let* ((home (path-join root "missing-cache-home"))
         (cache (path-join root "missing-cache-cache"))
         (project (path-join root "missing-cache-project")))
    (reset-dir home)
    (reset-dir cache)
    (reset-dir project)
    (install-trusted-key! keys home)
    (write-akku-config! home (path-join root "archive"))
    (write-project! project)
    (write-text
     (path-join project "kons.scm")
     "(package (name (fixture missing-cache)) (version \"0.1.0\") (source-path \"src\"))\n(dependencies (akku (name \"flat-name\") (version \"*\")))\n(dev-dependencies)\n")
    (run-fail "missing offline cache" home cache project "update --offline" "missing offline cache"))

  (let* ((home (path-join root "malformed-home"))
         (cache (path-join root "malformed-cache"))
         (archive (path-join root "malformed-archive"))
         (project (path-join root "malformed-project")))
    (reset-dir home)
    (reset-dir cache)
    (reset-dir project)
    (install-trusted-key! keys home)
    (write-signed-index! archive
                         (key-ref keys 'good-gnupg)
                         (key-ref keys 'good-email)
                         "(import (not akku format index))\n")
    (write-akku-config! home archive)
    (write-project! project)
    (run-fail "malformed Akku archive index" home cache project
              "add --akku flat-name"
              "malformed Akku archive index"))

  (let* ((home (path-join root "verify-home"))
         (cache (path-join root "verify-cache"))
         (archive (path-join root "verify-archive"))
         (project (path-join root "verify-project")))
    (reset-dir home)
    (reset-dir cache)
    (reset-dir project)
    (install-trusted-key! keys home)
    (write-signed-index! archive
                         (key-ref keys 'bad-gnupg)
                         (key-ref keys 'bad-email)
                         (happy-index))
    (write-akku-config! home archive)
    (write-project! project)
    (run-fail "verification failure" home cache project
              "add --akku flat-name"
              "verification failure"))

  (let* ((home (path-join root "checksum-home"))
         (cache (path-join root "checksum-cache"))
         (archive (path-join root "checksum-archive"))
         (project (path-join root "checksum-project"))
         (tarball (path-join root "bad-url.tar")))
    (reset-dir home)
    (reset-dir cache)
    (reset-dir project)
    (install-trusted-key! keys home)
    (write-tarball! tarball)
    (write-signed-index! archive
                         (key-ref keys 'good-gnupg)
                         (key-ref keys 'good-email)
                         (checksum-index (string-append "file://" tarball)))
    (write-akku-config! home archive)
    (write-project! project)
    (run-ok "add URL checksum package" home cache project "add --akku bad-url" "bad-url")
    (run-fail "checksum mismatch" home cache project
              "fetch --locked"
              "checksum mismatch")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku CLI")
  (exit (if (= failures 0) 0 1)))
