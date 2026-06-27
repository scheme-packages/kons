(define-library (kons akku registry)
  (export akku-index-metadata?
          akku-index-metadata-archive-url
          akku-index-metadata-sha1
          akku-index-metadata-index-path
          akku-index-metadata-signature-path
          akku-index-metadata-parsed-path
          akku-index-signature-relative-path
          akku-index-signature-url
          akku-metadata-root
          akku-archive-metadata-root
          akku-fetch-index!)
  (import (scheme base)
          (scheme file)
          (kons akku format)
          (kons akku registry-cache)
          (kons util))

  (begin
(define-record-type <akku-index-metadata>
  (make-akku-index-metadata archive-url sha1 index-path signature-path parsed-path)
  akku-index-metadata?
  (archive-url akku-index-metadata-archive-url)
  (sha1 akku-index-metadata-sha1)
  (index-path akku-index-metadata-index-path)
  (signature-path akku-index-metadata-signature-path)
  (parsed-path akku-index-metadata-parsed-path))

(define (store-root-for-home home)
  (path-join home "store"))

(define (akku-metadata-root . maybe-home)
  (path-join
   (path-join
    (if (pair? maybe-home)
        (store-root-for-home (car maybe-home))
        (kons-store-root))
    "akku")
   "metadata"))

(define (akku-archive-metadata-root archive-url . maybe-home)
  (path-join
   (if (pair? maybe-home)
       (akku-metadata-root (car maybe-home))
       (akku-metadata-root))
   (safe-store-token archive-url)))

(define (download-file! url output label)
  (run-command (string-append "mkdir -p " (shell-quote (dirname output))))
  (let ((status
         (shell-command-status
          (string-append
           "curl --connect-timeout 10 --max-time 120 -fsSL "
           (shell-quote url)
           " -o "
           (shell-quote output)
           " >/dev/null 2>&1"))))
    (unless (= status 0)
      (dependency-error label url))))

(define (validated-akku-index-datums path)
  (guard (exn
          ((error-object? exn)
           (dependency-error "malformed Akku archive index"
                             path
                             (error-object-message exn))))
    (read-akku-index path)
    (read-all-exprs path)))

(define (cached-index-metadata archive-url key-files root verifier)
  (let* ((index-path (index-cache-path root))
         (signature-path (signature-cache-path root))
         (parsed-path (parsed-cache-path root))
         (receipt-path (receipt-cache-path root)))
    (unless (and (file-exists? index-path)
                 (file-exists? signature-path)
                 (file-exists? parsed-path)
                 (file-exists? receipt-path))
      (dependency-error "missing offline cache for verified Akku archive index"
                        archive-url))
    (let* ((receipt (read-one-expr receipt-path))
           (sha1 (verified-receipt-sha1 receipt)))
      (unless (verifier index-path signature-path key-files)
        (dependency-error "Akku archive index verification failure for offline cache; run `kons update`"
                          archive-url))
      (unless (and sha1
                   (valid-sha1-text? sha1)
                   (string=? sha1 (sha1-file index-path)))
        (dependency-error "Akku archive index verification failure: offline cache does not match its trust receipt; run `kons update`"
                          archive-url))
      (validated-akku-index-datums index-path)
      (make-akku-index-metadata archive-url sha1 index-path signature-path parsed-path))))

(define (fetch-live-index! archive-url key-files root verifier)
  (let* ((tmp-index (temporary-file-path "kons-akku-index.scm"))
         (tmp-signature (temporary-file-path "kons-akku-index.sig")))
    (download-file! (archive-index-url archive-url)
                    tmp-index
                    "Akku archive index could not be fetched")
    (let* ((sha1 (sha1-file tmp-index))
           (signature-relative-path (akku-index-signature-relative-path sha1))
           (signature-url (akku-index-signature-url archive-url sha1)))
      (download-file! signature-url
                      tmp-signature
                      "Akku archive index signature could not be fetched")
      (unless (verifier tmp-index tmp-signature key-files)
        (dependency-error "Akku archive index verification failure: signature mismatch" archive-url))
      (let* ((index-path (index-cache-path root))
             (signature-path (signature-cache-path root))
             (parsed-path (parsed-cache-path root))
             (receipt-path (receipt-cache-path root))
             (datums (validated-akku-index-datums tmp-index)))
        (run-command (string-append "mkdir -p " (shell-quote root)))
        (copy-file! tmp-index index-path)
        (copy-file! tmp-signature signature-path)
        (write-parsed-cache! parsed-path archive-url sha1 signature-relative-path datums)
        (write-receipt! receipt-path archive-url sha1 signature-relative-path)
        (remove-file-if-exists! tmp-index)
        (remove-file-if-exists! tmp-signature)
        (make-akku-index-metadata archive-url sha1 index-path signature-path parsed-path)))))

(define (akku-fetch-index! archive-url key-files offline? . maybe-verifier)
  (let* ((root (akku-archive-metadata-root archive-url))
         (verifier (if (pair? maybe-verifier)
                       (car maybe-verifier)
                       verify-openpgp-detached-signature)))
    (if offline?
        (cached-index-metadata archive-url key-files root verifier)
        (fetch-live-index! archive-url key-files root verifier))))
))
