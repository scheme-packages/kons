(define-library (kons akku records)
  (export make-akku-package
          akku-package?
          akku-package-name
          akku-package-versions
          make-akku-version
          akku-version?
          akku-version-number
          akku-version-synopsis
          akku-version-description
          akku-version-authors
          akku-version-homepage
          akku-version-license
          akku-version-scripts
          akku-version-lock
          akku-version-source
          akku-version-depends
          akku-version-depends/dev
          akku-version-conflicts
          akku-version-properties
          make-akku-lock-project
          akku-lock-project?
          akku-lock-project-name
          akku-lock-project-location
          akku-lock-project-install
          akku-lock-project-installer
          akku-lock-project-scripts
          akku-lock-project-tag
          akku-lock-project-revision
          akku-lock-project-content)
  (import (scheme base))

  (begin
(define-record-type <akku-package>
  (make-akku-package name versions)
  akku-package?
  (name akku-package-name)
  (versions akku-package-versions))

(define-record-type <akku-version>
  (make-akku-version number synopsis description authors homepage license
                     scripts lock source depends depends/dev conflicts properties)
  akku-version?
  (number akku-version-number)
  (synopsis akku-version-synopsis)
  (description akku-version-description)
  (authors akku-version-authors)
  (homepage akku-version-homepage)
  (license akku-version-license)
  (scripts akku-version-scripts)
  (lock akku-version-lock)
  (source akku-version-source)
  (depends akku-version-depends)
  (depends/dev akku-version-depends/dev)
  (conflicts akku-version-conflicts)
  (properties akku-version-properties))

(define-record-type <akku-lock-project>
  (make-akku-lock-project name location install installer scripts tag revision content)
  akku-lock-project?
  (name akku-lock-project-name)
  (location akku-lock-project-location)
  (install akku-lock-project-install)
  (installer akku-lock-project-installer)
  (scripts akku-lock-project-scripts)
  (tag akku-lock-project-tag)
  (revision akku-lock-project-revision)
  (content akku-lock-project-content))

))
