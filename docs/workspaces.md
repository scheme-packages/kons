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
    "apps/cli")
  (default-members "apps/cli")
  (package
    (license "MIT")
    (repository "https://example.org/project.git")
    (authors "Example Team"))
  (dependencies
    (workspace (name (example lib)) (version "1.0.0"))))
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

If the workspace declares `default-members`, package commands run at the root
without `--workspace` or `--package` use those members:

```sh
kons check
kons test
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

Member commands share the workspace root lockfile. For example, running
`kons update` from `apps/cli` writes `kons.lock` next to the workspace
manifest, not inside `apps/cli`.

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

You can also declare that version once in the root `(workspace
(dependencies ...))` block. If no member or workspace default supplies the
version, publish fails because people outside your repo cannot use your
workspace path.

## Inherited Metadata

Workspace package defaults reduce repeated metadata in members:

```scheme
(workspace
  (members "packages/lib" "apps/cli")
  (default-members "apps/cli")
  (package
    (license "MIT")
    (repository "https://example.org/project.git")
    (homepage "https://example.org")
    (authors "Example Team")))
```

Members inherit empty `license`, `repository`, `homepage`, `documentation`, and
`authors` fields. A member can still set its own value to override the
workspace default.

## Common workflow

```sh
kons check --workspace
kons test --workspace
kons run --package apps/cli
kons publish --package packages/lib --dry-run
```
