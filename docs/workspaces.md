# Workspaces

A workspace is one repo with many kons packages.

Use it when you have a library and an app together, or many packages that
depend on each other.

## Create workspace

Root `kons.scm`:

```scheme
(workspace
  (members
    "packages/lib"
    "apps/cli"))
```

Each member folder still has its own `kons.scm`.

Example:

```text
my-project/
  kons.scm
  packages/lib/kons.scm
  apps/cli/kons.scm
```

## Run commands on all members

```sh
kons check --workspace
kons build --workspace
kons test --workspace
```

## Run one member

Use member path or package name:

```sh
kons run --package apps/cli
kons test --package packages/lib
kons install --package apps/cli --name example-cli
kons publish --package packages/lib --registry local
```

When your shell is already inside a member folder, kons detects the workspace
and uses that member.

## Member dependencies

One member can depend on another:

```scheme
(dependencies
  (workspace (name (example lib))))
```

During local work, kons uses the member source directly.

For publishing, add the version that registry users should get:

```scheme
(dependencies
  (workspace (name (example lib)) (version "1.0.0")))
```

Then local work still uses the workspace source, but `kons publish` writes a
registry dependency on `example/lib` version `1.0.0`.

If the version is missing, publish fails. This is required, because people outside
your repo cannot use your workspace path.

## Common workflow

```sh
kons check --workspace
kons test --workspace
kons run --package apps/cli
kons publish --package packages/lib --dry-run
```
