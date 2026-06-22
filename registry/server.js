import { createHmac, createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { sendMail, smtpConfigured } from "./smtp.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const env = process.env;
const config = {
  host: env.KONS_REGISTRY_HOST || "127.0.0.1",
  port: Number(env.KONS_REGISTRY_PORT || 8787),
  dataDir: path.resolve(env.KONS_REGISTRY_DATA || path.join(__dirname, "data")),
  publicDir: path.join(__dirname, "public"),
  baseUrl: env.KONS_REGISTRY_BASE_URL || "",
  sessionSecret: env.KONS_SESSION_SECRET || "kons-registry-dev-secret",
  admins: splitList(env.KONS_ADMIN_EMAILS),
  emailRegistration: env.KONS_EMAIL_REGISTRATION === "1",
  emailOpenRegistration: env.KONS_EMAIL_OPEN_REGISTRATION === "1",
  emailAllowlist: splitList(env.KONS_EMAIL_ALLOWLIST || env.KONS_ADMIN_EMAILS),
  emailShowCodes: env.KONS_EMAIL_SHOW_CODES === "1",
  emailCodeTtlMinutes: Number(env.KONS_EMAIL_CODE_TTL_MINUTES || 15),
  sourceUrl: "https://github.com/scheme-packages/kons",
  deployerMessages: parseDeployerMessages(env),
  smtp: {
    host: env.KONS_SMTP_HOST || "",
    port: Number(env.KONS_SMTP_PORT || 587),
    user: env.KONS_SMTP_USER || "",
    pass: env.KONS_SMTP_PASS || "",
    from: env.KONS_SMTP_FROM || env.KONS_SMTP_USER || "",
    secure: env.KONS_SMTP_SECURE === "1",
  },
  maxArchiveBytes: Number(env.KONS_MAX_ARCHIVE_MB || 32) * 1024 * 1024,
  storage: env.KONS_STORAGE || "local",
  s3: {
    endpoint: env.KONS_S3_ENDPOINT || "",
    region: env.KONS_S3_REGION || "us-east-1",
    bucket: env.KONS_S3_BUCKET || "",
    accessKeyId: env.KONS_S3_ACCESS_KEY_ID || "",
    secretAccessKey: env.KONS_S3_SECRET_ACCESS_KEY || "",
    forcePathStyle: env.KONS_S3_FORCE_PATH_STYLE !== "0",
    publicBaseUrl: env.KONS_S3_PUBLIC_BASE_URL || "",
  },
};

const oauthProviders = {
  google: {
    label: "Google",
    clientId: env.KONS_AUTH_GOOGLE_CLIENT_ID,
    clientSecret: env.KONS_AUTH_GOOGLE_CLIENT_SECRET,
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    userUrl: "https://openidconnect.googleapis.com/v1/userinfo",
    scope: "openid email profile",
    map(profile) {
      return {
        providerId: String(profile.sub),
        username: profile.email ? profile.email.split("@")[0] : `google-${profile.sub}`,
        displayName: profile.name || profile.email || `google-${profile.sub}`,
        email: profile.email || "",
        avatarUrl: profile.picture || "",
      };
    },
  },
  github: {
    label: "GitHub",
    clientId: env.KONS_AUTH_GITHUB_CLIENT_ID,
    clientSecret: env.KONS_AUTH_GITHUB_CLIENT_SECRET,
    authorizeUrl: "https://github.com/login/oauth/authorize",
    tokenUrl: "https://github.com/login/oauth/access_token",
    userUrl: "https://api.github.com/user",
    emailsUrl: "https://api.github.com/user/emails",
    scope: "read:user user:email",
    async map(profile, token) {
      let email = profile.email || "";
      if (!email && token) {
        const emails = await oauthJson("https://api.github.com/user/emails", token);
        const primary = Array.isArray(emails)
          ? emails.find((item) => item.primary && item.verified) || emails.find((item) => item.verified)
          : null;
        email = primary?.email || "";
      }
      return {
        providerId: String(profile.id),
        username: profile.login || `github-${profile.id}`,
        displayName: profile.name || profile.login || `github-${profile.id}`,
        email,
        avatarUrl: profile.avatar_url || "",
      };
    },
  },
  codeberg: {
    label: "Codeberg",
    clientId: env.KONS_AUTH_CODEBERG_CLIENT_ID,
    clientSecret: env.KONS_AUTH_CODEBERG_CLIENT_SECRET,
    authorizeUrl: "https://codeberg.org/login/oauth/authorize",
    tokenUrl: "https://codeberg.org/login/oauth/access_token",
    userUrl: "https://codeberg.org/api/v1/user",
    scope: "read:user read:email",
    map(profile) {
      return {
        providerId: String(profile.id),
        username: profile.login || `codeberg-${profile.id}`,
        displayName: profile.full_name || profile.login || `codeberg-${profile.id}`,
        email: profile.email || "",
        avatarUrl: profile.avatar_url || "",
      };
    },
  },
  discord: {
    label: "Discord",
    clientId: env.KONS_AUTH_DISCORD_CLIENT_ID,
    clientSecret: env.KONS_AUTH_DISCORD_CLIENT_SECRET,
    authorizeUrl: "https://discord.com/api/oauth2/authorize",
    tokenUrl: "https://discord.com/api/oauth2/token",
    userUrl: "https://discord.com/api/users/@me",
    scope: "identify email",
    map(profile) {
      const avatarUrl = profile.avatar
        ? `https://cdn.discordapp.com/avatars/${profile.id}/${profile.avatar}.png`
        : "";
      return {
        providerId: String(profile.id),
        username: profile.username || `discord-${profile.id}`,
        displayName: profile.global_name || profile.username || `discord-${profile.id}`,
        email: profile.email || "",
        avatarUrl,
      };
    },
  },
};

await fs.mkdir(config.dataDir, { recursive: true });
await fs.mkdir(path.join(config.dataDir, "archives"), { recursive: true });
await fs.mkdir(path.join(config.dataDir, "tmp"), { recursive: true });

const db = new DatabaseSync(path.join(config.dataDir, "registry.sqlite"));
db.exec(`
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  email TEXT UNIQUE,
  avatar_url TEXT NOT NULL DEFAULT '',
  is_admin INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS identities (
  provider TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  username TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  raw_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (provider, provider_id)
);
CREATE TABLE IF NOT EXISTS sessions (
  id_hash TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS api_tokens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  prefix TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT
);
CREATE TABLE IF NOT EXISTS packages (
  name TEXT PRIMARY KEY,
  description TEXT NOT NULL DEFAULT '',
  homepage TEXT NOT NULL DEFAULT '',
  repository TEXT NOT NULL DEFAULT '',
  documentation TEXT NOT NULL DEFAULT '',
  keywords_json TEXT NOT NULL DEFAULT '[]',
  created_by INTEGER NOT NULL REFERENCES users(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS package_owners (
  package_name TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'owner',
  created_at TEXT NOT NULL,
  PRIMARY KEY (package_name, user_id)
);
CREATE TABLE IF NOT EXISTS versions (
  package_name TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
  version TEXT NOT NULL,
  checksum TEXT NOT NULL,
  size INTEGER NOT NULL,
  archive_key TEXT NOT NULL,
  archive_filename TEXT NOT NULL,
  published_by INTEGER NOT NULL REFERENCES users(id),
  published_at TEXT NOT NULL,
  yanked INTEGER NOT NULL DEFAULT 0,
  yanked_at TEXT,
  yanked_by INTEGER REFERENCES users(id),
  description TEXT NOT NULL DEFAULT '',
  license TEXT NOT NULL DEFAULT '',
  dialects_json TEXT NOT NULL DEFAULT '[]',
  features_json TEXT NOT NULL DEFAULT '[]',
  readme TEXT NOT NULL DEFAULT '',
  manifest_json TEXT NOT NULL DEFAULT '{}',
  download_count INTEGER NOT NULL DEFAULT 0,
  last_downloaded_at TEXT,
  PRIMARY KEY (package_name, version)
);
CREATE TABLE IF NOT EXISTS dependencies (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  dep_name TEXT NOT NULL,
  req TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'normal',
  registry TEXT,
  optional INTEGER NOT NULL DEFAULT 0,
  target TEXT,
  features_json TEXT NOT NULL DEFAULT '[]',
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS version_libraries (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  kind TEXT NOT NULL,
  library_name TEXT NOT NULL,
  library_key TEXT NOT NULL,
  path TEXT NOT NULL DEFAULT '',
  imports_json TEXT NOT NULL DEFAULT '[]',
  exports_json TEXT NOT NULL DEFAULT '[]',
  implementation TEXT NOT NULL DEFAULT '',
  dialect TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_version_libraries_key_kind ON version_libraries(library_key, kind);
CREATE INDEX IF NOT EXISTS idx_version_libraries_package_version ON version_libraries(package_name, version);
CREATE TABLE IF NOT EXISTS version_identifiers (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  kind TEXT NOT NULL,
  library_name TEXT NOT NULL,
  identifier TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'export',
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_version_identifiers_identifier ON version_identifiers(identifier);
CREATE INDEX IF NOT EXISTS idx_version_identifiers_package_version ON version_identifiers(package_name, version);
CREATE TABLE IF NOT EXISTS package_search_terms (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  term TEXT NOT NULL,
  field TEXT NOT NULL,
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_package_search_terms_term ON package_search_terms(term);
CREATE INDEX IF NOT EXISTS idx_package_search_terms_package_version ON package_search_terms(package_name, version);
CREATE TABLE IF NOT EXISTS auth_states (
  state TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  return_to TEXT NOT NULL DEFAULT '/',
  email TEXT,
  username TEXT,
  code_hash TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
`);
ensureColumn("auth_states", "username", "TEXT");
ensureColumn("packages", "keywords_json", "TEXT NOT NULL DEFAULT '[]'");
ensureColumn("versions", "readme", "TEXT NOT NULL DEFAULT ''");
ensureColumn("versions", "download_count", "INTEGER NOT NULL DEFAULT 0");
ensureColumn("versions", "last_downloaded_at", "TEXT");
ensureColumn("version_libraries", "implementation", "TEXT NOT NULL DEFAULT ''");
ensureColumn("version_libraries", "dialect", "TEXT NOT NULL DEFAULT ''");

function splitList(value = "") {
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function normalizeMessage(item) {
  if (!item || typeof item !== "object" || Array.isArray(item)) return null;
  const title = String(item.title || "").trim().slice(0, 120);
  const body = String(item.body || item.message || "").trim().slice(0, 1200);
  const url = String(item.url || item.href || "").trim().slice(0, 500);
  const label = String(item.label || item.linkLabel || "Learn more").trim().slice(0, 80);
  const kind = String(item.kind || "info").trim().toLowerCase();
  if (!title && !body) return null;
  return {
    title,
    body,
    url,
    label,
    kind: ["info", "success", "warning", "danger"].includes(kind) ? kind : "info",
  };
}

function parseDeployerMessages(sourceEnv) {
  const messages = [];
  const json = String(sourceEnv.KONS_REGISTRY_MESSAGES_JSON || "").trim();
  if (json) {
    try {
      const parsed = JSON.parse(json);
      const items = Array.isArray(parsed) ? parsed : [parsed];
      for (const item of items) {
        const message = normalizeMessage(item);
        if (message) messages.push(message);
      }
    } catch (error) {
      console.warn(`[kons] ignoring invalid KONS_REGISTRY_MESSAGES_JSON: ${error.message}`);
    }
  }

  const single = normalizeMessage({
    title: sourceEnv.KONS_REGISTRY_MESSAGE_TITLE,
    body: sourceEnv.KONS_REGISTRY_MESSAGE,
    url: sourceEnv.KONS_REGISTRY_MESSAGE_URL,
    label: sourceEnv.KONS_REGISTRY_MESSAGE_LINK_LABEL,
    kind: sourceEnv.KONS_REGISTRY_MESSAGE_KIND,
  });
  if (single) messages.push(single);
  return messages.slice(0, 6);
}

function nowIso() {
  return new Date().toISOString();
}

function publicBaseUrl(req) {
  if (config.baseUrl) return config.baseUrl.replace(/\/$/, "");
  const proto = req.headers["x-forwarded-proto"] || "http";
  const host = req.headers["x-forwarded-host"] || req.headers.host || `${config.host}:${config.port}`;
  return `${proto}://${host}`;
}

function configuredPublicUrl() {
  return config.baseUrl ? config.baseUrl.replace(/\/$/, "") : "";
}

function packageDownloadUrl(name, version) {
  const base = configuredPublicUrl();
  const path = `/api/v1/packages/${encodeURIComponent(name)}/${encodeURIComponent(version)}/download`;
  return base ? `${base}${path}` : path;
}

function randomToken(bytes = 32) {
  return randomBytes(bytes).toString("base64url");
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function hmac(key, value, encoding) {
  return createHmac("sha256", key).update(value).digest(encoding);
}

function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && timingSafeEqual(left, right);
}

function parseCookies(req) {
  const out = {};
  for (const part of String(req.headers.cookie || "").split(";")) {
    const index = part.indexOf("=");
    if (index > -1) out[part.slice(0, index).trim()] = decodeURIComponent(part.slice(index + 1).trim());
  }
  return out;
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, headers);
  res.end(body);
}

function sendJson(res, status, data, headers = {}) {
  send(res, status, JSON.stringify(data, null, 2), {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    ...headers,
  });
}

function redirect(res, location) {
  send(res, 302, "", { location });
}

function httpError(status, message, details = undefined) {
  const err = new Error(message);
  err.status = status;
  err.details = details;
  return err;
}

function validationError(message, fields) {
  throw httpError(400, message, { fields });
}

function readBody(req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(httpError(413, "request body is too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

async function readJson(req, limit) {
  const body = await readBody(req, limit);
  if (!body.length) return {};
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    throw httpError(400, "invalid JSON body");
  }
}

function canonicalPackageName(name) {
  return String(name || "").trim().toLowerCase();
}

function validatePackageName(raw) {
  const name = canonicalPackageName(raw);
  if (!/^[a-z0-9][a-z0-9_-]*(\/[a-z0-9][a-z0-9_-]*)*$/.test(name)) {
    throw httpError(400, "package name must contain lowercase letters, numbers, underscores, hyphens, or slash-separated segments");
  }
  return name;
}

function validatePackageOwner(rawOwner) {
  const owner = rawOwner === undefined || rawOwner === null || String(rawOwner).trim() === ""
    ? ""
    : validateUsername(rawOwner);
  if (!owner) throw httpError(400, "package owner is required");
  return owner;
}

function validateUsername(raw) {
  const username = String(raw || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(username)) {
    throw httpError(400, "username must contain only lowercase letters, numbers, underscores, or hyphens");
  }
  return username;
}

function requestedUsername(raw) {
  const text = String(raw || "").trim();
  return text ? validateUsername(text) : "";
}

function requireRequestedUsername(raw) {
  const username = requestedUsername(raw);
  if (!username) throw httpError(400, "username is required");
  return username;
}

function usernameExists(username) {
  return !!db.prepare("SELECT 1 FROM users WHERE lower(username) = lower(?)").get(username);
}

function ensureUsernameAvailable(username) {
  if (username && usernameExists(username)) {
    throw httpError(409, "username is already taken", { username });
  }
}

function ensureColumn(table, column, definition) {
  const found = db.prepare(`PRAGMA table_info(${table})`).all().some((row) => row.name === column);
  if (!found) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}

function safeNameToken(name) {
  return name.replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "package";
}

function archiveKey(name, version) {
  const parts = name.split("/");
  const filename = `${safeNameToken(name)}-${version}.kons`;
  return `${parts.map(safeNameToken).join("/")}/${filename}`;
}

function parseSemver(version) {
  const match = String(version || "").match(
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$/
  );
  if (!match) return null;
  if (!validSemverIdentifiers(match[4], { allowLeadingZeroNumbers: false })) return null;
  if (!validSemverIdentifiers(match[5], { allowLeadingZeroNumbers: true })) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease: match[4] ? match[4].split(".") : [],
    build: match[5] || "",
    raw: version,
  };
}

function requireSemver(version) {
  const parsed = parseSemver(version);
  if (!parsed) throw httpError(400, "version must be valid SemVer, for example 1.2.3");
  return parsed;
}

function compareIdentifiers(a, b) {
  const an = /^[0-9]+$/.test(a);
  const bn = /^[0-9]+$/.test(b);
  if (an && bn) return Number(a) - Number(b);
  if (an) return -1;
  if (bn) return 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareSemver(a, b) {
  const av = parseSemver(a);
  const bv = parseSemver(b);
  if (!av || !bv) return String(a).localeCompare(String(b));
  for (const key of ["major", "minor", "patch"]) {
    if (av[key] !== bv[key]) return av[key] - bv[key];
  }
  if (!av.prerelease.length && bv.prerelease.length) return 1;
  if (av.prerelease.length && !bv.prerelease.length) return -1;
  for (let i = 0; i < Math.max(av.prerelease.length, bv.prerelease.length); i += 1) {
    if (av.prerelease[i] === undefined) return -1;
    if (bv.prerelease[i] === undefined) return 1;
    const cmp = compareIdentifiers(av.prerelease[i], bv.prerelease[i]);
    if (cmp) return cmp;
  }
  return 0;
}

function satisfies(version, range = "*") {
  const req = String(range || "*").trim();
  if (req === "*" || req === "") return true;
  if (req.startsWith("^")) {
    const base = parseSemver(normalizePartialVersion(req.slice(1)));
    const value = parseSemver(version);
    if (!base || !value || compareSemver(version, base.raw) < 0) return false;
    const upper = base.major > 0
      ? `${base.major + 1}.0.0`
      : base.minor > 0
        ? `0.${base.minor + 1}.0`
        : `0.0.${base.patch + 1}`;
    return compareSemver(version, upper) < 0;
  }
  if (req.startsWith("~")) {
    const base = parseSemver(normalizePartialVersion(req.slice(1)));
    if (!base || compareSemver(version, base.raw) < 0) return false;
    return compareSemver(version, `${base.major}.${base.minor + 1}.0`) < 0;
  }
  const op = req.match(/^(>=|>|<=|<|=)\s*(.+)$/);
  if (op) {
    const target = normalizePartialVersion(op[2]);
    if (!parseSemver(target)) return false;
    const cmp = compareSemver(version, target);
    return op[1] === ">=" ? cmp >= 0
      : op[1] === ">" ? cmp > 0
        : op[1] === "<=" ? cmp <= 0
          : op[1] === "<" ? cmp < 0
            : cmp === 0;
  }
  if (/^\d+$/.test(req)) return version.startsWith(`${req}.`);
  if (/^\d+\.\d+$/.test(req)) return version.startsWith(`${req}.`);
  if (/^\d+\.(x|\*)$/i.test(req)) return version.startsWith(`${req.split(".")[0]}.`);
  if (/^\d+\.\d+\.(x|\*)$/i.test(req)) return version.startsWith(`${req.split(".").slice(0, 2).join(".")}.`);
  return compareSemver(version, req) === 0;
}

function normalizePartialVersion(value) {
  const text = String(value || "").trim();
  if (/^\d+$/.test(text)) return `${text}.0.0`;
  if (/^\d+\.\d+$/.test(text)) return `${text}.0`;
  return text;
}

function validSemverIdentifiers(value, { allowLeadingZeroNumbers }) {
  if (!value) return true;
  return value.split(".").every((part) => {
    if (!part || !/^[0-9A-Za-z-]+$/.test(part)) return false;
    return allowLeadingZeroNumbers || !/^\d{2,}$/.test(part);
  });
}

function validSemverRange(range) {
  const req = String(range || "*").trim();
  if (req === "*" || req === "") return true;
  if (req.startsWith("^") || req.startsWith("~")) {
    return !!parseSemver(normalizePartialVersion(req.slice(1)));
  }
  const op = req.match(/^(>=|>|<=|<|=)\s*(.+)$/);
  if (op) return !!parseSemver(normalizePartialVersion(op[2]));
  if (/^\d+$/.test(req) || /^\d+\.\d+$/.test(req)) return true;
  if (/^\d+\.(x|\*)$/i.test(req) || /^\d+\.\d+\.(x|\*)$/i.test(req)) return true;
  return !!parseSemver(req);
}

function sparsePathForName(name) {
  const token = name.replaceAll("/", "-");
  const compact = token.replace(/[^a-z0-9]/g, "");
  const first = compact.slice(0, 2).padEnd(2, "_");
  const second = compact.slice(2, 4).padEnd(2, "_");
  return `${first}/${second}/${token}`;
}

function userFromRow(row) {
  if (!row) return null;
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    email: row.email || "",
    avatarUrl: row.avatar_url || "",
    isAdmin: Boolean(row.is_admin),
  };
}

function getUserById(id) {
  return userFromRow(db.prepare("SELECT * FROM users WHERE id = ?").get(id));
}

function getUserByUsername(username) {
  return userFromRow(db.prepare("SELECT * FROM users WHERE lower(username) = lower(?)").get(username));
}

function isAdminEmail(email) {
  return !!email && config.admins.some((item) => item.toLowerCase() === email.toLowerCase());
}

function upsertIdentityUser(provider, profile, rawProfile = {}, options = {}) {
  const existingIdentity = db
    .prepare("SELECT user_id FROM identities WHERE provider = ? AND provider_id = ?")
    .get(provider, profile.providerId);
  if (existingIdentity) return getUserById(existingIdentity.user_id);

  const now = nowIso();
  let user = profile.email
    ? userFromRow(db.prepare("SELECT * FROM users WHERE lower(email) = lower(?)").get(profile.email))
    : null;
  if (!user) {
    const preferredUsername = requireRequestedUsername(options.username || "");
    ensureUsernameAvailable(preferredUsername);
    const username = preferredUsername;
    const result = db.prepare(`
      INSERT INTO users (username, display_name, email, avatar_url, is_admin, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(
      username,
      options.displayName || profile.displayName || username,
      profile.email || null,
      profile.avatarUrl || "",
      isAdminEmail(profile.email) ? 1 : 0,
      now,
      now
    );
    user = getUserById(result.lastInsertRowid);
  }

  db.prepare(`
    INSERT INTO identities (provider, provider_id, user_id, username, email, raw_json, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    provider,
    profile.providerId,
    user.id,
    profile.username || "",
    profile.email || "",
    JSON.stringify(rawProfile),
    now,
    now
  );
  return user;
}

function createSession(userId) {
  const token = randomToken(32);
  const createdAt = nowIso();
  const expiresAt = new Date(Date.now() + 1000 * 60 * 60 * 24 * 30).toISOString();
  db.prepare("INSERT INTO sessions (id_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .run(sha256(token), userId, createdAt, expiresAt);
  return token;
}

function sessionCookie(token) {
  return `kons_session=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 30}`;
}

function clearSessionCookie() {
  return "kons_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0";
}

function currentUser(req) {
  const auth = String(req.headers.authorization || "");
  if (auth.startsWith("Bearer ")) {
    const token = auth.slice("Bearer ".length).trim();
    const row = db.prepare("SELECT * FROM api_tokens WHERE token_hash = ?").get(sha256(token));
    if (!row) return null;
    db.prepare("UPDATE api_tokens SET last_used_at = ? WHERE id = ?").run(nowIso(), row.id);
    return getUserById(row.user_id);
  }

  const session = parseCookies(req).kons_session;
  if (!session) return null;
  const row = db.prepare(`
    SELECT user_id FROM sessions WHERE id_hash = ? AND expires_at > ?
  `).get(sha256(session), nowIso());
  return row ? getUserById(row.user_id) : null;
}

function requireUser(req) {
  const user = currentUser(req);
  if (!user) throw httpError(401, "authentication required");
  return user;
}

function canManagePackage(user, name) {
  if (user?.isAdmin) return true;
  return !!db.prepare("SELECT 1 FROM package_owners WHERE package_name = ? AND user_id = ?").get(name, user?.id);
}

function requirePackageOwner(user, name) {
  if (!canManagePackage(user, name)) throw httpError(403, "package owner permission required");
}

function packageRow(name) {
  return db.prepare("SELECT * FROM packages WHERE name = ?").get(name);
}

function resolvePackageName(name) {
  return validatePackageName(name);
}

function versionRows(name) {
  return db.prepare("SELECT * FROM versions WHERE package_name = ?").all(name)
    .sort((a, b) => compareSemver(b.version, a.version));
}

function incrementDownloadCount(name, version) {
  db.prepare(`
    UPDATE versions
    SET download_count = download_count + 1,
        last_downloaded_at = ?
    WHERE package_name = ? AND version = ?
  `).run(nowIso(), name, version);
}

function dependencyRows(name, version) {
  return db.prepare(`
    SELECT dep_name, req, kind, registry, optional, target, features_json
    FROM dependencies WHERE package_name = ? AND version = ?
    ORDER BY dep_name
  `).all(name, version).map((row) => ({
    name: row.dep_name,
    req: row.req,
    kind: row.kind,
    registry: row.registry || null,
    optional: Boolean(row.optional),
    target: row.target || null,
    features: JSON.parse(row.features_json || "[]"),
  }));
}

function libraryRows(name, version) {
  return db.prepare(`
    SELECT kind, library_name, library_key, path, imports_json, exports_json, implementation, dialect
    FROM version_libraries
    WHERE package_name = ? AND version = ?
    ORDER BY kind, library_key
  `).all(name, version).map((row) => ({
    kind: row.kind,
    name: row.library_name,
    key: row.library_key,
    path: row.path || "",
    imports: JSON.parse(row.imports_json || "[]"),
    exports: JSON.parse(row.exports_json || "[]"),
    implementation: row.implementation || "",
    dialect: row.dialect || "",
  }));
}

function insertLibraryRows(name, version, libraries) {
  const libraryInsert = db.prepare(`
    INSERT INTO version_libraries
      (package_name, version, kind, library_name, library_key, path, imports_json, exports_json, implementation, dialect)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const identifierInsert = db.prepare(`
    INSERT INTO version_identifiers
      (package_name, version, kind, library_name, identifier, role)
    VALUES (?, ?, ?, ?, ?, 'export')
  `);
  for (const library of libraries) {
    libraryInsert.run(
      name,
      version,
      library.kind,
      library.name,
      library.key,
      library.path,
      JSON.stringify(library.imports),
      JSON.stringify(library.exports),
      library.implementation,
      library.dialect
    );
    for (const identifier of library.exports) {
      identifierInsert.run(name, version, library.kind, library.name, identifier);
    }
  }
}

function addSearchTerm(out, seen, field, value) {
  const term = String(value || "").trim().toLowerCase();
  if (!term) return;
  const key = `${field}:${term}`;
  if (seen.has(key)) return;
  seen.add(key);
  out.push({ field, term });
}

function collectSearchTerms({ name, description, keywords, dialects, features, dependencies, libraries }) {
  const out = [];
  const seen = new Set();
  addSearchTerm(out, seen, "package", name);
  for (const part of name.split("/")) addSearchTerm(out, seen, "package", part);
  addSearchTerm(out, seen, "description", description);
  for (const keyword of keywords || []) addSearchTerm(out, seen, "keyword", keyword);
  for (const dialect of dialects || []) addSearchTerm(out, seen, "dialect", dialect);
  for (const feature of features || []) addSearchTerm(out, seen, "feature", feature);
  for (const dependency of dependencies || []) {
    addSearchTerm(out, seen, "dependency", dependency.name);
  }
  for (const library of libraries || []) {
    addSearchTerm(out, seen, "library", library.name);
    addSearchTerm(out, seen, "library", library.key);
    addSearchTerm(out, seen, "library-path", library.path);
    addSearchTerm(out, seen, "implementation", library.implementation);
    addSearchTerm(out, seen, "dialect", library.dialect);
    for (const imported of library.imports || []) {
      addSearchTerm(out, seen, "import", Array.isArray(imported) ? imported.join("/") : imported);
    }
    for (const identifier of library.exports || []) {
      addSearchTerm(out, seen, "identifier", identifier);
    }
  }
  return out;
}

function insertSearchTermRows(name, version, metadata) {
  const insert = db.prepare(`
    INSERT INTO package_search_terms (package_name, version, term, field)
    VALUES (?, ?, ?, ?)
  `);
  for (const item of collectSearchTerms(metadata)) {
    insert.run(name, version, item.term, item.field);
  }
}

function jsonArray(value) {
  try {
    const parsed = JSON.parse(value || "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function backfillPackageSearchTerms() {
  const missingRows = db.prepare(`
    SELECT packages.name,
           packages.keywords_json,
           versions.version,
           versions.description,
           versions.dialects_json,
           versions.features_json
    FROM versions
    JOIN packages ON packages.name = versions.package_name
    WHERE NOT EXISTS (
      SELECT 1
      FROM package_search_terms
      WHERE package_search_terms.package_name = versions.package_name
        AND package_search_terms.version = versions.version
    )
    ORDER BY packages.name, versions.version
  `).all();
  if (missingRows.length === 0) return;

  db.exec("BEGIN");
  try {
    for (const row of missingRows) {
      insertSearchTermRows(row.name, row.version, {
        name: row.name,
        description: row.description,
        keywords: jsonArray(row.keywords_json),
        dialects: jsonArray(row.dialects_json),
        features: jsonArray(row.features_json),
        dependencies: dependencyRows(row.name, row.version),
        libraries: libraryRows(row.name, row.version),
      });
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  console.log(`[kons] backfilled package search terms for ${missingRows.length} version(s)`);
}

function ownerRows(name) {
  return db.prepare(`
    SELECT users.username, users.display_name, users.avatar_url
    FROM package_owners
    JOIN users ON users.id = package_owners.user_id
    WHERE package_owners.package_name = ?
    ORDER BY users.username
  `).all(name).map((row) => ({
    username: row.username,
    displayName: row.display_name,
    avatarUrl: row.avatar_url,
  }));
}

function publicPackage(name, viewer = null) {
  const pkg = packageRow(name);
  if (!pkg) return null;
  const versions = versionRows(name).map((row) => ({
    version: row.version,
    checksum: row.checksum,
    size: row.size,
    publishedAt: row.published_at,
    yanked: Boolean(row.yanked),
    description: row.description,
    license: row.license,
    dialects: JSON.parse(row.dialects_json || "[]"),
    features: JSON.parse(row.features_json || "[]"),
    readme: row.readme || "",
    downloads: Number(row.download_count || 0),
    lastDownloadedAt: row.last_downloaded_at || null,
    dependencies: dependencyRows(name, row.version),
    libraries: libraryRows(name, row.version),
  }));
  const owners = ownerRows(name);
  const latest = versions.find((version) => !version.yanked) || versions[0] || null;
  const downloads = versions.reduce((sum, version) => sum + Number(version.downloads || 0), 0);
  return {
    name,
    description: pkg.description,
    homepage: pkg.homepage,
    site: pkg.homepage,
    repository: pkg.repository,
    repo: pkg.repository,
    documentation: pkg.documentation,
    docs: pkg.documentation,
    readme: latest?.readme || "",
    keywords: JSON.parse(pkg.keywords_json || "[]"),
    latest,
    versions,
    downloads,
    owners,
    indexPath: sparsePathForName(name),
    canManage: viewer ? canManagePackage(viewer, name) : false,
    createdAt: pkg.created_at,
    updatedAt: pkg.updated_at,
  };
}

async function oauthJson(url, token) {
  const response = await fetch(url, {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${token}`,
      "user-agent": "kons-registry",
    },
  });
  if (!response.ok) throw httpError(502, "OAuth profile request failed");
  return response.json();
}

async function exchangeOAuthCode(provider, code, redirectUri) {
  const body = new URLSearchParams({
    client_id: provider.clientId,
    client_secret: provider.clientSecret,
    code,
    grant_type: "authorization_code",
    redirect_uri: redirectUri,
  });
  const response = await fetch(provider.tokenUrl, {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
      "user-agent": "kons-registry",
    },
    body,
  });
  if (!response.ok) throw httpError(502, "OAuth token exchange failed");
  const payload = await response.json();
  if (!payload.access_token) throw httpError(502, "OAuth provider did not return an access token");
  return payload.access_token;
}

function configuredProviders() {
  return Object.entries(oauthProviders)
    .filter(([, provider]) => provider.clientId && provider.clientSecret)
    .map(([id, provider]) => ({ id, label: provider.label, url: `/auth/${id}/start` }));
}

function isEmailAllowed(email) {
  const normalized = String(email || "").toLowerCase();
  if (!config.emailRegistration || !normalized.includes("@")) return false;
  if (config.emailOpenRegistration) return true;
  if (!config.emailAllowlist.length) return false;
  return config.emailAllowlist.some((entry) => {
    const item = entry.toLowerCase();
    if (item === "*") return true;
    return item.startsWith("@") ? normalized.endsWith(item) : normalized === item;
  });
}

function emailAuthInfo() {
  const smtp = smtpConfigured(config.smtp);
  return {
    enabled: config.emailRegistration,
    openRegistration: config.emailOpenRegistration,
    showCodes: config.emailShowCodes,
    delivery: smtp ? "smtp" : "log",
  };
}

async function deliverVerificationEmail(email, code) {
  const ttl = config.emailCodeTtlMinutes;
  const verifyUrl = `${config.baseUrl || "http://127.0.0.1:8787"}/account`;
  const text = [
    "Your (kons) verification code:",
    "",
    code,
    "",
    `This code expires in ${ttl} minutes.`,
    `Sign in at ${verifyUrl}`,
  ].join("\n");

  if (!smtpConfigured(config.smtp)) {
    console.log(`[kons] email verification code for ${email}: ${code}`);
    return { delivered: false, method: "log" };
  }

  await sendMail(config.smtp, {
    from: config.smtp.from,
    to: email,
    subject: "Your (kons) verification code",
    text,
  });
  console.log(`[kons] sent verification email to ${email}`);
  return { delivered: true, method: "smtp" };
}

function emailCodeHash(email, code) {
  return sha256(`${config.sessionSecret}:${email.toLowerCase()}:${code}`);
}

function decodeArchivePayload(value) {
  const text = String(value || "");
  const base64 = text.includes(",") ? text.slice(text.indexOf(",") + 1) : text;
  const buffer = Buffer.from(base64, "base64");
  if (!buffer.length) throw httpError(400, "archiveBase64 is required");
  if (buffer.length > config.maxArchiveBytes) throw httpError(413, "archive exceeds configured maximum size");
  return buffer;
}

function runProcess(command, args, input = null, maxOutput = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    const stdout = [];
    const stderr = [];
    let stdoutSize = 0;
    child.stdout.on("data", (chunk) => {
      stdoutSize += chunk.length;
      if (stdoutSize <= maxOutput) stdout.push(chunk);
    });
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      const out = Buffer.concat(stdout).toString("utf8");
      const err = Buffer.concat(stderr).toString("utf8");
      if (code === 0) resolve(out);
      else reject(httpError(400, `${command} failed`, err.trim()));
    });
    if (input) child.stdin.end(input);
    else child.stdin.end();
  });
}

function archiveIsGzip(buffer) {
  return buffer.length >= 2 && buffer[0] === 0x1f && buffer[1] === 0x8b;
}

function cleanArchivePath(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  const cleaned = raw.replace(/^\.\/+/, "");
  if (
    !cleaned
    || cleaned.startsWith("/")
    || cleaned.includes("\0")
    || cleaned.split("/").includes("..")
  ) {
    return "";
  }
  return cleaned;
}

function archiveEntryFor(entries, requested) {
  const clean = cleanArchivePath(requested);
  if (!clean) return "";
  return entries.find((entry) => cleanArchivePath(entry) === clean) || "";
}

async function extractReadme(tmp, gzip, entries, requested) {
  const entry = archiveEntryFor(entries, requested);
  if (!entry) return "";
  const extractArgs = gzip ? ["-xOzf", tmp, entry] : ["-xOf", tmp, entry];
  return runProcess("tar", extractArgs, null, 512 * 1024);
}

async function validateArchive(buffer, expectedName, expectedVersion, expectedOwner, requestedReadme = "") {
  const tmp = path.join(config.dataDir, "tmp", `${randomToken(12)}.kons`);
  await fs.writeFile(tmp, buffer);
  try {
    const gzip = archiveIsGzip(buffer);
    const listArgs = gzip ? ["-tzf", tmp] : ["-tf", tmp];
    const listing = await runProcess("tar", listArgs, null, 2 * 1024 * 1024);
    const entries = listing.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    if (!entries.length) throw httpError(400, "archive is empty");
    for (const entry of entries) {
      if (entry.startsWith("/") || entry.split("/").includes("..")) {
        throw httpError(400, "archive contains unsafe paths");
      }
    }
    const manifestEntry = entries.includes("kons.scm") ? "kons.scm" : entries.includes("./kons.scm") ? "./kons.scm" : "";
    if (!manifestEntry) throw httpError(400, "archive must contain kons.scm at its root");
    const extractArgs = gzip ? ["-xOzf", tmp, manifestEntry] : ["-xOf", tmp, manifestEntry];
    const manifestText = await runProcess("tar", extractArgs, null, 512 * 1024);
    const manifest = parseKonsManifest(manifestText);
    if (manifest.name !== expectedName) {
      throw httpError(400, "manifest package name does not match upload name", { manifestName: manifest.name });
    }
    if (!manifest.owner) {
      throw httpError(400, "kons.scm is missing package owner");
    }
    if (manifest.owner !== expectedOwner) {
      throw httpError(400, "manifest package owner does not match upload owner", { manifestOwner: manifest.owner });
    }
    if (manifest.version !== expectedVersion) {
      throw httpError(400, "manifest package version does not match upload version", { manifestVersion: manifest.version });
    }
    const readmePath = requestedReadme || manifest.readme || "";
    const readme = await extractReadme(tmp, gzip, entries, readmePath);
    return { manifest, entries, readme };
  } finally {
    await fs.rm(tmp, { force: true });
  }
}

function parseKonsManifest(text) {
  const withoutComments = String(text).replace(/;.*$/gm, "");
  const nameMatch = withoutComments.match(/\(name\s+\(([^)]*)\)\)/m)
    || withoutComments.match(/\(name\s+([^\s()]+)\s*\)/m);
  const ownerMatch = withoutComments.match(/\(owner\s+"([^"]+)"\)/m);
  const versionMatch = withoutComments.match(/\(version\s+"([^"]+)"\)/m);
  const readmeMatch = withoutComments.match(/\(readme\s+"([^"]+)"\)/m);
  if (!nameMatch) throw httpError(400, "kons.scm is missing package name");
  if (!ownerMatch) throw httpError(400, "kons.scm is missing package owner");
  if (!versionMatch) throw httpError(400, "kons.scm is missing package version");
  const name = nameMatch[1].trim().split(/\s+/).filter(Boolean).join("/");
  return {
    name: validatePackageName(name),
    owner: validateUsername(ownerMatch[1]),
    version: versionMatch[1],
    readme: readmeMatch?.[1] || "",
  };
}

function normalizeStringList(value, field, errors, { maxItems = 64 } = {}) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) {
    errors.push({ field, message: "must be an array of strings" });
    return [];
  }
  if (value.length > maxItems) {
    errors.push({ field, message: `must contain at most ${maxItems} items` });
  }
  return value.slice(0, maxItems).map((item, index) => {
    if (typeof item !== "string" || !item.trim()) {
      errors.push({ field: `${field}[${index}]`, message: "must be a non-empty string" });
      return "";
    }
    return item.trim();
  }).filter(Boolean);
}

function normalizeKeywords(value, errors) {
  const seen = new Set();
  const out = [];
  for (const [index, keyword] of normalizeStringList(value, "keywords", errors, { maxItems: 12 }).entries()) {
    const normalized = keyword.toLowerCase();
    if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(normalized)) {
      errors.push({
        field: `keywords[${index}]`,
        message: "must contain lowercase letters, numbers, dot, underscore, or hyphen",
      });
      continue;
    }
    if (!seen.has(normalized)) {
      seen.add(normalized);
      out.push(normalized);
    }
  }
  return out;
}

function normalizeDependencies(raw, errors) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push({ field: "dependencies", message: "must be an array" });
    return [];
  }
  return raw.map((dep, index) => {
    const prefix = `dependencies[${index}]`;
    if (!dep || typeof dep !== "object" || Array.isArray(dep)) {
      errors.push({ field: prefix, message: "must be an object" });
      return null;
    }

    let name = "";
    try {
      name = validatePackageName(dep.name);
    } catch (error) {
      errors.push({ field: `${prefix}.name`, message: error.message });
    }

    const reqValue = dep.req ?? dep.version;
    const req = typeof reqValue === "string" ? reqValue.trim() : "";
    if (!req) errors.push({ field: `${prefix}.req`, message: "is required" });
    else if (!validSemverRange(req)) {
      errors.push({ field: `${prefix}.req`, message: "must be a valid SemVer requirement" });
    }

    const kind = dep.kind === undefined ? "normal" : String(dep.kind).trim();
    if (!["normal", "dev", "build"].includes(kind)) {
      errors.push({ field: `${prefix}.kind`, message: "must be normal, dev, or build" });
    }

    if (dep.optional !== undefined && typeof dep.optional !== "boolean") {
      errors.push({ field: `${prefix}.optional`, message: "must be a boolean" });
    }
    if (dep.registry !== undefined && (typeof dep.registry !== "string" || !dep.registry.trim())) {
      errors.push({ field: `${prefix}.registry`, message: "must be a non-empty string" });
    }
    if (dep.target !== undefined && (typeof dep.target !== "string" || !dep.target.trim())) {
      errors.push({ field: `${prefix}.target`, message: "must be a non-empty string" });
    }

    const features = normalizeStringList(dep.features, `${prefix}.features`, errors);
    return {
      name,
      req,
      kind: ["normal", "dev", "build"].includes(kind) ? kind : "normal",
      registry: dep.registry ? String(dep.registry).trim() : null,
      optional: Boolean(dep.optional),
      target: dep.target ? String(dep.target).trim() : null,
      features,
    };
  }).filter((dep) => dep && dep.name && dep.req);
}

function normalizeLibraryNameParts(value, field, errors) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) {
      errors.push({ field, message: "must not be empty" });
      return [];
    }
    return [trimmed];
  }
  if (!Array.isArray(value)) {
    errors.push({ field, message: "must be an array of strings or a string" });
    return [];
  }
  const parts = value.map((part, index) => {
    const text = String(part || "").trim();
    if (!text) {
      errors.push({ field: `${field}[${index}]`, message: "must be a non-empty string" });
      return "";
    }
    if (text.length > 120) {
      errors.push({ field: `${field}[${index}]`, message: "must be 120 characters or less" });
      return "";
    }
    return text;
  }).filter(Boolean);
  if (!parts.length) errors.push({ field, message: "must contain at least one part" });
  return parts;
}

function libraryDisplayName(parts) {
  return parts.length === 1 ? parts[0] : `(${parts.join(" ")})`;
}

function libraryKey(parts) {
  return parts.join("/");
}

function normalizeLibraryNameList(value, field, errors) {
  if (!Array.isArray(value)) {
    errors.push({ field, message: "must be an array" });
    return [];
  }
  return value.map((item, index) => {
    const parts = normalizeLibraryNameParts(item, `${field}[${index}]`, errors);
    return parts.length ? parts : null;
  }).filter(Boolean);
}

function normalizeLibraryField(value, maxLength = 80) {
  return typeof value === "string" ? value.trim().toLowerCase().slice(0, maxLength) : "";
}

function defaultLibraryDialect(kind) {
  return ["r7rs", "r6rs"].includes(kind) ? kind : "";
}

function defaultLibraryImplementation(kind) {
  return ["guile", "gauche"].includes(kind) ? kind : "";
}

function normalizeLibraries(raw, errors) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push({ field: "libraries", message: "must be an array" });
    return [];
  }
  if (raw.length > 512) errors.push({ field: "libraries", message: "must contain at most 512 entries" });
  return raw.slice(0, 512).map((library, index) => {
    const prefix = `libraries[${index}]`;
    if (!library || typeof library !== "object" || Array.isArray(library)) {
      errors.push({ field: prefix, message: "must be an object" });
      return null;
    }

    const kind = String(library.kind || "").trim();
    if (!["r7rs", "r6rs", "guile", "gauche"].includes(kind)) {
      errors.push({ field: `${prefix}.kind`, message: "must be r7rs, r6rs, guile, or gauche" });
    }

    const normalizedKind = ["r7rs", "r6rs", "guile", "gauche"].includes(kind) ? kind : "r7rs";
    const nameParts = normalizeLibraryNameParts(library.name, `${prefix}.name`, errors);
    const displayName = String(library.displayName || libraryDisplayName(nameParts)).trim().slice(0, 300);
    const key = String(library.key || libraryKey(nameParts)).trim().slice(0, 300);
    if (!key) errors.push({ field: `${prefix}.key`, message: "is required" });
    const sourcePath = typeof library.path === "string" ? library.path.trim().slice(0, 600) : "";
    const imports = normalizeLibraryNameList(library.imports || [], `${prefix}.imports`, errors);
    const exports = normalizeStringList(library.exports || [], `${prefix}.exports`, errors, { maxItems: 2048 });
    const implementation = normalizeLibraryField(library.implementation) || defaultLibraryImplementation(normalizedKind);
    const dialect = normalizeLibraryField(library.dialect) || defaultLibraryDialect(normalizedKind);

    return {
      kind: normalizedKind,
      name: displayName || libraryDisplayName(nameParts),
      key: key || libraryKey(nameParts),
      path: sourcePath,
      imports,
      exports,
      implementation,
      dialect,
    };
  }).filter((library) => library && library.key);
}

function validatePublishPayload(payload) {
  const errors = [];
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    validationError("publish payload must be a JSON object", [
      { field: "body", message: "must be a JSON object" },
    ]);
  }

  let name = "";
  try {
    name = validatePackageName(payload.name);
  } catch (error) {
    errors.push({ field: "name", message: error.message });
  }

  const version = typeof payload.version === "string" ? payload.version.trim() : "";
  if (!version) {
    errors.push({ field: "version", message: "is required" });
  } else if (!parseSemver(version)) {
    errors.push({ field: "version", message: "must be valid SemVer, for example 1.2.3" });
  }

  const description = typeof payload.description === "string" ? payload.description.trim() : "";
  if (!description) errors.push({ field: "description", message: "is required" });

  const license = typeof payload.license === "string" ? payload.license.trim() : "";
  if (!license) errors.push({ field: "license", message: "is required" });

  if (typeof payload.archiveBase64 !== "string" || !payload.archiveBase64.trim()) {
    errors.push({ field: "archiveBase64", message: "is required" });
  }

  const dialects = normalizeStringList(payload.dialects, "dialects", errors);
  const features = normalizeStringList(payload.features, "features", errors);
  const keywords = normalizeKeywords(payload.keywords, errors);
  const dependencies = normalizeDependencies(payload.dependencies, errors);
  const libraries = normalizeLibraries(payload.libraries, errors);

  if (errors.length) validationError("publish payload validation failed", errors);
  return { name, version, description, license, dialects, features, keywords, dependencies, libraries };
}

async function putArchive(key, buffer) {
  if (config.storage === "s3") return putS3Object(key, buffer, "application/octet-stream");
  const dest = path.join(config.dataDir, "archives", key);
  await fs.mkdir(path.dirname(dest), { recursive: true });
  await fs.writeFile(dest, buffer, { flag: "wx" });
}

async function sendArchive(req, res, row) {
  if (config.storage === "s3") {
    if (config.s3.publicBaseUrl) {
      incrementDownloadCount(row.package_name, row.version);
      redirect(res, `${config.s3.publicBaseUrl.replace(/\/$/, "")}/${encodeS3Path(row.archive_key)}`);
      return;
    }
    const object = await getS3Object(row.archive_key);
    incrementDownloadCount(row.package_name, row.version);
    send(res, 200, Buffer.from(await object.arrayBuffer()), {
      "content-type": "application/octet-stream",
      "content-disposition": `attachment; filename="${row.archive_filename}"`,
      "cache-control": "public, max-age=31536000, immutable",
    });
    return;
  }
  const filePath = path.join(config.dataDir, "archives", row.archive_key);
  const stat = await fs.stat(filePath);
  incrementDownloadCount(row.package_name, row.version);
  res.writeHead(200, {
    "content-type": "application/octet-stream",
    "content-length": stat.size,
    "content-disposition": `attachment; filename="${row.archive_filename}"`,
    "cache-control": "public, max-age=31536000, immutable",
  });
  createReadStream(filePath).pipe(res);
}

function encodeS3Path(key) {
  return key.split("/").map(encodeURIComponent).join("/");
}

async function putS3Object(key, buffer, contentType) {
  const response = await s3Request("PUT", key, buffer, contentType);
  if (!response.ok) throw httpError(502, "S3 upload failed", await response.text());
}

async function getS3Object(key) {
  const response = await s3Request("GET", key, Buffer.alloc(0), "");
  if (!response.ok) throw httpError(502, "S3 download failed", await response.text());
  return response;
}

async function deleteArchive(row) {
  if (config.storage === "s3") {
    const response = await s3Request("DELETE", row.archive_key, Buffer.alloc(0), "");
    if (!response.ok && response.status !== 404) throw httpError(502, "S3 delete failed", await response.text());
    return;
  }
  await fs.rm(path.join(config.dataDir, "archives", row.archive_key), { force: true });
}

async function s3Request(method, key, body, contentType) {
  const s3 = config.s3;
  if (!s3.endpoint || !s3.bucket || !s3.accessKeyId || !s3.secretAccessKey) {
    throw httpError(500, "S3 storage is not fully configured");
  }
  const endpoint = new URL(s3.endpoint);
  const encodedKey = encodeS3Path(key);
  const canonicalUri = s3.forcePathStyle
    ? `${endpoint.pathname.replace(/\/$/, "")}/${s3.bucket}/${encodedKey}`
    : `${endpoint.pathname.replace(/\/$/, "")}/${encodedKey}`;
  const host = s3.forcePathStyle ? endpoint.host : `${s3.bucket}.${endpoint.host}`;
  const url = `${endpoint.protocol}//${host}${canonicalUri}`;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256(body);
  const canonicalHeaders = `host:${host}\nx-amz-content-sha256:${payloadHash}\nx-amz-date:${amzDate}\n`;
  const signedHeaders = "host;x-amz-content-sha256;x-amz-date";
  const canonicalRequest = [
    method,
    canonicalUri,
    "",
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join("\n");
  const scope = `${dateStamp}/${s3.region}/s3/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    sha256(canonicalRequest),
  ].join("\n");
  const kDate = hmac(`AWS4${s3.secretAccessKey}`, dateStamp);
  const kRegion = hmac(kDate, s3.region);
  const kService = hmac(kRegion, "s3");
  const kSigning = hmac(kService, "aws4_request");
  const signature = hmac(kSigning, stringToSign, "hex");
  const headers = {
    host,
    "x-amz-content-sha256": payloadHash,
    "x-amz-date": amzDate,
    authorization: `AWS4-HMAC-SHA256 Credential=${s3.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
  if (contentType) headers["content-type"] = contentType;
  return fetch(url, { method, headers, body: method === "GET" ? undefined : body });
}

function indexConfig(req) {
  const base = publicBaseUrl(req);
  return {
    version: 1,
    dl: `${base}/api/v1/packages/{name}/{version}/download`,
    api: base,
  };
}

function indexLines(name) {
  return versionRows(name).reverse().map((row) => JSON.stringify({
    name,
    vers: row.version,
    deps: dependencyRows(name, row.version).map((dep) => ({
      name: dep.name,
      req: dep.req,
      kind: dep.kind,
      registry: dep.registry,
      optional: dep.optional,
      target: dep.target,
      features: dep.features,
    })),
    checksum: row.checksum,
    yanked: Boolean(row.yanked),
    dialects: JSON.parse(row.dialects_json || "[]"),
    features: JSON.parse(row.features_json || "[]"),
  })).join("\n") + "\n";
}

async function publishPackage(req, res) {
  const user = requireUser(req);
  const payload = await readJson(req, config.maxArchiveBytes * 2);
  const {
    name: payloadName,
    version,
    description,
    license,
    dialects,
    features,
    keywords,
    dependencies,
    libraries,
  } = validatePublishPayload(payload);
  const name = payloadName;
  const owner = validatePackageOwner(payload.owner);
  const archive = decodeArchivePayload(payload.archiveBase64);
  const checksum = sha256(archive);
  const homepage = String(payload.homepage || payload.site || "");
  const repository = String(payload.repository || payload.repo || "");
  const documentation = String(payload.documentation || payload.docs || "");
  const readmePath = String(payload.readme || "");
  const validation = await validateArchive(archive, name, version, owner, readmePath);

  const existing = packageRow(name);
  if (existing) requirePackageOwner(user, name);

  if (db.prepare("SELECT 1 FROM versions WHERE package_name = ? AND version = ?").get(name, version)) {
    throw httpError(409, "package version already exists");
  }

  const key = archiveKey(name, version);
  const filename = path.basename(key);
  await putArchive(key, archive);

  const now = nowIso();
  db.exec("BEGIN");
  try {
    if (!existing) {
      db.prepare(`
        INSERT INTO packages
          (name, description, homepage, repository, documentation, keywords_json, created_by, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        name,
        description,
        homepage,
        repository,
        documentation,
        JSON.stringify(keywords),
        user.id,
        now,
        now
      );
      db.prepare("INSERT INTO package_owners (package_name, user_id, role, created_at) VALUES (?, ?, 'owner', ?)")
        .run(name, user.id, now);
    } else {
      db.prepare(`
        UPDATE packages
        SET description = COALESCE(NULLIF(?, ''), description),
            homepage = COALESCE(NULLIF(?, ''), homepage),
            repository = COALESCE(NULLIF(?, ''), repository),
            documentation = COALESCE(NULLIF(?, ''), documentation),
            keywords_json = ?,
            updated_at = ?
        WHERE name = ?
      `).run(
        description,
        homepage,
        repository,
        documentation,
        JSON.stringify(keywords),
        now,
        name
      );
    }

    db.prepare(`
      INSERT INTO versions
        (package_name, version, checksum, size, archive_key, archive_filename, published_by, published_at,
         description, license, dialects_json, features_json, readme, manifest_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      name,
      version,
      checksum,
      archive.length,
      key,
      filename,
      user.id,
      now,
      description,
      license,
      JSON.stringify(dialects),
      JSON.stringify(features),
      validation.readme,
      JSON.stringify(validation.manifest)
    );

    for (const dep of dependencies) {
      db.prepare(`
        INSERT INTO dependencies
          (package_name, version, dep_name, req, kind, registry, optional, target, features_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        name,
        version,
        dep.name,
        dep.req,
        dep.kind,
        dep.registry,
        dep.optional ? 1 : 0,
        dep.target,
        JSON.stringify(dep.features)
      );
    }
    insertLibraryRows(name, version, libraries);
    insertSearchTermRows(name, version, {
      name,
      description,
      keywords,
      dialects,
      features,
      dependencies,
      libraries,
    });
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }

  sendJson(res, 201, { package: publicPackage(name, user), checksum });
}

function resolvePackageVersion(name, req) {
  if (!validSemverRange(req)) throw httpError(400, "version requirement must be valid SemVer");
  const rows = versionRows(name)
    .filter((row) => !row.yanked)
    .filter((row) => satisfies(row.version, req));
  return rows[0] || null;
}

function packageVersionList(name, includeYanked = false) {
  if (!packageRow(name)) throw httpError(404, "package not found");
  return {
    package: name,
    versions: versionRows(name)
      .filter((row) => includeYanked || !row.yanked)
      .map((row) => ({
        version: row.version,
        checksum: row.checksum,
        size: row.size,
        downloadUrl: packageDownloadUrl(name, row.version),
        yanked: Boolean(row.yanked),
        publishedAt: row.published_at,
        description: row.description,
        license: row.license,
        dialects: JSON.parse(row.dialects_json || "[]"),
        features: JSON.parse(row.features_json || "[]"),
        dependencies: dependencyRows(name, row.version),
      })),
  };
}

function packageVersionMetadata(name, version) {
  const row = db.prepare("SELECT * FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  return {
    package: name,
    version: row.version,
    checksum: row.checksum,
    size: row.size,
    downloadUrl: packageDownloadUrl(name, row.version),
    yanked: Boolean(row.yanked),
    description: row.description,
    license: row.license,
    dialects: JSON.parse(row.dialects_json || "[]"),
    features: JSON.parse(row.features_json || "[]"),
    dependencies: dependencyRows(name, row.version),
    libraries: libraryRows(name, row.version),
  };
}

function packageVersionManifest(name, version) {
  const row = db.prepare("SELECT manifest_json FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  return {
    package: name,
    version,
    manifest: JSON.parse(row.manifest_json || "{}"),
  };
}

function resolveCandidateId(name, version) {
  return `registry:default:${name}:${version}`;
}

function cloneConstraintMap(source) {
  const out = new Map();
  for (const [name, items] of source.entries()) out.set(name, items.slice());
  return out;
}

function addResolveConstraint(constraints, name, req, from, kind = "normal") {
  const items = constraints.get(name) || [];
  items.push({ name, req, from, kind });
  constraints.set(name, items);
}

function selectedSatisfiesConstraints(selected, constraints, name) {
  const row = selected.get(name);
  if (!row) return false;
  return (constraints.get(name) || []).every((req) => satisfies(row.version, req.req));
}

function unresolvedConstraintName(selected, constraints) {
  for (const name of constraints.keys()) {
    if (!selectedSatisfiesConstraints(selected, constraints, name)) return name;
  }
  return "";
}

function resolveGraphConflict(name, constraints) {
  const requirements = (constraints.get(name) || []).map((req) => ({
    req: req.req,
    from: req.from,
    kind: req.kind,
  }));
  throw httpError(409, "dependency version conflict", { package: name, requirements });
}

function candidateVersionRows(name, constraints, includeYanked) {
  return versionRows(name)
    .filter((row) => includeYanked || !row.yanked)
    .filter((row) => (constraints.get(name) || []).every((req) => satisfies(row.version, req.req)));
}

function solveResolveGraph(selected, constraints, includeYanked) {
  const name = unresolvedConstraintName(selected, constraints);
  if (!name) return selected;

  const candidates = candidateVersionRows(name, constraints, includeYanked);
  if (!candidates.length) resolveGraphConflict(name, constraints);

  for (const row of candidates) {
    const nextSelected = new Map(selected);
    const nextConstraints = cloneConstraintMap(constraints);
    nextSelected.set(name, row);
    const from = resolveCandidateId(name, row.version);
    for (const dep of dependencyRows(name, row.version)) {
      if (dep.optional) continue;
      addResolveConstraint(nextConstraints, dep.name, dep.req, from, dep.kind || "normal");
    }
    try {
      return solveResolveGraph(nextSelected, nextConstraints, includeYanked);
    } catch (error) {
      if (error.status !== 409) throw error;
    }
  }
  resolveGraphConflict(name, constraints);
}

function resolveGraphEdges(rootRequirements, selected) {
  const out = [];
  for (const req of rootRequirements) {
    const row = selected.get(req.name);
    if (row) {
      out.push({
        from: "root",
        to: resolveCandidateId(req.name, row.version),
        name: req.name,
        req: req.req,
        kind: req.kind || "normal",
      });
    }
  }
  for (const [name, row] of selected.entries()) {
    const from = resolveCandidateId(name, row.version);
    for (const dep of dependencyRows(name, row.version)) {
      if (dep.optional) continue;
      const depRow = selected.get(dep.name);
      if (!depRow) continue;
      out.push({
        from,
        to: resolveCandidateId(dep.name, depRow.version),
        name: dep.name,
        req: dep.req,
        kind: dep.kind || "normal",
      });
    }
  }
  return out;
}

function resolveGraphPackage(name, row) {
  return {
    id: resolveCandidateId(name, row.version),
    package: name,
    name,
    version: row.version,
    checksum: row.checksum,
    size: row.size,
    downloadUrl: packageDownloadUrl(name, row.version),
    yanked: Boolean(row.yanked),
    description: row.description,
    license: row.license,
    dialects: JSON.parse(row.dialects_json || "[]"),
    features: JSON.parse(row.features_json || "[]"),
    dependencies: dependencyRows(name, row.version),
  };
}

function normalizeResolvePayload(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    validationError("resolve payload must be a JSON object", [
      { field: "body", message: "must be a JSON object" },
    ]);
  }
  const errors = [];
  const raw = payload.requirements ?? payload.dependencies;
  const dependencies = normalizeDependencies(raw, errors);
  if (!raw) errors.push({ field: "requirements", message: "is required" });
  if (errors.length) validationError("resolve payload validation failed", errors);
  return {
    includeYanked: Boolean(payload.includeYanked),
    requirements: dependencies.map((dep) => ({
      name: dep.name,
      req: dep.req,
      kind: dep.kind,
    })),
  };
}

async function resolvePackages(req, res) {
  const payload = normalizeResolvePayload(await readJson(req, 1024 * 1024));
  const constraints = new Map();
  for (const requirement of payload.requirements) {
    addResolveConstraint(constraints, requirement.name, requirement.req, "root", requirement.kind);
  }
  const selected = solveResolveGraph(new Map(), constraints, payload.includeYanked);
  const packages = [...selected.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([name, row]) => resolveGraphPackage(name, row));
  sendJson(res, 200, {
    packages,
    edges: resolveGraphEdges(payload.requirements, selected),
  });
}

async function handleAuthStart(req, res, providerId, url) {
  const provider = oauthProviders[providerId];
  if (!provider?.clientId || !provider?.clientSecret) throw httpError(404, "OAuth provider is not configured");
  const username = requestedUsername(url.searchParams.get("username") || url.searchParams.get("nickname") || "");
  const state = randomToken(24);
  const createdAt = nowIso();
  const expiresAt = new Date(Date.now() + 1000 * 60 * 10).toISOString();
  db.prepare("INSERT INTO auth_states (state, provider, return_to, username, created_at, expires_at) VALUES (?, ?, '/', ?, ?, ?)")
    .run(state, providerId, username, createdAt, expiresAt);
  const redirectUri = `${publicBaseUrl(req)}/auth/${providerId}/callback`;
  const authUrl = new URL(provider.authorizeUrl);
  authUrl.searchParams.set("client_id", provider.clientId);
  authUrl.searchParams.set("redirect_uri", redirectUri);
  authUrl.searchParams.set("response_type", "code");
  authUrl.searchParams.set("scope", provider.scope);
  authUrl.searchParams.set("state", state);
  redirect(res, authUrl.toString());
}

async function handleAuthCallback(req, res, providerId, url) {
  const provider = oauthProviders[providerId];
  if (!provider?.clientId || !provider?.clientSecret) throw httpError(404, "OAuth provider is not configured");
  const state = url.searchParams.get("state") || "";
  const code = url.searchParams.get("code") || "";
  const stateRow = db.prepare("SELECT * FROM auth_states WHERE state = ? AND provider = ? AND expires_at > ?")
    .get(state, providerId, nowIso());
  if (!stateRow || !code) throw httpError(400, "invalid OAuth callback state");
  db.prepare("DELETE FROM auth_states WHERE state = ?").run(state);
  const redirectUri = `${publicBaseUrl(req)}/auth/${providerId}/callback`;
  const token = await exchangeOAuthCode(provider, code, redirectUri);
  const rawProfile = await oauthJson(provider.userUrl, token);
  const mapped = await provider.map(rawProfile, token);
  const user = upsertIdentityUser(providerId, mapped, rawProfile, { username: stateRow.username || "" });
  const session = createSession(user.id);
  send(res, 302, "", {
    location: "/account?auth=ok",
    "set-cookie": sessionCookie(session),
  });
}

async function handleEmailStart(req, res) {
  const payload = await readJson(req, 16 * 1024);
  const email = String(payload.email || "").trim().toLowerCase();
  const username = requestedUsername(payload.username || payload.nickname || "");
  if (!isEmailAllowed(email)) throw httpError(403, "email registration is not enabled for this address");
  const existingUser = userFromRow(db.prepare("SELECT * FROM users WHERE lower(email) = lower(?)").get(email));
  if (!existingUser) {
    if (!username) throw httpError(400, "username is required");
    ensureUsernameAvailable(username);
  }
  const code = String(Math.floor(100000 + Math.random() * 900000));
  const state = randomToken(18);
  const createdAt = nowIso();
  const expiresAt = new Date(Date.now() + 1000 * 60 * config.emailCodeTtlMinutes).toISOString();
  db.prepare(`
    INSERT INTO auth_states (state, provider, return_to, email, username, code_hash, created_at, expires_at)
    VALUES (?, 'email', '/account', ?, ?, ?, ?, ?)
  `).run(state, email, username, emailCodeHash(email, code), createdAt, expiresAt);
  const delivery = await deliverVerificationEmail(email, code);
  sendJson(res, 200, {
    ok: true,
    message: delivery.delivered
      ? "verification code sent by email"
      : "verification code created; check the registry server log",
    delivery: delivery.method,
    code: !delivery.delivered && config.emailShowCodes ? code : undefined,
  });
}

async function handleEmailVerify(req, res) {
  const payload = await readJson(req, 16 * 1024);
  const email = String(payload.email || "").trim().toLowerCase();
  const code = String(payload.code || "").trim();
  const requested = requestedUsername(payload.username || payload.nickname || "");
  const row = db.prepare(`
    SELECT * FROM auth_states
    WHERE provider = 'email' AND lower(email) = lower(?) AND expires_at > ?
    ORDER BY created_at DESC
  `).get(email, nowIso());
  if (!row || !safeEqual(row.code_hash, emailCodeHash(email, code))) {
    throw httpError(400, "invalid or expired verification code");
  }
  const username = row.username || requested;
  const profile = {
    providerId: email,
    username: email.split("@")[0],
    displayName: username || email,
    email,
    avatarUrl: "",
  };
  const user = upsertIdentityUser("email", profile, { email }, { username, displayName: username || email });
  db.prepare("DELETE FROM auth_states WHERE state = ?").run(row.state);
  const session = createSession(user.id);
  sendJson(res, 200, { user }, { "set-cookie": sessionCookie(session) });
}

function listTokens(user) {
  return db.prepare(`
    SELECT id, name, prefix, created_at, last_used_at FROM api_tokens
    WHERE user_id = ? ORDER BY created_at DESC
  `).all(user.id).map((row) => ({
    id: row.id,
    name: row.name,
    prefix: row.prefix,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at,
  }));
}

async function createToken(req, res) {
  const user = requireUser(req);
  const payload = await readJson(req, 16 * 1024);
  const name = String(payload.name || "default").slice(0, 80);
  const raw = `kons_${randomToken(32)}`;
  const prefix = raw.slice(0, 14);
  db.prepare(`
    INSERT INTO api_tokens (user_id, name, token_hash, prefix, created_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(user.id, name, sha256(raw), prefix, nowIso());
  sendJson(res, 201, { token: raw, tokens: listTokens(user) });
}

function deleteToken(req, res, id) {
  const user = requireUser(req);
  db.prepare("DELETE FROM api_tokens WHERE id = ? AND user_id = ?").run(id, user.id);
  sendJson(res, 200, { tokens: listTokens(user) });
}

function packageNameFromApiPath(pathname, suffix = "") {
  let rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  if (suffix && rest.endsWith(suffix)) rest = rest.slice(0, -suffix.length);
  return resolvePackageName(rest.replace(/\/$/, ""));
}

function ownerRouteParts(pathname, withUsername = false) {
  const rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  const parts = rest.split("/").filter(Boolean);
  if (withUsername) {
    if (parts.length < 3 || parts.at(-2) !== "owners") throw httpError(404, "not found");
    return {
      name: resolvePackageName(parts.slice(0, -2).join("/")),
      username: validateUsername(parts.at(-1)),
    };
  }
  if (parts.length < 2 || parts.at(-1) !== "owners") throw httpError(404, "not found");
  return { name: resolvePackageName(parts.slice(0, -1).join("/")) };
}

function versionRouteParts(pathname, terminal) {
  const rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  const parts = rest.split("/").filter(Boolean);
  if (parts.at(-1) !== terminal || parts.length < 3) throw httpError(404, "not found");
  const version = parts.at(-2);
  requireSemver(version);
  const name = resolvePackageName(parts.slice(0, -2).join("/"));
  return { name, version };
}

function versionDeleteRouteParts(pathname) {
  const rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  const parts = rest.split("/").filter(Boolean);
  if (parts.length < 2) throw httpError(404, "not found");
  const version = parts.at(-1);
  requireSemver(version);
  const name = resolvePackageName(parts.slice(0, -1).join("/"));
  return { name, version };
}

async function yankVersion(req, res, unyank = false) {
  const user = requireUser(req);
  const { name, version } = versionRouteParts(new URL(req.url, "http://local").pathname, unyank ? "unyank" : "yank");
  requirePackageOwner(user, name);
  const row = db.prepare("SELECT 1 FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  db.prepare(`
    UPDATE versions SET yanked = ?, yanked_at = ?, yanked_by = ? WHERE package_name = ? AND version = ?
  `).run(unyank ? 0 : 1, unyank ? null : nowIso(), unyank ? null : user.id, name, version);
  sendJson(res, 200, { package: publicPackage(name, user) });
}

function listPackageOwners(req, res) {
  const { name } = ownerRouteParts(new URL(req.url, "http://local").pathname);
  if (!packageRow(name)) throw httpError(404, "package not found");
  sendJson(res, 200, { owners: ownerRows(name) });
}

async function addPackageOwner(req, res) {
  const user = requireUser(req);
  const pathname = new URL(req.url, "http://local").pathname;
  let route = pathname.endsWith("/owners") ? ownerRouteParts(pathname) : ownerRouteParts(pathname, true);
  if (pathname.endsWith("/owners")) {
    const payload = await readJson(req, 16 * 1024);
    route = { ...route, username: validateUsername(payload.username) };
  }
  if (!packageRow(route.name)) throw httpError(404, "package not found");
  requirePackageOwner(user, route.name);

  const owner = getUserByUsername(route.username);
  if (!owner) throw httpError(404, "user not found", { username: route.username });
  db.prepare(`
    INSERT OR IGNORE INTO package_owners (package_name, user_id, role, created_at)
    VALUES (?, ?, 'owner', ?)
  `).run(route.name, owner.id, nowIso());
  sendJson(res, 200, { owners: ownerRows(route.name) });
}

function removePackageOwner(req, res) {
  const user = requireUser(req);
  const { name, username } = ownerRouteParts(new URL(req.url, "http://local").pathname, true);
  if (!packageRow(name)) throw httpError(404, "package not found");
  requirePackageOwner(user, name);

  const owner = getUserByUsername(username);
  if (!owner) throw httpError(404, "user not found", { username });
  const count = db.prepare("SELECT count(*) AS count FROM package_owners WHERE package_name = ?").get(name).count;
  if (count <= 1 && db.prepare("SELECT 1 FROM package_owners WHERE package_name = ? AND user_id = ?").get(name, owner.id)) {
    throw httpError(400, "cannot remove the last package owner");
  }
  db.prepare("DELETE FROM package_owners WHERE package_name = ? AND user_id = ?").run(name, owner.id);
  sendJson(res, 200, { owners: ownerRows(name) });
}

function searchPackages(url, viewer) {
  const q = String(url.searchParams.get("q") || "").toLowerCase();
  const keyword = String(url.searchParams.get("keyword") || "").toLowerCase();
  const type = String(url.searchParams.get("type") || "package").toLowerCase();
  const page = Math.max(1, Number(url.searchParams.get("page") || 1));
  const perPage = Math.min(100, Math.max(1, Number(url.searchParams.get("per_page") || 20)));
  const searchTermPackages = q
    ? new Set(db.prepare(`
        SELECT DISTINCT package_name
        FROM package_search_terms
        WHERE lower(term) LIKE ?
      `).all(`%${q}%`).map((row) => row.package_name))
    : new Set();
  const rows = db.prepare("SELECT name FROM packages ORDER BY updated_at DESC, name ASC").all();
  const filtered = rows.map((row) => publicPackage(row.name, viewer)).filter((pkg) => {
    if (keyword && !(pkg.keywords || []).some((item) => item.toLowerCase() === keyword)) return false;
    if (!q) return true;
    if (searchTermPackages.has(pkg.name)) return true;
    return [
      pkg.name,
      pkg.description,
      pkg.repository,
      ...(pkg.keywords || []),
      ...(pkg.owners || []).map((owner) => owner.username),
      ...(pkg.owners || []).map((owner) => owner.displayName),
    ].join(" ").toLowerCase().includes(q);
  });
  const offset = (page - 1) * perPage;
  return {
    total: filtered.length,
    page,
    perPage,
    packages: filtered.slice(offset, offset + perPage),
    results: type === "all"
      ? [
          ...filtered.slice(offset, offset + perPage).map((pkg) => ({
            type: "package",
            name: pkg.name,
            package: pkg.name,
            version: pkg.latest?.version || "",
            description: pkg.description,
          })),
          ...searchLibraryResults(q, perPage, 0),
          ...searchIdentifierResults(q, perPage, 0),
        ]
      : type === "library"
        ? searchLibraryResults(q, perPage, offset)
        : type === "identifier"
          ? searchIdentifierResults(q, perPage, offset)
          : filtered.slice(offset, offset + perPage).map((pkg) => ({
              type: "package",
              name: pkg.name,
              package: pkg.name,
              version: pkg.latest?.version || "",
              description: pkg.description,
            })),
  };
}

function searchLibraryResults(q, limit = 20, offset = 0) {
  const like = `%${q || ""}%`;
  return db.prepare(`
    SELECT l.kind, l.library_name, l.library_key, l.implementation, l.dialect,
           l.package_name, l.version, v.description
    FROM version_libraries l
    JOIN versions v ON v.package_name = l.package_name AND v.version = l.version
    WHERE (? = ''
       OR lower(l.library_name) LIKE ?
       OR lower(l.library_key) LIKE ?
       OR lower(l.implementation) LIKE ?
       OR lower(l.dialect) LIKE ?)
    ORDER BY l.library_key, l.package_name, l.version DESC
    LIMIT ? OFFSET ?
  `).all(q, like, like, like, like, limit, offset).map((row) => ({
    type: "library",
    name: row.library_name,
    key: row.library_key,
    kind: row.kind,
    implementation: row.implementation || "",
    dialect: row.dialect || "",
    package: row.package_name,
    version: row.version,
    description: row.description,
  }));
}

function searchIdentifierResults(q, limit = 20, offset = 0) {
  const like = `%${q || ""}%`;
  return db.prepare(`
    SELECT i.identifier, i.kind, i.library_name, i.package_name, i.version, v.description
    FROM version_identifiers i
    JOIN versions v ON v.package_name = i.package_name AND v.version = i.version
    WHERE (? = '' OR lower(i.identifier) LIKE ?)
    ORDER BY i.identifier, i.library_name, i.package_name, i.version DESC
    LIMIT ? OFFSET ?
  `).all(q, like, limit, offset).map((row) => ({
    type: "identifier",
    name: row.identifier,
    identifier: row.identifier,
    kind: row.kind,
    library: row.library_name,
    package: row.package_name,
    version: row.version,
    description: row.description,
  }));
}

function librarySearch(url) {
  const q = String(url.searchParams.get("q") || "").toLowerCase();
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") || 20)));
  return { libraries: searchLibraryResults(q, limit, 0) };
}

function libraryProviders(key, url) {
  const libraryKeyValue = String(key || "").trim().toLowerCase();
  if (!libraryKeyValue) throw httpError(400, "library key is required");
  const kind = String(url.searchParams.get("kind") || "").toLowerCase();
  const rows = db.prepare(`
    SELECT l.kind, l.library_name, l.library_key, l.path, l.imports_json, l.exports_json,
           l.implementation, l.dialect, l.package_name, l.version, v.description, v.yanked
    FROM version_libraries l
    JOIN versions v ON v.package_name = l.package_name AND v.version = l.version
    WHERE lower(l.library_key) = ? AND (? = '' OR l.kind = ?)
    ORDER BY l.package_name, l.version DESC, l.kind
  `).all(libraryKeyValue, kind, kind).map((row) => ({
    type: "library",
    name: row.library_name,
    key: row.library_key,
    kind: row.kind,
    implementation: row.implementation || "",
    dialect: row.dialect || "",
    path: row.path || "",
    imports: JSON.parse(row.imports_json || "[]"),
    exports: JSON.parse(row.exports_json || "[]"),
    package: row.package_name,
    version: row.version,
    description: row.description,
    yanked: Boolean(row.yanked),
  }));
  return { key: libraryKeyValue, libraries: rows };
}

function packageDependents(name, includeYanked = false) {
  if (!packageRow(name)) throw httpError(404, "package not found");
  const rows = db.prepare(`
    SELECT d.package_name, d.version, d.req, d.kind, d.registry, d.optional,
           d.target, d.features_json, v.description, v.yanked
    FROM dependencies d
    JOIN versions v ON v.package_name = d.package_name AND v.version = d.version
    WHERE d.dep_name = ? AND (? = 1 OR v.yanked = 0)
    ORDER BY d.package_name, d.version DESC
  `).all(name, includeYanked ? 1 : 0).map((row) => ({
    package: row.package_name,
    version: row.version,
    req: row.req,
    kind: row.kind,
    registry: row.registry || null,
    optional: Boolean(row.optional),
    target: row.target || null,
    features: JSON.parse(row.features_json || "[]"),
    description: row.description,
    yanked: Boolean(row.yanked),
  }));
  return { package: name, dependents: rows };
}

function identifierSearch(url) {
  const q = String(url.searchParams.get("q") || "").toLowerCase();
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") || 20)));
  return { identifiers: searchIdentifierResults(q, limit, 0) };
}

function managedPackages(user) {
  const rows = user.isAdmin
    ? db.prepare("SELECT name FROM packages ORDER BY updated_at DESC, name ASC").all()
    : db.prepare(`
        SELECT packages.name
        FROM packages
        JOIN package_owners ON package_owners.package_name = packages.name
        WHERE package_owners.user_id = ?
        ORDER BY packages.updated_at DESC, packages.name ASC
      `).all(user.id);
  return rows.map((row) => publicPackage(row.name, user)).filter(Boolean);
}

async function deletePackageVersion(req, res) {
  const user = requireUser(req);
  const { name, version } = versionDeleteRouteParts(new URL(req.url, "http://local").pathname);
  requirePackageOwner(user, name);
  const row = db.prepare("SELECT * FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  await deleteArchive(row);
  db.prepare("DELETE FROM versions WHERE package_name = ? AND version = ?").run(name, version);
  if (!db.prepare("SELECT 1 FROM versions WHERE package_name = ?").get(name)) {
    db.prepare("DELETE FROM packages WHERE name = ?").run(name);
    sendJson(res, 200, { deleted: true, package: null });
    return;
  }
  db.prepare("UPDATE packages SET updated_at = ? WHERE name = ?").run(nowIso(), name);
  sendJson(res, 200, { deleted: true, package: publicPackage(name, user) });
}

async function deletePackage(req, res) {
  const user = requireUser(req);
  const name = packageNameFromApiPath(new URL(req.url, "http://local").pathname, "/delete");
  requirePackageOwner(user, name);
  const pkg = packageRow(name);
  if (!pkg) throw httpError(404, "package not found");
  const rows = db.prepare("SELECT * FROM versions WHERE package_name = ?").all(name);
  for (const row of rows) await deleteArchive(row);
  db.prepare("DELETE FROM packages WHERE name = ?").run(name);
  sendJson(res, 200, { deleted: true });
}

async function staticFile(req, res, pathname) {
  const aliases = {
    "/account": "account.html",
  };
  const file = pathname === "/"
    ? "index.html"
    : aliases[pathname] || pathname.replace(/^\/+/, "");
  const full = path.resolve(config.publicDir, file);
  if (!full.startsWith(config.publicDir)) throw httpError(403, "forbidden");
  try {
    const stat = await fs.stat(full);
    if (!stat.isFile()) throw httpError(404, "not found");
    const ext = path.extname(full);
    const type = {
      ".html": "text/html; charset=utf-8",
      ".css": "text/css; charset=utf-8",
      ".js": "application/javascript; charset=utf-8",
      ".svg": "image/svg+xml",
    }[ext] || "application/octet-stream";
    res.writeHead(200, { "content-type": type, "cache-control": "no-cache" });
    createReadStream(full).pipe(res);
  } catch {
    if (!pathname.startsWith("/api/") && !pathname.startsWith("/index/") && !pathname.startsWith("/auth/")) {
      await staticFile(req, res, "/");
      return;
    }
    throw httpError(404, "not found");
  }
}

async function route(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || "local"}`);
  const pathname = decodeURI(url.pathname);
  const viewer = currentUser(req);

  if (req.method === "GET" && pathname === "/healthz") {
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/meta") {
    sendJson(res, 200, {
      name: "kons",
      baseUrl: publicBaseUrl(req),
      publicUrl: configuredPublicUrl(),
      storage: config.storage,
      index: `${publicBaseUrl(req)}/index/config.json`,
      sourceUrl: config.sourceUrl,
      messages: config.deployerMessages,
      auth: {
        oauth: configuredProviders(),
        email: emailAuthInfo(),
      },
    });
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/auth/providers") {
    sendJson(res, 200, {
      oauth: configuredProviders(),
      email: emailAuthInfo(),
      publicUrl: configuredPublicUrl(),
      sourceUrl: config.sourceUrl,
      messages: config.deployerMessages,
    });
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/auth/me") {
    sendJson(res, 200, { user: viewer });
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/auth/logout") {
    const session = parseCookies(req).kons_session;
    if (session) db.prepare("DELETE FROM sessions WHERE id_hash = ?").run(sha256(session));
    sendJson(res, 200, { ok: true }, { "set-cookie": clearSessionCookie() });
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/auth/email/start") {
    await handleEmailStart(req, res);
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/auth/email/verify") {
    await handleEmailVerify(req, res);
    return;
  }

  const authStart = pathname.match(/^\/auth\/([a-z]+)\/start$/);
  if (req.method === "GET" && authStart) {
    await handleAuthStart(req, res, authStart[1], url);
    return;
  }

  const authCallback = pathname.match(/^\/auth\/([a-z]+)\/callback$/);
  if (req.method === "GET" && authCallback) {
    await handleAuthCallback(req, res, authCallback[1], url);
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/tokens") {
    const user = requireUser(req);
    sendJson(res, 200, { tokens: listTokens(user) });
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/tokens") {
    await createToken(req, res);
    return;
  }

  const tokenDelete = pathname.match(/^\/api\/v1\/tokens\/(\d+)$/);
  if (req.method === "DELETE" && tokenDelete) {
    deleteToken(req, res, Number(tokenDelete[1]));
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/search") {
    sendJson(res, 200, searchPackages(url, viewer));
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/resolve") {
    await resolvePackages(req, res);
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/libraries") {
    sendJson(res, 200, librarySearch(url));
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/v1/libraries/")) {
    const key = decodeURIComponent(pathname.slice("/api/v1/libraries/".length));
    sendJson(res, 200, libraryProviders(key, url));
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/identifiers") {
    sendJson(res, 200, identifierSearch(url));
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/me/packages") {
    const user = requireUser(req);
    sendJson(res, 200, { packages: managedPackages(user) });
    return;
  }

  if (req.method === "PUT" && pathname === "/api/v1/packages/new") {
    await publishPackage(req, res);
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/dependents") && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname, "/dependents");
    sendJson(res, 200, packageDependents(name, url.searchParams.get("includeYanked") === "1"));
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/versions") && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname, "/versions");
    sendJson(res, 200, packageVersionList(name, url.searchParams.get("includeYanked") === "1"));
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/metadata") && pathname.startsWith("/api/v1/packages/")) {
    const { name, version } = versionRouteParts(pathname, "metadata");
    sendJson(res, 200, packageVersionMetadata(name, version));
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/manifest") && pathname.startsWith("/api/v1/packages/")) {
    const { name, version } = versionRouteParts(pathname, "manifest");
    sendJson(res, 200, packageVersionManifest(name, version));
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/owners") && pathname.startsWith("/api/v1/packages/")) {
    listPackageOwners(req, res);
    return;
  }

  if (req.method === "POST" && pathname.endsWith("/owners") && pathname.startsWith("/api/v1/packages/")) {
    await addPackageOwner(req, res);
    return;
  }

  if (req.method === "PUT" && pathname.includes("/owners/") && pathname.startsWith("/api/v1/packages/")) {
    await addPackageOwner(req, res);
    return;
  }

  if (req.method === "DELETE" && pathname.includes("/owners/") && pathname.startsWith("/api/v1/packages/")) {
    removePackageOwner(req, res);
    return;
  }

  if (req.method === "DELETE" && pathname.endsWith("/yank") && pathname.startsWith("/api/v1/packages/")) {
    await yankVersion(req, res, false);
    return;
  }

  if (req.method === "PUT" && pathname.endsWith("/unyank") && pathname.startsWith("/api/v1/packages/")) {
    await yankVersion(req, res, true);
    return;
  }

  if (req.method === "DELETE" && pathname.endsWith("/delete") && pathname.startsWith("/api/v1/packages/")) {
    await deletePackage(req, res);
    return;
  }

  if (req.method === "DELETE" && pathname.startsWith("/api/v1/packages/")) {
    await deletePackageVersion(req, res);
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/download") && pathname.startsWith("/api/v1/packages/")) {
    const { name, version } = versionRouteParts(pathname, "download");
    const row = db.prepare("SELECT * FROM versions WHERE package_name = ? AND version = ?").get(name, version);
    if (!row) throw httpError(404, "package version not found");
    await sendArchive(req, res, row);
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/resolve") && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname, "/resolve");
    const row = resolvePackageVersion(name, url.searchParams.get("req") || "*");
    if (!row) throw httpError(404, "no matching package version");
    sendJson(res, 200, { version: row.version, package: publicPackage(name, viewer) });
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname);
    const pkg = publicPackage(name, viewer);
    if (!pkg) throw httpError(404, "package not found");
    sendJson(res, 200, { package: pkg });
    return;
  }

  if (req.method === "GET" && pathname === "/index/config.json") {
    sendJson(res, 200, indexConfig(req), { "cache-control": "public, max-age=60" });
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/index/")) {
    const sparsePath = pathname.slice("/index/".length);
    const rows = db.prepare("SELECT name FROM packages").all();
    const found = rows.find((row) => sparsePathForName(row.name) === sparsePath);
    if (!found) throw httpError(404, "index entry not found");
    send(res, 200, indexLines(found.name), {
      "content-type": "application/x-ndjson; charset=utf-8",
      "cache-control": "public, max-age=60",
    });
    return;
  }

  await staticFile(req, res, pathname);
}

const server = http.createServer((req, res) => {
  route(req, res).catch((error) => {
    const status = error.status || 500;
    if (status >= 500) console.error(error);
    const message = error.message || "internal server error";
    sendJson(res, status, {
      status,
      message,
      details: error.details ?? null,
      error: message,
    });
  });
});

backfillPackageSearchTerms();

server.listen(config.port, config.host, () => {
  const base = config.baseUrl || `http://${config.host}:${config.port}`;
  console.log(`[kons] listening on ${base}`);
  if (config.sessionSecret === "kons-registry-dev-secret") {
    console.log("[kons] set KONS_SESSION_SECRET before production use");
  }
  if (config.emailRegistration) {
    const mode = config.emailOpenRegistration ? "open registration" : "allowlist registration";
    const delivery = smtpConfigured(config.smtp) ? `smtp://${config.smtp.host}:${config.smtp.port}` : "server log";
    console.log(`[kons] email registration enabled (${mode}, delivery: ${delivery})`);
  }
});
