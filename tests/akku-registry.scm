(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (srfi 64)
        (kons akku registry)
        (kons util))

(test-begin "kons akku registry")

(define repo-root (current-directory))
(define load-path (string-append repo-root "/vendor/scm-args/src,"
                                  repo-root "/vendor/conduit/src,"
                                  repo-root "/src"))
(define capy (or (get-environment-variable "CAPY") "capy"))

(define (write-text path text)
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

(define (fixture-index-text)
  "(import (akku format index))
(package (name \"fixture\") (versions ((version \"1.0.0\"))))
")

(define (generate-key! home name email)
  (let ((batch (path-join home "key.batch")))
    (write-text
     batch
     (string-append
      "%no-protection\n"
      "Key-Type: RSA\n"
      "Key-Length: 2048\n"
      "Key-Usage: sign\n"
      "Name-Real: " name "\n"
      "Name-Email: " email "\n"
      "Expire-Date: 0\n"
      "%commit\n"))
    (run-command
     (string-append
      "GNUPGHOME=" (shell-quote home)
      " gpg --batch --quiet --generate-key "
      (shell-quote batch)))))

(define (export-keyring! home email keyring)
  (run-command
   (string-append
    "GNUPGHOME=" (shell-quote home)
    " gpg --batch --quiet --export "
    (shell-quote email)
    " > "
    (shell-quote keyring))))

(define (sign-file! home email payload signature)
  (run-command
   (string-append
    "GNUPGHOME=" (shell-quote home)
    " gpg --batch --yes --quiet --pinentry-mode loopback"
    " --local-user " (shell-quote email)
    " --detach-sign --output " (shell-quote signature)
    " " (shell-quote payload))))

(define (sha1-file path)
  (capture-first-line
   (string-append "sha1sum " (shell-quote path) " | awk '{print $1}'")))

(define (archive-url path)
  (string-append "file://" path "/"))

(define (prepare-signed-archive! root . maybe-index-text)
  (let* ((archive (path-join root "archive"))
         (gnupg (path-join root "gnupg"))
         (trusted (path-join root "trusted.gpg"))
         (index (path-join archive "Akku-index.scm")))
    (reset-dir archive)
    (reset-dir gnupg)
    (run-command (string-append "chmod 700 " (shell-quote gnupg)))
    (write-text index (if (pair? maybe-index-text)
                          (car maybe-index-text)
                          (fixture-index-text)))
    (generate-key! gnupg "Kons Akku Test" "akku-test@example.invalid")
    (export-keyring! gnupg "akku-test@example.invalid" trusted)
    (let* ((sha1 (sha1-file index))
           (sig-dir (path-join archive
                               (string-append "by-sha1/"
                                              (substring sha1 0 2))))
           (sig (path-join sig-dir (string-append sha1 ".sig"))))
      (run-command (string-append "mkdir -p " (shell-quote sig-dir)))
      (sign-file! gnupg "akku-test@example.invalid" index sig)
      `((archive . ,archive)
        (url . ,(archive-url archive))
        (keyring . ,trusted)
        (index . ,index)
        (sha1 . ,sha1)
        (signature . ,sig)))))

(define (run-child source home)
  (let ((script (path-join home "child.scm")))
    (write-text script source)
    (shell-command-status
     (string-append
      "KONS_HOME=" (shell-quote home)
      " " (shell-quote capy)
      " -L " (shell-quote load-path)
      " -s " (shell-quote script)
      " >/dev/null 2>&1"))))

(define (scheme-string value)
  (let ((out (open-output-string)))
    (write value out)
    (get-output-string out)))

(define (child-fetch-source url keyring offline?)
  (string-append
   "(import (scheme base) (kons akku registry))\n"
   "(akku-fetch-index! "
   (scheme-string url)
   " (list "
   (scheme-string keyring)
   ") "
   (if offline? "#t" "#f")
   ")\n"))

(define (write-forged-receipt! cache-root url sha1)
  (write-text
   (path-join cache-root "verified.scm")
   (string-append
    "(verified-akku-index\n"
    "  (archive-url " (scheme-string url) ")\n"
    "  (sha1 " (scheme-string sha1) ")\n"
    "  (signature-path "
    (scheme-string (akku-index-signature-relative-path sha1))
    "))\n")))

(test-equal "signature relative path uses first two sha1 characters"
  "by-sha1/ab/abcdef0123456789abcdef0123456789abcdef01.sig"
  (akku-index-signature-relative-path
   "abcdef0123456789abcdef0123456789abcdef01"))

(let* ((root "/tmp/kons-akku-registry-test")
       (home (kons-home))
       (fixture (prepare-signed-archive! root))
       (url (cdr (assoc 'url fixture)))
       (keyring (cdr (assoc 'keyring fixture)))
       (sha1 (cdr (assoc 'sha1 fixture))))
  (reset-dir home)
  (let ((metadata (akku-fetch-index! url (list keyring) #f)))
    (test-assert "live verified fetch returns metadata record"
      (akku-index-metadata? metadata))
    (test-equal "live verified fetch records sha1"
      sha1
      (akku-index-metadata-sha1 metadata))
    (test-assert "verified index bytes are cached"
      (file-exists? (akku-index-metadata-index-path metadata)))
    (test-assert "parsed metadata cache is written"
      (file-exists? (akku-index-metadata-parsed-path metadata)))
    (test-assert "parsed metadata contains archive import"
      (string-contains?
       (read-text (akku-index-metadata-parsed-path metadata))
       "(import (akku format index))")))

  (run-command (string-append "rm -rf " (shell-quote (cdr (assoc 'archive fixture)))))
  (test-equal "offline mode accepts previously verified cache"
    0
    (run-child (child-fetch-source url keyring #t) home))
  (write-text
   (path-join (akku-archive-metadata-root url home) "Akku-index.scm")
   "(import (akku format index))\n(package (name \"tampered\"))\n")
  (test-assert "offline mode rejects stale verified cache bytes"
    (not (= 0 (run-child (child-fetch-source url keyring #t) home))))
  (let* ((cache-root (akku-archive-metadata-root url home))
         (tampered-index (path-join cache-root "Akku-index.scm")))
    (write-forged-receipt! cache-root url (sha1-file tampered-index))
    (test-assert "offline mode rejects forged receipt for tampered cache bytes"
      (not (= 0 (run-child (child-fetch-source url keyring #t) home)))))

  (let ((unverified-home (path-join root "unverified-home")))
    (reset-dir unverified-home)
    (run-command
     (string-append
      "mkdir -p "
      (shell-quote (akku-archive-metadata-root url unverified-home))))
    (write-text
     (path-join (akku-archive-metadata-root url unverified-home) "Akku-index.scm")
     (fixture-index-text))
    (test-assert "offline mode rejects unverified cache without trust receipt"
      (not (= 0 (run-child (child-fetch-source url keyring #t) unverified-home))))))

(let* ((root "/tmp/kons-akku-registry-missing-signature-test")
       (home (path-join root "home"))
       (fixture (prepare-signed-archive! root)))
  (reset-dir home)
  (delete-file (cdr (assoc 'signature fixture)))
  (test-assert "live fetch rejects missing signature"
    (not (= 0
            (run-child
             (child-fetch-source (cdr (assoc 'url fixture))
                                 (cdr (assoc 'keyring fixture))
                                 #f)
             home)))))

(let* ((root "/tmp/kons-akku-registry-bad-signature-test")
       (home (path-join root "home"))
       (fixture (prepare-signed-archive! root)))
  (reset-dir home)
  (write-text (cdr (assoc 'signature fixture)) "not a valid signature")
  (test-assert "live fetch rejects bad signature"
    (not (= 0
            (run-child
             (child-fetch-source (cdr (assoc 'url fixture))
                                 (cdr (assoc 'keyring fixture))
                                 #f)
             home)))))

(let* ((root "/tmp/kons-akku-registry-malformed-index-test")
       (home (path-join root "home"))
       (fixture (prepare-signed-archive!
                 root
                 "(import (not akku format index))
(package (name \"fixture\") (versions (version \"1.0.0\")))
")))
  (reset-dir home)
  (test-assert "live fetch rejects signed malformed index header"
    (not (= 0
            (run-child
             (child-fetch-source (cdr (assoc 'url fixture))
                                 (cdr (assoc 'keyring fixture))
                                 #f)
             home)))))

(let* ((root "/tmp/kons-akku-registry-malformed-package-body-test")
       (home (path-join root "home"))
       (fixture (prepare-signed-archive!
                 root
                 "(import (akku format index))
(package (name \"fixture\"))
")))
  (reset-dir home)
  (test-assert "live fetch rejects signed malformed package body"
    (not (= 0
            (run-child
             (child-fetch-source (cdr (assoc 'url fixture))
                                 (cdr (assoc 'keyring fixture))
                                 #f)
             home)))))

(let* ((root "/tmp/kons-akku-registry-malformed-version-body-test")
       (home (path-join root "home"))
       (fixture (prepare-signed-archive!
                 root
                 "(import (akku format index))
(package (name \"fixture\") (versions ((version 1))))
")))
  (reset-dir home)
  (test-assert "live fetch rejects signed malformed version body"
    (not (= 0
            (run-child
             (child-fetch-source (cdr (assoc 'url fixture))
                                 (cdr (assoc 'keyring fixture))
                                 #f)
             home)))))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons akku registry")
  (exit (if (= failures 0) 0 1)))
