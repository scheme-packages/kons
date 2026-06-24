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

async function writeApp(root) {
  await fs.mkdir(path.join(root, "src", "vendor_sync"), { recursive: true });
  await fs.writeFile(
    path.join(root, "kons.scm"),
    `(package
  (name (vendor-sync app))
  (version "0.1.0")
  (source-path "src"))

(dependencies
  (registry (name (vendor-sync dep)) (version "^1.0.0") (registry "local")))
(dev-dependencies)
`
  );
  await fs.writeFile(
    path.join(root, "src", "vendor_sync", "app.sld"),
    `(define-library (vendor-sync app)
  (export message)
  (import (scheme base) (vendor-sync dep))
  (begin (define (message) "vendor sync")))
`
  );
}

async function runKons(app, env, args) {
  return execFileAsync(path.join(repoRoot, "bin", "kons"), args, {
    cwd: app,
    env,
  });
}

test("kons vendor --sync removes stale vendored package directories", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-vendor-sync-"));
  const port = 25000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const { server, output } = startRegistry(tmp, port);
  const app = path.join(tmp, "app");
  const env = {
    ...process.env,
    KONS_HOME: path.join(tmp, "home"),
    KONS_SCHEME: process.env.KONS_SCHEME || "capy",
    XDG_CACHE_HOME: path.join(tmp, "cache"),
  };

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "vendor-sync@example.test", "vendorsync");
    await publishSchemePackage(baseUrl, token, tmp, "vendor-sync/dep", "1.0.0");
    await writeApp(app);

    await runKons(app, env, ["registry", "add", "local", baseUrl, "--default"]);
    await runKons(app, env, ["update"]);
    await runKons(app, env, ["fetch", "--locked"]);

    await stopRegistry(server);

    const vendorRoot = path.join(app, "vendor", "kons");
    const staleRoot = path.join(vendorRoot, "stale-package-0-0-0");
    await fs.mkdir(staleRoot, { recursive: true });
    await fs.writeFile(path.join(staleRoot, "stale.txt"), "remove me\n");

    await runKons(app, env, ["vendor", "--sync", "--offline"]);

    await assert.rejects(
      fs.stat(staleRoot),
      { code: "ENOENT" }
    );
    const entries = (await fs.readdir(vendorRoot)).sort();
    assert.deepEqual(entries, ["kons-vendor.scm", "local-vendor-sync-dep-1-0-0"]);

    const metadata = await fs.readFile(path.join(vendorRoot, "kons-vendor.scm"), "utf8");
    assert.match(metadata, /\(name \(vendor-sync dep\)\)/);
    assert.match(metadata, /\(source-hash "[^"]+"/);
  } catch (error) {
    error.message = `${error.message}\n${output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(server);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
