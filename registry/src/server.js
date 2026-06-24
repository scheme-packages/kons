import http from "node:http";
import { createConfig } from "./config.js";
import { openRegistryDatabase } from "./database.js";
import * as httpUtils from "./http-utils.js";
import { createCore } from "./core.js";
import { createArchive } from "./archive.js";
import { createPayloadValidation } from "./payload.js";
import { createAuth } from "./auth.js";
import { createPublishResolve } from "./publish-resolve.js";
import { createPackageHandlers } from "./package-handlers.js";
import { createRateLimiter } from "./rate-limit.js";
import { createRoute } from "./routes.js";
import { createSigning } from "./signing.js";
import { smtpConfigured } from "./smtp.js";

const config = createConfig(process.env);
const db = await openRegistryDatabase(config);

httpUtils.bindHttpConfig(config);
const ctx = { db, config, ...httpUtils };
Object.assign(ctx, createCore(ctx));
Object.assign(ctx, createArchive(ctx));
Object.assign(ctx, createPayloadValidation(ctx));
Object.assign(ctx, createSigning(ctx));
Object.assign(ctx, createAuth(ctx));
Object.assign(ctx, createPublishResolve(ctx));
Object.assign(ctx, createPackageHandlers(ctx));
Object.assign(ctx, createRateLimiter(ctx));
ctx.route = createRoute(ctx);

const server = http.createServer((req, res) => {
  ctx.route(req, res).catch((error) => {
    const status = error.status || 500;
    if (status >= 500) console.error(error);
    const message = error.message || "internal server error";
    ctx.sendJson(res, status, {
      status,
      message,
      details: error.details ?? null,
      error: message,
    });
  });
});

ctx.backfillPackageSearchTerms();

server.listen(config.port, config.host, () => {
  const base = config.baseUrl || `http://${config.host}:${config.port}`;
  console.log(`[kons] listening on ${base}`);
  if (config.sessionSecret === "kons-registry-dev-secret") {
    console.log("[kons] set KONS_SESSION_SECRET before production use");
  }
  if (config.emailRegistration) {
    const mode = config.emailOpenRegistration ? "open registration" : "allowlist registration";
    const delivery = smtpConfigured(config.smtp) ? `smtp://${config.smtp.host}:${config.smtp.port}` : "server log";
    console.log(`[kons] email registration enabled (${mode}, delivery: ${delivery})`);
  }
});
