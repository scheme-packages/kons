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
curl -fsSL https://raw.githubusercontent.com/scheme-packages/kons/main/install.sh | sh
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

Supported names are `capy`, `guile`, `gauche`/`gosh`, `chibi`/`chibi-scheme`,
and `chez`/`chezscheme`.

## Add dependencies

```sh
kons add example/base --version ^1.2
kons add local/lib --path ../lib
kons add remote/lib --git https://example.invalid/lib.git --rev main
kons add scheme/base --system
kons remove local/lib
kons update
kons fetch
```

Registry packages use `https://kons.playxe.org` by default. To use another
registry, configure it like this:

```sh
kons registry add default https://packages.example.org --default
kons registry index https://packages.example.org/index/config.json default --default
```

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
