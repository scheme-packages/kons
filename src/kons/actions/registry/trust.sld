(define-library (kons actions registry trust)
  (export indexed-registry-trust-fields)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kons util)
          (kons compat json))

  (begin
(define (write-text-file path text)
  (call-with-output-file path
    (lambda (out)
      (display text out))))

(define (registry-trust-key-relative-path key-id)
  (path-join "keys" (string-append (safe-store-token key-id) ".pem")))

(define (registry-trust-key-path key-id)
  (path-join
   (path-join (kons-home) "config")
   (registry-trust-key-relative-path key-id)))

(define (write-registry-trust-key! key-id public-key)
  (let ((path (registry-trust-key-path key-id)))
    (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
    (write-text-file path public-key)
    (run-command (string-append "chmod 600 " (shell-quote path)))
    path))

(define (indexed-registry-trust-fields name index-data trust?)
  (if trust?
      (let* ((signing (json-ref index-data 'signing '()))
             (key-id (json-string-ref signing 'keyId ""))
             (public-key (json-string-ref signing 'publicKey "")))
        (when (or (string=? key-id "") (string=? public-key ""))
          (dependency-error
           "registry index response is missing signing key metadata"
           name))
        (write-registry-trust-key! key-id public-key)
        `((trust . required)
          (key-id . ,key-id)
          (key-file . ,(registry-trust-key-relative-path key-id))))
      '()))

))
