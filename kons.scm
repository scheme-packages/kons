(package
  (name (scheme-packages kons))
  (version "0.2.0")
  (license "MIT")
  (description "Scheme package manager and build system")
  (dialects r7rs)
  (source-path "src"))

(dependencies
  (git 
    (name (args))
    (url "https://github.com/playx18/scm-args.git")))

(dev-dependencies)

(overrides)
