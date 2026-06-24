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

test("registry preserves profile and compile-mode dependency selectors", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-registry-selectors-"));
  const port = 21000 + Math.floor(Math.random() * 1000);
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
    const token = await signInAndToken(baseUrl, "selectors@example.test", "selectors");
    await publishSchemePackage(baseUrl, token, tmp, "selector/leaf", "1.0.0");
    await publishSchemePackage(baseUrl, token, tmp, "selector/root", "1.0.0", [
      {
        name: "selector/leaf",
        req: "^1.0.0",
        dialects: ["r7rs"],
        profiles: ["release"],
        compileModes: ["compiled"],
      },
    ]);

    const metadata = await request(baseUrl, "/api/v1/packages/selector/root");
    assert.equal(metadata.response.status, 200);
    const dep = metadata.data.package.latest.dependencies[0];
    assert.deepEqual(dep.dialects, ["r7rs"]);
    assert.deepEqual(dep.profiles, ["release"]);
    assert.deepEqual(dep.compileModes, ["compiled"]);

    const sparse = await request(baseUrl, "/index/se/le/selector-root");
    assert.equal(sparse.response.status, 200);
    const line = sparse.data;
    assert.deepEqual(line.deps[0].dialects, ["r7rs"]);
    assert.deepEqual(line.deps[0].profiles, ["release"]);
    assert.deepEqual(line.deps[0].compileModes, ["compiled"]);

    const resolved = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        requirements: [{ name: "selector/root", req: "^1.0.0" }],
      }),
    });
    assert.equal(resolved.response.status, 200);
    const edge = resolved.data.edges.find((item) => item.name === "selector/leaf");
    assert.deepEqual(edge.dialects, ["r7rs"]);
    assert.deepEqual(edge.profiles, ["release"]);
    assert.deepEqual(edge.compileModes, ["compiled"]);

    const debugResolved = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        context: {
          profile: "debug",
          compileMode: "fresh-auto",
        },
        requirements: [{ name: "selector/root", req: "^1.0.0" }],
      }),
    });
    assert.equal(debugResolved.response.status, 200);
    assert.equal(debugResolved.data.context.profile, "debug");
    assert.equal(debugResolved.data.context.compileMode, "fresh-auto");
    assert.equal(
      debugResolved.data.packages.some((item) => item.name === "selector/leaf"),
      false,
    );
    assert.equal(
      debugResolved.data.edges.some((item) => item.name === "selector/leaf"),
      false,
    );

    const releaseResolved = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        context: {
          dialect: "r7rs",
          profile: "release",
          compileMode: "compiled",
        },
        requirements: [{ name: "selector/root", req: "^1.0.0" }],
      }),
    });
    assert.equal(releaseResolved.response.status, 200);
    assert.equal(
      releaseResolved.data.packages.some((item) => item.name === "selector/leaf"),
      true,
    );
    assert.equal(
      releaseResolved.data.edges.some((item) => item.name === "selector/leaf"),
      true,
    );

    const r6rsResolved = await request(baseUrl, "/api/v1/resolve", {
      method: "POST",
      body: JSON.stringify({
        context: {
          dialect: "r6rs",
          profile: "release",
          compileMode: "compiled",
        },
        requirements: [{ name: "selector/root", req: "^1.0.0" }],
      }),
    });
    assert.equal(r6rsResolved.response.status, 200);
    assert.equal(
      r6rsResolved.data.packages.some((item) => item.name === "selector/leaf"),
      false,
    );
    assert.equal(
      r6rsResolved.data.edges.some((item) => item.name === "selector/leaf"),
      false,
    );

    const repoRoot = path.resolve(import.meta.dirname, "../..");
    const env = {
      ...process.env,
      KONS_HOME: path.join(tmp, "home"),
      KONS_SCHEME: process.env.KONS_SCHEME || "capy",
      XDG_CACHE_HOME: path.join(tmp, "cache"),
    };
    await execFileAsync(path.join(repoRoot, "bin", "kons"), ["registry", "add", "local", baseUrl, "--default"], {
      cwd: repoRoot,
      env,
    });
    for (const args of [
      ["search", "selector", "--format", "json"],
      ["info", "selector/root", "--format", "json"],
      ["provides", "selector/root", "--format", "json"],
      ["identifier", "message", "--limit", "1", "--format", "json"],
    ]) {
      const result = await execFileAsync(path.join(repoRoot, "bin", "kons"), args, {
        cwd: repoRoot,
        env,
      });
      assert.equal(JSON.parse(result.stdout).formatVersion, 1);
    }
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
