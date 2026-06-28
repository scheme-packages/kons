(define-library (kons snow config)
  (export default-snow-source-alias
    default-snow-repository-url
    snow-repository-url
    snow-metadata-root
    snow-sources-root)
  (import (scheme base)
    (kons util))

  (begin
    (define default-snow-source-alias "snow")
    (define default-snow-repository-url "https://snow-fort.org/s/repo.scm")

    (define (snow-repository-url source)
      (cond
        ((or (not source) (string=? source "") (string=? source default-snow-source-alias))
          default-snow-repository-url)
        ((or (string-contains? source "://") (string-prefix? "/" source))
          source)
        (else source)))

    (define (snow-metadata-root . maybe-home)
      (path-join
        (path-join
          (if (pair? maybe-home)
            (path-join (car maybe-home) "store")
            (kons-store-root))
          "snow")
        "metadata"))

    (define (snow-sources-root)
      (path-join (path-join (kons-store-root) "snow") "sources"))))
