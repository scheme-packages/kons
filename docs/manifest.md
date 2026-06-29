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
| `name` | Package name, written like `(example hello)`. Registry packages cannot use reserved route roots like `api`, `auth`, or `index`. |
| `version` | Package version. Use SemVer when publishing. |
| `owner` | Package owner name for publishing. |
| `license` | SPDX license expression, like `"MIT"` or `"MIT OR Apache-2.0"`. |
| `description` | Short text shown in registry. |
| `keywords` | Search words for registry, like `"parser"` or `"web"`. |
| `readme` | README file path included in published registry pages, usually `"README.md"`. |
| `site` | Project website URL. Alias for `homepage`. |
| `repo` | Source repository URL. Alias for `repository`. |
| `docs` | Documentation URL. Alias for `documentation`. |
| `dialects` | `r7rs`, `r6rs`, or both if your code supports it. R7RS-only packages can be translated to generated R6RS `.sls` files for R6RS-only runtimes when they use the supported portable subset described in [Usage](usage.md); `kons check` and `compat-scan` report unsupported imports/forms such as `(scheme time)`, `(scheme load)`, and `(scheme repl)`. |
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

kons records discovered imports and common export forms in metadata. Published
packages send that library and identifier metadata to the registry so users can
search by package, library, or exported identifier.

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

Registry dependencies are solved transitively. When package A depends on package
B and B depends on package C, `kons update` records both B and C in `kons.lock`
with dependency edges. A plain `kons update` keeps locked registry versions when
they still satisfy all constraints; `kons update --upgrade` selects newer
compatible versions.

Akku package dependency:

```scheme
(dependencies
  (akku (name "srfi-1")
        (version "^1.0")
        (source "akku")))
```

List-shaped Akku names use Scheme list syntax and round-trip as lists:

```scheme
(dependencies
  (akku (name (chibi match))
        (version "0.7.0")))
```

The `source` field is an Akku source alias, not a Kons registry alias. It
defaults to `"akku"`, which resolves through `$KONS_HOME/config/akku-sources.scm`.
Akku versions are SemVer requirements. Kons can resolve and fetch Akku packages,
but it does not publish packages to the Akku registry.

Snow package dependency:

```scheme
(dependencies
  (snow (name (retropikzel system))
        (version "^1.0")))
```

Snow names are Scheme lists. The `source` field defaults to `"snow"`, which
points at `https://snow-fort.org/s/repo.scm`; it may also be a repository URL
or local repository file. Snow versions are SemVer requirements. Kons resolves
library dependencies from Snow repository metadata and materializes snowballs
into `$KONS_HOME/store/snow/sources`.

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
| `akku` | Package comes from a verified Akku archive index. |
| `snow` | Package comes from a Snow repository. |
| `path` | Package is in a local directory. |
| `git` | Package is in a Git repo. |
| `workspace` | Package is another member of same workspace. |
| `system` | Library is provided by the Scheme implementation. |

Dependencies can be limited to specific build contexts:

```scheme
(dependencies
  (registry
    (name (example guile-lib))
    (version "^1.0")
    (schemes guile))
  (path
    (name (example release-helper))
    (path "../release-helper")
    (version "1.0.0")
    (profiles release))
  (path
    (name (example compiled-helper))
    (path "../compiled-helper")
    (version "1.0.0")
    (compile-modes compiled))
  (path
    (name (example r7rs-helper))
    (path "../r7rs-helper")
    (version "1.0.0")
    (dialects r7rs))
  (cond-expand
    (r6rs
      (akku
        (name "akku-r7rs")
        (version "*"))))
  (cond-expand
    ((target-os linux)
      (registry
        (name (example linux-ffi))
        (version "^1.0")))))
```

Supported dependency selectors are `schemes`, `implementations`, `dialects`,
`targets`, `profiles`, and `compile-modes`. Conditional dependencies use
manifest `cond-expand` blocks. Selectors and expanded conditions are stored in
the lockfile, and explicit changes to `--scheme`, `--target`, `--profile`, or
`--compile-mode`, as well as changes to the selected package dialect, require a
matching lock update.

`cond-expand` predicates accept bare flags such as `unix` or `windows`,
key/value checks such as `(target-arch x86_64)` or `(target-os linux)`,
and `(and ...)`, `(or ...)`, and `(not ...)`. Available options come from the
selected target triple, target Scheme implementation, package dialect, profile,
compile mode, and active features. For example, `r6rs` and `(dialect r6rs)`
match an R6RS package run, while `capy`, `(scheme capy)`, and
`(implementation capy)` match the selected target implementation. Clauses use
first-match semantics; `else` applies only when no earlier predicate matched.

You can also apply one predicate to several dependencies:

```scheme
(dependencies
  (cond-expand
    ((and unix (target-arch x86_64))
      (system (scheme file))
      (registry (name (example unix64)) (version "^1.0")))
    (else
      (system (scheme base)))))
```

Top-level `cond-expand` blocks can wrap `dependencies`, `dev-dependencies`, and
`overrides` blocks.

## Dependency commands

You can edit `kons.scm` with commands instead of typing by hand:

```sh
kons add example/base --version ^1.2
kons add example/base --version ^1.2 --registry local
kons add --akku srfi-1 --version ^1.0
kons add --akku '(chibi match)' --version 0.7.0
kons add --akku srfi-1 --registry akku
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

Workspace roots can provide defaults for member metadata and dependency publish
versions:

```scheme
(workspace
  (members "packages/base" "apps/cli")
  (default-members "apps/cli")
  (package
    (license "MIT")
    (repository "https://example.org/project.git")
    (authors "Example Team"))
  (dependencies
    (workspace (name (example base)) (version "1.0.0"))))
```

Members inherit empty `license`, `repository`, `homepage`, `documentation`, and
`authors` fields. Dependencies inherit a workspace dependency `version` when the
member dependency does not declare one.

`default-members` lists workspace members used by package commands run at the
workspace root without `--workspace` or `--package`. Use `--workspace` to run all
members, or `--package MEMBER` to select one explicitly.

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

Features can also add dependencies or request features on a dependency:

```scheme
(dependencies
  (registry (name (example http)) (version "^1.0")))

(package
  (features
    (tls
      (dependencies
        (registry (name (example http))
                  (version "^1.0")
                  (features tls)))))))
```

When `tls` is active, the resolver keeps the normal `example/http` dependency
and also requests its `tls` feature.

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
      ((and tls unix)
       (define (message) "tls enabled on unix"))
      ((target-os windows)
       (define (message) "windows"))
      (tls
       (define (message) "tls enabled"))
      (else
       (define (message) "plain")))))
```

The helper exports:

| Binding | Meaning |
| --- | --- |
| `active-features` | List of active features. |
| `active-condition-options` | Active kons condition options. |
| `feature-enabled?` | Check a feature at runtime. |
| `condition-enabled?` | Check a condition predicate at runtime. |
| `feature-cond` | Choose code by feature or condition predicate. |

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
| `(scheme-impl IMPL)` | Run this hook with `capy`, `guile`, `gauche`, `chibi`, `chez`, `sagittarius`, `stklos`, `kawa`, `loko`, `skint`, `cyclone`, `mit`, `mosh`, or `ironscheme`. |

If `build.scm` exists and no `build-hooks` field exists, kons runs it.

Hooks receive build root and source root as positional command line arguments.
They also receive named argv entries: `--kons-build-root`,
`--kons-source-root`, `--kons-package-root`, `--kons-out-dir`,
`--kons-target-scheme`, `--kons-hook-scheme`, `--kons-profile`,
`--kons-target`, `--kons-package-name`, `--kons-package-version`, repeated
`--kons-feature`, and repeated `--kons-dialect`.

Hooks can import `(kons build)` from the generated build load path. The helper
exports context values plus directive helpers:

| Helper | Effect |
| --- | --- |
| `(rerun-on-change PATH ...)` | Rerun when these package-relative paths change. |
| `(write-library NAME FORM)` | Write generated `.sld` or `.sls` for `NAME` and add the output root to load paths. |
| `(add-library-path PATH ...)` / `(add-load-path PATH ...)` | Add generated Scheme load paths. |
| `(add-dlopen-path PATH ...)` | Add runtime native library search paths. |
| `(add-ld-library-path PATH ...)` / `(add-dyld-library-path PATH ...)` | Add platform dynamic-library paths. |
| `(add-ld-preload PATH ...)` / `(add-ld-preload-path PATH ...)` | Add preload settings for runtime commands. |
| `(set-runtime-env NAME VALUE)` / `(add-runtime-env-path NAME PATH ...)` | Add runtime environment settings. |
| `(link-search PATH ...)` / `(link-lib LIB ...)` | Record native link metadata. |
| `(output KEY VALUE)` / `(metadata KEY VALUE)` | Record arbitrary generated output metadata. |

The same directives can be printed as sexpressions, for example
`(kons::rerun-on-change "schema.json")`.

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
(import (scheme base) (kons build))

(write-library
 '(example generated generated)
 '(define-library (example generated generated)
    (export message)
    (import (scheme base))
    (begin
      (define message "hello from build hook"))))
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
kons --scheme capy --dialect r6rs run
kons --scheme guile --dialect r6rs run
kons --scheme chez run
```

## Project config

`.kons/config.scm` can add extra load paths:

```scheme
(load-paths "vendor/shared")
(chez-load-paths "vendor/chez")
```

Use this for local project setup. For real dependencies, prefer `dependencies`.
