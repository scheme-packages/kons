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

Kons can translate straightforward R7RS `define-library` files into generated
R6RS `.sls` files when an R7RS package is run with an R6RS-only implementation.
The translator is conservative: it handles common declarations, `include`,
`include-library-declarations`, `include-ci`, `cond-expand`, simple renamed
exports, and import modifiers (`only`, `except`, `prefix`, `rename`) when the
inner import maps to one R6RS import. Supported standard imports include
`(scheme base)`, `(scheme char)`, `(scheme write)`, `(scheme read)`,
`(scheme file)`, `(scheme process-context)`, `(scheme cxr)`, `(scheme complex)`,
`(scheme case-lambda)`, `(scheme eval)`, `(scheme inexact)`, `(scheme r5rs)`,
and restricted `(only (scheme lazy) delay force)`. Full `(scheme lazy)`,
`(scheme time)`, `(scheme load)`, and `(scheme repl)` are intentionally reported
as unsupported until there is a portable R6RS target. `kons check` and
`kons --scheme NAME compat-scan` report standard imports that still need a
dependency, compatible implementation, or package variant.

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
kons verify          # verify lockfile and materialized sources
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

For registries that sign metadata, pin the public key and require trust in
`$KONS_HOME/config/registries.scm`:

```sh
kons registry index https://packages.example.org/index/config.json default --default --trust
```

Or configure the key manually:

```scheme
(registries
  (registry
    (name "default")
    (url "https://packages.example.org")
    (default #t)
    (trust required)
    (key-id "2026-06-main")
    (key-file "keys/2026-06-main.pem")))
```

During signing-key rotation, keep both public keys trusted until old metadata
caches and old lockfiles no longer need offline verification:

```scheme
(registries
  (registry
    (name "default")
    (url "https://packages.example.org")
    (default #t)
    (trust required)
    (keys
      (key (id "2026-06-main") (file "keys/2026-06-main.pem"))
      (key (id "2026-09-main") (file "keys/2026-09-main.pem")))))
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
kons update           # resolve deps and write kons.lock
kons update --upgrade # update compatible registry deps too
kons fetch            # download missing deps
kons fetch --plan     # show what will happen
kons vendor           # copy locked registry deps into vendor/kons
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
kons search "(example lib)" --type library
kons search parse-token --type identifier
```

## Lockfile and offline mode

```sh
kons build --locked  # require current kons.lock
kons build --offline # do not fetch missing deps
kons build --frozen  # locked + offline
```

Registry dependencies are resolved transitively. `kons.lock` records every
resolved registry package and the dependency edges between them. A plain
`kons update` preserves locked registry versions that still satisfy the manifest
and transitive constraints; use `kons update --upgrade` to select newer
compatible versions. Use these flags in CI when you want repeatable builds.
The lock root also records the selected scheme, target, profile, compile mode,
and features. Running with a different explicit context requires `kons update`.

Vendor locked registry dependencies for offline builds:

```sh
kons vendor
kons vendor --directory third_party/kons
kons vendor --sync
kons vendor --plan
```

This writes the locked registry package sources, a vendor metadata file, and a
root `kons-vendor.scm` source-replacement pointer. Locked registry dependencies
are loaded from the vendor tree before the global registry store, so the vendor
directory and pointer can be checked into a repository for frozen/offline builds.

You can also configure source replacement outside the project pointer. Put this
in `$KONS_HOME/config/source-replacements.scm` to map a registry alias to a
vendor metadata file or directory:

```scheme
(source-replacements
  (replace
    (registry "default")
    (directory "/path/to/vendor/kons")))
```

When `directory` is used, Kons reads `kons-vendor.scm` from that directory. Use
`metadata` instead to point at a specific metadata file.

## Registry commands

```sh
kons registry list
kons registry add NAME URL
kons registry add NAME URL --default
kons registry index INDEX-URL NAME
kons registry index INDEX-URL NAME --trust
kons registry remove NAME
kons registry default NAME
```

Search and inspect packages:

```sh
kons search parser --limit 10
kons search parser --type all
kons search parser --format json
kons provides example/base
kons provides example/base --format json
kons identifier parse-token
kons identifier parse-token --format json
kons info example/base
kons info example/base --format json
kons tree
kons tree --format json
kons graph --format dot
kons graph --format json
kons dependency-scan
kons dependency-scan --format json
kons archive-scan --format json
kons archive-scan --archive .kons/package/example-lib-0.1.0.kons --format json
kons --scheme chez compat-scan
kons --scheme chez compat-scan --format json
kons license-scan --format json
kons license-scan --directory notices
kons resolve
kons resolve --format json
kons metadata
kons metadata --format json
kons status
kons status --format json
kons doctor
```

Machine-readable diagnostics:

```sh
kons update --locked --message-format json
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

A feature can add dependencies or forward features to an existing dependency:

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

A hook gets two positional arguments for compatibility:

1. build root
2. source root

It also receives named argv entries such as `--kons-build-root`,
`--kons-source-root`, `--kons-package-root`, `--kons-target-scheme`,
`--kons-hook-scheme`, `--kons-profile`, repeated `--kons-feature`, and
repeated `--kons-dialect`.

Import `(kons build)` in the hook for parsed accessors and directive helpers:

```scheme
(import (scheme base) (kons build))

(rerun-on-change "templates/data.json")
(metadata "generator" "build.scm")
```

Build hooks can also print directives directly:

```scheme
(kons::rerun-on-change "templates/data.json")
(kons::ld-library-path "native/lib")
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
(import (scheme base) (kons build))

(write-library
 '(example generated generated)
 '(define-library (example generated generated)
    (export message)
    (import (scheme base))
    (begin
      (define message "hello from build hook"))))
```

`write-library` writes `.sld` for R7RS packages and `.sls` for R6RS packages,
then adds the build output to the package load path.

For native artifacts, use:

```scheme
(add-dlopen-path "native")
(add-ld-library-path "native")
(add-dyld-library-path "native")
(add-ld-preload "native/libhook.so")
(set-runtime-env "MY_LIB_MODE" "debug")
```

Kons applies these directives to later `run`, `test`, and `bench` commands.

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

R7RS packages can also run on R6RS-only implementations through generated
`.sls` translations when their libraries use the supported portable subset. Run
`kons check --plan` or `kons --scheme NAME compat-scan` to see which files will
be translated and which imports or forms remain unsupported.

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
| `verify` | Verify the lockfile, materialized sources, and cached archives. |
| `vendor` | Copy locked registry dependencies into a vendor directory. |
| `run` | Run main program, script, or bin. |
| `repl` | Start Scheme REPL with project paths. |
| `check` | Check manifest and dependency setup. |
| `build` | Run hooks and compile when possible. |
| `test` | Run tests. |
| `bench` | Run benchmarks. |
| `install` | Install local launcher. |
| `clean` | Remove generated build/store files. |
| `tree` | Show dependency tree. |
| `graph` | Print dependency graph data or DOT. |
| `dependency-scan` | Scan source imports against local libraries. |
| `archive-scan` | Inspect package archive metadata. |
| `compat-scan` | Report likely Scheme portability gaps. |
| `license-scan` | Report package licenses and notices. |
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
