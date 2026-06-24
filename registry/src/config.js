import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const registryRoot = path.resolve(__dirname, "..");

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

function numberEnv(env, name, fallback) {
  const value = Number(env[name] || "");
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function rateLimitConfig(env, name, limit, windowMs) {
  const prefix = `KONS_RATE_LIMIT_${name}`;
  return {
    limit: numberEnv(env, `${prefix}_LIMIT`, limit),
    windowMs: numberEnv(env, `${prefix}_WINDOW_MS`, numberEnv(env, "KONS_RATE_LIMIT_WINDOW_MS", windowMs)),
  };
}

export function createConfig(env = process.env) {
  return {
    host: env.KONS_REGISTRY_HOST || "127.0.0.1",
    port: Number(env.KONS_REGISTRY_PORT || 8787),
    dataDir: path.resolve(env.KONS_REGISTRY_DATA || path.join(registryRoot, "data")),
    publicDir: path.join(registryRoot, "public"),
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
    signing: {
      keyId: env.KONS_REGISTRY_SIGNING_KEY_ID || "",
      privateKeyFile: env.KONS_REGISTRY_SIGNING_PRIVATE_KEY_FILE
        ? path.resolve(env.KONS_REGISTRY_SIGNING_PRIVATE_KEY_FILE)
        : "",
      publicKeyFile: env.KONS_REGISTRY_SIGNING_PUBLIC_KEY_FILE
        ? path.resolve(env.KONS_REGISTRY_SIGNING_PUBLIC_KEY_FILE)
        : "",
    },
    rateLimits: {
      enabled: env.KONS_RATE_LIMITS !== "0",
      auth: rateLimitConfig(env, "AUTH", 20, 15 * 60 * 1000),
      publish: rateLimitConfig(env, "PUBLISH", 30, 60 * 60 * 1000),
      search: rateLimitConfig(env, "SEARCH", 120, 60 * 1000),
      download: rateLimitConfig(env, "DOWNLOAD", 120, 60 * 1000),
    },
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
}
