# Usage

This page shows the common `kons` commands. It is written like a small cheat
sheet, so you can copy commands and change names.

## Install

From this repository:

```sh
./install.sh --kons-home "$HOME/.kons" --scheme capy --non-interactive
```

Add kons to your shell:

```sh
echo '. "$HOME/.kons/env"' >> ~/.bashrc
echo '. "$HOME/.kons/env"' >> ~/.zshrc
echo 'source "$HOME/.kons/env.fish"' >> ~/.config/fish/config.fish
```

Pick default Scheme:

```sh
export KONS_SCHEME=guile
```

You can also use `--scheme` on one command:

```sh
kons --scheme gosh test
```

The `kons` manager can run under `capy`, `guile`, `gauche`/`gosh`, and
`chibi`/`chibi-scheme`.

Target package runtimes also include `chez`/`chezscheme`, `sagittarius`/`sash`,
`stklos`, `kawa`, `loko`, `skint`, `cyclone`, `mit`, `mosh`, and `ironscheme`
when the package dialect matches the implementation.

## Create a project

```sh
kons new hello
cd hello
kons run
```

For an existing folder:

```sh
kons init .
```

For a library only package:

```sh
kons new my-lib --lib
```

## Run, test, build

```sh
kons run             # run the default program
kons run --release   # run with release profile
kons run --bin hello # run one named bin
kons run --example hello # run one example
kons run --list      # show runnable targets
kons repl            # open REPL with package load paths

kons test            # run tests
kons test --list     # show test files
kons bench           # run benches
kons check           # check manifest and deps
kons build           # build only
kons build --release # release build
```

Pass arguments to your program after `--`:

```sh
kons run -- --name Ada
```

## Dependencies

Registry package:

```sh
kons add example/base --version ^1.2
```

Registry packages use `https://kons.playxe.org` by default. To use another
registry, configure it like this:

```sh
kons registry add default https://packages.example.org --default
kons registry index https://packages.example.org/index/config.json default --default
```

Local package:

```sh
kons add local/lib --path ../lib
```

Git package:

```sh
kons add remote/lib --git https://example.invalid/lib.git --rev main
```

System dependency, already provided by Scheme:

```sh
kons add scheme/base --system
```

Remove and update:

```sh
kons remove local/lib
kons update          # resolve deps and write kons.lock
kons fetch           # download missing deps
kons fetch --plan    # show what will happen
```

Use `--dev` for dev dependencies:

```sh
kons add test/helper --version ^0.1 --dev
```

Use `--package MEMBER` when editing one workspace member.

## Keywords

Add keywords to `kons.scm` so the registry can find your package:

```scheme
(package
  (name (example parser))
  (version "0.1.0")
  (description "Parser helpers")
  (license "MIT")
  (keywords "parser" "scheme" "text"))
```

Then users can search by keyword:

```sh
kons search parser
```

## Lockfile and offline mode

```sh
kons build --locked  # require current kons.lock
kons build --offline # do not fetch missing deps
kons build --frozen  # locked + offline
```

Use these in CI when you want repeatable builds.

## Registry commands

```sh
kons registry list
kons registry add NAME URL
kons registry add NAME URL --default
kons registry index INDEX-URL NAME
kons registry remove NAME
kons registry default NAME
```

Search and inspect packages:

```sh
kons search parser --limit 10
kons info example/base
kons tree
kons resolve
kons metadata
kons status
kons doctor
```

## Login and publish

Login stores a token in your local kons home:

```sh
kons login --registry local --token kons_...
kons logout --registry local
```

Package and publish:

```sh
kons package --list
kons package
kons publish --registry local --dry-run
kons publish --registry local
```

You can also pass token without storing it:

```sh
kons publish --registry local --token kons_...
```

Yank means hide version from new dependency solving. It does not delete the
archive, so old lockfiles still work.

```sh
kons yank example/lib@1.2.3 --registry local
kons yank --version 1.2.3 --undo example/lib --registry local
```

Owners:

```sh
kons owner list example/lib --registry local
kons owner --add alice example/lib --registry local
kons owner --remove alice example/lib --registry local
```

For publish, the package should have name, version, owner, description, and
license in `kons.scm`.

## Install a command

```sh
kons install
kons install --name my-command
kons install --package apps/cli --name my-cli
```

This installs a launcher for a local package.

## Features

Declare features in `kons.scm`:

```scheme
(package
  (name (example app))
  (version "1.0.0")
  (features
    (default tls)
    (tls)
    (debug)))
```

Use them from commands:

```sh
kons run --features debug
kons run --no-default-features
kons run --no-default-features --features tls
```

In Scheme code, import the generated feature helper:

```scheme
(import (scheme base)
        (example app kons features))

(feature-cond
  (tls
   (define mode 'tls))
  (else
   (define mode 'plain)))
```

The helper also gives `active-features` and `feature-enabled?`.

## Build hooks

Build hooks are Scheme files that run before build. Put this in `kons.scm`:

```scheme
(package
  (name (example app))
  (version "1.0.0")
  (dialects r7rs)
  (source-path "src")
  (build-hooks
    (scheme "build.scm")
    (scheme "codegen.scm" (rerun-on-change "templates/data.json"))))
```

If there is no `build-hooks` field but `build.scm` exists, kons runs it.

A hook gets two arguments:

1. build root
2. source root

Small `build.scm` example:

```scheme
(import (scheme base) (scheme file) (scheme write))

(let ((build-root (cadr (command-line))))
  (call-with-output-file (string-append build-root "/generated.scm")
    (lambda (out)
      (display "(define generated-message \"hello\")" out)
      (newline out))))
```

Full example with a generated library:

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

Run hooks with another Scheme:

```sh
kons --scheme capy --hook-scheme guile build
```

Or set it for one hook:

```scheme
(build-hooks
  (scheme "build.scm" (scheme-impl guile)))
```

Priority is: hook `scheme-impl`, then `--hook-scheme`, then `--scheme`.

## R6RS

Use `(dialects r6rs)` and `.sps` / `.sls` files:

```scheme
(package
  (name (example r6rs-tool))
  (version "0.1.0")
  (license "MIT")
  (description "An R6RS tool")
  (dialects r6rs)
  (source-path "src")
  (main "main.sps"))
```

Run it:

```sh
kons --scheme capy run
kons --scheme guile run
kons --scheme chez run
```

## Useful global options

```sh
kons --manifest path/to/kons.scm test
kons --path packages/app run
kons --profile release build
kons --jobs 4 test
kons --quiet build
kons --verbose build
kons --no-color build
kons --version
kons help run
```

`--jobs N` can fetch, prepare, and compile in parallel. It needs a Scheme with
thread support. Capy, Gauche, and Guile can do parallel jobs today.

## All commands, short

| Command | Use it for |
| --- | --- |
| `new` | Create a new package folder. |
| `init` | Create `kons.scm` in an existing folder. |
| `add` | Add dependency to `kons.scm`. |
| `remove` | Remove dependency from `kons.scm`. |
| `update` | Resolve dependencies and write `kons.lock`. |
| `fetch` | Download dependencies. |
| `run` | Run main program, script, or bin. |
| `repl` | Start Scheme REPL with project paths. |
| `check` | Check manifest and dependency setup. |
| `build` | Run hooks and compile when possible. |
| `test` | Run tests. |
| `bench` | Run benchmarks. |
| `install` | Install local launcher. |
| `clean` | Remove generated build/store files. |
| `tree` | Show dependency tree. |
| `resolve` | Show resolved dependency graph. |
| `metadata` | Print normalized manifest data. |
| `status` | Show project readiness. |
| `doctor` | Check Scheme tools and paths. |
| `registry` | Manage registry aliases. |
| `search` | Search registry packages. |
| `info` | Show registry package info. |
| `login` | Store registry API token. |
| `logout` | Remove local registry token. |
| `package` | Make package archive. |
| `publish` | Upload package to registry. |
| `yank` | Hide a published version from new resolves. |
| `unyank` | Undo yank. |
| `owner` | Manage package owners. |
