import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

export const execFileAsync = promisify(execFile);

export async function request(baseUrl, pathname, options = {}) {
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

export async function waitForHealth(baseUrl) {
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

export async function signInAndToken(baseUrl, email, username = "") {
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

export async function makeArchive(tmp, name, version, owner = "alice") {
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

export async function makeSchemeArchive(tmp, name, version, owner = "alice") {
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

export async function publishSchemePackage(baseUrl, token, tmp, name, version, dependencies = [], features = [], featureDependencies = []) {
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
      featureDependencies,
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
