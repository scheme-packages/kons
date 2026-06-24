export function createRoute(ctx) {
  const { currentUser, sendJson, publicBaseUrl, configuredPublicUrl, configuredProviders, emailAuthInfo, config, parseCookies, clearSessionCookie, sha256, db, enforceRateLimit, handleEmailStart, handleEmailVerify, handleAuthStart, handleAuthCallback, requireUser, listTokens, createToken, deleteToken, searchPackages, resolvePackages, librarySearch, libraryProviders, identifierSearch, managedPackages, publishPackage, packageNameFromApiPath, packageDependents, packageVersionList, versionRouteParts, packageVersionMetadata, packageVersionManifest, listPackageOwners, addPackageOwner, removePackageOwner, listPackageAudit, yankVersion, deletePackage, deletePackageVersion, httpError, sendArchive, resolvePackageVersion, publicPackage, indexConfig, sparsePathForName, indexLines, send, staticFile } = ctx;

async function route(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || "local"}`);
  const pathname = decodeURI(url.pathname);
  const viewer = currentUser(req);

  if (req.method === "GET" && pathname === "/healthz") {
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/meta") {
    sendJson(res, 200, {
      name: "kons",
      baseUrl: publicBaseUrl(req),
      publicUrl: configuredPublicUrl(),
      storage: config.storage,
      index: `${publicBaseUrl(req)}/index/config.json`,
      sourceUrl: config.sourceUrl,
      messages: config.deployerMessages,
      auth: {
        oauth: configuredProviders(),
        email: emailAuthInfo(),
      },
    });
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/auth/providers") {
    sendJson(res, 200, {
      oauth: configuredProviders(),
      email: emailAuthInfo(),
      publicUrl: configuredPublicUrl(),
      sourceUrl: config.sourceUrl,
      messages: config.deployerMessages,
    });
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/auth/me") {
    sendJson(res, 200, { user: viewer });
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/auth/logout") {
    const session = parseCookies(req).kons_session;
    if (session) db.prepare("DELETE FROM sessions WHERE id_hash = ?").run(sha256(session));
    sendJson(res, 200, { ok: true }, { "set-cookie": clearSessionCookie() });
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/auth/email/start") {
    enforceRateLimit(req, "auth");
    await handleEmailStart(req, res);
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/auth/email/verify") {
    enforceRateLimit(req, "auth");
    await handleEmailVerify(req, res);
    return;
  }

  const authStart = pathname.match(/^\/auth\/([a-z]+)\/start$/);
  if (req.method === "GET" && authStart) {
    enforceRateLimit(req, "auth");
    await handleAuthStart(req, res, authStart[1], url);
    return;
  }

  const authCallback = pathname.match(/^\/auth\/([a-z]+)\/callback$/);
  if (req.method === "GET" && authCallback) {
    enforceRateLimit(req, "auth");
    await handleAuthCallback(req, res, authCallback[1], url);
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/tokens") {
    const user = requireUser(req);
    sendJson(res, 200, { tokens: listTokens(user) });
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/tokens") {
    await createToken(req, res);
    return;
  }

  const tokenDelete = pathname.match(/^\/api\/v1\/tokens\/(\d+)$/);
  if (req.method === "DELETE" && tokenDelete) {
    deleteToken(req, res, Number(tokenDelete[1]));
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/search") {
    enforceRateLimit(req, "search");
    sendJson(res, 200, searchPackages(url, viewer));
    return;
  }

  if (req.method === "POST" && pathname === "/api/v1/resolve") {
    await resolvePackages(req, res);
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/libraries") {
    enforceRateLimit(req, "search");
    sendJson(res, 200, librarySearch(url));
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/v1/libraries/")) {
    enforceRateLimit(req, "search");
    const key = decodeURIComponent(pathname.slice("/api/v1/libraries/".length));
    sendJson(res, 200, libraryProviders(key, url));
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/identifiers") {
    enforceRateLimit(req, "search");
    sendJson(res, 200, identifierSearch(url));
    return;
  }

  if (req.method === "GET" && pathname === "/api/v1/me/packages") {
    const user = requireUser(req);
    sendJson(res, 200, { packages: managedPackages(user) });
    return;
  }

  if (req.method === "PUT" && pathname === "/api/v1/packages/new") {
    enforceRateLimit(req, "publish");
    await publishPackage(req, res);
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/dependents") && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname, "/dependents");
    sendJson(res, 200, packageDependents(name, url.searchParams.get("includeYanked") === "1"));
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/versions") && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname, "/versions");
    sendJson(
      res,
      200,
      packageVersionList(
        name,
        url.searchParams.get("includeYanked") === "1",
        url.searchParams.get("signed") === "1"
      )
    );
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/metadata") && pathname.startsWith("/api/v1/packages/")) {
    const { name, version } = versionRouteParts(pathname, "metadata");
    sendJson(res, 200, packageVersionMetadata(name, version));
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/manifest") && pathname.startsWith("/api/v1/packages/")) {
    const { name, version } = versionRouteParts(pathname, "manifest");
    sendJson(res, 200, packageVersionManifest(name, version));
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/owners") && pathname.startsWith("/api/v1/packages/")) {
    listPackageOwners(req, res);
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/audit") && pathname.startsWith("/api/v1/packages/")) {
    listPackageAudit(req, res);
    return;
  }

  if (req.method === "POST" && pathname.endsWith("/owners") && pathname.startsWith("/api/v1/packages/")) {
    await addPackageOwner(req, res);
    return;
  }

  if (req.method === "PUT" && pathname.includes("/owners/") && pathname.startsWith("/api/v1/packages/")) {
    await addPackageOwner(req, res);
    return;
  }

  if (req.method === "DELETE" && pathname.includes("/owners/") && pathname.startsWith("/api/v1/packages/")) {
    removePackageOwner(req, res);
    return;
  }

  if (req.method === "DELETE" && pathname.endsWith("/yank") && pathname.startsWith("/api/v1/packages/")) {
    await yankVersion(req, res, false);
    return;
  }

  if (req.method === "PUT" && pathname.endsWith("/unyank") && pathname.startsWith("/api/v1/packages/")) {
    await yankVersion(req, res, true);
    return;
  }

  if (req.method === "DELETE" && pathname.endsWith("/delete") && pathname.startsWith("/api/v1/packages/")) {
    await deletePackage(req, res);
    return;
  }

  if (req.method === "DELETE" && pathname.startsWith("/api/v1/packages/")) {
    await deletePackageVersion(req, res);
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/download") && pathname.startsWith("/api/v1/packages/")) {
    enforceRateLimit(req, "download");
    const { name, version } = versionRouteParts(pathname, "download");
    const row = db.prepare("SELECT * FROM versions WHERE package_name = ? AND version = ?").get(name, version);
    if (!row) throw httpError(404, "package version not found");
    await sendArchive(req, res, row);
    return;
  }

  if (req.method === "GET" && pathname.endsWith("/resolve") && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname, "/resolve");
    const row = resolvePackageVersion(name, url.searchParams.get("req") || "*");
    if (!row) throw httpError(404, "no matching package version");
    sendJson(res, 200, { version: row.version, package: publicPackage(name, viewer) });
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/api/v1/packages/")) {
    const name = packageNameFromApiPath(pathname);
    const pkg = publicPackage(name, viewer);
    if (!pkg) throw httpError(404, "package not found");
    sendJson(res, 200, { package: pkg });
    return;
  }

  if (req.method === "GET" && pathname === "/index/config.json") {
    sendJson(res, 200, indexConfig(req), { "cache-control": "public, max-age=60" });
    return;
  }

  if (req.method === "GET" && pathname.startsWith("/index/")) {
    const sparsePath = pathname.slice("/index/".length);
    const rows = db.prepare("SELECT name FROM packages").all();
    const found = rows.find((row) => sparsePathForName(row.name) === sparsePath);
    if (!found) throw httpError(404, "index entry not found");
    send(res, 200, indexLines(found.name), {
      "content-type": "application/x-ndjson; charset=utf-8",
      "cache-control": "public, max-age=60",
    });
    return;
  }

  await staticFile(req, res, pathname);
}

  return route;
}
