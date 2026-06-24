import assert from "node:assert/strict";
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
import {
  identifierPageHtml,
  libraryPageHtml,
  packageRoute,
  routeForTypedResult,
} from "../public/route-views.js";

const registryRoot = path.resolve(import.meta.dirname, "..");

function startRegistry(tmp, port) {
  const server = spawn(process.execPath, ["server.js"], {
    cwd: registryRoot,
    env: {
      ...process.env,
      KONS_REGISTRY_HOST: "127.0.0.1",
      KONS_REGISTRY_PORT: String(port),
      KONS_REGISTRY_DATA: path.join(tmp, "data"),
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

async function stopRegistry(server) {
  if (server.exitCode === null && server.signalCode === null) {
    server.kill("SIGTERM");
    await new Promise((resolve) => server.once("exit", resolve));
  }
}

test("registry web UI has dedicated library and identifier routes", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-registry-ui-routes-"));
  const port = 23000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const { server, output } = startRegistry(tmp, port);

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "ui-routes@example.test", "uiroutes");
    await publishSchemePackage(baseUrl, token, tmp, "ui-routes/lib", "1.0.0");

    const libraries = await request(baseUrl, "/api/v1/libraries/ui-routes/lib");
    assert.equal(libraries.response.status, 200);
    assert.deepEqual(libraries.data.libraries.map((item) => item.package), ["ui-routes/lib"]);
    assert.equal(libraries.data.libraries[0].version, "1.0.0");
    assert.deepEqual(libraries.data.libraries[0].exports, ["message"]);
    assert.equal(routeForTypedResult(libraries.data.libraries[0]), "#/lib/ui-routes%2Flib");

    const displayLibraries = await request(
      baseUrl,
      `/api/v1/libraries/${encodeURIComponent("(ui-routes lib)")}`,
    );
    assert.equal(displayLibraries.response.status, 200);
    assert.equal(displayLibraries.data.key, "ui-routes/lib");
    assert.deepEqual(displayLibraries.data.libraries, libraries.data.libraries);

    const libraryHtml = libraryPageHtml(libraries.data, "ui-routes/lib");
    assert.match(libraryHtml, /Packages and versions that publish this library/);
    assert.match(libraryHtml, /ui-routes\/lib/);
    assert.match(libraryHtml, /v1\.0\.0/);
    assert.match(libraryHtml, new RegExp(packageRoute("ui-routes/lib")));

    const identifiers = await request(baseUrl, "/api/v1/identifiers?q=message");
    assert.equal(identifiers.response.status, 200);
    const exporter = identifiers.data.identifiers.find((item) => item.package === "ui-routes/lib");
    assert.ok(exporter);
    assert.equal(exporter.identifier, "message");
    assert.equal(exporter.library, "(ui-routes lib)");
    assert.equal(routeForTypedResult(exporter), "#/identifier/message");

    const identifierHtml = identifierPageHtml({
      name: "message",
      results: identifiers.data.identifiers,
    }, "message");
    assert.match(identifierHtml, /Libraries and packages that export this identifier/);
    assert.match(identifierHtml, /\(ui-routes lib\)/);
    assert.match(identifierHtml, /ui-routes\/lib/);
    assert.match(identifierHtml, /#\/lib\/ui-routes%2Flib/);
  } catch (error) {
    error.message = `${error.message}\n${output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(server);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test("package page exposes signature and checksum details", async () => {
  const source = await fs.readFile(path.join(registryRoot, "public", "app.js"), "utf8");

  assert.match(source, /Signature status/);
  assert.match(source, /Signing algorithm/);
  assert.match(source, /Signing key/);
  assert.match(source, /Latest checksum/);
  assert.match(source, /Latest published by/);
  assert.match(source, /function signatureDetailHtml/);
  assert.match(source, /version-meta/);
  assert.match(source, /checksumHtml\(checksum\)/);
  assert.match(source, /version\.publishedBy\?\.username/);
});
