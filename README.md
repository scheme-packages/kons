# kons

[![license: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

kons is a package manager and build system for Scheme, inspired by Cargo.

* No complicated setup to point out where libraries are; kons discovers
  `define-library` and R6RS `library` forms
  with a `kons.scm` manifest and a transitive `kons.lock`.
* One tool across many Schemes: drive the manager with Capy, Gauche,
  GNU Guile, or Chibi Scheme, and run target packages on Chez Scheme,
  Sagittarius, STklos, Kawa, Loko, Skint, Cyclone, MIT/GNU Scheme,
  Mosh, and IronScheme when the dialect matches.
* Translate straightforward R7RS `define-library` files into generated
  R6RS `.sls` files so R7RS packages run on R6RS-only implementations.
* Consume packages out of the box from the kons registry,
  [Akku.scm][akku] archives, and [Snow][snow] snowballs, plus local
  paths, Git, and system deps — no separate tool needed.
* Workspaces, features, build hooks, vendoring, and signed registry
  metadata for repeatable, offline-capable builds.

 [akku]: https://akkuscm.org/
 [snow]: https://snow-fort.org/


## Dependencies

kons itself needs a Scheme implementation that can run its manager
library. It is developed and tested with Capy, Gauche, GNU Guile, and
Chibi Scheme. Network operations use `curl`, and Git sources use `git`
when available. Target packages can target a much wider set of
implementations (see below); kons only needs one of the manager
implementations installed to drive them.

## Supported Schemes

kons can run itself on:

 - Capy
 - Gauche
 - GNU Guile
 - Chibi Scheme

kons can drive target packages on:

 - Capy
 - Chez Scheme
 - Gauche
 - GNU Guile
 - Chibi Scheme
 - Sagittarius
 - STklos
 - Kawa
 - Loko
 - Skint
 - Cyclone
 - MIT/GNU Scheme
 - Mosh
 - IronScheme

## Installation

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

Pick a default Scheme:

```sh
export KONS_SCHEME=guile
```

You can also select a Scheme per command:

```sh
kons --scheme gosh test
```

Other useful `install.sh` flags: `--source DIR` to install from a local
checkout, `--tarball-url URL` / `--repo URL` / `--ref REF` to control
where the source comes from, and `--prefix DIR` as an alias for
`--kons-home`.

## Usage

How to get started with a new project:

 - Run `kons new hello` to create a new project from a template, then
   `cd hello` and `kons run`. For an existing folder, run `kons init .`.
   For a library-only package, run `kons new my-lib --lib`.
 - Run `kons add example/base --version ^1.2` to add a registry
   dependency. Use `--akku` for Akku packages, `--snow` for Snow
   packages, `--path` for local packages, `--git` for Git sources, and
   `--system` for dependencies provided by the Scheme implementation.
 - Run `kons update` to resolve dependencies and write `kons.lock`.
   `kons update --upgrade` selects newer compatible versions. Run
   `kons fetch` to download missing dependencies.
 - Run `kons run`, `kons test`, `kons bench`, `kons build`, `kons repl`,
   or `kons check`. Pass arguments to your program after `--`, e.g.
   `kons run -- --name Ada`.
 - Run `kons build --locked`, `--offline`, or `--frozen` for
   repeatable CI builds. `kons vendor` copies locked registry deps into
   a vendor tree for fully offline builds.

The default registry is `https://kons.playxe.org`. Configure alternate
registries and signing keys with `kons registry ...` or in
`$KONS_HOME/config/registries.scm`.

When you have a package you want to share, log in and publish:

```sh
kons login --registry local --token kons_...
kons package
kons publish --registry local
```

More details, including the full command list, manifest fields,
workspaces, features, and build hooks, are in the docs:

 - [Usage](docs/usage.md)
 - [Manifest](docs/manifest.md)
 - [Workspaces](docs/workspaces.md)
 - [Development](docs/development.md)

## Compatibility with Akku and Snow

kons speaks the [Akku.scm][akku] and [Snow][snow] formats directly and
fetches their packages out of the box. You do not need `akku` or a Snow
client installed. kons has its own readers, resolvers, and verified
materializers for each, kept in `src/kons/akku/` and `src/kons/snow/`.

[Akku.scm][akku] is a language package manager for Scheme that
distributes R6RS and R7RS libraries from `https://archive.akkuscm.org/`.
kons consumes Akku packages with `--akku`:

```sh
kons add --akku srfi-1 --version ^1.0
kons add --akku '(chibi match)' --version 0.7.0
kons add --akku srfi-1 --registry akku
```

Akku archive indexes are verified against trusted OpenPGP keyrings from
`$KONS_HOME/config/akku/keys.d` (bundled keys ship in
`src/kons/akku/keys.d/`). Source payloads are materialized from locked
metadata: URL tarballs are SHA-256 checked, Git sources are checked out
to the locked revision, and directory sources are copied only from safe
paths. Metadata and source caches live separately from the kons
registry under `$KONS_HOME/store/akku/`. kons consumes Akku packages
but does not publish to the Akku registry — that stays with `akku
publish`.

[Snow][snow] (snow-fort.org) is the long-running R7RS package repo at
`https://snow-fort.org/s/repo.scm`. kons consumes Snow packages with
`--snow`, using Scheme list names:

```sh
kons add --snow retropikzel/system --version ^1.0
kons add --snow '(chibi match)' --version 0.7.0
kons add --snow retropikzel/system --registry https://snow-fort.org/s/repo.scm
```

Snow repository metadata is cached under `$KONS_HOME/store/snow/metadata`,
and snowballs are checksum-verified and extracted under
`$KONS_HOME/store/snow/sources`. Offline and frozen commands reuse those
caches. As with Akku, kons consumes Snow packages but does not publish
to Snow.

### How they compare

| | kons | Akku.scm | Snow (snow-fort) |
| --- | --- | --- | --- |
| Primary focus | Build system + package manager (Cargo-style) | Package manager + index | Package index (snowballs) |
| Package sources | kons registry, Akku, Snow, Git, path, system | Akku archive | Snow repo |
| Manifest | `kons.scm` (package/workspace) | `Akku.scm` | none (per-package metadata) |
| Lockfile | `kons.lock`, transitive | `akku.lock` | none |
| Transitive semver solving | yes | partial | no |
| Run/test/bench/build/repl | yes, per implementation | install into `.akku`, you run | install snowballs, you run |
| R7RS → R6RS translation | yes, generated `.sls` | yes (R7RS for R6RS impls) | no |
| Multi-implementation run targets | 14 runtimes | several, via `.akku/env` | several |
| Workspaces, features, build hooks | yes | no | no |
| Vendoring / offline / frozen | yes | offline cache | cache only |
| Signed metadata | kons registry + Akku OpenPGP | OpenPGP | no |
| Publish target | kons registry | Akku registry | Snow (out of scope for kons) |
| Implementations that run the tool | Capy, Gauche, GNU Guile, Chibi Scheme | GNU Guile, Chez Scheme, Loko | n/a (no manager) |

### kons — pros and cons

Pros:

* One manifest + lockfile gives transitive solving, repeatable builds,
  and offline/vendored layouts.
* Drives 14 target runtimes from a single manager, with R7RS→R6RS
  translation for R6RS-only implementations.
* Reads Akku and Snow packages natively, so existing libraries work
  without a second tool.
* Workspaces, features, build hooks, signed registry metadata, and
  `kons vendor` for frozen CI.

Cons:

* The kons registry is newer and smaller than Akku or Snow; reach is
  built on top of those indexes for now.
* kons does not publish to Akku or Snow — use `akku publish` or the
  Snow process for those.
* The manager itself only runs on Capy, Gauche, GNU Guile, and
  Chibi Scheme (target packages can still use the wider set).
* R7RS→R6RS translation covers a portable subset; unsupported forms
  such as `(scheme time)`, `(scheme load)`, and `(scheme repl)` are
  reported, not silently broken.

### Akku.scm — pros and cons

Pros:

* Established R6RS/R7RS archive with OpenPGP-signed indexes.
* Converts R7RS libraries for R6RS implementations and exposes them to
  many Schemes via `.akku/env`.
* Lockfile and per-project `.akku` sandbox.

Cons:

* No Cargo-style workspaces, features, build hooks, or vendoring.
* Tooling runs only on GNU Guile, Chez Scheme, or Loko.
* No built-in run/test/bench/build command matrix across runtimes.

### Snow (snow-fort) — pros and cons

Pros:

* Long-running R7RS repository with broad implementation coverage.
* Simple snowball distribution that many Schemes can consume directly.

Cons:

* No manifest, lockfile, or transitive version solving.
* No signing, no build system, no run/test commands.
* No workspace, feature, or offline-vendoring story.

## Source layout

kons is written in portable R7RS `(define-library)` modules under
`src/`. The entry point is `src/main.scm`, which calls
`(kons core)`; that delegates to `(kons commands)`, which wires up every
subcommand. The tree is organized so each concern has its own library:

 - `src/kons/core.sld`, `commands.sld`, `options.sld`, `ui.sld` —
   command dispatch, argument grammar, and user-facing output.
 - `src/kons/commands/` — one library per subcommand (`add`, `build`,
   `check`, `fetch`, `install`, `publish`, `registry`, `run`, `test`,
   `vendor`, `verify`, etc.), sharing `framework.sld`.
 - `src/kons/actions/` — the work behind each command: dependency
   resolution, lockfile and manifest handling, library discovery,
   scanning, packaging, and publishing. `actions/activation/` covers
   build hooks, generated libraries, and R7RS→R6RS translation;
   `actions/registry/` covers registry HTTP routes, trust, and display.
 - `src/kons/manifest.sld`, `lock.sld`, `resolver.sld`, `semver.sld`,
   `features.sld`, `names.sld` — manifest and lockfile data models,
   version solving, feature selection, and package-name handling.
 - `src/kons/registry.sld`, `library-discovery.sld`, `runner.sld`,
   `jobs.sld`, `util.sld`, `implementation.sld` — registry client,
   source-tree library discovery, program runner, parallel jobs,
   shared utilities, and implementation detection.
 - `src/kons/implementation/` — per-implementation adapters
   (`chez`, `guile`, `gauche`, `chibi`, `capy`, `sagittarius`, `stklos`,
   `kawa`, `loko`, `skint`, `cyclone`, `mit`, `mosh`, `ironscheme`).
 - `src/kons/dep/` — dependency source backends: `registry`, `akku`,
   `snow`, `git`, `path`, `system`, `workspace`, `store`, `shared`.
 - `src/kons/akku/` and `src/kons/snow/` — Akku and Snow metadata
   formats, resolvers, lock/manifest readers, and the Akku OpenPGP
   keyring under `akku/keys.d/`.
 - `src/kons/compat/` — small compatibility shims for `files`,
   `threads`, and `json` across manager implementations.

Add a new subcommand by dropping a library in `commands/` and
`actions/`, then registering its maker in `commands.sld`.

## Contact

 - Email: adel.prokurov@gmail.com
 - Telegram: [@aprokurov](https://t.me/aprokurov)
 - IRC: `playX` on `#scheme` at [Libera.Chat](https://libera.chat/).
 - [kons on GitHub](https://github.com/scheme-packages/kons) for issues
   and source.
 - The default registry lives at `https://kons.playxe.org`.

## License

kons is free software released under the terms of the BSD 3-Clause
license. See [LICENSE](LICENSE) for the full text. The license covers
the source code of kons itself. Mere use of kons as a build tool does
not place any restrictions on your source code, in the same way that
CMake or GNU automake do not impose their licenses on the projects that
use them.

If licensing is important to you, review the license of any packages
you install into your project. Kons reports package licenses via
`kons license-scan` and gathers copyright notices into a notices
directory, but this information may be incomplete.
