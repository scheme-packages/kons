(package
  (name (ci features))
  (version "0.1.0")
  (license "MIT")
  (description "feature integration")
  (dialects r7rs)
  (source-path "src")
  (main "main.scm")
  (tests "tests/main.scm")
  (features
    (default)
    (tls)))

(dependencies
  (system (scheme base) (scheme write)))

(dev-dependencies)

(cond-expand
  ((and (feature tls) unix)
   (dependencies
     (system (scheme case-lambda))))
  (else
   (dependencies
     (system (scheme cxr)))))
