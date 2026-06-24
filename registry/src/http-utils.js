import { createHmac, createHash, randomBytes, timingSafeEqual } from "node:crypto";

let config;

function bindHttpConfig(value) {
  config = value;
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

export { bindHttpConfig, nowIso, publicBaseUrl, configuredPublicUrl, packageDownloadUrl, randomToken, sha256, hmac, safeEqual, parseCookies, send, sendJson, redirect, httpError, validationError, readBody, readJson };
