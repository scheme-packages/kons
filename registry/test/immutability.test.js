import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  makeSchemeArchive,
  request,
  signInAndToken,
  waitForHealth,
} from "./helpers.js";

function startRegistry({ port, dataDir }) {
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

async function publishPackage(baseUrl, token, tmp, name, version) {
  const archiveBase64 = await makeSchemeArchive(tmp, name, version);
  const publish = await request(baseUrl, "/api/v1/packages/new", {
    method: "PUT",
    headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({
      name,
      owner: "alice",
      version,
      description: name,
      license: "MIT",
      archiveBase64,
    }),
  });
  assert.equal(publish.response.status, 201);
  return Buffer.from(archiveBase64, "base64");
}

test("published package versions are immutable and remain downloadable after yank", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-immutability-"));
  const port = 24000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const registry = startRegistry({ port, dataDir: path.join(tmp, "data") });

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "immutable@example.test", "immutable");
    const archive = await publishPackage(baseUrl, token, tmp, "immutable/pkg", "1.0.0");

    const yank = await request(baseUrl, "/api/v1/packages/immutable/pkg/1.0.0/yank", {
      method: "DELETE",
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(yank.response.status, 200);

    const deleteVersion = await request(baseUrl, "/api/v1/packages/immutable/pkg/1.0.0", {
      method: "DELETE",
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(deleteVersion.response.status, 409);
    assert.match(deleteVersion.data.message, /immutable/);

    const deletePackage = await request(baseUrl, "/api/v1/packages/immutable/pkg/delete", {
      method: "DELETE",
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(deletePackage.response.status, 409);
    assert.match(deletePackage.data.message, /immutable/);

    const versions = await request(baseUrl, "/api/v1/packages/immutable/pkg/versions?includeYanked=1");
    assert.equal(versions.response.status, 200);
    assert.deepEqual(versions.data.versions.map((item) => item.version), ["1.0.0"]);
    assert.equal(versions.data.versions[0].yanked, true);

    const download = await fetch(`${baseUrl}/api/v1/packages/immutable/pkg/1.0.0/download`);
    assert.equal(download.status, 200);
    assert.deepEqual(Buffer.from(await download.arrayBuffer()), archive);
  } catch (error) {
    error.message = `${error.message}\n${registry.output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
