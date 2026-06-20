# Manifest

Every package has a `kons.scm` file. This file tells kons the package name,
where source files are, what to run, and what dependencies are needed.

Small example:

```scheme
(package
  (name (example hello))
  (version "0.1.0")
  (owner "you")
  (license "MIT")
  (description "Small hello package")
  (keywords "scheme" "example")
  (dialects r7rs)
  (source-path "src")
  (main "main.scm")
  (tests "tests/main.scm")
  (examples "examples/hello.scm")
  (bins (hello "main.scm")))

(dependencies)
(dev-dependencies)
```

## Package fields

Common fields:

| Field | Meaning |
| --- | --- |
| `name` | Package name, written like `(example hello)`. |
| `version` | Package version. Use SemVer when publishing. |
| `owner` | Package owner name for publishing. |
| `license` | License text or SPDX name, like `"MIT"`. |
| `description` | Short text shown in registry. |
| `keywords` | Search words for registry, like `"parser"` or `"web"`. |
| `readme` | README file path included in published registry pages, usually `"README.md"`. |
| `site` | Project website URL. Alias for `homepage`. |
| `repo` | Source repository URL. Alias for `repository`. |
| `docs` | Documentation URL. Alias for `documentation`. |
| `dialects` | `r7rs`, `r6rs`, or both if your code supports it. |
| `source-path` | Folder with source files. Usually `"src"`. |
| `main` | Main file for `kons run`. |
| `tests` | Test files for `kons test`. |
| `benches` | Bench files for `kons bench`. |
| `examples` | Example files for `kons run --example NAME`. Names default to file stems. |
| `bins` | Named commands for `kons run --bin NAME`. |

## Library discovery

kons scans `source-path` and finds libraries by itself.

Supported forms:

- R7RS `define-library` in `.sld` and `.scm`
- R6RS `library` in `.sls` and `.scm`
- simple module declarations in `.scm`

If you do not want scanning:

```scheme
(package
  (name (example manual))
  (version "0.1.0")
  (source-path "src")
  (discover-libraries #f)
  (libraries (example manual)))
```

## Dependencies

Put runtime dependencies in `(dependencies ...)`.
Put test/build only dependencies in `(dev-dependencies ...)`.

Registry dependency:

```scheme
(dependencies
  (registry (name (example base))
            (version "^1.2")
            (registry "default")))
```

The `registry` field can be skipped when you use the default registry.

Path dependency:

```scheme
(dependencies
  (path (name (local lib))
        (path "../lib")))
```

Git dependency:

```scheme
(dependencies
  (git (name (remote lib))
       (url "https://example.invalid/lib.git")
       (rev "main")))
```

Workspace dependency:

```scheme
(dependencies
  (workspace (name (example lib))))
```

System dependency:

```scheme
(dependencies
  (system (name (scheme base))))
```

Dependency kinds:

| Kind | Use it when |
| --- | --- |
| `registry` | Package comes from a Kons registry. |
| `path` | Package is in a local directory. |
| `git` | Package is in a Git repo. |
| `workspace` | Package is another member of same workspace. |
| `system` | Library is provided by the Scheme implementation. |

## Dependency commands

You can edit `kons.scm` with commands instead of typing by hand:

```sh
kons add example/base --version ^1.2
kons add example/base --version ^1.2 --registry local
kons add local/lib --path ../lib
kons add remote/lib --git https://example.invalid/lib.git --rev main
kons add scheme/base --system
kons add test/helper --version ^0.1 --dev
kons remove local/lib
```

Preview before writing:

```sh
kons add example/base --version ^1.2 --plan
```

## Publishing local dependencies

Path, workspace, and Git dependencies are good for local work. But registry
users cannot use your local paths. So when you publish, these deps need a
registry version too:

```scheme
(dependencies
  (workspace (name (example base)) (version "1.0.0"))
  (path (name (example local))
        (path "../local")
        (version "^1.2")
        (registry "local"))
  (git (name (example remote))
       (url "https://example.invalid/lib.git")
       (version "^2.0")))
```

Locally, kons still uses workspace/path/git source. During publish, kons writes
these as registry requirements. If the version is missing, publish fails.

## Overrides

Overrides replace a dependency without changing the original dependency list.
This is useful while testing a local copy.

```scheme
(dependencies
  (git (name (example lib))
       (url "https://example.invalid/lib.git")
       (rev "abc123")))

(overrides
  (path (name (example lib))
        (path "../lib")))
```

Vendored dependency example:

```scheme
(overrides
  (path (name (args))
        (path "vendor/scm-args")))
```

## Features

Features are optional switches for your package:

```scheme
(package
  (name (example app))
  (version "1.0.0")
  (features
    (default tls)
    (tls)
    (debug)))
```

Use them:

```sh
kons run --features tls,debug
kons run --no-default-features
```

Import the generated helper in R7RS code:

```scheme
(define-library (example app main)
  (export message)
  (import (scheme base)
          (example app kons features))
  (begin
    (feature-cond
      (tls
       (define (message) "tls enabled"))
      (else
       (define (message) "plain")))))
```

The helper exports:

| Binding | Meaning |
| --- | --- |
| `active-features` | List of active features. |
| `feature-enabled?` | Check a feature at runtime. |
| `feature-cond` | Choose code by feature. |

For R6RS, import the same helpers.

## Build hooks

Build hooks run before compile:

```scheme
(package
  (name (example app))
  (version "1.0.0")
  (source-path "src")
  (build-hooks
    (scheme "build.scm")
    (scheme "codegen.scm" (rerun-on-change "templates/data.json"))
    (scheme "chez-gen.scm" (scheme-impl chez))))
```

Hook properties:

| Property | Meaning |
| --- | --- |
| `(rerun-on-change PATH ...)` | Run again when these files change. |
| `(scheme-impl IMPL)` | Run this hook with `capy`, `guile`, `gauche`, `chibi`, or `chez`. |

If `build.scm` exists and no `build-hooks` field exists, kons runs it.

Hooks receive build root and source root as command line arguments. Files
written in build root are added to load path.

Clean example:

```scheme
;; kons.scm
(package
  (name (example generated))
  (version "0.1.0")
  (source-path "src")
  (main "main.scm")
  (build-hooks
    (scheme "build.scm")))
```

```scheme
;; build.scm
(import (scheme base) (scheme file) (scheme write))

(let ((build-root (cadr (command-line))))
  (call-with-output-file (string-append build-root "/generated.sld")
    (lambda (out)
      (write
       `(define-library (example generated generated)
          (export message)
          (import (scheme base))
          (begin
            (define message "hello from build hook")))
       out)
      (newline out))))
```

```scheme
;; src/main.scm
(import (scheme base)
        (scheme write)
        (example generated generated))

(display message)
(newline)
```

Run it:

```sh
kons run
```

## R6RS package

```scheme
(package
  (name (example r6rs-tool))
  (version "0.1.0")
  (dialects r6rs)
  (source-path "src")
  (main "main.sps"))
```

Use `.sls` for libraries and `.sps` for programs.

Run with:

```sh
kons --scheme capy run
kons --scheme guile run
kons --scheme chez run
```

## Project config

`.kons/config.scm` can add extra load paths:

```scheme
(load-paths "vendor/shared")
(chez-load-paths "vendor/chez")
```

Use this for local project setup. For real dependencies, prefer `dependencies`.
