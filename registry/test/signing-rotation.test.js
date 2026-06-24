import assert from "node:assert/strict";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  execFileAsync,
  publishSchemePackage,
  request,
  signInAndToken,
  waitForHealth,
} from "./helpers.js";

function ed25519KeyPair() {
  return crypto.generateKeyPairSync("ed25519", {
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
}

async function writeSigningKeyPair(tmp, id, keyPair) {
  const privateKeyFile = path.join(tmp, `${id}-private.pem`);
  const publicKeyFile = path.join(tmp, `${id}-public.pem`);
  await fs.writeFile(privateKeyFile, keyPair.privateKey);
  await fs.writeFile(publicKeyFile, keyPair.publicKey);
  return {
    id,
    privateKeyFile,
    publicKeyFile,
    publicKey: keyPair.publicKey,
  };
}

function startRegistry({ port, dataDir, signingKey }) {
  const server = spawn(process.execPath, ["server.js"], {
    cwd: path.resolve(import.meta.dirname, ".."),
    env: {
      ...process.env,
      KONS_REGISTRY_HOST: "127.0.0.1",
      KONS_REGISTRY_PORT: String(port),
      KONS_REGISTRY_DATA: dataDir,
      KONS_EMAIL_REGISTRATION: "1",
      KONS_EMAIL_OPEN_REGISTRATION: "1",
      KONS_EMAIL_SHOW_CODES: "1",
      KONS_SESSION_SECRET: "test-secret",
      KONS_REGISTRY_SIGNING_KEY_ID: signingKey.id,
      KONS_REGISTRY_SIGNING_PRIVATE_KEY_FILE: signingKey.privateKeyFile,
      KONS_REGISTRY_SIGNING_PUBLIC_KEY_FILE: signingKey.publicKeyFile,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const output = [];
  server.stdout.on("data", (chunk) => output.push(chunk.toString()));
  server.stderr.on("data", (chunk) => output.push(chunk.toString()));
  return { server, output };
}

async function stopRegistry(handle) {
  if (handle.server.exitCode === null && handle.server.signalCode === null) {
    handle.server.kill("SIGTERM");
    await new Promise((resolve) => handle.server.once("exit", resolve));
  }
}

async function writeAppManifest(root, registryName) {
  await fs.mkdir(path.join(root, "src", "rotate"), { recursive: true });
  await fs.writeFile(
    path.join(root, "kons.scm"),
    `(package
  (name (rotate app))
  (version "0.1.0")
  (license "MIT")
  (description "rotation test")
  (source-path "src"))

(dependencies
  (registry (name (rotate dep)) (version "^1.0.0") (registry "${registryName}")))
(dev-dependencies)
`
  );
  await fs.writeFile(
    path.join(root, "src", "rotate", "app.sld"),
    `(define-library (rotate app)
  (export message)
  (import (scheme base) (rotate dep))
  (begin (define (message) "rotation")))
`
  );
}

async function writeTrustConfig(home, baseUrl, oldKey, newKey) {
  await fs.mkdir(path.join(home, "config", "keys"), { recursive: true });
  await fs.copyFile(oldKey.publicKeyFile, path.join(home, "config", "keys", "old-key.pem"));
  await fs.copyFile(newKey.publicKeyFile, path.join(home, "config", "keys", "new-key.pem"));
  await fs.writeFile(
    path.join(home, "config", "registries.scm"),
    `(registries
  (registry
    (name "local")
    (url "${baseUrl}")
    (default #t)
    (trust required)
    (keys
      (key (id "old-key") (file "keys/old-key.pem"))
      (key (id "new-key") (file "keys/new-key.pem")))))
`
  );
}

async function writeSingleKeyTrustConfig(home, baseUrl, key) {
  await fs.mkdir(path.join(home, "config", "keys"), { recursive: true });
  await fs.copyFile(key.publicKeyFile, path.join(home, "config", "keys", `${key.id}.pem`));
  await fs.writeFile(
    path.join(home, "config", "registries.scm"),
    `(registries
  (registry
    (name "local")
    (url "${baseUrl}")
    (default #t)
    (trust required)
    (key-id "${key.id}")
    (key-file "keys/${key.id}.pem")))
`
  );
}

async function writeMismatchedTrustConfig(home, baseUrl, keyId, pinnedPublicKeyFile) {
  await fs.mkdir(path.join(home, "config", "keys"), { recursive: true });
  await fs.copyFile(pinnedPublicKeyFile, path.join(home, "config", "keys", `${keyId}.pem`));
  await fs.writeFile(
    path.join(home, "config", "registries.scm"),
    `(registries
  (registry
    (name "local")
    (url "${baseUrl}")
    (default #t)
    (trust required)
    (key-id "${keyId}")
    (key-file "keys/${keyId}.pem")))
`
  );
}

async function collectFiles(root) {
  const out = [];

  async function visit(dir) {
    let entries = [];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch (error) {
      if (error.code === "ENOENT") return;
      throw error;
    }

    for (const entry of entries) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await visit(file);
      } else {
        out.push(file);
      }
    }
  }

  await visit(root);
  return out;
}

test("trusted registry update rejects live metadata signed by an untrusted key before caching payload", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-signing-invalid-live-"));
  const port = 23000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const dataDir = path.join(tmp, "data");
  const trustedKeyMaterial = ed25519KeyPair();
  const signingKey = await writeSigningKeyPair(tmp, "local-key", trustedKeyMaterial);
  const wrongPinnedKey = await writeSigningKeyPair(tmp, "wrong-local-key", ed25519KeyPair());
  const repoRoot = path.resolve(import.meta.dirname, "../..");
  const appRoot = path.join(tmp, "app");
  const konsHome = path.join(tmp, "home");
  const konsEnv = {
    ...process.env,
    KONS_HOME: konsHome,
    KONS_SCHEME: process.env.KONS_SCHEME || "capy",
    XDG_CACHE_HOME: path.join(tmp, "cache"),
  };
  const registry = startRegistry({ port, dataDir, signingKey });

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "invalid-live@example.test", "invalidlive");
    await publishSchemePackage(baseUrl, token, tmp, "rotate/dep", "1.0.0");
    await writeAppManifest(appRoot, "local");
    await writeMismatchedTrustConfig(konsHome, baseUrl, signingKey.id, wrongPinnedKey.publicKeyFile);

    await assert.rejects(
      execFileAsync(path.join(repoRoot, "bin", "kons"), ["update"], {
        cwd: appRoot,
        env: konsEnv,
      }),
      /registry metadata signature mismatch/
    );

    const cacheFiles = await collectFiles(path.join(konsHome, "store", "registry", "metadata"));
    const payloadCaches = cacheFiles.filter((file) => file.endsWith("rotate-dep-versions.json"));
    const sparseCaches = cacheFiles.filter((file) => file.endsWith("rotate-dep-index.jsonl"));
    assert.deepEqual(payloadCaches, []);
    assert.equal(sparseCaches.length, 1);
  } catch (error) {
    error.message = `${error.message}\n${registry.output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test("trusted registry metadata accepts overlapping signing keys during rotation", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-signing-rotation-"));
  const port = 22000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const dataDir = path.join(tmp, "data");
  const oldKey = await writeSigningKeyPair(tmp, "old-key", ed25519KeyPair());
  const newKey = await writeSigningKeyPair(tmp, "new-key", ed25519KeyPair());
  const repoRoot = path.resolve(import.meta.dirname, "../..");
  const appRoot = path.join(tmp, "app");
  const konsHome = path.join(tmp, "home");
  const konsEnv = {
    ...process.env,
    KONS_HOME: konsHome,
    KONS_SCHEME: process.env.KONS_SCHEME || "capy",
    XDG_CACHE_HOME: path.join(tmp, "cache"),
  };
  let registry = startRegistry({ port, dataDir, signingKey: oldKey });

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "rotation@example.test", "rotation");
    await publishSchemePackage(baseUrl, token, tmp, "rotate/dep", "1.0.0");

    const sparse = await request(baseUrl, "/index/ro/ta/rotate-dep");
    assert.equal(sparse.response.status, 200);
    const indexLine = sparse.data;
    assert.equal(indexLine.name, "rotate/dep");
    assert.equal(indexLine.signed.alg, "ed25519");
    assert.equal(indexLine.signed.keyId, "old-key");
    const signedPayload = Buffer.from(indexLine.signed.payloadBase64, "base64");
    const signedSignature = Buffer.from(indexLine.signed.signatureBase64, "base64");
    assert.equal(crypto.verify(null, signedPayload, oldKey.publicKey, signedSignature), true);
    const signedIndexLine = JSON.parse(signedPayload.toString("utf8"));
    assert.equal(signedIndexLine.name, indexLine.name);
    assert.equal(signedIndexLine.vers, indexLine.vers);
    assert.equal(signedIndexLine.checksum, indexLine.checksum);

    await execFileAsync(
      path.join(repoRoot, "bin", "kons"),
      ["registry", "index", `${baseUrl}/index/config.json`, "local", "--default", "--trust"],
      {
        cwd: repoRoot,
        env: konsEnv,
      },
    );
    const indexedConfig = await fs.readFile(path.join(konsHome, "config", "registries.scm"), "utf8");
    assert.match(indexedConfig, /\(trust required\)/);
    assert.match(indexedConfig, /\(key-id "old-key"\)/);
    assert.match(indexedConfig, /\(key-file "keys\/old-key\.pem"\)/);
    assert.equal(
      await fs.readFile(path.join(konsHome, "config", "keys", "old-key.pem"), "utf8"),
      oldKey.publicKey,
    );

    await writeAppManifest(appRoot, "local");
    await writeTrustConfig(konsHome, baseUrl, oldKey, newKey);

    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["update"], {
      cwd: appRoot,
      env: konsEnv,
    });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["fetch"], {
      cwd: appRoot,
      env: konsEnv,
    });

    await stopRegistry(registry);
    registry = null;
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["verify", "--offline"], {
      cwd: appRoot,
      env: konsEnv,
    });

    registry = startRegistry({ port, dataDir, signingKey: newKey });
    await waitForHealth(baseUrl);
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["update"], {
      cwd: appRoot,
      env: konsEnv,
    });
  } catch (error) {
    error.message = `${error.message}\n${registry ? registry.output.join("") : ""}`;
    throw error;
  } finally {
    if (registry) await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
