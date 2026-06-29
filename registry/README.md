# (kons) Registry

**(kons)** - package registry for `kons` package manager and build system.

## Quick start (local)

Requires Node.js 26 or newer.

```sh
cd registry
npm run dev
```

Open `http://127.0.0.1:8787`. Development mode prints email verification codes
to the server log.

Configure the CLI against the local registry:

```sh
kons registry add local http://127.0.0.1:8787 --default
kons login --registry local --token kons_...
kons package --list
kons publish --registry local --dry-run
kons publish --registry local
kons search example --registry local
```

## Production deployment

Use Docker Compose with Gmail SMTP for email registration:

```sh
cd registry
cp .env.example .env
# edit .env (see DEPLOY.md)
docker compose up -d --build
```

Full walkthrough: [DEPLOY.md](./DEPLOY.md)

Includes:

- Gmail App Password setup
- Open or allowlisted email registration
- HTTPS reverse proxy examples
- Backups and OAuth configuration

## Pages

| URL | Purpose |
|-----|---------|
| `/` | Search and browse packages |
| `/account` | Register, sign in, API tokens, publish |
| `/index/config.json` | Sparse index config |

## Configuration

Core settings:

```sh
KONS_REGISTRY_HOST=0.0.0.0
KONS_REGISTRY_PORT=8787
KONS_REGISTRY_BASE_URL=https://packages.example.org
KONS_REGISTRY_DATA=/var/lib/kons-registry
KONS_SESSION_SECRET='replace-this'
KONS_ADMIN_EMAILS='you@example.org'
KONS_REGISTRY_MESSAGE='Maintenance window Sunday 02:00 UTC.'
KONS_REGISTRY_MESSAGE_URL='https://status.example.org'
```

When `KONS_REGISTRY_BASE_URL` is set, browser navigation links use that public
origin. This is useful when the registry process listens on `127.0.0.1` behind a
proxy or tunnel.

Email registration:

```sh
KONS_EMAIL_REGISTRATION=1
KONS_EMAIL_OPEN_REGISTRATION=1
KONS_EMAIL_ALLOWLIST='you@example.org,@example.org'
KONS_EMAIL_CODE_TTL_MINUTES=15
```

Gmail SMTP (sends verification codes):

```sh
KONS_SMTP_HOST=smtp.gmail.com
KONS_SMTP_PORT=587
KONS_SMTP_USER=you@gmail.com
KONS_SMTP_PASS=your-gmail-app-password
KONS_SMTP_FROM=you@gmail.com
```

Without SMTP configured, codes are written to the server log. For local dev
only, `KONS_EMAIL_SHOW_CODES=1` also returns codes in API responses.

OAuth registration:

```sh
KONS_AUTH_GITHUB_CLIENT_ID=...
KONS_AUTH_GITHUB_CLIENT_SECRET=...
KONS_AUTH_GOOGLE_CLIENT_ID=...
KONS_AUTH_GOOGLE_CLIENT_SECRET=...
```

Callback URLs:

```text
https://packages.example.org/auth/github/callback
https://packages.example.org/auth/google/callback
```

## API Tokens

Sign in at `/account`, choose a username if this is a new account, create a
token, then use it for publish/yank requests:

```text
Authorization: Bearer kons_...
```

For CI, set `KONS_REGISTRY_TOKEN` instead of writing credentials to
`KONS_HOME`, or pass `--token` to `kons publish`, `kons yank`, and
`kons owner`.

## Publish API

`PUT /api/v1/packages/new`

Package names must use lowercase slash-separated segments. Top-level route names
such as `api`, `auth`, `index`, `search`, and `tokens` are reserved.

```json
{
  "name": "example/lib",
  "owner": "scheme-packages",
  "version": "1.0.0",
  "description": "Example Scheme library",
  "license": "MIT OR Apache-2.0",
  "keywords": ["scheme", "example"],
  "dialects": ["r7rs"],
  "dependencies": [
    { "type": "registry", "name": "example/base", "req": "^1.0", "kind": "normal" },
    { "type": "akku", "name": ["chibi", "match"], "req": "0.7.0", "source": "akku" },
    { "type": "snow", "name": ["retropikzel", "system"], "req": "^1.0", "source": "snow" }
  ],
  "archiveBase64": "..."
}
```

Dependency `type` defaults to `registry`. Use `type: "akku"` to publish
metadata for a dependency resolved from an Akku archive source; flat Akku names
are strings, and list-shaped Akku names are arrays. Use `type: "snow"` for
Snow Fort dependency metadata; Snow names are arrays and `source` defaults to
the Snow repository alias or URL.

## Signed Metadata

The registry can sign package-version metadata and sparse index entries with
Ed25519. This is optional for local registries, but public registries should
enable it and publish the public key out-of-band for clients that set
`(trust required)`.

Generate a key pair:

```sh
openssl genpkey -algorithm ed25519 -out registry-signing-private.pem
openssl pkey -in registry-signing-private.pem -pubout -out registry-signing-public.pem
```

Configure the server:

```sh
KONS_REGISTRY_SIGNING_KEY_ID=2026-06-main
KONS_REGISTRY_SIGNING_PRIVATE_KEY_FILE=/run/secrets/kons-registry-signing-private.pem
KONS_REGISTRY_SIGNING_PUBLIC_KEY_FILE=/etc/kons/registry-signing-public.pem
```

Clients can require signatures by pinning the public key in
`$KONS_HOME/config/registries.scm`:

```scheme
(registries
  (registry
    (name "public")
    (url "https://packages.example.org")
    (trust required)
    (key-id "2026-06-main")
    (key-file "keys/2026-06-main.pem")))
```

For key rotation, configure clients with both trusted keys before switching the
server:

```scheme
(registries
  (registry
    (name "public")
    (url "https://packages.example.org")
    (trust required)
    (keys
      (key (id "2026-06-main") (file "keys/2026-06-main.pem"))
      (key (id "2026-09-main") (file "keys/2026-09-main.pem")))))
```

After clients have both keys, restart the registry with
`KONS_REGISTRY_SIGNING_KEY_ID=2026-09-main` and the new private/public key
files. Keep the old public key in client configs until old signed metadata
caches and older lockfiles no longer need to be verified offline.

## Rate Limits

The registry applies in-memory fixed-window limits per client address. Configure
them with:

```sh
KONS_RATE_LIMITS=1
KONS_RATE_LIMIT_WINDOW_MS=60000
KONS_RATE_LIMIT_AUTH_LIMIT=20
KONS_RATE_LIMIT_PUBLISH_LIMIT=30
KONS_RATE_LIMIT_SEARCH_LIMIT=120
KONS_RATE_LIMIT_DOWNLOAD_LIMIT=120
```

Set `KONS_RATE_LIMITS=0` to disable limits. Behind a proxy, forward the real
client address in `X-Forwarded-For`.

## Sparse Index

```text
GET /index/config.json
GET /index/ex/am/example-lib
```

## S3-Compatible Storage

Set `KONS_STORAGE=s3` and configure `KONS_S3_*` variables. See `.env.example`.

## Ownership

- The first authenticated publisher owns the package.
- Owners can publish new versions and yank/unyank versions from the account
  page.
- Owners can be managed through `kons owner list`, `kons owner --add`, and
  `kons owner --remove`.
- Admin emails from `KONS_ADMIN_EMAILS` can manage any package.
- Package versions are immutable; delete requests are denied and recorded in
  the audit log.
- Yanking does not delete archives; it only prevents new dependency resolution
  from selecting that version.
