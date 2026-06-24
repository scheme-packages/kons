(import (scheme base)
        (scheme file)
        (srfi 64)
        (kons util))

(test-begin "kons json output")

(define root "/tmp/kons-json-output-test")
(define dep-root (path-join root "deps/runtime"))
(define dev-root (path-join root "deps/dev"))
(define resolve-json-path (path-join root "resolve.json"))
(define tree-json-path (path-join root "tree.json"))
(define status-json-path (path-join root "status.json"))

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

(define (json-check path . scripts)
  (shell-command-status
   (string-append
    "node -e "
    (shell-quote
     (string-append
      "const fs=require('fs');"
      "const data=JSON.parse(fs.readFileSync("
      (call-with-output-string (lambda (out) (write path out)))
      ",'utf8'));"
      (apply string-append scripts))))))

(run-command (string-append "rm -rf " (shell-quote root)))

(write-file
 (path-join root "kons.scm")
 "(package
  (name (example json-app))
  (version \"0.1.0\")
  (source-path \"src\")
  (main \"main.scm\"))

(dependencies
  (path (name (example json-runtime)) (path \"deps/runtime\") (version \"1.0.0\")))
(dev-dependencies
  (path (name (example json-dev)) (path \"deps/dev\") (version \"1.0.0\")))
")

(write-file
 (path-join root "src/example/json-app.sld")
 "(define-library (example json-app)
  (export value)
  (import (scheme base) (example json-runtime))
  (begin (define value runtime-value)))
")

(write-file
 (path-join root "src/main.scm")
 "(import (scheme base) (example json-app))
value
")

(write-file
 (path-join dep-root "kons.scm")
 "(package
  (name (example json-runtime))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join dep-root "src/example/json-runtime.sld")
 "(define-library (example json-runtime)
  (export runtime-value)
  (import (scheme base))
  (begin (define runtime-value 1)))
")

(write-file
 (path-join dev-root "kons.scm")
 "(package
  (name (example json-dev))
  (version \"1.0.0\")
  (source-path \"src\"))

(dependencies)
(dev-dependencies)
")

(write-file
 (path-join dev-root "src/example/json-dev.sld")
 "(define-library (example json-dev)
  (export dev-value)
  (import (scheme base))
  (begin (define dev-value 1)))
")

(test-equal
 "resolve json command exits"
 0
 (command-status "resolve --format json" resolve-json-path))

(test-equal
 "resolve json has versioned runtime and dev dependency sections"
 0
 (json-check
  resolve-json-path
  "const runtime=data['runtime-dependencies']||[];"
  "const dev=data['dev-dependencies']||[];"
  "if(data.formatVersion!==1) process.exit(1);"
  "if(!Array.isArray(data.root)||data.root.join('/')!=='example/json-app') process.exit(2);"
  "if(!runtime.some((dep)=>dep.type==='path'&&dep.name.join('/')==='example/json-runtime')) process.exit(3);"
  "if(!dev.some((dep)=>dep.type==='path'&&dep.name.join('/')==='example/json-dev')) process.exit(4);"))

(test-equal
 "tree candidate json command exits"
 0
 (command-status "tree --format json" tree-json-path))

(test-equal
 "tree candidate json has versioned dependency and edge arrays"
 0
 (json-check
  tree-json-path
  "const deps=data.dependencies||[];"
  "if(data.formatVersion!==1) process.exit(1);"
  "if(!data.root||data.root.name.join('/')!=='example/json-app') process.exit(2);"
  "if(data.source!=='candidate') process.exit(3);"
  "if(!Array.isArray(deps)||!deps.some((dep)=>dep.type==='path'&&dep.name.join('/')==='example/json-runtime')) process.exit(4);"
  "if(!Array.isArray(data.edges)) process.exit(5);"))

(test-equal
 "update command exits before locked json checks"
 0
 (command-status "update" (path-join root "update.out")))

(test-equal
 "tree locked json command exits"
 0
 (command-status "tree --locked --format json" tree-json-path))

(test-equal
 "tree locked json has versioned dependency and edge arrays"
 0
 (json-check
  tree-json-path
  "const deps=data.dependencies||[];"
  "if(data.formatVersion!==1) process.exit(1);"
  "if(!data.root||data.root.name.join('/')!=='example/json-app') process.exit(2);"
  "if(data.source!=='lockfile') process.exit(3);"
  "if(!Array.isArray(deps)||!deps.some((dep)=>dep.type==='path'&&dep.name.join('/')==='example/json-runtime')) process.exit(4);"
  "if(!Array.isArray(data.edges)) process.exit(5);"))

(test-equal
 "status json command exits"
 0
 (command-status "status --offline --format json" status-json-path))

(test-equal
 "status json has versioned lockfile, action, and locked dependency sections"
 0
 (json-check
  status-json-path
  "const locked=data['locked-dependencies']||[];"
  "if(data.formatVersion!==1) process.exit(1);"
  "if(!data.root||data.root.name.join('/')!=='example/json-app') process.exit(2);"
  "if(!data.lockfile||data.lockfile.status!=='current') process.exit(3);"
  "if(!Array.isArray(data.actions)) process.exit(4);"
  "if(!Array.isArray(locked)||!locked.some((dep)=>dep.type==='path'&&dep.name.join('/')==='example/json-runtime')) process.exit(5);"))

(let ((failures (test-runner-fail-count (test-runner-get))))
  (test-end "kons json output")
  (exit (if (= failures 0) 0 1)))
