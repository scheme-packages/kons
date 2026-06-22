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

async function makeSchemeArchive(tmp, name, version, owner = "alice") {
  const token = `${name.replaceAll("/", "-")}-${version}`;
  const source = path.join(tmp, token);
  const archive = path.join(tmp, `${token}.kons`);
  const packageName = name.split("/").join(" ");
  const libraryPath = path.join(source, "src", `${name}.sld`);
  await fs.mkdir(path.dirname(libraryPath), { recursive: true });
  await fs.writeFile(
    path.join(source, "kons.scm"),
    `(package
  (name (${packageName}))
  (owner "${owner}")
  (version "${version}")
  (license "MIT")
  (description "${name}")
  (source-path "src"))

(dependencies)
(dev-dependencies)
`
  );
  await fs.writeFile(
    libraryPath,
    `(define-library (${packageName})
  (export message)
  (import (scheme base))
  (begin (define (message) "${name}")))
`
  );
  await execFileAsync("tar", ["-czf", archive, "-C", source, "kons.scm", "src"]);
  return (await fs.readFile(archive)).toString("base64");
}

async function publishSchemePackage(baseUrl, token, tmp, name, version, dependencies = [], features = []) {
  const archiveBase64 = await makeSchemeArchive(tmp, name, version);
  const libraryName = name.split("/");
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
      dependencies,
      features,
      libraries: [{
        kind: "r7rs",
        name: libraryName,
        displayName: `(${libraryName.join(" ")})`,
        key: name,
        path: `src/${name}.sld`,
        imports: [["scheme", "base"]],
        exports: ["message"],
      }],
    }),
  });
  assert.equal(publish.response.status, 201);
  return publish.data.package;
}

test("registry publish validation and owner APIs", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-registry-test-"));
  const port = 19000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const output = [];
  const startServer = () => {
    const child = spawn(process.execPath, ["server.js"], {
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
    child.stdout.on("data", (chunk) => output.push(chunk.toString()));
    child.stderr.on("data", (chunk) => output.push(chunk.toString()));
    return child;
  };
  let server = startServer();

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

    const indexHtml = await fetch(`${baseUrl}/`);
    assert.equal(indexHtml.status, 200);
    const indexText = await indexHtml.text();
    assert.match(indexText, /id="search-type"/);

    const appJs = await fetch(`${baseUrl}/app.js`);
    assert.equal(appJs.status, 200);
    const appText = await appJs.text();
    assert.match(appText, /function libraryHtml/);
    assert.match(appText, /Dependents/);

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
        libraries: [{
          kind: "r7rs",
          name: ["foo", "bar"],
        displayName: "(foo bar)",
        key: "foo/bar",
        path: "src/foo/bar.sld",
        dialect: "r7rs",
        imports: [["scheme", "base"]],
        exports: ["parse", "render"],
      }],
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
    assert.deepEqual(publish.data.package.latest.libraries.map((library) => library.key), ["foo/bar"]);
    assert.equal(publish.data.package.latest.libraries[0].dialect, "r7rs");
    assert.deepEqual(publish.data.package.latest.libraries[0].exports, ["parse", "render"]);
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

    const librarySearch = await request(baseUrl, "/api/v1/search?q=foo/bar&type=library");
    assert.equal(librarySearch.response.status, 200);
    assert.deepEqual(librarySearch.data.results.map((result) => result.key), ["foo/bar"]);
    assert.equal(librarySearch.data.results[0].dialect, "r7rs");

    const dialectSearch = await request(baseUrl, "/api/v1/search?q=r7rs&type=library");
    assert.equal(dialectSearch.response.status, 200);
    assert.deepEqual(dialectSearch.data.results.map((result) => result.key), ["foo/bar"]);

    const packageSearchByIdentifier = await request(baseUrl, "/api/v1/search?q=parse&type=package");
    assert.equal(packageSearchByIdentifier.response.status, 200);
    assert.deepEqual(packageSearchByIdentifier.data.results.map((result) => result.package), ["foo/bar"]);

    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await new Promise((resolve) => server.once("exit", resolve));
    }
    await execFileAsync(process.execPath, [
      "--input-type=module",
      "-e",
      `
        import { DatabaseSync } from "node:sqlite";
        const db = new DatabaseSync(process.argv[1]);
        db.prepare("DELETE FROM package_search_terms WHERE package_name = ? AND version = ?").run("foo/bar", "1.0.0");
        const row = db.prepare("SELECT COUNT(*) AS count FROM package_search_terms WHERE package_name = ? AND version = ?").get("foo/bar", "1.0.0");
        db.close();
        if (row.count !== 0) process.exit(1);
      `,
      path.join(tmp, "data", "registry.sqlite"),
    ]);
    server = startServer();
    await waitForHealth(baseUrl);

    const backfilledPackageSearch = await request(baseUrl, "/api/v1/search?q=parse&type=package");
    assert.equal(backfilledPackageSearch.response.status, 200);
    assert.deepEqual(backfilledPackageSearch.data.results.map((result) => result.package), ["foo/bar"]);

    const libraryProviders = await request(baseUrl, "/api/v1/libraries/foo/bar");
    assert.equal(libraryProviders.response.status, 200);
    assert.equal(libraryProviders.data.key, "foo/bar");
    assert.deepEqual(libraryProviders.data.libraries.map((result) => result.package), ["foo/bar"]);
    assert.equal(libraryProviders.data.libraries[0].dialect, "r7rs");
    assert.deepEqual(libraryProviders.data.libraries[0].exports, ["parse", "render"]);

    const identifierSearch = await request(baseUrl, "/api/v1/identifiers?q=parse");
    assert.equal(identifierSearch.response.status, 200);
    assert.deepEqual(identifierSearch.data.identifiers.map((result) => result.identifier), ["parse"]);

    const versionList = await request(baseUrl, "/api/v1/packages/foo/bar/versions");
    assert.equal(versionList.response.status, 200);
    assert.deepEqual(versionList.data.versions.map((version) => version.version), ["1.0.0"]);
    assert.match(versionList.data.versions[0].downloadUrl, /\/api\/v1\/packages\/foo%2Fbar\/1\.0\.0\/download$/);
    assert.equal(versionList.data.versions[0].checksum, publish.data.checksum);
    assert.equal(typeof versionList.data.versions[0].size, "number");
    assert.deepEqual(versionList.data.versions[0].features, []);
    assert.deepEqual(versionList.data.versions[0].dependencies.map((dep) => dep.name), ["dep"]);

    const versionMetadata = await request(baseUrl, "/api/v1/packages/foo/bar/1.0.0/metadata");
    assert.equal(versionMetadata.response.status, 200);
    assert.equal(versionMetadata.data.package, "foo/bar");
    assert.equal(versionMetadata.data.version, "1.0.0");
    assert.match(versionMetadata.data.downloadUrl, /\/api\/v1\/packages\/foo%2Fbar\/1\.0\.0\/download$/);
    assert.equal(versionMetadata.data.checksum, publish.data.checksum);
    assert.deepEqual(versionMetadata.data.libraries.map((library) => library.key), ["foo/bar"]);
    assert.equal(versionMetadata.data.libraries[0].dialect, "r7rs");

    const versionManifest = await request(baseUrl, "/api/v1/packages/foo/bar/1.0.0/manifest");
    assert.equal(versionManifest.response.status, 200);
    assert.equal(versionManifest.data.package, "foo/bar");
    assert.equal(versionManifest.data.version, "1.0.0");
    assert.equal(versionManifest.data.manifest.name, "foo/bar");
    assert.equal(versionManifest.data.manifest.version, "1.0.0");

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
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await new Promise((resolve) => server.once("exit", resolve));
    }
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test("kons update locks transitive registry dependencies", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-transitive-registry-test-"));
  const port = 20000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const repoRoot = path.resolve(import.meta.dirname, "../..");
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
    const token = await signInAndToken(baseUrl, "alice-transitive@example.test", "alice");
    await publishSchemePackage(baseUrl, token, tmp, "example/a", "1.0.0", [], ["fast"]);
    await publishSchemePackage(baseUrl, token, tmp, "example/b", "1.0.0", [
      { name: "example/a", req: "^1.0.0" },
    ]);
    await publishSchemePackage(baseUrl, token, tmp, "example/c", "1.0.0", [
      { name: "example/b", req: "^1.0.0" },
    ]);

    const dependents = await request(baseUrl, "/api/v1/packages/example/a/dependents");
    assert.equal(dependents.response.status, 200);
    assert.deepEqual(dependents.data.dependents.map((result) => result.package), ["example/b"]);
    assert.equal(dependents.data.dependents[0].req, "^1.0.0");

    const bDependents = await request(baseUrl, "/api/v1/packages/example/b/dependents");
    assert.equal(bDependents.response.status, 200);
    assert.deepEqual(bDependents.data.dependents.map((result) => result.package), ["example/c"]);
    assert.equal(bDependents.data.dependents[0].req, "^1.0.0");

    const serverResolve = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        requirements: [{ name: "example/c", req: "^1.0.0" }],
      }),
    });
    assert.equal(serverResolve.response.status, 200);
    assert.deepEqual(serverResolve.data.packages.map((pkg) => pkg.package), ["example/a", "example/b", "example/c"]);
    assert.deepEqual(serverResolve.data.edges.map((edge) => edge.name), ["example/c", "example/b", "example/a"]);

    const app = path.join(tmp, "app");
    await fs.mkdir(path.join(app, "src", "example"), { recursive: true });
    await fs.writeFile(
      path.join(app, "kons.scm"),
      `(package
  (name (example app))
  (version "0.1.0")
  (license "MIT")
  (description "app")
  (source-path "src"))

(dependencies
  (registry (name (example c)) (version "^1.0.0") (registry "local")))
(dev-dependencies)
`
    );
    await fs.writeFile(
      path.join(app, "src", "example", "app.sld"),
`(define-library (example app)
  (export message)
  (import (scheme base) (example a) (example b) (example c))
  (begin (define (message) "app")))
`
    );
    await fs.writeFile(path.join(app, "src", "main.scm"), `(import (scheme base) (example app))\n(message)\n`);

    const konsEnv = {
      ...process.env,
      KONS_HOME: path.join(tmp, "home"),
      KONS_SCHEME: process.env.KONS_SCHEME || "capy",
      XDG_CACHE_HOME: path.join(tmp, "cache"),
    };
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["registry", "add", "local", baseUrl, "--default"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const provides = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["provides", "example/a"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(provides.stdout, /package example\/a v1\.0\.0/);

    const identifier = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["identifier", "message", "--limit", "1"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(identifier.stdout, /message/);
    assert.match(identifier.stdout, /package example\/[abc] v1\.0\.0/);

    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "update"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const lock = await fs.readFile(path.join(app, "kons.lock"), "utf8");
    assert.match(lock, /\(name \(example a\)\)/);
    assert.match(lock, /\(name \(example b\)\)/);
    assert.match(lock, /\(name \(example c\)\)/);
    assert.match(lock, /\(version "1\.0\.0"\)/);
    assert.match(lock, /\(name \(example a\)\)\s+\(req "\^1\.0\.0"\)\s+\(version "1\.0\.0"\)[\s\S]*?\(features fast\)/);
    assert.match(lock, /\(edges/);
    assert.match(lock, /\(from root\)/);

    await publishSchemePackage(baseUrl, token, tmp, "example/a", "1.1.0");
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "update"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const preservedLock = await fs.readFile(path.join(app, "kons.lock"), "utf8");
    assert.match(preservedLock, /\(name \(example a\)\)\s+\(req "\^1\.0\.0"\)\s+\(version "1\.0\.0"\)/);
    assert.doesNotMatch(preservedLock, /\(name \(example a\)\)\s+\(req "\^1\.0\.0"\)\s+\(version "1\.1\.0"\)/);

    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "update", "--upgrade"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const upgradedLock = await fs.readFile(path.join(app, "kons.lock"), "utf8");
    assert.match(upgradedLock, /\(name \(example a\)\)\s+\(req "\^1\.0\.0"\)\s+\(version "1\.1\.0"\)/);

    const metadataRoot = path.join(tmp, "home", "store", "registry", "metadata");
    const registryCacheDirs = await fs.readdir(metadataRoot);
    assert.ok(registryCacheDirs.length > 0);
    const corruptedCache = path.join(metadataRoot, registryCacheDirs[0], "example-c-versions.json");
    const originalCache = await fs.readFile(corruptedCache, "utf8");
    await fs.writeFile(corruptedCache, "{not json");
    await assert.rejects(
      execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "update", "--offline"], {
        cwd: repoRoot,
        env: konsEnv,
      }),
      /registry metadata JSON could not be parsed; run `kons update` to refresh it/
    );
    await fs.writeFile(corruptedCache, originalCache);

    const tree = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "tree", "--locked"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(tree.stdout, /\(edges/);
    assert.match(tree.stdout, /\(name \(example a\)\)/);
    assert.match(tree.stdout, /\(name \(example b\)\)/);
    assert.match(tree.stdout, /\(name \(example c\)\)/);

    await fs.rm(path.join(tmp, "home", "store"), { recursive: true, force: true });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "fetch", "--locked"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await new Promise((resolve) => server.once("exit", resolve));
    }
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "check", "--frozen"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "build", "--offline"], {
      cwd: repoRoot,
      env: konsEnv,
    });
  } catch (error) {
    error.message = `${error.message}\n${output.join("")}`;
    throw error;
  } finally {
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await new Promise((resolve) => server.once("exit", resolve));
    }
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
