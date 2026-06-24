import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";

export function createArchive(ctx) {
  const { config, randomToken, sha256, hmac, send, redirect, httpError, validatePackageName, validateUsername, incrementDownloadCount } = ctx;

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

  return { decodeArchivePayload, validateArchive, putArchive, sendArchive, deleteArchive };
}
