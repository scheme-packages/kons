import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  publishSchemePackage,
  request,
  signInAndToken,
  waitForHealth,
} from "./helpers.js";

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
      candidate.featureDependencies || [],
    );
  }
}

async function resolveSampleCase(baseUrl, sampleCase, context = null) {
  const body = context
    ? { context, requirements: sampleCase.requirements }
    : { requirements: sampleCase.requirements };
  const resolved = await request(baseUrl, "/api/v1/resolve", {
    method: "POST",
    body: JSON.stringify(body),
  });
  assert.equal(resolved.response.status, 200);
  return resolved.data;
}

function packageNames(resolved) {
  return resolved.packages.map((pkg) => pkg.package || pkg.name);
}

function edgeNames(resolved) {
  return resolved.edges.map((edge) => edge.name);
}

function sorted(values) {
  return values.slice().sort((left, right) => left.localeCompare(right));
}

async function assertBaseSampleCase(baseUrl, sampleCase) {
  const resolved = await resolveSampleCase(baseUrl, sampleCase);
  assert.deepEqual(
    sorted(packageNames(resolved)),
    sampleCase.selectedPackages,
    `${sampleCase.name} selected package set`,
  );
  assert.deepEqual(
    packageNames(resolved),
    sampleCase.registryPackages,
    `${sampleCase.name} package order`,
  );
  assert.deepEqual(
    edgeNames(resolved),
    sampleCase.registryEdges,
    `${sampleCase.name} edge order`,
  );
}

async function assertContextExpectation(baseUrl, sampleCase, expectation) {
  const resolved = await resolveSampleCase(baseUrl, sampleCase, expectation.context);
  assert.deepEqual(
    packageNames(resolved),
    expectation.registryPackages,
    `${sampleCase.name}: ${expectation.name} packages`,
  );
  assert.deepEqual(
    edgeNames(resolved),
    expectation.registryEdges,
    `${sampleCase.name}: ${expectation.name} edges`,
  );
}

test("registry resolve stays aligned with the shared resolver sample", async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kons-registry-resolver-sample-"));
  const port = 22000 + Math.floor(Math.random() * 1000);
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
    const sample = await readSharedResolverSample();
    await waitForHealth(baseUrl);
    const token = await signInAndToken(baseUrl, "resolver-sample@example.test", "resolversample");
    await publishSampleCandidates(baseUrl, token, tmp, sample.candidates);

    for (const sampleCase of sample.cases) {
      await assertBaseSampleCase(baseUrl, sampleCase);
      for (const expectation of sampleCase.contextExpectations || []) {
        await assertContextExpectation(baseUrl, sampleCase, expectation);
      }
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
