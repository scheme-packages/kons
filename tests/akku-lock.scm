(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (srfi 64)
        (kons akku format)
        (kons lock)
        (kons util))

(test-begin "kons Akku lock")

(define root "/tmp/kons-akku-lock-test")
(define archive-root (path-join root "archive"))
(define home-root (path-join root "home"))
(define cache-root (path-join root "cache"))
(define project-root (path-join root "project"))
(define output-path (path-join root "update.out"))
(define repo-root (current-directory))
(define load-path (string-append repo-root "/vendor/scm-args/src,"
                                  repo-root "/vendor/conduit/src,"
                                  repo-root "/src"))
(define capy (or (get-environment-variable "CAPY") "capy"))

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

(define (generate-key! gnupg)
  (let ((batch (path-join root "key.batch")))
    (write-text
     batch
     (string-append
      "%no-protection\n"
      "Key-Type: RSA\n"
      "Key-Length: 2048\n"
      "Key-Usage: sign\n"
      "Name-Real: Kons Akku Lock Test\n"
      "Name-Email: akku-lock@example.invalid\n"
      "Expire-Date: 0\n"
      "%commit\n"))
    (run-command
     (string-append
      "GNUPGHOME=" (shell-quote gnupg)
      " gpg --batch --quiet --generate-key "
      (shell-quote batch)))))

(define (export-keyring! gnupg keyring)
  (run-command (string-append "mkdir -p " (shell-quote (dirname keyring))))
  (run-command
   (string-append
    "GNUPGHOME=" (shell-quote gnupg)
    " gpg --batch --quiet --export akku-lock@example.invalid > "
    (shell-quote keyring))))

(define (sign-file! gnupg payload signature)
  (run-command
   (string-append
    "GNUPGHOME=" (shell-quote gnupg)
    " gpg --batch --yes --quiet --pinentry-mode loopback"
    " --local-user akku-lock@example.invalid"
    " --detach-sign --output " (shell-quote signature)
    " " (shell-quote payload))))

(define (archive-url path)
  (string-append "file://" path "/"))

(define (prepare-signed-archive!)
  (let* ((gnupg (path-join root "gnupg"))
         (trusted (path-join home-root "config/akku/keys.d/trusted.gpg"))
         (index (path-join archive-root "Akku-index.scm")))
    (reset-dir archive-root)
    (reset-dir gnupg)
    (run-command (string-append "chmod 700 " (shell-quote gnupg)))
    (write-text
     index
     "(import (akku format index))

(package (name \"flat-name\")
  (versions
    ((version \"1.2.0\")
     (lock (location (git \"https://example.invalid/flat.git\"))
           (tag \"v1.2.0\")
           (revision \"abc123\"))
     (depends (direct-leaf \"^1.0\"))
     (depends/dev (dev-only \"^1.0\"))
     (conflicts (old-flat \"<1.0\")))))

(package (name \"direct-leaf\")
  (versions
    ((version \"1.0.0\")
     (lock (location (url \"https://example.invalid/direct-leaf.tar.gz\"))
           (content (sha256 \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\")))
     (depends)
     (depends/dev)
     (conflicts))))

(package (name (chibi match))
  (versions
    ((version \"0.7.0\")
     (lock (location (directory \"vendor/chibi-match\")))
     (depends)
     (depends/dev)
     (conflicts))))
")
    (generate-key! gnupg)
    (export-keyring! gnupg trusted)
    (let* ((sha1 (sha1-file index))
           (sig-dir (path-join archive-root
                               (string-append "by-sha1/"
                                              (substring sha1 0 2))))
           (sig (path-join sig-dir (string-append sha1 ".sig"))))
      (run-command (string-append "mkdir -p " (shell-quote sig-dir)))
      (sign-file! gnupg index sig)
      (archive-url archive-root))))

(define (prepare-project! source-url)
  (write-text
   (path-join home-root "config/akku-sources.scm")
   (string-append
    "(akku-sources\n"
    "  (source (name \"fixture\") (url " (scheme-string source-url) ")))\n"))
  (write-text
   (path-join project-root "kons.scm")
   "(package
  (name (fixture app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (akku (name \"flat-name\") (version \"^1.0\") (source \"fixture\"))
  (akku (name (chibi match)) (version \"0.7.0\") (source \"fixture\")))
")
  (write-text (path-join project-root "src/fixture/app.sld")
              "(define-library (fixture app) (export) (import (scheme base)))\n"))

(define (scheme-string value)
  (let ((out (open-output-string)))
    (write value out)
    (get-output-string out)))

(define (run-update!)
  (shell-command-status
   (string-append
    "KONS_HOME=" (shell-quote home-root)
    " XDG_CACHE_HOME=" (shell-quote cache-root)
    " KONS_SCHEME=capy "
    (shell-quote capy)
    " -L " (shell-quote load-path)
    " -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join project-root "kons.scm"))
    " --no-color update >"
    (shell-quote output-path)
    " 2>&1")))

(define (entry-by-name entries name)
  (let loop ((items entries))
    (cond
     ((null? items) #f)
     ((equal? (lock-entry-ref (car items) 'name #f) name) (car items))
     (else (loop (cdr items))))))

(define (entry-type-count entries type)
  (let loop ((items entries) (count 0))
    (cond
     ((null? items) count)
     ((eq? (lock-entry-type (car items)) type)
      (loop (cdr items) (+ count 1)))
     (else (loop (cdr items) count)))))

(define (raises-message-containing? text thunk)
  (guard (exn
          ((and (error-object? exn)
                (string-contains? (error-object-message exn) text))
           #t)
          (else #f))
    (thunk)
    #f))

(reset-dir root)
(reset-dir home-root)
(reset-dir cache-root)
(let ((source-url (prepare-signed-archive!)))
  (prepare-project! source-url)
  (test-equal "lock update succeeds for Akku dependencies"
              0
              (run-update!))
  (when (not (file-exists? (path-join project-root "kons.lock")))
    (display (read-text output-path)))
  (let* ((lock (read-lockfile (path-join project-root "kons.lock")))
         (entries (lock-package-entries lock))
         (flat (entry-by-name entries "flat-name"))
         (list-entry (entry-by-name entries '(chibi match)))
         (leaf (entry-by-name entries "direct-leaf")))
    (test-equal "Akku package count includes transitive dependency"
                3
                (entry-type-count entries 'akku))
    (test-assert "flat Akku entry is locked" flat)
    (test-equal "flat Akku key" "akku/string/flat-name" (lock-entry-ref flat 'key #f))
    (test-equal "flat Akku version" "1.2.0" (lock-entry-ref flat 'version #f))
    (test-equal "flat Akku source alias" "fixture" (lock-entry-ref flat 'source #f))
    (test-equal "flat Akku source URL" source-url (lock-entry-ref flat 'source-url #f))
    (test-equal "flat Akku source kind" 'git (lock-entry-ref flat 'source-kind #f))
    (test-equal "flat Akku git remote"
                "https://example.invalid/flat.git"
                (lock-entry-ref flat 'remote #f))
    (test-equal "flat Akku tag" "v1.2.0" (lock-entry-ref flat 'tag #f))
    (test-equal "flat Akku revision" "abc123" (lock-entry-ref flat 'revision #f))
    (test-equal "flat Akku dependency metadata"
                '((direct-leaf "^1.0"))
                (lock-entry-ref flat 'depends #f))
    (test-assert "flat Akku source cache path"
                 (string-contains? (lock-entry-ref flat 'source-cache-path "")
                                   "/store/akku/sources/"))
    (test-assert "list-shaped Akku entry is locked" list-entry)
    (test-equal "list-shaped Akku name round-trips"
                '(chibi match)
                (lock-entry-ref list-entry 'name #f))
    (test-equal "list-shaped Akku key"
                "akku/list/chibi/match"
                (lock-entry-ref list-entry 'key #f))
    (test-equal "list-shaped Akku source kind"
                'directory
                (lock-entry-ref list-entry 'source-kind #f))
    (test-equal "list-shaped Akku source path"
                "vendor/chibi-match"
                (lock-entry-ref list-entry 'path #f))
    (test-assert "URL Akku transitive entry is locked" leaf)
    (test-equal "URL Akku source kind" 'url (lock-entry-ref leaf 'source-kind #f))
    (test-equal "URL Akku sha256"
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                (lock-entry-ref leaf 'url-sha256 #f))))

(define bad-lock-path (path-join root "bad-Akku.lock"))
(write-text bad-lock-path "(import (not akku format lockfile))\n(projects)\n")
(test-assert "unsupported Akku.lock import shape raises diagnostic"
             (raises-message-containing?
              "Akku format parse error: wrong import header"
              (lambda () (read-akku-lock bad-lock-path))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons Akku lock")
  (exit (if (= failures 0) 0 1)))
