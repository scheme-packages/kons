(define-library (kons akku config)
  (export default-akku-source-alias
    default-akku-source-url
    akku-sources-path
    akku-source-list
    write-akku-source-list!
    akku-source-url
    akku-metadata-root
    akku-sources-root)
  (import (scheme base)
    (scheme file)
    (kons util))

  (begin
    (define default-akku-source-alias "akku")
    (define default-akku-source-url "https://archive.akkuscm.org/archive/")

    (define (akku-config-root)
      (path-join (kons-home) "config"))

    (define (akku-sources-path)
      (path-join (akku-config-root) "akku-sources.scm"))

    (define (read-one-expr path default)
      (if (file-exists? path)
        (let ((exprs (read-all-exprs path)))
          (if (null? exprs) default (car exprs)))
        default))

    (define (source-entry? value)
      (and (pair? value) (eq? (car value) 'source)))

    (define (source-entry-name entry)
      (field-ref (cdr entry) 'name ""))

    (define (source-entry-url entry)
      (field-ref (cdr entry) 'url ""))

    (define (default-source-entry)
      `(source
        (name ,default-akku-source-alias)
        (url ,default-akku-source-url)))

    (define (configured-akku-source-list)
      (let ((expr (read-one-expr (akku-sources-path) '(akku-sources))))
        (if (and (pair? expr) (eq? (car expr) 'akku-sources))
          (filter source-entry? (cdr expr))
          '())))

    (define (default-source-configured? sources)
      (let loop ((items sources))
        (cond
          ((null? items) #f)
          ((string=? (source-entry-name (car items)) default-akku-source-alias) #t)
          (else (loop (cdr items))))))

    (define (akku-source-list)
      (let ((sources (configured-akku-source-list)))
        (if (default-source-configured? sources)
          sources
          (cons (default-source-entry) sources))))

    (define (write-akku-source-list! sources)
      (run-command (string-append "mkdir -p " (shell-quote (akku-config-root))))
      (write-expr-file (akku-sources-path) (cons 'akku-sources sources)))

    (define (absolute-http-url? text)
      (or (string-prefix? "http://" text)
        (string-prefix? "https://" text)))

    (define (with-trailing-slash text)
      (let ((len (string-length text)))
        (if (and (> len 0) (char=? (string-ref text (- len 1)) #\/))
          text
          (string-append text "/"))))

    (define (find-akku-source-entry name)
      (let loop ((items (akku-source-list)))
        (cond
          ((null? items) #f)
          ((string=? (source-entry-name (car items)) name) (car items))
          (else (loop (cdr items))))))

    (define (akku-source-url source)
      (cond
        ((or (not source) (string=? source "")) default-akku-source-url)
        ((absolute-http-url? source) (with-trailing-slash source))
        (else
          (let ((entry (find-akku-source-entry source)))
            (unless entry (dependency-error "unknown Akku source" source))
            (with-trailing-slash (source-entry-url entry))))))

    (define (akku-store-root)
      (path-join (kons-store-root) "akku"))

    (define (akku-metadata-root)
      (path-join (akku-store-root) "metadata"))

    (define (akku-sources-root)
      (path-join (akku-store-root) "sources"))))
