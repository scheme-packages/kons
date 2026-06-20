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

```json
{
  "name": "example/lib",
  "owner": "scheme-packages",
  "version": "1.0.0",
  "description": "Example Scheme library",
  "license": "MIT",
  "keywords": ["scheme", "example"],
  "dialects": ["r7rs"],
  "dependencies": [
    { "name": "example/base", "req": "^1.0", "kind": "normal" }
  ],
  "archiveBase64": "..."
}
```

## Sparse Index

```text
GET /index/config.json
GET /index/ex/am/example-lib
```

## S3-Compatible Storage

Set `KONS_STORAGE=s3` and configure `KONS_S3_*` variables. See `.env.example`.

## Ownership

- The first authenticated publisher owns the package.
- Owners can publish new versions, yank/unyank, and delete packages or specific
  package versions from the account page.
- Owners can be managed through `kons owner list`, `kons owner --add`, and
  `kons owner --remove`.
- Admin emails from `KONS_ADMIN_EMAILS` can manage any package.
- Package versions are immutable.
- Yanking does not delete archives; it only prevents new dependency resolution
  from selecting that version.
