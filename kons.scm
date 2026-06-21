(package
  (name (scheme-packages kons))
  (version "0.2.0")
  (license "MIT")
  (description "Scheme package manager and build system")
  (dialects r7rs)
  (source-path "src"))

(dependencies
  (registry
    (name (conduit))
    (version "^0.1"))
  (registry
    (name (args))
    (version "^0.1")))

(dev-dependencies)

(overrides)
