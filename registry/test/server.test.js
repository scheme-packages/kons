import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";
import { execFileAsync, makeArchive, publishSchemePackage, request, signInAndToken, waitForHealth } from "./helpers.js";

async function readSharedResolverSample() {
  const samplePath = path.resolve(import.meta.dirname, "../../tests/samples/resolver/shared.json");
  return JSON.parse(await fs.readFile(samplePath, "utf8"));
}

async function publishSampleCandidates(baseUrl, token, tmp, candidates) {
  for (const candidate of candidates) {
    await publishSchemePackage(
      baseUrl,
      token,
      tmp,
      candidate.name,
      candidate.version,
      candidate.dependencies || [],
      candidate.features || [],
      candidate.featureDependencies || []
    );
  }
}

async function assertSharedRegistryResolverCases(baseUrl, sample) {
  for (const sampleCase of sample.cases) {
    const resolved = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({ requirements: sampleCase.requirements }),
    });
    assert.equal(resolved.response.status, 200);
    assert.deepEqual(
      resolved.data.packages.map((pkg) => pkg.package || pkg.name),
      sampleCase.registryPackages,
      `${sampleCase.name} packages`
    );
    assert.deepEqual(
      resolved.data.edges.map((edge) => edge.name),
      sampleCase.registryEdges,
      `${sampleCase.name} edges`
    );
  }
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
        license: "not a license",
        archiveBase64: "bm90LWFuLWFyY2hpdmU=",
        dependencies: [{ name: "dep" }],
      }),
    });
    assert.equal(invalidPublish.response.status, 400);
    assert.equal(invalidPublish.data.status, 400);
    assert.equal(invalidPublish.data.message, "publish payload validation failed");
    assert.ok(invalidPublish.data.details.fields.some((field) => field.field === "dependencies[0].req"));
    assert.ok(invalidPublish.data.details.fields.some((field) => field.field === "license"));

    const reservedNamePublish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${aliceToken}` },
      body: JSON.stringify({
        name: "api/client",
        owner: "alice",
        version: "1.0.0",
        description: "Reserved package root",
        license: "MIT",
        archiveBase64: "bm90LWFuLWFyY2hpdmU=",
      }),
    });
    assert.equal(reservedNamePublish.response.status, 400);
    assert.equal(reservedNamePublish.data.message, "publish payload validation failed");
    assert.ok(reservedNamePublish.data.details.fields.some((field) => field.field === "name"));

    const archiveBase64 = await makeArchive(tmp, "foo/bar", "1.0.0", "alice");
    const publish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${aliceToken}` },
      body: JSON.stringify({
        name: "foo/bar",
        owner: "alice",
        version: "1.0.0",
        description: "Sample package",
        license: "MIT OR Apache-2.0",
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
    assert.equal(versionList.data.versions[0].publishedBy.username, "alice");
    assert.equal(versionList.data.versions[0].provenance.checksum, publish.data.checksum);
    assert.equal(versionList.data.versions[0].provenance.publishedBy.username, "alice");
    assert.deepEqual(versionList.data.versions[0].features, []);
    assert.deepEqual(versionList.data.versions[0].dependencies.map((dep) => dep.name), ["dep"]);

    const unsignedSignedList = await request(baseUrl, "/api/v1/packages/foo/bar/versions?signed=1");
    assert.equal(unsignedSignedList.response.status, 409);
    assert.equal(unsignedSignedList.data.message, "registry signing is not configured");

    const versionMetadata = await request(baseUrl, "/api/v1/packages/foo/bar/1.0.0/metadata");
    assert.equal(versionMetadata.response.status, 200);
    assert.equal(versionMetadata.data.package, "foo/bar");
    assert.equal(versionMetadata.data.version, "1.0.0");
    assert.match(versionMetadata.data.downloadUrl, /\/api\/v1\/packages\/foo%2Fbar\/1\.0\.0\/download$/);
    assert.equal(versionMetadata.data.checksum, publish.data.checksum);
    assert.equal(versionMetadata.data.publishedBy.username, "alice");
    assert.equal(versionMetadata.data.provenance.checksum, publish.data.checksum);
    assert.equal(versionMetadata.data.provenance.publishedBy.username, "alice");
    assert.deepEqual(versionMetadata.data.libraries.map((library) => library.key), ["foo/bar"]);
    assert.equal(versionMetadata.data.libraries[0].dialect, "r7rs");

    const indexEntry = await fetch(`${baseUrl}/index/fo/ob/foo-bar`);
    assert.equal(indexEntry.status, 200);
    const sparseIndexText = await indexEntry.text();
    const indexLines = sparseIndexText.trim().split("\n").map((line) => JSON.parse(line));
    assert.equal(indexLines[0].checksum, publish.data.checksum);
    assert.equal(indexLines[0].provenance.checksum, publish.data.checksum);
    assert.equal(indexLines[0].provenance.publishedBy.username, "alice");

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
    assert.equal(deleteVersion.response.status, 409);
    assert.match(deleteVersion.data.message, /immutable/);

    const audit = await request(baseUrl, "/api/v1/packages/foo/bar/audit", {
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(audit.response.status, 200);
    assert.equal(audit.data.package, "foo/bar");
    const auditActions = audit.data.events.map((event) => event.action);
    assert.ok(auditActions.includes("publish"));
    assert.ok(auditActions.includes("owner-add"));
    assert.ok(auditActions.includes("owner-remove"));
    assert.ok(auditActions.includes("yank"));
    assert.ok(auditActions.includes("unyank"));
    assert.equal(auditActions.includes("delete-version"), false);
    const publishEvent = audit.data.events.find((event) => event.action === "publish" && event.version === "1.0.0");
    assert.equal(publishEvent.actor.username, "alice");
    assert.equal(publishEvent.details.publishedBy.username, "alice");
    assert.equal(publishEvent.details.checksum, publish.data.checksum);

    const deletePackage = await request(baseUrl, "/api/v1/packages/foo/bar/delete", {
      method: "DELETE",
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(deletePackage.response.status, 409);
    assert.match(deletePackage.data.message, /immutable/);

    const afterDelete = await request(baseUrl, "/api/v1/packages/foo/bar");
    assert.equal(afterDelete.response.status, 200);
    assert.deepEqual(afterDelete.data.package.versions.map((version) => version.version), ["1.1.0", "1.0.0"]);
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

test("registry rate limits auth, publish, search, and downloads", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-registry-rate-limit-test-"));
  const port = 22000 + Math.floor(Math.random() * 1000);
  const baseUrl = `http://127.0.0.1:${port}`;
  const output = [];
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
      KONS_RATE_LIMIT_WINDOW_MS: "60000",
      KONS_RATE_LIMIT_AUTH_LIMIT: "2",
      KONS_RATE_LIMIT_PUBLISH_LIMIT: "1",
      KONS_RATE_LIMIT_SEARCH_LIMIT: "1",
      KONS_RATE_LIMIT_DOWNLOAD_LIMIT: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  server.stdout.on("data", (chunk) => output.push(chunk.toString()));
  server.stderr.on("data", (chunk) => output.push(chunk.toString()));

  try {
    await waitForHealth(baseUrl);

    const authHeaders = { "x-forwarded-for": "203.0.113.10" };
    assert.equal((await request(baseUrl, "/api/v1/auth/email/start", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ email: "rate-one@example.test", username: "rateone" }),
    })).response.status, 200);
    assert.equal((await request(baseUrl, "/api/v1/auth/email/start", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ email: "rate-two@example.test", username: "ratetwo" }),
    })).response.status, 200);
    const limitedAuth = await request(baseUrl, "/api/v1/auth/email/start", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ email: "rate-three@example.test", username: "ratethree" }),
    });
    assert.equal(limitedAuth.response.status, 429);
    assert.equal(limitedAuth.data.details.bucket, "auth");

    const token = await signInAndToken(baseUrl, "rate-owner@example.test", "rateowner");

    const searchHeaders = { "x-forwarded-for": "203.0.113.11" };
    assert.equal((await request(baseUrl, "/api/v1/search?q=missing", {
      headers: searchHeaders,
    })).response.status, 200);
    const limitedSearch = await request(baseUrl, "/api/v1/search?q=missing", {
      headers: searchHeaders,
    });
    assert.equal(limitedSearch.response.status, 429);
    assert.equal(limitedSearch.data.details.bucket, "search");

    const publishHeaders = {
      authorization: `Bearer ${token}`,
      "x-forwarded-for": "203.0.113.12",
    };
    assert.equal((await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: publishHeaders,
      body: JSON.stringify({
        name: "rate/invalid",
        owner: "rateowner",
        version: "1.0.0",
        description: "Rate limited publish",
        license: "MIT",
        archiveBase64: "bm90LWFuLWFyY2hpdmU=",
        dependencies: [{ name: "dep" }],
      }),
    })).response.status, 400);
    const limitedPublish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: publishHeaders,
      body: JSON.stringify({
        name: "rate/invalid",
        owner: "rateowner",
        version: "1.0.0",
        description: "Rate limited publish",
        license: "MIT",
        archiveBase64: "bm90LWFuLWFyY2hpdmU=",
        dependencies: [{ name: "dep" }],
      }),
    });
    assert.equal(limitedPublish.response.status, 429);
    assert.equal(limitedPublish.data.details.bucket, "publish");

    const archiveBase64 = await makeArchive(tmp, "rate/pkg", "1.0.0", "rateowner");
    const publish = await request(baseUrl, "/api/v1/packages/new", {
      method: "PUT",
      headers: { authorization: `Bearer ${token}` },
      body: JSON.stringify({
        name: "rate/pkg",
        owner: "rateowner",
        version: "1.0.0",
        description: "Download rate package",
        license: "MIT",
        archiveBase64,
      }),
    });
    assert.equal(publish.response.status, 201);

    const downloadHeaders = { "x-forwarded-for": "203.0.113.13" };
    assert.equal((await fetch(`${baseUrl}/api/v1/packages/rate/pkg/1.0.0/download`, {
      headers: downloadHeaders,
    })).status, 200);
    const limitedDownload = await request(baseUrl, "/api/v1/packages/rate/pkg/1.0.0/download", {
      headers: downloadHeaders,
    });
    assert.equal(limitedDownload.response.status, 429);
    assert.equal(limitedDownload.data.details.bucket, "download");
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
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519", {
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
  const privateKeyFile = path.join(tmp, "registry-private.pem");
  const publicKeyFile = path.join(tmp, "registry-public.pem");
  await fs.writeFile(privateKeyFile, privateKey);
  await fs.writeFile(publicKeyFile, publicKey);
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
      KONS_REGISTRY_SIGNING_KEY_ID: "local-test-key",
      KONS_REGISTRY_SIGNING_PRIVATE_KEY_FILE: privateKeyFile,
      KONS_REGISTRY_SIGNING_PUBLIC_KEY_FILE: publicKeyFile,
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

    const indexConfig = await request(baseUrl, "/index/config.json");
    assert.equal(indexConfig.response.status, 200);
    assert.equal(indexConfig.data.signing.alg, "ed25519");
    assert.equal(indexConfig.data.signing.keyId, "local-test-key");
    assert.match(indexConfig.data.signing.publicKey, /BEGIN PUBLIC KEY/);

    const signedVersions = await request(baseUrl, "/api/v1/packages/example/a/versions?signed=1&includeYanked=1");
    assert.equal(signedVersions.response.status, 200);
    assert.equal(signedVersions.data.signed.alg, "ed25519");
    assert.equal(signedVersions.data.signed.keyId, "local-test-key");
    const signedPayload = Buffer.from(signedVersions.data.signed.payloadBase64, "base64");
    const signedSignature = Buffer.from(signedVersions.data.signed.signatureBase64, "base64");
    assert.equal(crypto.verify(null, signedPayload, publicKey, signedSignature), true);
    const tamperedPayload = Buffer.from(signedPayload);
    tamperedPayload[0] = tamperedPayload[0] === 123 ? 91 : 123;
    assert.equal(crypto.verify(null, tamperedPayload, publicKey, signedSignature), false);
    assert.equal(JSON.parse(signedPayload.toString("utf8")).versions[0].checksum, signedVersions.data.versions[0].checksum);

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
    await fs.mkdir(path.join(konsEnv.KONS_HOME, "config", "keys"), { recursive: true });
    await fs.copyFile(publicKeyFile, path.join(konsEnv.KONS_HOME, "config", "keys", "local-test-key.pem"));
    await fs.writeFile(
      path.join(konsEnv.KONS_HOME, "config", "registries.scm"),
      `(registries
  (registry
    (name "local")
    (url "${baseUrl}")
    (default #t)
    (trust required)
    (key-id "local-test-key")
    (key-file "keys/local-test-key.pem")))
`
    );
    const provides = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["provides", "example/a"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(provides.stdout, /package example\/a v1\.0\.0/);

    const searchJson = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["search", "example", "--type", "package", "--format", "json"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.deepEqual(JSON.parse(searchJson.stdout).results.map((result) => result.package).sort(), ["example/a", "example/b", "example/c"]);

    const infoJson = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["info", "example/a", "--format", "json"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const infoData = JSON.parse(infoJson.stdout);
    assert.equal(infoData.package.name, "example/a");
    assert.equal(infoData.package.trust.signedMetadata, true);
    assert.equal(infoData.package.trust.keyId, "local-test-key");
    assert.equal(infoData.package.latest.publishedBy.username, "alice");
    assert.equal(infoData.package.latest.provenance.checksum, infoData.package.latest.checksum);

    const infoText = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["info", "example/a"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(infoText.stdout, /checksum:/);
    assert.match(infoText.stdout, /published by: alice/);
    assert.match(infoText.stdout, /signed metadata: available local-test-key/);

    const providesJson = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["provides", "example/a", "--format", "json"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.deepEqual(JSON.parse(providesJson.stdout).libraries.map((result) => result.package), ["example/a"]);

    const identifier = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["identifier", "message", "--limit", "1"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(identifier.stdout, /message/);
    assert.match(identifier.stdout, /package example\/[abc] v1\.0\.0/);

    const identifierJson = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["identifier", "message", "--limit", "1", "--format", "json"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.equal(JSON.parse(identifierJson.stdout).identifiers[0].identifier, "message");

    await publishSchemePackage(baseUrl, token, tmp, "example/feature-leaf", "1.0.0");
    await publishSchemePackage(baseUrl, token, tmp, "example/feature-lib", "1.0.0", [
      { name: "example/feature-leaf", req: "^1.0.0", optional: true },
    ], ["feature-leaf"]);

    const featureResolveWithoutFeature = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        requirements: [{ name: "example/feature-lib", req: "^1.0.0" }],
      }),
    });
    assert.equal(featureResolveWithoutFeature.response.status, 200);
    assert.deepEqual(featureResolveWithoutFeature.data.packages.map((pkg) => pkg.name), ["example/feature-lib"]);

    const featureResolve = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        requirements: [{ name: "example/feature-lib", req: "^1.0.0", features: ["feature-leaf"] }],
      }),
    });
    assert.equal(featureResolve.response.status, 200);
    assert.deepEqual(featureResolve.data.packages.map((pkg) => pkg.name), ["example/feature-leaf", "example/feature-lib"]);
    assert.deepEqual(featureResolve.data.packages.find((pkg) => pkg.name === "example/feature-lib").features, ["feature-leaf"]);
    assert.equal(featureResolve.data.edges.find((edge) => edge.name === "example/feature-leaf").optional, true);

    const sharedResolverSample = await readSharedResolverSample();
    await publishSampleCandidates(baseUrl, token, tmp, sharedResolverSample.candidates);
    await assertSharedRegistryResolverCases(baseUrl, sharedResolverSample);

    const featureApp = path.join(tmp, "feature-app");
    await fs.mkdir(path.join(featureApp, "src", "example"), { recursive: true });
    await fs.writeFile(
      path.join(featureApp, "kons.scm"),
      `(package
  (name (example feature-app))
  (version "0.1.0")
  (license "MIT")
  (description "feature app")
  (source-path "src"))

(dependencies
  (registry (name (example feature-lib)) (version "^1.0.0") (registry "local") (features feature-leaf)))
(dev-dependencies)
`
    );
    await fs.writeFile(
      path.join(featureApp, "src", "example", "feature-app.sld"),
`(define-library (example feature-app)
  (export message)
  (import (scheme base) (example feature-lib) (example feature-leaf))
  (begin (define (message) "feature-app")))
`
    );
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(featureApp, "kons.scm"), "update"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const featureLock = await fs.readFile(path.join(featureApp, "kons.lock"), "utf8");
    assert.match(featureLock, /\(name \(example feature-lib\)\)\s+\(req "\^1\.0\.0"\)\s+\(version "1\.0\.0"\)[\s\S]*?\(features feature-leaf\)/);
    assert.match(featureLock, /\(name \(example feature-leaf\)\)\s+\(req "\^1\.0\.0"\)\s+\(version "1\.0\.0"\)/);
    assert.match(featureLock, /\(name \(example feature-leaf\)\)\s+\(req "\^1\.0\.0"\)\s+\(kind normal\)\s+\(features\)\s+\(optional #t\)/);

    await publishSchemePackage(baseUrl, token, tmp, "example/selector-capy", "1.0.0");
    await publishSchemePackage(baseUrl, token, tmp, "example/selector-guile", "1.0.0");
    await publishSchemePackage(baseUrl, token, tmp, "example/selector-linux", "1.0.0");
    await publishSchemePackage(baseUrl, token, tmp, "example/selector-darwin", "1.0.0");
    await publishSchemePackage(baseUrl, token, tmp, "example/selector-root", "1.0.0", [
      { name: "example/selector-capy", req: "^1.0.0", schemes: ["capy"] },
      { name: "example/selector-guile", req: "^1.0.0", schemes: ["guile"] },
      { name: "example/selector-linux", req: "^1.0.0", targets: ["linux-x86_64"] },
      { name: "example/selector-darwin", req: "^1.0.0", targets: ["darwin"] },
    ]);
    const selectorMetadata = await request(baseUrl, "/api/v1/packages/example/selector-root/1.0.0/metadata");
    assert.equal(selectorMetadata.response.status, 200);
    assert.deepEqual(selectorMetadata.data.dependencies.find((dep) => dep.name === "example/selector-capy").schemes, ["capy"]);
    assert.deepEqual(selectorMetadata.data.dependencies.find((dep) => dep.name === "example/selector-linux").targets, ["linux-x86_64"]);

    const selectorApp = path.join(tmp, "selector-app");
    await fs.mkdir(path.join(selectorApp, "src", "example"), { recursive: true });
    await fs.writeFile(
      path.join(selectorApp, "kons.scm"),
      `(package
  (name (example selector-app))
  (version "0.1.0")
  (license "MIT")
  (description "selector app")
  (source-path "src"))

(dependencies
  (registry (name (example selector-root)) (version "^1.0.0") (registry "local")))
(dev-dependencies)
`
    );
    await fs.writeFile(
      path.join(selectorApp, "src", "example", "selector-app.sld"),
`(define-library (example selector-app)
  (export message)
  (import (scheme base) (example selector-root))
  (begin (define (message) "selector-app")))
`
    );
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(selectorApp, "kons.scm"), "--scheme", "capy", "--target", "linux-x86_64", "update"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const selectorLock = await fs.readFile(path.join(selectorApp, "kons.lock"), "utf8");
    assert.match(selectorLock, /\(name \(example selector-root\)\)/);
    assert.match(selectorLock, /\(name \(example selector-capy\)\)/);
    assert.match(selectorLock, /\(name \(example selector-linux\)\)/);
    assert.doesNotMatch(selectorLock, /\(name \(example selector-guile\)\)/);
    assert.doesNotMatch(selectorLock, /\(name \(example selector-darwin\)\)/);
    assert.match(selectorLock, /\(name \(example selector-capy\)\)\s+\(req "\^1\.0\.0"\)\s+\(kind normal\)\s+\(features\)\s+\(optional #f\)\s+\(schemes capy\)/);
    assert.match(selectorLock, /\(name \(example selector-linux\)\)\s+\(req "\^1\.0\.0"\)\s+\(kind normal\)\s+\(features\)\s+\(optional #f\)\s+\(targets "linux-x86_64"\)/);

    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "update"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const lock = await fs.readFile(path.join(app, "kons.lock"), "utf8");
    assert.match(lock, /\(name \(example a\)\)/);
    assert.match(lock, /\(name \(example b\)\)/);
    assert.match(lock, /\(name \(example c\)\)/);
    assert.match(lock, /\(version "1\.0\.0"\)/);
    assert.match(lock, /\(name \(example a\)\)\s+\(req "\^1\.0\.0"\)\s+\(version "1\.0\.0"\)[\s\S]*?\(features\)/);
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

    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "fetch", "--locked"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const metadataRoot = path.join(tmp, "home", "store", "registry", "metadata");
    const registryCacheDirs = await fs.readdir(metadataRoot);
    assert.ok(registryCacheDirs.length > 0);
    const payloadCache = path.join(metadataRoot, registryCacheDirs[0], "example-c-versions.json");
    const sparseCache = path.join(metadataRoot, registryCacheDirs[0], "example-c-index.jsonl");
    const originalPayloadCache = await fs.readFile(payloadCache, "utf8");
    const originalSparseCache = await fs.readFile(sparseCache, "utf8");
    const verifiedPayload = JSON.parse(originalPayloadCache);
    assert.equal(verifiedPayload.package, "example/c");
    assert.ok(verifiedPayload.versions[0].checksum);
    const signedCache = JSON.parse(originalSparseCache.trim().split("\n")[0]);
    assert.equal(signedCache.signed.alg, "ed25519");
    assert.equal(signedCache.signed.keyId, "local-test-key");
    signedCache.signed.signatureBase64 = "AAAA";
    await fs.writeFile(sparseCache, `${JSON.stringify(signedCache)}\n`);
    await assert.rejects(
      execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "check", "--frozen"], {
        cwd: repoRoot,
        env: konsEnv,
      }),
      /registry metadata signature mismatch/
    );
    await fs.writeFile(sparseCache, originalSparseCache);

    await fs.writeFile(payloadCache, "{not json");
    await assert.rejects(
      execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "update", "--offline"], {
        cwd: repoRoot,
        env: konsEnv,
      }),
      /verified registry metadata cache does not match its signature/
    );
    await fs.writeFile(payloadCache, originalPayloadCache);

    const tree = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "tree", "--locked"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(tree.stdout, /\(edges/);
    assert.match(tree.stdout, /\(name \(example a\)\)/);
    assert.match(tree.stdout, /\(name \(example b\)\)/);
    assert.match(tree.stdout, /\(name \(example c\)\)/);

    const graphDot = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "graph", "--locked", "--format", "dot"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    assert.match(graphDot.stdout, /^digraph kons_dependencies \{/);
    assert.match(graphDot.stdout, /"root" -> "registry:local:example\/c:1\.0\.0"/);
    assert.match(graphDot.stdout, /"registry:local:example\/c:1\.0\.0" -> "registry:local:example\/b:1\.0\.0"/);
    assert.match(graphDot.stdout, /"registry:local:example\/b:1\.0\.0" -> "registry:local:example\/a:1\.1\.0"/);

    await fs.rm(path.join(tmp, "home", "store"), { recursive: true, force: true });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "fetch", "--locked"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await new Promise((resolve) => server.once("exit", resolve));
    }
    await execFileAsync(
      path.join(repoRoot, "bin", "kons"),
      ["--manifest", path.join(app, "kons.scm"), "vendor", "--offline", "--sync", "--directory", "third_party/kons"],
      {
        cwd: repoRoot,
        env: konsEnv,
      }
    );
    const vendorRoot = path.join(app, "third_party", "kons");
    const vendorMetadata = await fs.readFile(path.join(vendorRoot, "kons-vendor.scm"), "utf8");
    assert.match(vendorMetadata, /\(name \(example a\)\)/);
    assert.match(vendorMetadata, /\(name \(example b\)\)/);
    assert.match(vendorMetadata, /\(name \(example c\)\)/);
    assert.match(vendorMetadata, /\(archive "\.kons-archive"\)/);
    assert.match(vendorMetadata, /\(source-hash "[^"]+"/);
    assert.match(vendorMetadata, /\(source-replacement/);
    assert.match(vendorMetadata, /\(directory "\."\)/);
    const vendorPointer = await fs.readFile(path.join(app, "kons-vendor.scm"), "utf8");
    assert.match(vendorPointer, /\(source-replacement/);
    assert.match(vendorPointer, /\(metadata "third_party\/kons\/kons-vendor\.scm"\)/);
    const vendorEntries = (await fs.readdir(vendorRoot)).filter((entry) => entry !== "kons-vendor.scm");
    assert.deepEqual(vendorEntries.sort(), ["local-example-a-1-1-0", "local-example-b-1-0-0", "local-example-c-1-0-0"]);

    const vendoredTree = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "tree", "--locked", "--offline", "--format", "json"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const vendoredTreeJson = JSON.parse(vendoredTree.stdout);
    const vendoredTreeA = vendoredTreeJson.dependencies.find((dep) => dep.name?.join("/") === "example/a");
    assert.equal(vendoredTreeA.source, "vendored");
    assert.match(vendoredTreeA["source-path"], /third_party\/kons\/local-example-a-1-1-0$/);

    const vendoredStatus = await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "status", "--offline", "--format", "json"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    const vendoredStatusJson = JSON.parse(vendoredStatus.stdout);
    const vendoredStatusA = vendoredStatusJson["locked-dependencies"].find((dep) => Array.isArray(dep.name) && dep.name.join("/") === "example/a");
    assert.equal(vendoredStatusA.source, "vendored");
    assert.match(vendoredStatusA["source-path"], /third_party\/kons\/local-example-a-1-1-0$/);

    await fs.rm(path.join(tmp, "home", "store"), { recursive: true, force: true });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "check", "--frozen"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "build", "--frozen"], {
      cwd: repoRoot,
      env: konsEnv,
    });
    await fs.appendFile(path.join(vendorRoot, "local-example-a-1-1-0", "src", "example", "a.sld"), "\n;; tampered\n");
    await assert.rejects(
      execFileAsync(path.join(repoRoot, "bin", "kons"), ["--manifest", path.join(app, "kons.scm"), "check", "--frozen"], {
        cwd: repoRoot,
        env: konsEnv,
      }),
      /vendored source hash does not match metadata/
    );
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
