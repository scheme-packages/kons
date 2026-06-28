import { createReadStream } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";

export function createPackageHandlers(ctx) {
  const { db, config, sendJson, httpError, readJson, requireUser, requirePackageOwner, resolvePackageName, validateUsername, requireSemver, nowIso, publicPackage, packageRow, ownerRows, getUserByUsername, logAuditAction, auditLogRows, dataArray } = ctx;

function packageNameFromApiPath(pathname, suffix = "") {
  let rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  if (suffix && rest.endsWith(suffix)) rest = rest.slice(0, -suffix.length);
  return resolvePackageName(rest.replace(/\/$/, ""));
}

function ownerRouteParts(pathname, withUsername = false) {
  const rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  const parts = rest.split("/").filter(Boolean);
  if (withUsername) {
    if (parts.length < 3 || parts.at(-2) !== "owners") throw httpError(404, "not found");
    return {
      name: resolvePackageName(parts.slice(0, -2).join("/")),
      username: validateUsername(parts.at(-1)),
    };
  }
  if (parts.length < 2 || parts.at(-1) !== "owners") throw httpError(404, "not found");
  return { name: resolvePackageName(parts.slice(0, -1).join("/")) };
}

function versionRouteParts(pathname, terminal) {
  const rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  const parts = rest.split("/").filter(Boolean);
  if (parts.at(-1) !== terminal || parts.length < 3) throw httpError(404, "not found");
  const version = parts.at(-2);
  requireSemver(version);
  const name = resolvePackageName(parts.slice(0, -2).join("/"));
  return { name, version };
}

function versionDeleteRouteParts(pathname) {
  const rest = decodeURIComponent(pathname.slice("/api/v1/packages/".length));
  const parts = rest.split("/").filter(Boolean);
  if (parts.length < 2) throw httpError(404, "not found");
  const version = parts.at(-1);
  requireSemver(version);
  const name = resolvePackageName(parts.slice(0, -1).join("/"));
  return { name, version };
}

async function yankVersion(req, res, unyank = false) {
  const user = requireUser(req);
  const { name, version } = versionRouteParts(new URL(req.url, "http://local").pathname, unyank ? "unyank" : "yank");
  requirePackageOwner(user, name);
  const row = db.prepare("SELECT 1 FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  db.prepare(`
    UPDATE versions SET yanked = ?, yanked_at = ?, yanked_by = ? WHERE package_name = ? AND version = ?
  `).run(unyank ? 0 : 1, unyank ? null : nowIso(), unyank ? null : user.id, name, version);
  logAuditAction(unyank ? "unyank" : "yank", {
    packageName: name,
    version,
    actor: user,
  });
  sendJson(res, 200, { package: publicPackage(name, user) });
}

function listPackageOwners(req, res) {
  const { name } = ownerRouteParts(new URL(req.url, "http://local").pathname);
  if (!packageRow(name)) throw httpError(404, "package not found");
  sendJson(res, 200, { owners: ownerRows(name) });
}

async function addPackageOwner(req, res) {
  const user = requireUser(req);
  const pathname = new URL(req.url, "http://local").pathname;
  let route = pathname.endsWith("/owners") ? ownerRouteParts(pathname) : ownerRouteParts(pathname, true);
  if (pathname.endsWith("/owners")) {
    const payload = await readJson(req, 16 * 1024);
    route = { ...route, username: validateUsername(payload.username) };
  }
  if (!packageRow(route.name)) throw httpError(404, "package not found");
  requirePackageOwner(user, route.name);

  const owner = getUserByUsername(route.username);
  if (!owner) throw httpError(404, "user not found", { username: route.username });
  const result = db.prepare(`
    INSERT OR IGNORE INTO package_owners (package_name, user_id, role, created_at)
    VALUES (?, ?, 'owner', ?)
  `).run(route.name, owner.id, nowIso());
  if (result.changes > 0) {
    logAuditAction("owner-add", {
      packageName: route.name,
      actor: user,
      details: { username: owner.username },
    });
  }
  sendJson(res, 200, { owners: ownerRows(route.name) });
}

function removePackageOwner(req, res) {
  const user = requireUser(req);
  const { name, username } = ownerRouteParts(new URL(req.url, "http://local").pathname, true);
  if (!packageRow(name)) throw httpError(404, "package not found");
  requirePackageOwner(user, name);

  const owner = getUserByUsername(username);
  if (!owner) throw httpError(404, "user not found", { username });
  const count = db.prepare("SELECT count(*) AS count FROM package_owners WHERE package_name = ?").get(name).count;
  if (count <= 1 && db.prepare("SELECT 1 FROM package_owners WHERE package_name = ? AND user_id = ?").get(name, owner.id)) {
    throw httpError(400, "cannot remove the last package owner");
  }
  const result = db.prepare("DELETE FROM package_owners WHERE package_name = ? AND user_id = ?").run(name, owner.id);
  if (result.changes > 0) {
    logAuditAction("owner-remove", {
      packageName: name,
      actor: user,
      details: { username: owner.username },
    });
  }
  sendJson(res, 200, { owners: ownerRows(name) });
}

function listPackageAudit(req, res) {
  const user = requireUser(req);
  const name = packageNameFromApiPath(new URL(req.url, "http://local").pathname, "/audit");
  if (!packageRow(name)) throw httpError(404, "package not found");
  requirePackageOwner(user, name);
  sendJson(res, 200, { package: name, events: auditLogRows(name) });
}

function searchPackages(url, viewer) {
  const q = String(url.searchParams.get("q") || "").toLowerCase();
  const keyword = String(url.searchParams.get("keyword") || "").toLowerCase();
  const type = String(url.searchParams.get("type") || "package").toLowerCase();
  const page = Math.max(1, Number(url.searchParams.get("page") || 1));
  const perPage = Math.min(100, Math.max(1, Number(url.searchParams.get("per_page") || 20)));
  const searchTermPackages = q
    ? new Set(db.prepare(`
        SELECT DISTINCT package_name
        FROM package_search_terms
        WHERE lower(term) LIKE ?
      `).all(`%${q}%`).map((row) => row.package_name))
    : new Set();
  const rows = db.prepare("SELECT name FROM packages ORDER BY updated_at DESC, name ASC").all();
  const filtered = rows.map((row) => publicPackage(row.name, viewer)).filter((pkg) => {
    if (keyword && !(pkg.keywords || []).some((item) => item.toLowerCase() === keyword)) return false;
    if (!q) return true;
    if (searchTermPackages.has(pkg.name)) return true;
    return [
      pkg.name,
      pkg.description,
      pkg.repository,
      ...(pkg.keywords || []),
      ...(pkg.owners || []).map((owner) => owner.username),
      ...(pkg.owners || []).map((owner) => owner.displayName),
    ].join(" ").toLowerCase().includes(q);
  });
  const offset = (page - 1) * perPage;
  const packageResults = filtered.map(packageSearchResult);
  const allResults = type === "all"
    ? pagedCombinedSearchResults(packageResults, q, offset, perPage)
    : null;
  let results;
  if (allResults) {
    results = allResults.results;
  } else if (type === "library") {
    results = searchLibraryResults(q, perPage, offset);
  } else if (type === "identifier") {
    results = searchIdentifierResults(q, perPage, offset);
  } else {
    results = filtered.slice(offset, offset + perPage).map(packageSearchResult);
  }
  return {
    total: allResults ? allResults.total : filtered.length,
    page,
    perPage,
    packages: filtered.slice(offset, offset + perPage),
    results,
  };
}

function packageSearchResult(pkg) {
  return {
    type: "package",
    name: pkg.name,
    package: pkg.name,
    version: pkg.latest?.version || "",
    description: pkg.description,
  };
}

function takePageItems(items, start, limit) {
  if (limit <= 0 || start >= items.length) return [];
  return items.slice(start, start + limit);
}

function pagedCombinedSearchResults(packageResults, q, offset, perPage) {
  const libraryCount = countLibraryResults(q);
  const identifierCount = countIdentifierResults(q);
  let start = offset;
  let remaining = perPage;
  const results = [];

  const packages = takePageItems(packageResults, start, remaining);
  results.push(...packages);
  remaining -= packages.length;
  start = Math.max(0, start - packageResults.length);

  if (remaining > 0) {
    const libraries = start < libraryCount
      ? searchLibraryResults(q, remaining, start)
      : [];
    results.push(...libraries);
    remaining -= libraries.length;
    start = Math.max(0, start - libraryCount);
  }

  if (remaining > 0) {
    results.push(...searchIdentifierResults(q, remaining, start));
  }

  return {
    total: packageResults.length + libraryCount + identifierCount,
    results,
  };
}

function countLibraryResults(q) {
  const like = `%${q || ""}%`;
  return db.prepare(`
    SELECT COUNT(*) AS count
    FROM version_libraries l
    WHERE (? = ''
       OR lower(l.library_name) LIKE ?
       OR lower(l.library_key) LIKE ?
       OR lower(l.implementation) LIKE ?
       OR lower(l.dialect) LIKE ?)
  `).get(q, like, like, like, like).count;
}

function searchLibraryResults(q, limit = 20, offset = 0) {
  const like = `%${q || ""}%`;
  return db.prepare(`
    SELECT l.kind, l.library_name, l.library_key, l.implementation, l.dialect,
           l.package_name, l.version, v.description
    FROM version_libraries l
    JOIN versions v ON v.package_name = l.package_name AND v.version = l.version
    WHERE (? = ''
       OR lower(l.library_name) LIKE ?
       OR lower(l.library_key) LIKE ?
       OR lower(l.implementation) LIKE ?
       OR lower(l.dialect) LIKE ?)
    ORDER BY l.library_key, l.package_name, l.version DESC
    LIMIT ? OFFSET ?
  `).all(q, like, like, like, like, limit, offset).map((row) => ({
    type: "library",
    name: row.library_name,
    key: row.library_key,
    kind: row.kind,
    implementation: row.implementation || "",
    dialect: row.dialect || "",
    package: row.package_name,
    version: row.version,
    description: row.description,
  }));
}

function countIdentifierResults(q) {
  const like = `%${q || ""}%`;
  return db.prepare(`
    SELECT COUNT(*) AS count
    FROM version_identifiers i
    WHERE (? = '' OR lower(i.identifier) LIKE ?)
  `).get(q, like).count;
}

function searchIdentifierResults(q, limit = 20, offset = 0) {
  const like = `%${q || ""}%`;
  return db.prepare(`
    SELECT i.identifier, i.kind, i.library_name, i.package_name, i.version, v.description
    FROM version_identifiers i
    JOIN versions v ON v.package_name = i.package_name AND v.version = i.version
    WHERE (? = '' OR lower(i.identifier) LIKE ?)
    ORDER BY i.identifier, i.library_name, i.package_name, i.version DESC
    LIMIT ? OFFSET ?
  `).all(q, like, limit, offset).map((row) => ({
    type: "identifier",
    name: row.identifier,
    identifier: row.identifier,
    kind: row.kind,
    library: row.library_name,
    package: row.package_name,
    version: row.version,
    description: row.description,
  }));
}

function librarySearch(url) {
  const q = String(url.searchParams.get("q") || "").toLowerCase();
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") || 20)));
  return { libraries: searchLibraryResults(q, limit, 0) };
}

function libraryRouteKey(value) {
  const text = String(value || "").trim().toLowerCase();
  if (!text) return "";
  if (text.startsWith("(") && text.endsWith(")")) {
    return text.slice(1, -1).trim().split(/\s+/).filter(Boolean).join("/");
  }
  if (!text.includes("/") && /\s/.test(text)) {
    return text.split(/\s+/).filter(Boolean).join("/");
  }
  return text;
}

function libraryProviders(key, url) {
  const libraryKeyValue = libraryRouteKey(key);
  if (!libraryKeyValue) throw httpError(400, "library key is required");
  const kind = String(url.searchParams.get("kind") || "").toLowerCase();
  const rows = db.prepare(`
    SELECT l.kind, l.library_name, l.library_key, l.path, l.imports_json, l.exports_json,
           l.implementation, l.dialect, l.package_name, l.version, v.description, v.yanked
    FROM version_libraries l
    JOIN versions v ON v.package_name = l.package_name AND v.version = l.version
    WHERE lower(l.library_key) = ? AND (? = '' OR l.kind = ?)
    ORDER BY l.package_name, l.version DESC, l.kind
  `).all(libraryKeyValue, kind, kind).map((row) => ({
    type: "library",
    name: row.library_name,
    key: row.library_key,
    kind: row.kind,
    implementation: row.implementation || "",
    dialect: row.dialect || "",
    path: row.path || "",
    imports: dataArray(row.imports_json),
    exports: dataArray(row.exports_json),
    package: row.package_name,
    version: row.version,
    description: row.description,
    yanked: Boolean(row.yanked),
  }));
  return { key: libraryKeyValue, libraries: rows };
}

function packageDependents(name, includeYanked = false) {
  if (!packageRow(name)) throw httpError(404, "package not found");
  const rows = db.prepare(`
    SELECT d.package_name, d.version, d.req, d.kind, d.registry, d.optional,
           d.target, d.schemes_json, d.implementations_json, d.targets_json, d.features_json, v.description, v.yanked
    FROM dependencies d
    JOIN versions v ON v.package_name = d.package_name AND v.version = d.version
    WHERE d.dep_name = ? AND (? = 1 OR v.yanked = 0)
    ORDER BY d.package_name, d.version DESC
  `).all(name, includeYanked ? 1 : 0).map((row) => ({
    package: row.package_name,
    version: row.version,
    req: row.req,
    kind: row.kind,
    registry: row.registry || null,
    optional: Boolean(row.optional),
    target: row.target || null,
    schemes: dataArray(row.schemes_json),
    implementations: dataArray(row.implementations_json),
    targets: dataArray(row.targets_json),
    features: dataArray(row.features_json),
    description: row.description,
    yanked: Boolean(row.yanked),
  }));
  return { package: name, dependents: rows };
}

function identifierSearch(url) {
  const q = String(url.searchParams.get("q") || "").toLowerCase();
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") || 20)));
  return { identifiers: searchIdentifierResults(q, limit, 0) };
}

function managedPackages(user) {
  const rows = user.isAdmin
    ? db.prepare("SELECT name FROM packages ORDER BY updated_at DESC, name ASC").all()
    : db.prepare(`
        SELECT packages.name
        FROM packages
        JOIN package_owners ON package_owners.package_name = packages.name
        WHERE package_owners.user_id = ?
        ORDER BY packages.updated_at DESC, packages.name ASC
      `).all(user.id);
  return rows.map((row) => publicPackage(row.name, user)).filter(Boolean);
}

async function deletePackageVersion(req, res) {
  const user = requireUser(req);
  const { name, version } = versionDeleteRouteParts(new URL(req.url, "http://local").pathname);
  requirePackageOwner(user, name);
  const row = db.prepare("SELECT * FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  logAuditAction("delete-version-denied", {
    packageName: name,
    version,
    actor: user,
    details: {
      reason: "immutable-version",
      checksum: row.checksum,
    },
  });
  throw httpError(409, "published package versions are immutable; yank instead");
}

async function deletePackage(req, res) {
  const user = requireUser(req);
  const name = packageNameFromApiPath(new URL(req.url, "http://local").pathname, "/delete");
  requirePackageOwner(user, name);
  const pkg = packageRow(name);
  if (!pkg) throw httpError(404, "package not found");
  const versions = db.prepare("SELECT version FROM versions WHERE package_name = ? ORDER BY version DESC").all(name);
  logAuditAction("delete-package-denied", {
    packageName: name,
    actor: user,
    details: {
      reason: "immutable-package",
      versions: versions.map((row) => row.version),
    },
  });
  throw httpError(409, "published packages are immutable; yank versions instead");
}

async function staticFile(req, res, pathname) {
  const aliases = {
    "/account": "account.html",
  };
  const file = pathname === "/"
    ? "index.html"
    : aliases[pathname] || pathname.replace(/^\/+/, "");
  const full = path.resolve(config.publicDir, file);
  if (!full.startsWith(config.publicDir)) throw httpError(403, "forbidden");
  try {
    const stat = await fs.stat(full);
    if (!stat.isFile()) throw httpError(404, "not found");
    const ext = path.extname(full);
    const type = {
      ".html": "text/html; charset=utf-8",
      ".css": "text/css; charset=utf-8",
      ".js": "application/javascript; charset=utf-8",
      ".svg": "image/svg+xml",
    }[ext] || "application/octet-stream";
    res.writeHead(200, { "content-type": type, "cache-control": "no-cache" });
    createReadStream(full).pipe(res);
  } catch {
    if (!pathname.startsWith("/api/") && !pathname.startsWith("/index/") && !pathname.startsWith("/auth/")) {
      await staticFile(req, res, "/");
      return;
    }
    throw httpError(404, "not found");
  }
}

  return { packageNameFromApiPath, versionRouteParts, yankVersion, listPackageOwners, addPackageOwner, removePackageOwner, listPackageAudit, searchPackages, librarySearch, libraryProviders, packageDependents, identifierSearch, managedPackages, deletePackageVersion, deletePackage, staticFile };
}
