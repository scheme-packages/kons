import assert from "node:assert/strict";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  publishSchemePackage,
  request,
  signInAndToken,
  waitForHealth,
} from "./helpers.js";

const registryRoot = path.resolve(import.meta.dirname, "..");

function ed25519KeyPair() {
  return crypto.generateKeyPairSync("ed25519", {
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
}

async function writeSigningKeyPair(tmp, id) {
  const keyPair = ed25519KeyPair();
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

function startRegistry(tmp, port, signingKey = null) {
  const env = {
    ...process.env,
    KONS_REGISTRY_HOST: "127.0.0.1",
    KONS_REGISTRY_PORT: String(port),
    KONS_REGISTRY_DATA: path.join(tmp, "data"),
    KONS_EMAIL_REGISTRATION: "1",
    KONS_EMAIL_OPEN_REGISTRATION: "1",
    KONS_EMAIL_SHOW_CODES: "1",
    KONS_SESSION_SECRET: "test-secret",
  };
  if (signingKey) {
    env.KONS_REGISTRY_SIGNING_KEY_ID = signingKey.id;
    env.KONS_REGISTRY_SIGNING_PRIVATE_KEY_FILE = signingKey.privateKeyFile;
    env.KONS_REGISTRY_SIGNING_PUBLIC_KEY_FILE = signingKey.publicKeyFile;
  }

  const server = spawn(process.execPath, ["server.js"], {
    cwd: registryRoot,
    env,
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

function resolveBody() {
  return {
    requirements: [
      {
        name: "signed/root",
        req: "^1.0.0",
        registry: "default",
        kind: "normal",
      },
    ],
  };
}

async function publishResolveSample(baseUrl, token, tmp) {
  await publishSchemePackage(
    baseUrl,
    token,
    tmp,
    "signed/root",
    "1.0.0",
    [{ name: "signed/dep", req: "^1.0.0", registry: "default", kind: "normal" }],
  );
  await publishSchemePackage(baseUrl, token, tmp, "signed/dep", "1.0.0");
}

test("registry resolve response is signed when signing is configured", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-resolve-signing-"));
  const port = 23000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const signingKey = await writeSigningKeyPair(tmp, "resolve-key");
  const registry = startRegistry(tmp, port, signingKey);

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "resolve-signing@example.test", "resolvesigning");
    await publishResolveSample(baseUrl, token, tmp);

    const resolved = await request(baseUrl, "/api/v1/resolve?signed=1", {
      method: "POST",
      body: JSON.stringify(resolveBody()),
    });
    assert.equal(resolved.response.status, 200);
    assert.equal(resolved.data.signed.alg, "ed25519");
    assert.equal(resolved.data.signed.keyId, "resolve-key");

    const payload = Buffer.from(resolved.data.signed.payloadBase64, "base64");
    const signature = Buffer.from(resolved.data.signed.signatureBase64, "base64");
    assert.equal(crypto.verify(null, payload, signingKey.publicKey, signature), true);

    const signedPayload = JSON.parse(payload.toString("utf8"));
    const unsignedResponse = {
      context: resolved.data.context,
      packages: resolved.data.packages,
      edges: resolved.data.edges,
    };
    assert.deepEqual(signedPayload, unsignedResponse);
    assert.deepEqual(resolved.data.packages.map((item) => item.package), ["signed/dep", "signed/root"]);
  } catch (error) {
    error.message = `${error.message}\n${registry.output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test("registry resolve signed mode requires signing configuration", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-resolve-signing-required-"));
  const port = 23000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const registry = startRegistry(tmp, port);

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "resolve-unsigned@example.test", "resolveunsigned");
    await publishResolveSample(baseUrl, token, tmp);

    const resolved = await request(baseUrl, "/api/v1/resolve?signed=1", {
      method: "POST",
      body: JSON.stringify(resolveBody()),
    });
    assert.equal(resolved.response.status, 409);
    assert.equal(resolved.data.message, "registry signing is not configured");
  } catch (error) {
    error.message = `${error.message}\n${registry.output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
