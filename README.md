# kons

`kons` is a small package manager and build tool for Scheme projects.

It can create a project, fetch dependencies, write `kons.lock`, run tests,
build code, install a command, and publish packages to a Kons registry.

## Install

```sh
make install
```

Or install from the script:

```sh
curl -fsSL https://raw.githubusercontent.com/scheme-packages/kons/master/install.sh | sh
```

Then load the environment file in your shell:

```sh
echo '. "$HOME/.kons/env"' >> ~/.bashrc
# or, for zsh
echo '. "$HOME/.kons/env"' >> ~/.zshrc
```

## First project

```sh
kons new hello
cd hello
kons run
kons test
```

Use `kons init .` when the directory already exists.

## Normal commands

```sh
kons run             # run the main program
kons test            # run tests
kons check           # check manifest and dependencies
kons build           # build only
kons verify          # verify lockfile and materialized sources
kons build --jobs 4  # run work in parallel when the Scheme supports threads
kons repl            # open a Scheme REPL with project load paths
kons install         # install a launcher for the project
kons clean           # remove generated files
```

Use another Scheme implementation like this:

```sh
kons --scheme guile run
```

Or set a default:

```sh
export KONS_SCHEME=guile
```

`kons` can run the package manager itself with `capy`, `guile`,
`gauche`/`gosh`, and `chibi`/`chibi-scheme`.

Target package runtimes also include `chez`/`chezscheme`, `sagittarius`/`sash`,
`stklos`, `kawa`, `loko`, `skint`, `cyclone`, `mit`, `mosh`, and `ironscheme`
when the package dialect matches the implementation.

## Portability model

`kons` can translate straightforward R7RS `define-library` files into generated
R6RS `.sls` files when an R7RS package is run with an R6RS-only implementation.
The translator handles common library declarations, `include`,
`include-library-declarations`, `include-ci`, `cond-expand`, simple renamed
exports, and import modifiers (`only`, `except`, `prefix`, `rename`) when the
inner import maps to one R6RS import. It maps common standard `(scheme ...)`
imports such as `base`, `char`, `write`, `read`, `file`, `process-context`,
`cxr`, `complex`, `case-lambda`, `eval`, `inexact`, `r5rs`, and restricted
`(only (scheme lazy) delay force)` to specific R6RS/RNRS libraries. Full
`(scheme lazy)`, `(scheme time)`, `(scheme load)`, and `(scheme repl)` are
reported as unsupported until there is a portable R6RS target for them. Use
`kons check` or `kons --scheme NAME compat-scan` to see translated files and
forms that still need a dependency, a different implementation, or a package
variant.

## Add dependencies

```sh
kons add example/base --version ^1.2
kons add --akku srfi-1 --version ^1.0
kons add --akku '(chibi match)' --version 0.7.0
kons add --snow retropikzel/system --version ^1.0
kons add local/lib --path ../lib
kons add remote/lib --git https://example.invalid/lib.git --rev main
kons add scheme/base --system
kons remove local/lib
kons update
kons fetch
kons vendor
kons dependency-scan
kons archive-scan
kons --scheme chez compat-scan
```

Registry packages use `https://kons.playxe.org` by default. To use another
registry, configure it like this:

```sh
kons registry add default https://packages.example.org --default
kons registry index https://packages.example.org/index/config.json default --default
```

If a registry signs metadata, pin its public key in
`$KONS_HOME/config/registries.scm` and set `(trust required)`, or run
`kons registry index URL NAME --trust` to pin the key advertised by the index
config. During key rotation, use `(keys (key ...))` to trust both the old and
new public keys until old metadata caches and lockfiles no longer need offline
verification.

Akku package sources are configured separately in
`$KONS_HOME/config/akku-sources.scm`. Kons verifies Akku archive indexes with
trusted OpenPGP keyrings, locks source metadata, verifies URL tarball SHA-256
checksums before extraction, and materializes Akku sources under
`$KONS_HOME/store/akku/sources`. Kons consumes Akku packages; publishing remains
for Kons registries only.

Snow packages are resolved from `https://snow-fort.org/s/repo.scm` by default.
Use `(snow (name (retropikzel system)) (version "^1.0"))` or
`kons add --snow retropikzel/system --version ^1.0`; Snow metadata and
snowballs are cached under `$KONS_HOME/store/snow`.

## Publish

```sh
kons login --token kons_...
kons package --list
kons package
kons publish --dry-run
kons publish
kons yank example/lib@1.2.3
```

Before publishing, `kons.scm` should have name, version, owner, description,
and license.

Add keywords for registry search:

```scheme
(package
  (name (example parser))
  (version "0.1.0")
  (description "Parser helpers")
  (license "MIT")
  (keywords "parser" "scheme" "text"))
```

## Workspaces

Root `kons.scm`:

```scheme
(workspace
  (members
    "packages/lib"
    "apps/cli"))
```

Then:

```sh
kons test --workspace
kons run --package apps/cli
kons publish --package packages/lib
```

## More docs

- [Usage](docs/usage.md) - daily commands and examples
- [Manifest](docs/manifest.md) - how to write `kons.scm`
- [Workspaces](docs/workspaces.md) - many packages in one repo
- [Development](docs/development.md) - hacking on kons itself
