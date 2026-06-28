# kons

A package manager and build tool for Scheme projects.

## Install

```sh
make install
```

Or from the install script:

```sh
curl -fsSL https://raw.githubusercontent.com/scheme-packages/kons/master/install.sh | sh
```

Then source the environment in your shell:

```sh
echo '. "$HOME/.kons/env"' >> ~/.bashrc   # or ~/.zshrc
```

## Quick start

```sh
kons new hello
cd hello
kons run
kons test
```

For an existing directory: `kons init .`

## Commands

```sh
kons run             # run the main program
kons test            # run tests
kons check           # check manifest and dependencies
kons build           # build
kons repl            # REPL with project load paths
kons install         # install a launcher
kons clean           # remove generated files
```

Pick a Scheme implementation per command, or set a default:

```sh
kons --scheme guile run
export KONS_SCHEME=guile
```

The manager runs under `capy`, `guile`, `gauche`/`gosh`, and `chibi`/`chibi-scheme`.
Packages can also target `chez`, `sagittarius`, `stklos`, `kawa`, `loko`, `skint`,
`cyclone`, `mit`, `mosh`, and `ironscheme`.

## Dependencies

```sh
kons add example/base --version ^1.2
kons add --akku srfi-1 --version ^1.0
kons add --snow retropikzel/system --version ^1.0
kons add local/lib --path ../lib
kons add remote/lib --git https://example.invalid/lib.git --rev main
kons add scheme/base --system
kons remove local/lib
kons update          # resolve deps, write kons.lock
kons fetch           # download missing deps
kons vendor          # copy locked deps into vendor/
```

The default registry is `https://kons.playxe.org`. Add another:

```sh
kons registry add default https://packages.example.org --default
```

## Publish

```sh
kons login --token kons_...
kons package
kons publish --dry-run
kons publish
kons yank example/lib@1.2.3
```

`kons.scm` needs name, version, owner, description, and license.

## Workspaces

```scheme
;; kons.scm
(workspace
  (members
    "packages/lib"
    "apps/cli"))
```

```sh
kons test --workspace
kons run --package apps/cli
```

## Docs

- [Usage](docs/usage.md)
- [Manifest](docs/manifest.md)
- [Workspaces](docs/workspaces.md)
- [Development](docs/development.md)
