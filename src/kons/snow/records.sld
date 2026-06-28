(define-library (kons snow records)
  (export make-snow-package
    snow-package?
    snow-package-name
    snow-package-version
    snow-package-url
    snow-package-sha256
    snow-package-size
    snow-package-description
    snow-package-libraries
    make-snow-library
    snow-library?
    snow-library-name
    snow-library-path
    snow-library-depends)
  (import (scheme base))

  (begin
    (define-record-type <snow-package>
      (make-snow-package name version url sha256 size description libraries)
      snow-package?
      (name snow-package-name)
      (version snow-package-version)
      (url snow-package-url)
      (sha256 snow-package-sha256)
      (size snow-package-size)
      (description snow-package-description)
      (libraries snow-package-libraries))

    (define-record-type <snow-library>
      (make-snow-library name path depends)
      snow-library?
      (name snow-library-name)
      (path snow-library-path)
      (depends snow-library-depends))))
