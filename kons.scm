(package
  (name (scheme-packages kons))
  (version "0.2.0")
  (license "MIT")
  (description "Scheme package manager and build system")
  (dialects r7rs)
  (source-path "src")
  (tests
    "tests/implementation.scm"
    "tests/jobs.scm"
    "tests/lock.scm"
    "tests/library-discovery.scm"
    "tests/resolver.scm"))

(dependencies
  (registry
    (name (conduit))
    (version "^0.1"))
  (registry
    (name (args))
    (version "^0.1")))

(dev-dependencies)

