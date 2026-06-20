import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);

async function request(baseUrl, pathname, options = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    ...options,
    headers: {
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...(options.headers || {}),
    },
  });
  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  return { response, data };
}

async function waitForHealth(baseUrl) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const { response } = await request(baseUrl, "/healthz");
      if (response.ok) return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error("registry server did not become healthy");
}

async function signInAndToken(baseUrl, email, username = "") {
  const start = await request(baseUrl, "/api/v1/auth/email/start", {
    method: "POST",
    body: JSON.stringify({ email, username }),
  });
  assert.equal(start.response.status, 200);
  assert.match(start.data.code, /^\d{6}$/);

  const verify = await request(baseUrl, "/api/v1/auth/email/verify", {
    method: "POST",
    body: JSON.stringify({ email, code: start.data.code, username }),
  });
  assert.equal(verify.response.status, 200);
  if (username) assert.equal(verify.data.user.username, username);
  const cookie = verify.response.headers.get("set-cookie");
  assert.ok(cookie);

  const token = await request(baseUrl, "/api/v1/tokens", {
    method: "POST",
    headers: { cookie },
    body: JSON.stringify({ name: "e2e" }),
  });
  assert.equal(token.response.status, 201);
  assert.match(token.data.token, /^kons_/);
  return token.data.token;
}

async function makeArchive(tmp, name, version, owner = "alice") {
  const source = path.join(tmp, "package");
  const archive = path.join(tmp, "package.kons");
  await fs.mkdir(source, { recursive: true });
  const packageName = name.split("/").join(" ");
  await fs.writeFile(
    path.join(source, "kons.scm"),
    `(package\n  (name (${packageName}))\n  (owner "${owner}")\n  (version "${version}")\n  (readme "README.md"))\n`
  );
  await fs.writeFile(path.join(source, "README.md"), `# ${name}\n\nSample README for ${version}.\n`);
  await execFileAsync("tar", ["-czf", archive, "-C", source, "kons.scm", "README.md"]);
  return (await fs.readFile(archive)).toString("base64");
}

test("registry publish validation and owner APIs", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-registry-test-"));
  const port = 19000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const server = spawn(process.execPath, ["server.js"], {
    cwd: path.resolve(import.meta.dirname, ".."),
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

  try {
    await waitForHealth(baseUrl);
    const missingUsername = await request(baseUrl, "/api/v1/auth/email/start", {
      method: "POST",
      body: JSON.stringify({ email: "no-name@example.test" }),
    });
    assert.equal(missingUsername.response.status, 400);
    assert.equal(missingUsername.data.message, "username is required");

    const meta = await request(baseUrl, "/api/v1/meta");
    assert.equal(meta.response.status, 200);
    assert.equal(meta.data.sourceUrl, "https://github.com/scheme-packages/kons");

    const aliceToken = await signInAndToken(baseUrl, "alice@example.test", "alice");
    await signInAndToken(baseUrl, "bob@example.test", "bob");

    const duplicateNickname = await request(baseUrl, "/api/v1/auth/email/start", {
      method: "POST",
      body: JSON.stringify({ email: "other@example.test", username: "alice" }),
    });
    assert.equal(duplicateNickname.response.status, 409);
    assert.equal(duplicateNickname.data.message, "username is already taken");

    const anonymous = await request(baseUrl, "/api/v1/tokens");
    assert.equal(anonymous.response.status, 401);
    assert.equal(anonymous.data.status, 401);
    assert.equal(anonymous.data.message, "authentication required");
    assert.equal(anonymous.data.details, null);

    const invalidPublish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${aliceToken}` },
      body: JSON.stringify({
        name: "foo/bar",
        owner: "alice",
        version: "1.0.0",
        description: "Sample package",
        license: "MIT",
        archiveBase64: "bm90LWFuLWFyY2hpdmU=",
        dependencies: [{ name: "dep" }],
      }),
    });
    assert.equal(invalidPublish.response.status, 400);
    assert.equal(invalidPublish.data.status, 400);
    assert.equal(invalidPublish.data.message, "publish payload validation failed");
    assert.ok(invalidPublish.data.details.fields.some((field) => field.field === "dependencies[0].req"));

    const archiveBase64 = await makeArchive(tmp, "foo/bar", "1.0.0", "alice");
    const publish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${aliceToken}` },
      body: JSON.stringify({
        name: "foo/bar",
        owner: "alice",
        version: "1.0.0",
        description: "Sample package",
        license: "MIT",
        site: "https://example.test/foo/bar",
        repo: "https://git.example.test/foo/bar",
        docs: "https://docs.example.test/foo/bar",
        readme: "README.md",
        keywords: ["Parser", "scheme"],
        archiveBase64,
        dependencies: [{ name: "dep", req: "^1.0.0" }],
      }),
    });
    assert.equal(publish.response.status, 201);
    assert.equal(publish.data.package.name, "foo/bar");
    assert.equal(publish.data.package.indexPath, "fo/ob/foo-bar");
    assert.equal(publish.data.package.site, "https://example.test/foo/bar");
    assert.equal(publish.data.package.repo, "https://git.example.test/foo/bar");
    assert.equal(publish.data.package.docs, "https://docs.example.test/foo/bar");
    assert.match(publish.data.package.readme, /Sample README for 1\.0\.0/);
    assert.match(publish.data.package.latest.readme, /Sample README for 1\.0\.0/);
    assert.deepEqual(publish.data.package.keywords, ["parser", "scheme"]);
    assert.deepEqual(publish.data.package.owners.map((owner) => owner.username), ["alice"]);
    assert.equal(publish.data.package.downloads, 0);
    assert.equal(publish.data.package.latest.downloads, 0);

    const download = await fetch(`${baseUrl}/api/v1/packages/foo/bar/1.0.0/download`);
    assert.equal(download.status, 200);
    assert.equal(download.headers.get("content-type"), "application/octet-stream");
    assert.ok((await download.arrayBuffer()).byteLength > 0);

    const downloadedPackage = await request(baseUrl, "/api/v1/packages/foo/bar");
    assert.equal(downloadedPackage.response.status, 200);
    assert.equal(downloadedPackage.data.package.downloads, 1);
    assert.equal(downloadedPackage.data.package.latest.downloads, 1);

    const keywordSearch = await request(baseUrl, "/api/v1/search?keyword=parser");
    assert.equal(keywordSearch.response.status, 200);
    assert.deepEqual(keywordSearch.data.packages.map((pkg) => pkg.name), ["foo/bar"]);

    const textSearch = await request(baseUrl, "/api/v1/search?q=scheme");
    assert.equal(textSearch.response.status, 200);
    assert.deepEqual(textSearch.data.packages.map((pkg) => pkg.name), ["foo/bar"]);

    const addOwner = await request(baseUrl, "/api/v1/packages/foo/bar/owners/bob", {
      method: "PUT",
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(addOwner.response.status, 200);
    assert.deepEqual(addOwner.data.owners.map((owner) => owner.username), ["alice", "bob"]);

    const listOwners = await request(baseUrl, "/api/v1/packages/foo/bar/owners", {
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(listOwners.response.status, 200);
    assert.deepEqual(listOwners.data.owners.map((owner) => owner.username), ["alice", "bob"]);

    const removeOwner = await request(baseUrl, "/api/v1/packages/foo/bar/owners/bob", {
      method: "DELETE",
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(removeOwner.response.status, 200);
    assert.deepEqual(removeOwner.data.owners.map((owner) => owner.username), ["alice"]);

    const secondArchiveBase64 = await makeArchive(tmp, "foo/bar", "1.1.0", "alice");
    const secondPublish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${aliceToken}` },
      body: JSON.stringify({
        name: "foo/bar",
        owner: "alice",
        version: "1.1.0",
        description: "Sample package",
        license: "MIT",
        archiveBase64: secondArchiveBase64,
      }),
    });
    assert.equal(secondPublish.response.status, 201);
    assert.equal(secondPublish.data.package.downloads, 1);

    const managed = await request(baseUrl, "/api/v1/me/packages", {
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(managed.response.status, 200);
    assert.deepEqual(managed.data.packages.map((pkg) => pkg.name), ["foo/bar"]);
    assert.deepEqual(managed.data.packages[0].versions.map((version) => version.version), ["1.1.0", "1.0.0"]);

    const yank = await request(baseUrl, "/api/v1/packages/foo/bar/1.1.0/yank", {
      method: "DELETE",
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(yank.response.status, 200);
    assert.equal(yank.data.package.versions.find((version) => version.version === "1.1.0").yanked, true);

    const unyank = await request(baseUrl, "/api/v1/packages/foo/bar/1.1.0/unyank", {
      method: "PUT",
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(unyank.response.status, 200);
    assert.equal(unyank.data.package.versions.find((version) => version.version === "1.1.0").yanked, false);

    const deleteVersion = await request(baseUrl, "/api/v1/packages/foo/bar/1.1.0", {
      method: "DELETE",
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(deleteVersion.response.status, 200);
    assert.equal(deleteVersion.data.package.versions.length, 1);
    assert.equal(deleteVersion.data.package.versions[0].version, "1.0.0");

    const deletePackage = await request(baseUrl, "/api/v1/packages/foo/bar/delete", {
      method: "DELETE",
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(deletePackage.response.status, 200);
    assert.equal(deletePackage.data.deleted, true);

    const afterDelete = await request(baseUrl, "/api/v1/packages/foo/bar");
    assert.equal(afterDelete.response.status, 404);
  } catch (error) {
    error.message = `${error.message}\n${output.join("")}`;
    throw error;
  } finally {
    server.kill("SIGTERM");
    await new Promise((resolve) => server.once("exit", resolve));
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
