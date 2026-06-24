import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import {
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
      KONS_ADMIN_EMAILS: "admin@example.test",
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

function assertAuditLogAppendOnly(dataDir) {
  const db = new DatabaseSync(path.join(dataDir, "registry.sqlite"));
  try {
    assert.throws(
      () => db.prepare("UPDATE audit_log SET action = ? WHERE package_name = ?").run("tampered", "audit/admin"),
      /audit_log is append-only/,
    );
    assert.throws(
      () => db.prepare("DELETE FROM audit_log WHERE package_name = ?").run("audit/admin"),
      /audit_log is append-only/,
    );
    const count = db.prepare("SELECT count(*) AS count FROM audit_log WHERE package_name = ?").get("audit/admin").count;
    assert.equal(count >= 7, true);
  } finally {
    db.close();
  }
}

test("admins can inspect package audit logs without package ownership", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-admin-audit-"));
  const port = 23000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const dataDir = path.join(tmp, "data");
  const registry = startRegistry(port, dataDir);

  try {
    await waitForHealth(baseUrl);
    const ownerToken = await signInAndToken(baseUrl, "alice@example.test", "alice");
    const strangerToken = await signInAndToken(baseUrl, "stranger@example.test", "stranger");
    const adminToken = await signInAndToken(baseUrl, "admin@example.test", "admin");

    await publishSchemePackage(baseUrl, ownerToken, tmp, "audit/admin", "1.0.0");
    await request(baseUrl, "/api/v1/packages/audit/admin/1.0.0/yank", {
      method: "DELETE",
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    await request(baseUrl, "/api/v1/packages/audit/admin/1.0.0/unyank", {
      method: "PUT",
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    await request(baseUrl, "/api/v1/packages/audit/admin/owners", {
      method: "POST",
      headers: { authorization: `Bearer ${ownerToken}` },
      body: JSON.stringify({ username: "stranger" }),
    });
    await request(baseUrl, "/api/v1/packages/audit/admin/owners/stranger", {
      method: "DELETE",
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    const deleteVersion = await request(baseUrl, "/api/v1/packages/audit/admin/1.0.0", {
      method: "DELETE",
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    assert.equal(deleteVersion.response.status, 409);
    const deletePackage = await request(baseUrl, "/api/v1/packages/audit/admin/delete", {
      method: "DELETE",
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    assert.equal(deletePackage.response.status, 409);

    const strangerAudit = await request(baseUrl, "/api/v1/packages/audit/admin/audit", {
      headers: { authorization: `Bearer ${strangerToken}` },
    });
    assert.equal(strangerAudit.response.status, 403);

    const adminAudit = await request(baseUrl, "/api/v1/packages/audit/admin/audit", {
      headers: { authorization: `Bearer ${adminToken}` },
    });
    assert.equal(adminAudit.response.status, 200);
    assert.equal(adminAudit.data.package, "audit/admin");

    const actions = adminAudit.data.events.map((event) => event.action);
    assert.deepEqual(
      ["publish", "yank", "unyank", "owner-add", "owner-remove", "delete-version-denied", "delete-package-denied"]
        .filter((action) => !actions.includes(action)),
      [],
    );

    const publishEvent = adminAudit.data.events.find((event) => event.action === "publish");
    assert.ok(publishEvent);
    assert.equal(publishEvent.version, "1.0.0");
    assert.equal(publishEvent.actor.username, "alice");
    assert.equal(publishEvent.details.publishedBy.username, "alice");
    assert.equal(adminAudit.data.events.find((event) => event.action === "owner-add").details.username, "stranger");
    assert.equal(adminAudit.data.events.find((event) => event.action === "owner-remove").details.username, "stranger");
    assert.equal(adminAudit.data.events.find((event) => event.action === "delete-version-denied").details.reason, "immutable-version");
    assert.deepEqual(adminAudit.data.events.find((event) => event.action === "delete-package-denied").details.versions, ["1.0.0"]);
    await stopRegistry(registry);
    assertAuditLogAppendOnly(dataDir);
  } catch (error) {
    error.message = `${error.message}\n${registry.output.join("")}`;
    throw error;
  } finally {
    await stopRegistry(registry);
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
