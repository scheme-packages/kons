export function createCore(ctx) {
  const { db, config, nowIso, randomToken, sha256, parseCookies, httpError, dataArray, dataObject, dataValue, dataText } = ctx;

function canonicalPackageName(name) {
  return String(name || "").trim().toLowerCase();
}

const reservedPackageNameRoots = new Set([
  "account",
  "admin",
  "api",
  "auth",
  "assets",
  "healthz",
  "identifiers",
  "index",
  "libraries",
  "login",
  "logout",
  "me",
  "new",
  "package",
  "packages",
  "search",
  "static",
  "tokens",
]);

function reservedPackageNameRoot(name) {
  return name.split("/")[0] || "";
}

function validatePackageName(raw) {
  const name = canonicalPackageName(raw);
  if (!/^[a-z0-9][a-z0-9_-]*(\/[a-z0-9][a-z0-9_-]*)*$/.test(name)) {
    throw httpError(400, "package name must contain lowercase letters, numbers, underscores, hyphens, or slash-separated segments");
  }
  if (reservedPackageNameRoots.has(reservedPackageNameRoot(name))) {
    throw httpError(400, "package name root is reserved by the registry");
  }
  return name;
}

function validatePackageOwner(rawOwner) {
  const owner = String(rawOwner || "").trim();
  if (!owner) throw httpError(400, "package owner is required");
  return validateUsername(owner);
}

function validateUsername(raw) {
  const username = String(raw || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(username)) {
    throw httpError(400, "username must contain only lowercase letters, numbers, underscores, or hyphens");
  }
  return username;
}

function requestedUsername(raw) {
  const text = String(raw || "").trim();
  return text ? validateUsername(text) : "";
}

function requireRequestedUsername(raw) {
  const username = requestedUsername(raw);
  if (!username) throw httpError(400, "username is required");
  return username;
}

function usernameExists(username) {
  return !!db.prepare("SELECT 1 FROM users WHERE lower(username) = lower(?)").get(username);
}

function ensureUsernameAvailable(username) {
  if (username && usernameExists(username)) {
    throw httpError(409, "username is already taken", { username });
  }
}

function safeNameToken(name) {
  return name.replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "package";
}

function archiveKey(name, version) {
  const parts = name.split("/");
  const filename = `${safeNameToken(name)}-${version}.kons`;
  return `${parts.map(safeNameToken).join("/")}/${filename}`;
}

function parseSemver(version) {
  const match = String(version || "").match(
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$/
  );
  if (!match) return null;
  if (!validSemverIdentifiers(match[4], { allowLeadingZeroNumbers: false })) return null;
  if (!validSemverIdentifiers(match[5], { allowLeadingZeroNumbers: true })) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease: match[4] ? match[4].split(".") : [],
    build: match[5] || "",
    raw: version,
  };
}

function requireSemver(version) {
  const parsed = parseSemver(version);
  if (!parsed) throw httpError(400, "version must be valid SemVer, for example 1.2.3");
  return parsed;
}

function compareIdentifiers(a, b) {
  const an = /^[0-9]+$/.test(a);
  const bn = /^[0-9]+$/.test(b);
  if (an && bn) return Number(a) - Number(b);
  if (an) return -1;
  if (bn) return 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareSemver(a, b) {
  const av = parseSemver(a);
  const bv = parseSemver(b);
  if (!av || !bv) return String(a).localeCompare(String(b));
  for (const key of ["major", "minor", "patch"]) {
    if (av[key] !== bv[key]) return av[key] - bv[key];
  }
  if (!av.prerelease.length && bv.prerelease.length) return 1;
  if (av.prerelease.length && !bv.prerelease.length) return -1;
  for (let i = 0; i < Math.max(av.prerelease.length, bv.prerelease.length); i += 1) {
    if (av.prerelease[i] === undefined) return -1;
    if (bv.prerelease[i] === undefined) return 1;
    const cmp = compareIdentifiers(av.prerelease[i], bv.prerelease[i]);
    if (cmp) return cmp;
  }
  return 0;
}

function satisfies(version, range = "*") {
  const req = String(range || "*").trim();
  if (req === "*" || req === "") return true;
  if (req.startsWith("^")) {
    const base = parseSemver(normalizePartialVersion(req.slice(1)));
    const value = parseSemver(version);
    if (!base || !value || compareSemver(version, base.raw) < 0) return false;
    let upper;
    if (base.major > 0) {
      upper = `${base.major + 1}.0.0`;
    } else if (base.minor > 0) {
      upper = `0.${base.minor + 1}.0`;
    } else {
      upper = `0.0.${base.patch + 1}`;
    }
    return compareSemver(version, upper) < 0;
  }
  if (req.startsWith("~")) {
    const base = parseSemver(normalizePartialVersion(req.slice(1)));
    if (!base || compareSemver(version, base.raw) < 0) return false;
    return compareSemver(version, `${base.major}.${base.minor + 1}.0`) < 0;
  }
  const op = req.match(/^(>=|>|<=|<|=)\s*(.+)$/);
  if (op) {
    const target = normalizePartialVersion(op[2]);
    if (!parseSemver(target)) return false;
    const cmp = compareSemver(version, target);
    const ops = {
      ">=": (c) => c >= 0,
      ">": (c) => c > 0,
      "<=": (c) => c <= 0,
      "<": (c) => c < 0,
      "=": (c) => c === 0,
    };
    return (ops[op[1]] || ops["="])(cmp);
  }
  if (/^\d+$/.test(req)) return version.startsWith(`${req}.`);
  if (/^\d+\.\d+$/.test(req)) return version.startsWith(`${req}.`);
  if (/^\d+\.(x|\*)$/i.test(req)) return version.startsWith(`${req.split(".")[0]}.`);
  if (/^\d+\.\d+\.(x|\*)$/i.test(req)) return version.startsWith(`${req.split(".").slice(0, 2).join(".")}.`);
  return compareSemver(version, req) === 0;
}

function normalizePartialVersion(value) {
  const text = String(value || "").trim();
  if (/^\d+$/.test(text)) return `${text}.0.0`;
  if (/^\d+\.\d+$/.test(text)) return `${text}.0`;
  return text;
}

function validSemverIdentifiers(value, { allowLeadingZeroNumbers }) {
  if (!value) return true;
  return value.split(".").every((part) => {
    if (!part || !/^[0-9A-Za-z-]+$/.test(part)) return false;
    return allowLeadingZeroNumbers || !/^0\d+$/.test(part);
  });
}

function validSemverRange(range) {
  const req = String(range || "*").trim();
  if (req === "*" || req === "") return true;
  if (req.startsWith("^") || req.startsWith("~")) {
    return !!parseSemver(normalizePartialVersion(req.slice(1)));
  }
  const op = req.match(/^(>=|>|<=|<|=)\s*(.+)$/);
  if (op) return !!parseSemver(normalizePartialVersion(op[2]));
  if (/^\d+$/.test(req) || /^\d+\.\d+$/.test(req)) return true;
  if (/^\d+\.(x|\*)$/i.test(req) || /^\d+\.\d+\.(x|\*)$/i.test(req)) return true;
  return !!parseSemver(req);
}

function sparsePathForName(name) {
  const token = name.replaceAll("/", "-");
  const compact = token.replace(/[^a-z0-9]/g, "");
  const first = compact.slice(0, 2).padEnd(2, "_");
  const second = compact.slice(2, 4).padEnd(2, "_");
  return `${first}/${second}/${token}`;
}

function userFromRow(row) {
  if (!row) return null;
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    email: row.email || "",
    avatarUrl: row.avatar_url || "",
    isAdmin: Boolean(row.is_admin),
  };
}

function getUserById(id) {
  return userFromRow(db.prepare("SELECT * FROM users WHERE id = ?").get(id));
}

function getUserByUsername(username) {
  return userFromRow(db.prepare("SELECT * FROM users WHERE lower(username) = lower(?)").get(username));
}

function isAdminEmail(email) {
  return !!email && config.admins.some((item) => item.toLowerCase() === email.toLowerCase());
}

function upsertIdentityUser(provider, profile, rawProfile = {}, options = {}) {
  const existingIdentity = db
    .prepare("SELECT user_id FROM identities WHERE provider = ? AND provider_id = ?")
    .get(provider, profile.providerId);
  if (existingIdentity) return getUserById(existingIdentity.user_id);

  const now = nowIso();
  let user = profile.email
    ? userFromRow(db.prepare("SELECT * FROM users WHERE lower(email) = lower(?)").get(profile.email))
    : null;
  if (!user) {
    const preferredUsername = requireRequestedUsername(options.username || "");
    ensureUsernameAvailable(preferredUsername);
    const username = preferredUsername;
    const result = db.prepare(`
      INSERT INTO users (username, display_name, email, avatar_url, is_admin, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(
      username,
      options.displayName || profile.displayName || username,
      profile.email || null,
      profile.avatarUrl || "",
      isAdminEmail(profile.email) ? 1 : 0,
      now,
      now
    );
    user = getUserById(result.lastInsertRowid);
  }

  db.prepare(`
    INSERT INTO identities (provider, provider_id, user_id, username, email, raw_json, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    provider,
    profile.providerId,
    user.id,
    profile.username || "",
    profile.email || "",
    JSON.stringify(rawProfile),
    now,
    now
  );
  return user;
}

function createSession(userId) {
  const token = randomToken(32);
  const createdAt = nowIso();
  const expiresAt = new Date(Date.now() + 1000 * 60 * 60 * 24 * 30).toISOString();
  db.prepare("INSERT INTO sessions (id_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .run(sha256(token), userId, createdAt, expiresAt);
  return token;
}

function sessionCookie(token) {
  return `kons_session=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 30}`;
}

function clearSessionCookie() {
  return "kons_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0";
}

function currentUser(req) {
  const auth = String(req.headers.authorization || "");
  if (auth.startsWith("Bearer ")) {
    const token = auth.slice("Bearer ".length).trim();
    const row = db.prepare("SELECT * FROM api_tokens WHERE token_hash = ?").get(sha256(token));
    if (!row) return null;
    db.prepare("UPDATE api_tokens SET last_used_at = ? WHERE id = ?").run(nowIso(), row.id);
    return getUserById(row.user_id);
  }

  const session = parseCookies(req).kons_session;
  if (!session) return null;
  const row = db.prepare(`
    SELECT user_id FROM sessions WHERE id_hash = ? AND expires_at > ?
  `).get(sha256(session), nowIso());
  return row ? getUserById(row.user_id) : null;
}

function requireUser(req) {
  const user = currentUser(req);
  if (!user) throw httpError(401, "authentication required");
  return user;
}

function canManagePackage(user, name) {
  if (user?.isAdmin) return true;
  return !!db.prepare("SELECT 1 FROM package_owners WHERE package_name = ? AND user_id = ?").get(name, user?.id);
}

function requirePackageOwner(user, name) {
  if (!canManagePackage(user, name)) throw httpError(403, "package owner permission required");
}

function packageRow(name) {
  return db.prepare("SELECT * FROM packages WHERE name = ?").get(name);
}

function resolvePackageName(name) {
  return validatePackageName(name);
}

function versionRows(name) {
  return db.prepare("SELECT * FROM versions WHERE package_name = ?").all(name)
    .sort((a, b) => compareSemver(b.version, a.version));
}

function incrementDownloadCount(name, version) {
  db.prepare(`
    UPDATE versions
    SET download_count = download_count + 1,
        last_downloaded_at = ?
    WHERE package_name = ? AND version = ?
  `).run(nowIso(), name, version);
}

function dependencyNameValue(row) {
  if (!row.dep_name_json) return row.dep_name;
  const parsed = dataValue(row.dep_name_json);
  return parsed === undefined || parsed === null || parsed === false ? row.dep_name : parsed;
}

function dependencyNameSearchText(name) {
  if (Array.isArray(name)) return name.join("/");
  return String(name || "");
}

function dependencyRows(name, version) {
  return db.prepare(`
    SELECT dep_type, dep_name, dep_name_json, req, kind, registry, source, optional, target, schemes_json, implementations_json, dialects_json, targets_json, profiles_json, compile_modes_json, condition_json, features_json
    FROM dependencies WHERE package_name = ? AND version = ?
    ORDER BY dep_name
  `).all(name, version).map((row) => {
    const condition = dataValue(row.condition_json || "#f");
    return {
      type: row.dep_type || "registry",
      name: dependencyNameValue(row),
      req: row.req,
      kind: row.kind,
      registry: row.registry || null,
      source: row.source || null,
      optional: Boolean(row.optional),
      target: row.target || null,
      schemes: dataArray(row.schemes_json),
      implementations: dataArray(row.implementations_json),
      dialects: dataArray(row.dialects_json),
      targets: dataArray(row.targets_json),
      profiles: dataArray(row.profiles_json),
      compileModes: dataArray(row.compile_modes_json),
      condition: condition === undefined ? null : condition,
      features: dataArray(row.features_json),
    };
  });
}

function libraryRows(name, version) {
  return db.prepare(`
    SELECT kind, library_name, library_key, path, imports_json, exports_json, implementation, dialect
    FROM version_libraries
    WHERE package_name = ? AND version = ?
    ORDER BY kind, library_key
  `).all(name, version).map((row) => ({
    kind: row.kind,
    name: row.library_name,
    key: row.library_key,
    path: row.path || "",
    imports: dataArray(row.imports_json),
    exports: dataArray(row.exports_json),
    implementation: row.implementation || "",
    dialect: row.dialect || "",
  }));
}

function insertLibraryRows(name, version, libraries) {
  const libraryInsert = db.prepare(`
    INSERT INTO version_libraries
      (package_name, version, kind, library_name, library_key, path, imports_json, exports_json, implementation, dialect)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const identifierInsert = db.prepare(`
    INSERT INTO version_identifiers
      (package_name, version, kind, library_name, identifier, role)
    VALUES (?, ?, ?, ?, ?, 'export')
  `);
  for (const library of libraries) {
    libraryInsert.run(
      name,
      version,
      library.kind,
      library.name,
      library.key,
      library.path,
      dataText(library.imports),
      dataText(library.exports),
      library.implementation,
      library.dialect
    );
    for (const identifier of library.exports) {
      identifierInsert.run(name, version, library.kind, library.name, identifier);
    }
  }
}

function addSearchTerm(out, seen, field, value) {
  const term = String(value || "").trim().toLowerCase();
  if (!term) return;
  const key = `${field}:${term}`;
  if (seen.has(key)) return;
  seen.add(key);
  out.push({ field, term });
}

function collectSearchTerms({ name, description, keywords, dialects, features, dependencies, libraries }) {
  const out = [];
  const seen = new Set();
  addSearchTerm(out, seen, "package", name);
  for (const part of name.split("/")) addSearchTerm(out, seen, "package", part);
  addSearchTerm(out, seen, "description", description);
  for (const keyword of keywords || []) addSearchTerm(out, seen, "keyword", keyword);
  for (const dialect of dialects || []) addSearchTerm(out, seen, "dialect", dialect);
  for (const feature of features || []) addSearchTerm(out, seen, "feature", feature);
  for (const dependency of dependencies || []) {
    addSearchTerm(out, seen, "dependency", dependencyNameSearchText(dependency.name));
    addSearchTerm(out, seen, "dependency-source", dependency.type);
    addSearchTerm(out, seen, "dependency-source", dependency.source);
  }
  for (const library of libraries || []) {
    addSearchTerm(out, seen, "library", library.name);
    addSearchTerm(out, seen, "library", library.key);
    addSearchTerm(out, seen, "library-path", library.path);
    addSearchTerm(out, seen, "implementation", library.implementation);
    addSearchTerm(out, seen, "dialect", library.dialect);
    for (const imported of library.imports || []) {
      addSearchTerm(out, seen, "import", Array.isArray(imported) ? imported.join("/") : imported);
    }
    for (const identifier of library.exports || []) {
      addSearchTerm(out, seen, "identifier", identifier);
    }
  }
  return out;
}

function insertSearchTermRows(name, version, metadata) {
  const insert = db.prepare(`
    INSERT INTO package_search_terms (package_name, version, term, field)
    VALUES (?, ?, ?, ?)
  `);
  for (const item of collectSearchTerms(metadata)) {
    insert.run(name, version, item.term, item.field);
  }
}

function structuredArray(value) {
  try {
    const parsed = dataArray(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function backfillPackageSearchTerms() {
  const missingRows = db.prepare(`
    SELECT packages.name,
           packages.keywords_json,
           versions.version,
           versions.description,
           versions.dialects_json,
           versions.features_json
    FROM versions
    JOIN packages ON packages.name = versions.package_name
    WHERE NOT EXISTS (
      SELECT 1
      FROM package_search_terms
      WHERE package_search_terms.package_name = versions.package_name
        AND package_search_terms.version = versions.version
    )
    ORDER BY packages.name, versions.version
  `).all();
  if (missingRows.length === 0) return;

  db.exec("BEGIN");
  try {
    for (const row of missingRows) {
      insertSearchTermRows(row.name, row.version, {
        name: row.name,
        description: row.description,
        keywords: structuredArray(row.keywords_json),
        dialects: structuredArray(row.dialects_json),
        features: structuredArray(row.features_json),
        dependencies: dependencyRows(row.name, row.version),
        libraries: libraryRows(row.name, row.version),
      });
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  console.log(`[kons] backfilled package search terms for ${missingRows.length} version(s)`);
}

function ownerRows(name) {
  return db.prepare(`
    SELECT users.username, users.display_name, users.avatar_url
    FROM package_owners
    JOIN users ON users.id = package_owners.user_id
    WHERE package_owners.package_name = ?
    ORDER BY users.username
  `).all(name).map((row) => ({
    username: row.username,
    displayName: row.display_name,
    avatarUrl: row.avatar_url,
  }));
}

function auditActor(user) {
  if (!user) return { id: null, username: "" };
  return {
    id: user.id,
    username: user.username || "",
  };
}

function logAuditAction(action, { packageName = "", version = "", actor = null, details = {} } = {}) {
  const auditActorSnapshot = auditActor(actor);
  db.prepare(`
    INSERT INTO audit_log
      (action, package_name, version, actor_id, actor_username, details_json, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(
    action,
    packageName,
    version || "",
    auditActorSnapshot.id,
    auditActorSnapshot.username,
    JSON.stringify(details || {}),
    nowIso()
  );
}

function auditLogRows(packageName, limit = 100) {
  return db.prepare(`
    SELECT id, action, package_name, version, actor_id, actor_username, details_json, created_at
    FROM audit_log
    WHERE package_name = ?
    ORDER BY id DESC
    LIMIT ?
  `).all(packageName, limit).map((row) => ({
    id: row.id,
    action: row.action,
    package: row.package_name,
    version: row.version || "",
    actor: row.actor_id
      ? { id: row.actor_id, username: row.actor_username || "" }
      : null,
    details: dataObject(row.details_json),
    createdAt: row.created_at,
  }));
}

function versionPublisher(row) {
  const user = getUserById(row.published_by);
  if (!user) return null;
  return {
    id: user.id,
    username: user.username,
    displayName: user.displayName,
  };
}

function versionProvenance(row) {
  return {
    publishedBy: versionPublisher(row),
    publishedAt: row.published_at,
    checksum: row.checksum,
    size: row.size,
  };
}

function registryTrustState() {
  const signing = config.signing || {};
  const configured = Boolean(signing.keyId && signing.privateKeyFile);
  return {
    signedMetadata: configured,
    alg: configured ? "ed25519" : "",
    keyId: signing.keyId || "",
  };
}

function publicPackage(name, viewer = null) {
  const pkg = packageRow(name);
  if (!pkg) return null;
  const versions = versionRows(name).map((row) => ({
    version: row.version,
    checksum: row.checksum,
    size: row.size,
    publishedAt: row.published_at,
    publishedBy: versionPublisher(row),
    provenance: versionProvenance(row),
    yanked: Boolean(row.yanked),
    description: row.description,
    license: row.license,
    dialects: dataArray(row.dialects_json),
    features: dataArray(row.features_json),
    readme: row.readme || "",
    downloads: Number(row.download_count || 0),
    lastDownloadedAt: row.last_downloaded_at || null,
    dependencies: dependencyRows(name, row.version),
    libraries: libraryRows(name, row.version),
  }));
  const owners = ownerRows(name);
  const latest = versions.find((version) => !version.yanked) || versions[0] || null;
  const downloads = versions.reduce((sum, version) => sum + Number(version.downloads || 0), 0);
  return {
    name,
    description: pkg.description,
    homepage: pkg.homepage,
    site: pkg.homepage,
    repository: pkg.repository,
    repo: pkg.repository,
    documentation: pkg.documentation,
    docs: pkg.documentation,
    readme: latest?.readme || "",
    keywords: dataArray(pkg.keywords_json),
    latest,
    versions,
    downloads,
    owners,
    indexPath: sparsePathForName(name),
    trust: registryTrustState(),
    canManage: viewer ? canManagePackage(viewer, name) : false,
    createdAt: pkg.created_at,
    updatedAt: pkg.updated_at,
  };
}

  return { canonicalPackageName, validatePackageName, validatePackageOwner, validateUsername, requestedUsername, requireRequestedUsername, usernameExists, ensureUsernameAvailable, safeNameToken, archiveKey, parseSemver, requireSemver, compareSemver, satisfies, normalizePartialVersion, validSemverRange, sparsePathForName, userFromRow, getUserById, getUserByUsername, isAdminEmail, upsertIdentityUser, createSession, sessionCookie, clearSessionCookie, currentUser, requireUser, canManagePackage, requirePackageOwner, packageRow, resolvePackageName, versionRows, incrementDownloadCount, dependencyRows, libraryRows, insertLibraryRows, collectSearchTerms, insertSearchTermRows, backfillPackageSearchTerms, ownerRows, logAuditAction, auditLogRows, publicPackage };
}
