import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  makeSchemeArchive,
  request,
  signInAndToken,
  waitForHealth,
} from "./helpers.js";

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

function installLibraryInsertFailure(dataDir) {
  const db = new DatabaseSync(path.join(dataDir, "registry.sqlite"));
  try {
    db.exec(`
      CREATE TRIGGER fail_library_insert
      BEFORE INSERT ON version_libraries
      BEGIN
        SELECT RAISE(FAIL, 'forced library metadata failure');
      END;
    `);
  } finally {
    db.close();
  }
}

function packageRows(dataDir, name) {
  const db = new DatabaseSync(path.join(dataDir, "registry.sqlite"));
  try {
    return {
      packages: db.prepare("SELECT count(*) AS count FROM packages WHERE name = ?").get(name).count,
      versions: db.prepare("SELECT count(*) AS count FROM versions WHERE package_name = ?").get(name).count,
      libraries: db.prepare("SELECT count(*) AS count FROM version_libraries WHERE package_name = ?").get(name).count,
      identifiers: db.prepare("SELECT count(*) AS count FROM version_identifiers WHERE package_name = ?").get(name).count,
      searchTerms: db.prepare("SELECT count(*) AS count FROM package_search_terms WHERE package_name = ?").get(name).count,
      auditEvents: db.prepare("SELECT count(*) AS count FROM audit_log WHERE package_name = ?").get(name).count,
    };
  } finally {
    db.close();
  }
}

async function archiveFiles(root) {
  const files = [];
  async function visit(dir) {
    let entries = [];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch (error) {
      if (error.code === "ENOENT") return;
      throw error;
    }
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) await visit(fullPath);
      else files.push(path.relative(root, fullPath));
    }
  }
  await visit(root);
  return files.sort();
}

test("publish rolls back rich metadata failures and removes uploaded archive", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-publish-rollback-"));
  const port = 26000 + Math.floor(Math.random() * 1000);
  const dataDir = path.join(tmp, "data");
  const baseUrl = `http://127.0.0.1:${port}`;
  const { server, output } = startRegistry(tmp, port);

  try {
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "rollback@example.test", "rollback");
    installLibraryInsertFailure(dataDir);

    const archiveBase64 = await makeSchemeArchive(tmp, "rollback/pkg", "1.0.0");
    const publish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${token}` },
      body: JSON.stringify({
        name: "rollback/pkg",
        owner: "alice",
        version: "1.0.0",
        description: "rollback/pkg",
        license: "MIT",
        archiveBase64,
        libraries: [{
          kind: "r7rs",
          name: ["rollback", "pkg"],
          displayName: "(rollback pkg)",
          key: "rollback/pkg",
          path: "src/rollback/pkg.sld",
          imports: [["scheme", "base"]],
          exports: ["message"],
        }],
      }),
    });

    assert.equal(publish.response.status, 500);
    assert.match(publish.data.message, /forced library metadata failure/);
    assert.deepEqual(packageRows(dataDir, "rollback/pkg"), {
      packages: 0,
      versions: 0,
      libraries: 0,
      identifiers: 0,
      searchTerms: 0,
      auditEvents: 0,
    });
    assert.deepEqual(await archiveFiles(path.join(dataDir, "archives")), []);
  } catch (error) {
    error.message = `${error.message}\n${output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(server);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
