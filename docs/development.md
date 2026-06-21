# Development

This page is for working on kons itself.

## Run tests

Main test suite:

```sh
make check
```

Full local matrix:

```sh
make check-required
```

For the full matrix you need these commands on `PATH`:

- `capy`
- `gosh`
- `guile`
- `chibi-scheme`
- `scheme` from Chez Scheme
- `sash`
- `stklos`
- `kawa`
- `loko`
- `skint`
- `cyclone`
- `scheme` from MIT/GNU Scheme, selected as `mit`
- `mosh`
- `ironscheme`

## Registry tests

When changing `registry/`, also run:

```sh
cd registry
npm test
npm run check
```

## Manual release check

Before release, run kons with the Scheme implementations it supports well:

```sh
kons --scheme capy test
kons --scheme gosh test
kons --scheme guile test
kons --scheme chibi-scheme test
kons --scheme sagittarius test
kons --scheme stklos test
kons --scheme kawa test
kons --scheme loko test
kons --scheme skint test
kons --scheme cyclone test
```

Also check R6RS examples with:

```sh
kons --scheme capy run
kons --scheme guile run
kons --scheme chez run
kons --scheme mosh run
kons --scheme ironscheme run
```

Local container verification for the non-default runtimes uses Podman:

```sh
make ci-podman-local
```
