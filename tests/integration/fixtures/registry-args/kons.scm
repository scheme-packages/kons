(package
  (name (ci registry))
  (version "0.1.0")
  (license "MIT")
  (description "registry integration")
  (dialects r7rs)
  (source-path "src")
  (main "main.scm")
  (tests "tests/main.scm"))

(dependencies
  (system (scheme base) (scheme write))
  (registry
    (name (args))
    (version "^0.1")))

(dev-dependencies)
