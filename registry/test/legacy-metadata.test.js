import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  makeArchive,
  request,
  signInAndToken,
  waitForHealth,
} from "./helpers.js";

function startRegistry(port, dataDir) {
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

test("packages without rich library metadata still display, search, and resolve", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-legacy-metadata-"));
  const port = 23000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const registry = startRegistry(port, path.join(tmp, "data"));

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "legacy@example.test", "legacy");
    const archiveBase64 = await makeArchive(tmp, "legacy/pkg", "1.0.0", "legacy");
    const publish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${token}` },
      body: JSON.stringify({
        name: "legacy/pkg",
        owner: "legacy",
        version: "1.0.0",
        description: "Legacy package without rich metadata",
        license: "MIT",
        keywords: ["legacy"],
        archiveBase64,
      }),
    });
    assert.equal(publish.response.status, 201);
    assert.deepEqual(publish.data.package.latest.libraries, []);

    const packageView = await request(baseUrl, "/api/v1/packages/legacy/pkg");
    assert.equal(packageView.response.status, 200);
    assert.equal(packageView.data.package.name, "legacy/pkg");
    assert.equal(packageView.data.package.latest.version, "1.0.0");
    assert.deepEqual(packageView.data.package.latest.libraries, []);

    const metadata = await request(baseUrl, "/api/v1/packages/legacy/pkg/1.0.0/metadata");
    assert.equal(metadata.response.status, 200);
    assert.equal(metadata.data.checksum, publish.data.checksum);
    assert.deepEqual(metadata.data.libraries, []);

    const search = await request(baseUrl, "/api/v1/search?q=legacy&type=package");
    assert.equal(search.response.status, 200);
    assert.deepEqual(search.data.results.map((result) => result.package), ["legacy/pkg"]);

    const librarySearch = await request(baseUrl, "/api/v1/search?q=legacy&type=library");
    assert.equal(librarySearch.response.status, 200);
    assert.deepEqual(librarySearch.data.results, []);

    const identifierSearch = await request(baseUrl, "/api/v1/identifiers?q=message");
    assert.equal(identifierSearch.response.status, 200);
    assert.deepEqual(identifierSearch.data.identifiers, []);

    const resolved = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        requirements: [{ name: "legacy/pkg", req: "^1.0.0" }],
      }),
    });
    assert.equal(resolved.response.status, 200);
    assert.deepEqual(resolved.data.packages.map((pkg) => pkg.package), ["legacy/pkg"]);

    const sparse = await fetch(`${baseUrl}/index/le/ga/legacy-pkg`);
    assert.equal(sparse.status, 200);
    const sparseLine = JSON.parse((await sparse.text()).trim());
    assert.equal(sparseLine.name, "legacy/pkg");
    assert.equal(sparseLine.checksum, publish.data.checksum);
  } catch (error) {
    error.message = `${error.message}\n${registry.output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
