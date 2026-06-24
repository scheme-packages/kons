(import (scheme base)
        (scheme file)
        (srfi 64)
        (kons util))

(test-begin "kons graph")

(define root "/tmp/kons-graph-test")
(define dep-root (path-join root "deps/helper"))
(define dot-path (path-join root "graph.dot"))
(define json-path (path-join root "graph.json"))

(define (write-file path text)
  (run-command (string-append "mkdir -p " (shell-quote (dirname path))))
  (call-with-output-file path
    (lambda (out) (display text out))))

(define (command-status command output-path)
  (shell-command-status
   (string-append
    "KONS_HOME="
    (shell-quote (path-join root "home"))
    " XDG_CACHE_HOME="
    (shell-quote (path-join root "cache"))
    " KONS_SCHEME=capy capy -L vendor/scm-args/src,vendor/conduit/src,src -s src/kons/main.scm -- --manifest "
    (shell-quote (path-join root "kons.scm"))
    " "
    command
    " >"
    (shell-quote output-path))))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example graph-app))
  (version \"0.1.0\")
  (source-path \"src\"))

(dependencies
  (path (name (example graph-helper)) (path \"deps/helper\")))
(dev-dependencies)
")

(write-file
 (path-join root "src/example/graph-app.sld")
 "(define-library (example graph-app)
  (export value)
  (import (scheme base) (example graph-helper))
  (begin (define value helper-value)))
")

(write-file
 (path-join dep-root "kons.scm")
 "(package
  (name (example graph-helper))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join dep-root "src/example/graph-helper.sld")
 "(define-library (example graph-helper)
  (export helper-value)
  (import (scheme base))
  (begin (define helper-value 1)))
")

(test-equal
 "graph dot command exits"
 0
 (command-status "graph --format dot" dot-path))

(test-equal
 "graph dot has Graphviz header and root edge"
 0
 (shell-command-status
  (string-append
   "node -e 'const fs=require(\"fs\"); const data=fs.readFileSync(\""
   dot-path
   "\",\"utf8\"); if (!/^digraph kons_dependencies \\{/.test(data) || !data.includes(\"\\\"root\\\" -> \\\"path:example/graph-helper\\\"\")) process.exit(1)'")))

(test-equal
 "graph dot parses with Graphviz when available"
 0
 (shell-command-status
  (string-append
   "if command -v dot >/dev/null 2>&1; then dot -Tsvg "
   (shell-quote dot-path)
   " >/tmp/kons-graph-test.svg; else exit 0; fi")))

(test-equal
 "graph json command exits"
 0
 (command-status "graph --format json" json-path))

(test-equal
 "graph json has nodes and edges"
 0
 (shell-command-status
  (string-append
   "node -e 'const fs=require(\"fs\"); const data=JSON.parse(fs.readFileSync(\""
   json-path
   "\",\"utf8\")); if (data.formatVersion !== 1 || !Array.isArray(data.nodes) || !Array.isArray(data.edges) || !data.edges.some((edge)=>edge.to === \"path:example/graph-helper\")) process.exit(1)'")))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons graph")
  (exit (if (= failures 0) 0 1)))
