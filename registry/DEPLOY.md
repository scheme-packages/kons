# Deploying (kons)

This guide covers a full production-style deployment with Docker Compose, email
registration, and Gmail SMTP for verification codes.

## What you get

- Package search and sparse index at `/`
- Account registration and sign-in at `/account`
- Email verification codes delivered over SMTP
- Persistent SQLite database and package archives in a Docker volume
- Optional OAuth providers (GitHub, Google, etc.)

## Prerequisites

- A server or VM with Docker and Docker Compose
- A domain name pointing at that server (recommended)
- A Gmail account with 2-step verification enabled
- A Gmail **App Password** for SMTP (not your normal Gmail password)

## 1. Create a Gmail App Password

1. Open [Google Account Security](https://myaccount.google.com/security)
2. Enable **2-Step Verification** if it is not already on
3. Open **App passwords**
4. Create a password for "Mail" / "Other (kons registry)"
5. Copy the 16-character password

Use this value for `KONS_SMTP_PASS`.

## 2. Configure environment

From the `registry/` directory:

```sh
cp .env.example .env
```

Edit `.env`:

```sh
KONS_REGISTRY_BASE_URL=https://packages.example.org
KONS_SESSION_SECRET=$(openssl rand -hex 32)
KONS_ADMIN_EMAILS=you@gmail.com
KONS_REGISTRY_MESSAGE=Welcome to the public Scheme package registry.
KONS_REGISTRY_MESSAGE_URL=https://status.example.org

KONS_EMAIL_REGISTRATION=1
KONS_EMAIL_OPEN_REGISTRATION=1

KONS_SMTP_HOST=smtp.gmail.com
KONS_SMTP_PORT=587
KONS_SMTP_USER=you@gmail.com
KONS_SMTP_PASS=xxxx xxxx xxxx xxxx
KONS_SMTP_FROM=you@gmail.com
```

Notes:

- Set `KONS_REGISTRY_BASE_URL` to the public URL users will open in a browser.
  If the app is reached through `127.0.0.1` behind a proxy or tunnel, account,
  package, index, and API links in the web UI will point back to this public URL.
- `KONS_EMAIL_OPEN_REGISTRATION=1` allows any email address to register.
  Disable it and set `KONS_EMAIL_ALLOWLIST` to restrict sign-ups.
- Do **not** set `KONS_EMAIL_SHOW_CODES=1` in production when SMTP is configured.

### Add deployer messages to the web UI

For a single notice:

```sh
KONS_REGISTRY_MESSAGE_TITLE=Notice
KONS_REGISTRY_MESSAGE='Publishing is moderated during the migration.'
KONS_REGISTRY_MESSAGE_URL=https://status.example.org
KONS_REGISTRY_MESSAGE_LINK_LABEL=Status
KONS_REGISTRY_MESSAGE_KIND=warning
```

For multiple notices, set `KONS_REGISTRY_MESSAGES_JSON` to a JSON array of
objects with `title`, `body`, `url`, `label`, and `kind`.

### Restrict registration to specific addresses

```sh
KONS_EMAIL_OPEN_REGISTRATION=0
KONS_EMAIL_ALLOWLIST=you@gmail.com,@yourdomain.org
```

Domain entries must start with `@`.

## 3. Start with Docker Compose

```sh
cd registry
docker compose up -d --build
```

Check health:

```sh
curl -fsS http://127.0.0.1:8787/healthz
docker compose logs -f registry
```

You should see:

```text
[kons] email registration enabled (open registration, delivery: smtp://smtp.gmail.com:587)
```

Open the registry:

```text
http://127.0.0.1:8787
```

Data is stored in the `registry-data` Docker volume (`registry.sqlite` and
archives).

## 4. Put HTTPS in front (recommended)

The registry listens on plain HTTP inside the container. Terminate TLS with a
reverse proxy.

### Caddy example

```text
packages.example.org {
  reverse_proxy 127.0.0.1:8787
}
```

### nginx example

```nginx
server {
  listen 443 ssl;
  server_name packages.example.org;

  location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
  }
}
```

After HTTPS is working, confirm:

```sh
curl -fsS https://packages.example.org/healthz
curl -fsS https://packages.example.org/api/v1/meta
```

## 5. Register the first account

1. Open `https://packages.example.org/account`
2. Enter the username you want on this registry
3. Enter your email address
4. Click **Send verification code**
5. Check your inbox for the 6-digit code
6. Enter the code and click **Verify code**

The first verified email in `KONS_ADMIN_EMAILS` becomes an admin account.

Then:

1. Create an API token on the **Tokens** tab
2. Publish a package with the CLI
3. Use the **Packages** card on the account page to yank, unyank, download, or
   delete package versions

## 6. Optional OAuth providers

Add provider credentials to `.env`, then restart:

```sh
docker compose up -d
```

Callback URLs must use your public base URL:

```text
https://packages.example.org/auth/github/callback
https://packages.example.org/auth/google/callback
https://packages.example.org/auth/codeberg/callback
https://packages.example.org/auth/discord/callback
```

## 7. Upgrades and backups

Upgrade to a new image:

```sh
docker compose pull
docker compose up -d --build
```

Back up registry data:

```sh
docker compose down
docker run --rm \
  -v registry_registry-data:/data \
  -v "$PWD/backups:/backup" \
  alpine tar czf /backup/kons-registry-$(date +%F).tgz -C /data .
docker compose up -d
```

Restore by extracting the archive into the volume before starting the service.

## 8. Local development without Docker

For local testing without real email delivery:

```sh
cd registry
KONS_EMAIL_REGISTRATION=1 \
KONS_EMAIL_SHOW_CODES=1 \
KONS_EMAIL_OPEN_REGISTRATION=1 \
npm run dev
```

Verification codes are printed to the server log and optionally returned in the
API response.

To test Gmail SMTP locally, add the `KONS_SMTP_*` variables to your shell or a
local `.env` file and run `node server.js`.

## Troubleshooting

### Gmail rejects SMTP authentication

- Use an App Password, not your normal Gmail password
- Confirm 2-step verification is enabled on the Google account
- Check `KONS_SMTP_USER` matches the Gmail address that owns the App Password

### Registration returns 403

- Ensure `KONS_EMAIL_REGISTRATION=1`
- For restricted mode, confirm the address matches `KONS_EMAIL_ALLOWLIST`

### OAuth callback errors

- Callback URL must exactly match the provider app settings
- `KONS_REGISTRY_BASE_URL` must match the public HTTPS URL

### Codes only appear in logs

- SMTP variables are missing or incorrect
- Check `docker compose logs registry` for SMTP errors
