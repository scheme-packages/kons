(package
  (name (ci build-hooks))
  (version "0.1.0")
  (license "MIT")
  (description "build hook integration")
  (dialects r7rs)
  (source-path "src")
  (main "main.scm")
  (tests "tests/main.scm")
  (build-hooks
    (scheme "build.scm")))

(dependencies
  (system (scheme base) (scheme write)))

(dev-dependencies)
