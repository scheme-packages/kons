(define-library (kons akku registry-cache)
  (export without-trailing-slash
    valid-sha1-text?
    akku-index-signature-relative-path
    akku-index-signature-url
    index-cache-path
    signature-cache-path
    parsed-cache-path
    receipt-cache-path
    archive-index-url
    sha1-file
    copy-file!
    remove-file-if-exists!
    verify-openpgp-detached-signature
    read-one-expr
    verified-receipt-sha1
    write-parsed-cache!
    write-receipt!)
  (import (scheme base)
    (scheme file)
    (scheme write)
    (kons compat files)
    (kons util))

  (begin
    (define (copy-file! source dest)
      (run-command
        (string-append "cp " (shell-quote source) " " (shell-quote dest))))

    (define (remove-file-if-exists! path)
      (when (file-exists? path)
        (delete-file path)))

    (define (without-trailing-slash text)
      (let ((len (string-length text)))
        (if (and (> len 0) (char=? (string-ref text (- len 1)) #\/))
          (substring text 0 (- len 1))
          text)))

    (define (hex-char? ch)
      (or (and (char>=? ch #\0) (char<=? ch #\9))
        (and (char>=? ch #\a) (char<=? ch #\f))
        (and (char>=? ch #\A) (char<=? ch #\F))))

    (define (valid-sha1-text? text)
      (and (string? text)
        (= (string-length text) 40)
        (let loop ((i 0))
          (cond
            ((= i 40) #t)
            ((hex-char? (string-ref text i)) (loop (+ i 1)))
            (else #f)))))

    (define (akku-index-signature-relative-path sha1)
      (unless (valid-sha1-text? sha1)
        (dependency-error "Akku archive index SHA-1 is invalid" sha1))
      (string-append "by-sha1/"
        (substring sha1 0 2)
        "/"
        sha1
        ".sig"))

    (define (akku-index-signature-url archive-url sha1)
      (string-append (without-trailing-slash archive-url)
        "/"
        (akku-index-signature-relative-path sha1)))

    (define (index-cache-path root)
      (path-join root "Akku-index.scm"))

    (define (signature-cache-path root)
      (path-join root "Akku-index.scm.sig"))

    (define (parsed-cache-path root)
      (path-join root "Akku-index.parsed.scm"))

    (define (receipt-cache-path root)
      (path-join root "verified.scm"))

    (define (archive-index-url archive-url)
      (string-append (without-trailing-slash archive-url) "/Akku-index.scm"))

    (define (sha1-file path)
      (capture-first-line
        (string-append "sha1sum " (shell-quote path) " | awk '{print $1}'")))

    (define default-akku-archive-key-file "akku-archive-2018.gpg")

    (define (configured-akku-key-files-in keys-dir)
      (let* (
             (result
               (capture-command-lines/status
                 (string-append
                   "if [ -d "
                   (shell-quote keys-dir)
                   " ]; then "
                   "find "
                   (shell-quote keys-dir)
                   " -type f \\( -name '*.gpg' -o -name '*.pgp' \\) | LC_ALL=C sort; "
                   "fi"))))
        (if (= (car result) 0) (cadr result) '())))

    (define (configured-akku-key-files)
      (configured-akku-key-files-in
        (path-join (path-join (path-join (kons-home) "config") "akku") "keys.d")))

    (define (default-akku-key-file-paths)
      (list
        (path-join
          (path-join (path-join (path-join (kons-home) "lib") "bin") "kons")
          (path-join
            (path-join (path-join "src" "kons") "akku")
            (path-join "keys.d" default-akku-archive-key-file)))
        (path-join
          (path-join (path-join (path-join (kons-home) "lib") "kons") "src")
          (path-join
            (path-join "kons" "akku")
            (path-join "keys.d" default-akku-archive-key-file)))
        (path-join
          (current-directory)
          (path-join
            (path-join (path-join "src" "kons") "akku")
            (path-join "keys.d" default-akku-archive-key-file)))))

    (define (existing-key-files paths)
      (let loop ((items paths) (out '()))
        (cond
          ((null? items) (reverse out))
          ((file-exists? (car items)) (loop (cdr items) (cons (car items) out)))
          (else (loop (cdr items) out)))))

    (define (member-string? value values)
      (let loop ((items values))
        (cond
          ((null? items) #f)
          ((string=? value (car items)) #t)
          (else (loop (cdr items))))))

    (define (dedupe-key-files files)
      (let loop ((items files) (out '()))
        (cond
          ((null? items) (reverse out))
          ((member-string? (car items) out) (loop (cdr items) out))
          (else (loop (cdr items) (cons (car items) out))))))

    (define (default-akku-key-files)
      (existing-key-files (default-akku-key-file-paths)))

    (define (normalize-key-files key-files)
      (cond
        ((not key-files) (dedupe-key-files
                          (append (configured-akku-key-files)
                            (default-akku-key-files))))
        ((list? key-files) key-files)
        (else (dependency-error "Akku trusted keyring list is invalid" key-files))))

    (define (gpgv-keyring-args key-files)
      (let loop ((items key-files) (out ""))
        (if (null? items)
          out
          (loop (cdr items)
            (string-append out
              " --keyring "
              (shell-quote (car items)))))))

    (define (verify-openpgp-detached-signature payload signature key-files)
      (let ((keys (normalize-key-files key-files)))
        (when (null? keys)
          (dependency-error "trusted Akku OpenPGP keyring is required"))
        (for-each
          (lambda (key)
            (unless (string? key)
              (dependency-error "trusted Akku OpenPGP keyring path is invalid" key))
            (unless (file-exists? key)
              (dependency-error "trusted Akku OpenPGP keyring is missing" key)))
          keys)
        (= (shell-command-status
            (string-append
              "gpgv --quiet"
              (gpgv-keyring-args keys)
              " "
              (shell-quote signature)
              " "
              (shell-quote payload)
              " >/dev/null 2>&1"))
          0)))

    (define (read-one-expr path)
      (let ((exprs (read-all-exprs path)))
        (if (pair? exprs) (car exprs) '())))

    (define (receipt-field receipt key default)
      (let ((found (and (pair? receipt)
                    (assq key (cdr receipt)))))
        (cond
          ((and found (pair? (cdr found))) (cadr found))
          (else default))))

    (define (verified-receipt-sha1 receipt)
      (and (pair? receipt)
        (eq? (car receipt) 'verified-akku-index)
        (receipt-field receipt 'sha1 #f)))

    (define (write-parsed-cache! parsed-path archive-url sha1 signature-relative-path datums)
      (run-command (string-append "mkdir -p " (shell-quote (dirname parsed-path))))
      (remove-file-if-exists! parsed-path)
      (call-with-output-file parsed-path
        (lambda (out)
          (write
            `(akku-index
              (archive-url ,archive-url)
              (sha1 ,sha1)
              (signature-path ,signature-relative-path)
              (datums ,@datums))
            out)
          (newline out))))

    (define (write-receipt! receipt-path archive-url sha1 signature-relative-path)
      (remove-file-if-exists! receipt-path)
      (call-with-output-file receipt-path
        (lambda (out)
          (write
            `(verified-akku-index
              (archive-url ,archive-url)
              (sha1 ,sha1)
              (signature-path ,signature-relative-path))
            out)
          (newline out))))))
