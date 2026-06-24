import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  execFileAsync,
  publishSchemePackage,
  signInAndToken,
  waitForHealth,
} from "./helpers.js";

const repoRoot = path.resolve(import.meta.dirname, "../..");
const registryRoot = path.resolve(import.meta.dirname, "..");

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function startRegistry(tmp, baseUrl, port) {
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

async function runKons(tmp, args) {
  const env = {
    ...process.env,
    KONS_HOME: path.join(tmp, "home"),
    KONS_SCHEME: process.env.KONS_SCHEME || "capy",
    XDG_CACHE_HOME: path.join(tmp, "cache"),
  };
  return execFileAsync(path.join(repoRoot, "bin", "kons"), args, {
    cwd: repoRoot,
    env,
  });
}

async function runKonsJson(tmp, args) {
  const result = await runKons(tmp, args);
  return JSON.parse(result.stdout);
}

function assertKeys(value, keys) {
  assert.deepEqual(Object.keys(value), keys);
}

test("registry CLI inspection JSON output is versioned and stable", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-registry-json-"));
  const port = 22000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const { server, output } = startRegistry(tmp, baseUrl, port);

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "json-output@example.test", "jsonout");
    await publishSchemePackage(baseUrl, token, tmp, "json-output/alpha", "1.0.0");
    await sleep(1100);
    await publishSchemePackage(baseUrl, token, tmp, "json-output/beta", "1.0.0");
    await sleep(1100);
    await publishSchemePackage(baseUrl, token, tmp, "json-output/gamma", "1.0.0");

    await runKons(tmp, ["registry", "add", "local", baseUrl, "--default"]);

    const searchArgs = ["search", "json-output", "--type", "package", "--format", "json"];
    const firstSearch = await runKonsJson(tmp, searchArgs);
    const secondSearch = await runKonsJson(tmp, searchArgs);
    assert.deepEqual(firstSearch, secondSearch);
    assertKeys(firstSearch, ["formatVersion", "total", "page", "perPage", "packages", "results"]);
    assert.equal(firstSearch.formatVersion, 1);
    assert.deepEqual(
      firstSearch.results.map((result) => result.package),
      ["json-output/gamma", "json-output/beta", "json-output/alpha"],
    );
    assert.deepEqual(
      firstSearch.results.map((result) => Object.keys(result)),
      [
        ["type", "name", "package", "version", "description"],
        ["type", "name", "package", "version", "description"],
        ["type", "name", "package", "version", "description"],
      ],
    );
    assert.equal(firstSearch.results[0].type, "package");
    assert.equal(firstSearch.results[0].version, "1.0.0");

    const allFirstPage = await runKonsJson(tmp, [
      "search",
      "json-output",
      "--type",
      "all",
      "--limit",
      "2",
      "--format",
      "json",
    ]);
    assert.equal(allFirstPage.formatVersion, 1);
    assert.equal(allFirstPage.total, 6);
    assert.equal(allFirstPage.perPage, 2);
    assert.equal(allFirstPage.results.length, 2);
    assert.deepEqual(
      allFirstPage.results.map((result) => result.type),
      ["package", "package"],
    );
    assert.deepEqual(
      allFirstPage.results.map((result) => result.package),
      ["json-output/gamma", "json-output/beta"],
    );

    const allSecondPage = await runKonsJson(tmp, [
      "search",
      "json-output",
      "--type",
      "all",
      "--limit",
      "2",
      "--page",
      "2",
      "--format",
      "json",
    ]);
    assert.equal(allSecondPage.results.length, 2);
    assert.deepEqual(
      allSecondPage.results.map((result) => result.type),
      ["package", "library"],
    );
    assert.deepEqual(
      allSecondPage.results.map((result) => result.package),
      ["json-output/alpha", "json-output/alpha"],
    );

    const libraryArgs = ["search", "json-output", "--type", "library", "--format", "json"];
    const librarySearch = await runKonsJson(tmp, libraryArgs);
    assert.equal(librarySearch.formatVersion, 1);
    assert.deepEqual(
      librarySearch.results.map((result) => result.package),
      ["json-output/alpha", "json-output/beta", "json-output/gamma"],
    );
    assert.deepEqual(
      Object.keys(librarySearch.results[0]),
      ["type", "name", "key", "kind", "implementation", "dialect", "package", "version", "description"],
    );

    const info = await runKonsJson(tmp, ["info", "json-output/alpha", "--format", "json"]);
    assertKeys(info, ["formatVersion", "package"]);
    assert.equal(info.formatVersion, 1);
    assert.equal(info.package.name, "json-output/alpha");
    assert.equal(info.package.latest.version, "1.0.0");
    assert.deepEqual(
      Object.keys(info.package.latest.libraries[0]),
      ["kind", "name", "key", "path", "imports", "exports", "implementation", "dialect"],
    );
    assert.deepEqual(info.package.latest.libraries[0].exports, ["message"]);

    const providesArgs = ["provides", "json-output/alpha", "--format", "json"];
    const firstProvides = await runKonsJson(tmp, providesArgs);
    const secondProvides = await runKonsJson(tmp, providesArgs);
    assert.deepEqual(firstProvides, secondProvides);
    assertKeys(firstProvides, ["formatVersion", "key", "libraries"]);
    assert.equal(firstProvides.formatVersion, 1);
    assert.equal(firstProvides.key, "json-output/alpha");
    assert.deepEqual(
      firstProvides.libraries.map((result) => result.package),
      ["json-output/alpha"],
    );
    const displayProvides = await runKonsJson(tmp, [
      "provides",
      "(json-output alpha)",
      "--format",
      "json",
    ]);
    assert.equal(displayProvides.key, "json-output/alpha");
    assert.deepEqual(displayProvides.libraries, firstProvides.libraries);
    assert.deepEqual(
      Object.keys(firstProvides.libraries[0]),
      [
        "type",
        "name",
        "key",
        "kind",
        "implementation",
        "dialect",
        "path",
        "imports",
        "exports",
        "package",
        "version",
        "description",
        "yanked",
      ],
    );

    const identifierArgs = ["identifier", "message", "--limit", "3", "--format", "json"];
    const firstIdentifier = await runKonsJson(tmp, identifierArgs);
    const secondIdentifier = await runKonsJson(tmp, identifierArgs);
    assert.deepEqual(firstIdentifier, secondIdentifier);
    assertKeys(firstIdentifier, ["formatVersion", "identifiers"]);
    assert.equal(firstIdentifier.formatVersion, 1);
    assert.deepEqual(
      firstIdentifier.identifiers.map((result) => result.package),
      ["json-output/alpha", "json-output/beta", "json-output/gamma"],
    );
    assert.deepEqual(
      Object.keys(firstIdentifier.identifiers[0]),
      ["type", "name", "identifier", "kind", "library", "package", "version", "description"],
    );

    const searchText = await runKons(tmp, ["search", "json-output", "--type", "package"]);
    assert.match(searchText.stdout, /json-output\/gamma  v1\.0\.0/);
    const infoText = await runKons(tmp, ["info", "json-output/alpha"]);
    assert.match(infoText.stdout, /json-output\/alpha 1\.0\.0/);
    assert.match(infoText.stdout, /libraries:/);
    const providesText = await runKons(tmp, ["provides", "json-output/alpha"]);
    assert.match(providesText.stdout, /package json-output\/alpha v1\.0\.0/);
    const displayProvidesText = await runKons(tmp, ["provides", "(json-output alpha)"]);
    assert.match(displayProvidesText.stdout, /package json-output\/alpha v1\.0\.0/);
    const identifierText = await runKons(tmp, ["identifier", "message", "--limit", "1"]);
    assert.match(identifierText.stdout, /message/);
    assert.match(identifierText.stdout, /package json-output\/alpha v1\.0\.0/);
  } catch (error) {
    error.message = `${error.message}\n${output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(server);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
