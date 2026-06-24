import assert from "node:assert/strict";
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

async function writeApp(root) {
  await fs.mkdir(path.join(root, "src", "offline"), { recursive: true });
  await fs.writeFile(
    path.join(root, "kons.scm"),
    `(package
  (name (offline app))
  (version "0.1.0")
  (license "MIT")
  (description "offline app")
  (source-path "src"))

(dependencies
  (registry (name (offline root)) (version "^1.0.0") (registry "local")))
(dev-dependencies)
`
  );
  await fs.writeFile(
    path.join(root, "src", "offline", "app.sld"),
    `(define-library (offline app)
  (export message)
  (import (scheme base) (offline root) (offline leaf))
  (begin (define (message) "offline")))
`
  );
  await fs.writeFile(
    path.join(root, "src", "main.scm"),
    `(import (scheme base) (offline app))
(message)
`
  );
}

async function findVersionsCache(root, packageToken) {
  const entries = await fs.readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      const found = await findVersionsCache(fullPath, packageToken);
      if (found) return found;
    } else if (entry.name === `${packageToken}-versions.json`) {
      return fullPath;
    }
  }
  return null;
}

test("offline and frozen builds use cached registry metadata without vendoring", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-offline-cache-"));
  const port = 24000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const repoRoot = path.resolve(import.meta.dirname, "../..");
  const registry = startRegistry(port, path.join(tmp, "data"));
  const app = path.join(tmp, "app");
  const konsEnv = {
    ...process.env,
    KONS_HOME: path.join(tmp, "home"),
    KONS_SCHEME: process.env.KONS_SCHEME || "capy",
    XDG_CACHE_HOME: path.join(tmp, "cache"),
  };

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "offline@example.test", "offline");
    await publishSchemePackage(baseUrl, token, tmp, "offline/leaf", "1.0.0");
    await publishSchemePackage(baseUrl, token, tmp, "offline/root", "1.0.0", [
      { name: "offline/leaf", req: "^1.0.0" },
    ]);
    await writeApp(app);

    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["registry", "add", "local", baseUrl, "--default"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["update"], {
      cwd: app,
      env: konsEnv,
    });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["fetch", "--locked"], {
      cwd: app,
      env: konsEnv,
    });

    await stopRegistry(registry);

    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["check", "--offline"], {
      cwd: app,
      env: konsEnv,
    });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["build", "--offline"], {
      cwd: app,
      env: konsEnv,
    });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["build", "--frozen"], {
      cwd: app,
      env: konsEnv,
    });

    const rootVersionsCache = await findVersionsCache(
      path.join(konsEnv.KONS_HOME, "store", "registry", "metadata"),
      "offline-root"
    );
    assert.ok(rootVersionsCache);
    const originalVersionsCache = await fs.readFile(rootVersionsCache, "utf8");
    await fs.writeFile(rootVersionsCache, "{not json");
    await assert.rejects(
      execFileAsync(path.join(repoRoot, "bin", "kons"), ["update", "--offline"], {
        cwd: app,
        env: konsEnv,
      }),
      /registry metadata JSON could not be parsed; run `kons update` to refresh it/
    );
    await fs.writeFile(rootVersionsCache, originalVersionsCache);

    await assert.rejects(
      fs.stat(path.join(app, "kons-vendor.scm")),
      { code: "ENOENT" }
    );
  } catch (error) {
    error.message = `${error.message}\n${registry.output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
