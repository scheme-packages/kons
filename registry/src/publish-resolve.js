import path from "node:path";

export function createPublishResolve(ctx) {
  const { db, config, publicBaseUrl, sendJson, httpError, readJson, requireUser, validatePackageOwner, decodeArchivePayload, sha256, validateArchive, packageRow, requirePackageOwner, archiveKey, putArchive, deleteArchive, nowIso, insertLibraryRows, insertSearchTermRows, logAuditAction, publicPackage, validSemverRange, versionRows, satisfies, dependencyRows, packageDownloadUrl, libraryRows, validationError, normalizeDependencies, validatePublishPayload, sparsePathForName, signingConfig, signedPayload } = ctx;

function indexConfig(req) {
  const base = publicBaseUrl(req);
  const config = {
    version: 1,
    dl: `${base}/api/v1/packages/{name}/{version}/download`,
    api: base,
  };
  const signing = signingConfig();
  if (signing) config.signing = signing;
  return config;
}

function versionPublisher(row) {
  const user = db.prepare("SELECT id, username, display_name FROM users WHERE id = ?").get(row.published_by);
  if (!user) return null;
  return {
    id: user.id,
    username: user.username,
    displayName: user.display_name,
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

function relativeDownloadPath(name, version) {
  return `/api/v1/packages/${encodeURIComponent(name)}/${version}/download`;
}

function signedVersionRow(name, row) {
  return {
    version: row.version,
    checksum: row.checksum,
    size: row.size,
    download: relativeDownloadPath(name, row.version),
    yanked: Boolean(row.yanked),
    publishedAt: row.published_at,
    provenance: versionProvenance(row),
    description: row.description,
    license: row.license,
    dialects: JSON.parse(row.dialects_json || "[]"),
    features: JSON.parse(row.features_json || "[]"),
    featureDependencies: JSON.parse(row.feature_dependencies_json || "[]"),
    dependencies: dependencyRows(name, row.version),
  };
}

function sparseIndexEntry(name, row) {
  return {
    name,
    vers: row.version,
    deps: dependencyRows(name, row.version).map((dep) => ({
      name: dep.name,
      req: dep.req,
      kind: dep.kind,
      registry: dep.registry,
      optional: dep.optional,
      target: dep.target,
      schemes: dep.schemes || [],
      implementations: dep.implementations || [],
      dialects: dep.dialects || [],
      targets: dep.targets || [],
      profiles: dep.profiles || [],
      compileModes: dep.compileModes || [],
      features: dep.features,
    })),
    checksum: row.checksum,
    provenance: versionProvenance(row),
    yanked: Boolean(row.yanked),
    dialects: JSON.parse(row.dialects_json || "[]"),
    features: JSON.parse(row.features_json || "[]"),
    featureDependencies: JSON.parse(row.feature_dependencies_json || "[]"),
  };
}

function signedSparseIndexEntry(name, row) {
  const entry = sparseIndexEntry(name, row);
  const signed = signedPayload(entry);
  if (!signed) return entry;
  return { ...entry, signed };
}

function indexLines(name) {
  return versionRows(name)
    .reverse()
    .map((row) => JSON.stringify(signedSparseIndexEntry(name, row)))
    .join("\n") + "\n";
}

async function publishPackage(req, res) {
  const user = requireUser(req);
  const payload = await readJson(req, config.maxArchiveBytes * 2);
  const {
    name: payloadName,
    version,
    description,
    license,
    dialects,
    features,
    featureDependencies,
    keywords,
    dependencies,
    libraries,
  } = validatePublishPayload(payload);
  const name = payloadName;
  const owner = validatePackageOwner(payload.owner);
  const archive = decodeArchivePayload(payload.archiveBase64);
  const checksum = sha256(archive);
  const homepage = String(payload.homepage || payload.site || "");
  const repository = String(payload.repository || payload.repo || "");
  const documentation = String(payload.documentation || payload.docs || "");
  const readmePath = String(payload.readme || "");
  const validation = await validateArchive(archive, name, version, owner, readmePath);

  const existing = packageRow(name);
  if (existing) requirePackageOwner(user, name);

  if (db.prepare("SELECT 1 FROM versions WHERE package_name = ? AND version = ?").get(name, version)) {
    throw httpError(409, "package version already exists");
  }

  const key = archiveKey(name, version);
  const filename = path.basename(key);
  await putArchive(key, archive);

  const now = nowIso();
  db.exec("BEGIN");
  try {
    if (!existing) {
      db.prepare(`
        INSERT INTO packages
          (name, description, homepage, repository, documentation, keywords_json, created_by, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        name,
        description,
        homepage,
        repository,
        documentation,
        JSON.stringify(keywords),
        user.id,
        now,
        now
      );
      db.prepare("INSERT INTO package_owners (package_name, user_id, role, created_at) VALUES (?, ?, 'owner', ?)")
        .run(name, user.id, now);
    } else {
      db.prepare(`
        UPDATE packages
        SET description = COALESCE(NULLIF(?, ''), description),
            homepage = COALESCE(NULLIF(?, ''), homepage),
            repository = COALESCE(NULLIF(?, ''), repository),
            documentation = COALESCE(NULLIF(?, ''), documentation),
            keywords_json = ?,
            updated_at = ?
        WHERE name = ?
      `).run(
        description,
        homepage,
        repository,
        documentation,
        JSON.stringify(keywords),
        now,
        name
      );
    }

    db.prepare(`
      INSERT INTO versions
        (package_name, version, checksum, size, archive_key, archive_filename, published_by, published_at,
         description, license, dialects_json, features_json, feature_dependencies_json, readme, manifest_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      name,
      version,
      checksum,
      archive.length,
      key,
      filename,
      user.id,
      now,
      description,
      license,
      JSON.stringify(dialects),
      JSON.stringify(features),
      JSON.stringify(featureDependencies),
      validation.readme,
      JSON.stringify(validation.manifest)
    );

    for (const dep of dependencies) {
      db.prepare(`
      INSERT INTO dependencies
          (package_name, version, dep_name, req, kind, registry, optional, target, schemes_json, implementations_json, dialects_json, targets_json, profiles_json, compile_modes_json, features_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        name,
        version,
        dep.name,
        dep.req,
        dep.kind,
        dep.registry,
        dep.optional ? 1 : 0,
        dep.target,
        JSON.stringify(dep.schemes),
        JSON.stringify(dep.implementations),
        JSON.stringify(dep.dialects),
        JSON.stringify(dep.targets),
        JSON.stringify(dep.profiles),
        JSON.stringify(dep.compileModes),
        JSON.stringify(dep.features)
      );
    }
    insertLibraryRows(name, version, libraries);
    insertSearchTermRows(name, version, {
      name,
      description,
      keywords,
      dialects,
      features,
      dependencies,
      libraries,
    });
    logAuditAction("publish", {
      packageName: name,
      version,
      actor: user,
      details: {
        checksum,
        size: archive.length,
        publishedBy: {
          id: user.id,
          username: user.username,
          displayName: user.displayName,
        },
        createdPackage: !existing,
      },
    });
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    await deleteArchive({ archive_key: key });
    throw error;
  }

  sendJson(res, 201, { package: publicPackage(name, user), checksum });
}

function resolvePackageVersion(name, req) {
  if (!validSemverRange(req)) throw httpError(400, "version requirement must be valid SemVer");
  const rows = versionRows(name)
    .filter((row) => !row.yanked)
    .filter((row) => satisfies(row.version, req));
  return rows[0] || null;
}

function packageVersionList(name, includeYanked = false, requireSigned = false) {
  if (!packageRow(name)) throw httpError(404, "package not found");
  const rows = versionRows(name).filter((row) => includeYanked || !row.yanked);
  const response = {
    package: name,
    versions: rows
      .map((row) => ({
        version: row.version,
        checksum: row.checksum,
        size: row.size,
        downloadUrl: packageDownloadUrl(name, row.version),
        yanked: Boolean(row.yanked),
        publishedAt: row.published_at,
        publishedBy: versionPublisher(row),
        provenance: versionProvenance(row),
        description: row.description,
        license: row.license,
        dialects: JSON.parse(row.dialects_json || "[]"),
        features: JSON.parse(row.features_json || "[]"),
        featureDependencies: JSON.parse(row.feature_dependencies_json || "[]"),
        dependencies: dependencyRows(name, row.version),
      })),
  };
  const signed = signedPayload({
    package: name,
    versions: rows.map((row) => signedVersionRow(name, row)),
  });
  if (requireSigned && !signed) {
    throw httpError(409, "registry signing is not configured");
  }
  if (signed) response.signed = signed;
  return response;
}

function packageVersionMetadata(name, version) {
  const row = db.prepare("SELECT * FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  return {
    package: name,
    version: row.version,
    checksum: row.checksum,
    size: row.size,
    downloadUrl: packageDownloadUrl(name, row.version),
    yanked: Boolean(row.yanked),
    publishedAt: row.published_at,
    publishedBy: versionPublisher(row),
    provenance: versionProvenance(row),
    description: row.description,
    license: row.license,
    dialects: JSON.parse(row.dialects_json || "[]"),
    features: JSON.parse(row.features_json || "[]"),
    featureDependencies: JSON.parse(row.feature_dependencies_json || "[]"),
    dependencies: dependencyRows(name, row.version),
    libraries: libraryRows(name, row.version),
  };
}

function packageVersionManifest(name, version) {
  const row = db.prepare("SELECT manifest_json FROM versions WHERE package_name = ? AND version = ?").get(name, version);
  if (!row) throw httpError(404, "package version not found");
  return {
    package: name,
    version,
    manifest: JSON.parse(row.manifest_json || "{}"),
  };
}

function resolveCandidateId(name, version) {
  return `registry:default:${name}:${version}`;
}

function cloneConstraintMap(source) {
  const out = new Map();
  for (const [name, items] of source.entries()) out.set(name, items.slice());
  return out;
}

function uniqueStrings(values) {
  const seen = new Set();
  const out = [];
  for (const value of values || []) {
    const text = String(value || "").trim();
    if (text && !seen.has(text)) {
      seen.add(text);
      out.push(text);
    }
  }
  return out;
}

function mergeFeatures(left, right) {
  return uniqueStrings([...(left || []), ...(right || [])]);
}

function requestedFeaturesForName(constraints, name) {
  let features = [];
  for (const requirement of constraints.get(name) || []) {
    features = mergeFeatures(features, requirement.features || []);
  }
  return features;
}

function featureActivatesDependency(feature, depName) {
  const text = String(feature || "");
  const lastPart = depName.split("/").filter(Boolean).at(-1) || depName;
  return text === depName || text === lastPart;
}

function optionalDependencyActive(dep, features) {
  if (!dep.optional) return true;
  return (features || []).some((feature) => featureActivatesDependency(feature, dep.name));
}

function featureDependencyRows(row, features) {
  return JSON.parse(row.feature_dependencies_json || "[]")
    .filter((item) => (features || []).includes(item.feature))
    .flatMap((item) => item.dependencies || []);
}

function stringContextField(payload, field, errors) {
  const value = payload[field];
  if (value == null || value === "") return "";
  if (typeof value !== "string") {
    errors.push({ field: `context.${field}`, message: "must be a string" });
    return "";
  }
  return value.trim();
}

function normalizeResolveContext(payload, errors) {
  const raw = payload.context;
  if (raw == null) {
    return {
      scheme: "",
      dialect: "",
      target: "",
      profile: "",
      compileMode: "",
    };
  }
  if (typeof raw !== "object" || Array.isArray(raw)) {
    errors.push({ field: "context", message: "must be a JSON object" });
    return {
      scheme: "",
      dialect: "",
      target: "",
      profile: "",
      compileMode: "",
    };
  }
  return {
    scheme: stringContextField(raw, "scheme", errors),
    dialect: stringContextField(raw, "dialect", errors),
    target: stringContextField(raw, "target", errors),
    profile: stringContextField(raw, "profile", errors),
    compileMode: stringContextField(raw, "compileMode", errors),
  };
}

function selectorFieldMatches(selectedValue, allowedValues) {
  if (!selectedValue) return true;
  if (!allowedValues || allowedValues.length === 0) return true;
  return allowedValues.includes(selectedValue);
}

function dependencyMatchesResolveContext(dep, context) {
  const schemes = [
    ...(dep.schemes || []),
    ...(dep.implementations || []),
  ];
  return selectorFieldMatches(context.scheme, schemes)
    && selectorFieldMatches(context.dialect, dep.dialects || [])
    && selectorFieldMatches(context.target, dep.targets || [])
    && selectorFieldMatches(context.profile, dep.profiles || [])
    && selectorFieldMatches(context.compileMode, dep.compileModes || []);
}

function activeDependencyRows(name, row, features, context) {
  return [
    ...dependencyRows(name, row.version),
    ...featureDependencyRows(row, features),
  ].filter((dep) => dependencyMatchesResolveContext(dep, context));
}

function addResolveConstraint(constraints, name, req, from, kind = "normal", features = [], optional = false, selectors = {}) {
  const items = constraints.get(name) || [];
  items.push({
    name,
    req,
    from,
    kind,
    features: uniqueStrings(features),
    optional,
    schemes: uniqueStrings(selectors.schemes || []),
    implementations: uniqueStrings(selectors.implementations || []),
    dialects: uniqueStrings(selectors.dialects || []),
    targets: uniqueStrings(selectors.targets || []),
    profiles: uniqueStrings(selectors.profiles || []),
    compileModes: uniqueStrings(selectors.compileModes || []),
  });
  constraints.set(name, items);
}

function selectedSatisfiesConstraints(selected, constraints, name) {
  const selectedPackage = selected.get(name);
  if (!selectedPackage) return false;
  const versionMatches = (constraints.get(name) || []).every((req) => satisfies(selectedPackage.row.version, req.req));
  const featuresMatch = JSON.stringify(selectedPackage.features || []) === JSON.stringify(requestedFeaturesForName(constraints, name));
  return versionMatches && featuresMatch;
}

function unresolvedConstraintName(selected, constraints) {
  for (const name of constraints.keys()) {
    if (!selectedSatisfiesConstraints(selected, constraints, name)) return name;
  }
  return "";
}

function resolveGraphConflict(name, constraints) {
  const requirements = (constraints.get(name) || []).map((req) => ({
    req: req.req,
    from: req.from,
    kind: req.kind,
    features: req.features || [],
    optional: Boolean(req.optional),
    schemes: req.schemes || [],
    implementations: req.implementations || [],
    dialects: req.dialects || [],
    targets: req.targets || [],
    profiles: req.profiles || [],
    compileModes: req.compileModes || [],
  }));
  throw httpError(409, "dependency version conflict", { package: name, requirements });
}

function candidateVersionRows(name, constraints, includeYanked) {
  return versionRows(name)
    .filter((row) => includeYanked || !row.yanked)
    .filter((row) => (constraints.get(name) || []).every((req) => satisfies(row.version, req.req)));
}

function solveResolveGraph(selected, constraints, includeYanked, context) {
  const name = unresolvedConstraintName(selected, constraints);
  if (!name) return selected;

  const candidates = candidateVersionRows(name, constraints, includeYanked);
  if (!candidates.length) resolveGraphConflict(name, constraints);
  const selectedFeatures = requestedFeaturesForName(constraints, name);

  for (const row of candidates) {
    const nextSelected = new Map(selected);
    const nextConstraints = cloneConstraintMap(constraints);
    nextSelected.set(name, { row, features: selectedFeatures });
    const from = resolveCandidateId(name, row.version);
    for (const dep of activeDependencyRows(name, row, selectedFeatures, context)) {
      if (!optionalDependencyActive(dep, selectedFeatures)) continue;
      addResolveConstraint(
        nextConstraints,
        dep.name,
        dep.req,
        from,
        dep.kind || "normal",
        dep.features || [],
        Boolean(dep.optional),
        dep,
      );
    }
    try {
      return solveResolveGraph(nextSelected, nextConstraints, includeYanked, context);
    } catch (error) {
      if (error.status !== 409) throw error;
    }
  }
  resolveGraphConflict(name, constraints);
}

function resolveGraphEdges(rootRequirements, selected, context) {
  const out = [];
  for (const req of rootRequirements) {
    const selectedPackage = selected.get(req.name);
    if (selectedPackage) {
      out.push({
        from: "root",
        to: resolveCandidateId(req.name, selectedPackage.row.version),
        name: req.name,
        req: req.req,
        kind: req.kind || "normal",
        features: req.features || [],
        optional: Boolean(req.optional),
        schemes: req.schemes || [],
        implementations: req.implementations || [],
        dialects: req.dialects || [],
        targets: req.targets || [],
        profiles: req.profiles || [],
        compileModes: req.compileModes || [],
      });
    }
  }
  for (const [name, selectedPackage] of selected.entries()) {
    const row = selectedPackage.row;
    const features = selectedPackage.features || [];
    const from = resolveCandidateId(name, row.version);
    for (const dep of activeDependencyRows(name, row, features, context)) {
      if (!optionalDependencyActive(dep, features)) continue;
      const depPackage = selected.get(dep.name);
      if (!depPackage) continue;
      out.push({
        from,
        to: resolveCandidateId(dep.name, depPackage.row.version),
        name: dep.name,
        req: dep.req,
        kind: dep.kind || "normal",
        features: dep.features || [],
        optional: Boolean(dep.optional),
        schemes: dep.schemes || [],
        implementations: dep.implementations || [],
        dialects: dep.dialects || [],
        targets: dep.targets || [],
        profiles: dep.profiles || [],
        compileModes: dep.compileModes || [],
      });
    }
  }
  return out;
}

function resolveGraphPackage(name, selectedPackage) {
  const row = selectedPackage.row;
  return {
    id: resolveCandidateId(name, row.version),
    package: name,
    name,
    version: row.version,
    checksum: row.checksum,
    size: row.size,
    downloadUrl: packageDownloadUrl(name, row.version),
    yanked: Boolean(row.yanked),
    publishedAt: row.published_at,
    publishedBy: versionPublisher(row),
    provenance: versionProvenance(row),
    description: row.description,
    license: row.license,
    dialects: JSON.parse(row.dialects_json || "[]"),
    availableFeatures: JSON.parse(row.features_json || "[]"),
    features: selectedPackage.features || [],
    featureDependencies: JSON.parse(row.feature_dependencies_json || "[]"),
    dependencies: dependencyRows(name, row.version),
  };
}

function normalizeResolvePayload(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    validationError("resolve payload must be a JSON object", [
      { field: "body", message: "must be a JSON object" },
    ]);
  }
  const errors = [];
  const raw = payload.requirements ?? payload.dependencies;
  const dependencies = normalizeDependencies(raw, errors);
  const context = normalizeResolveContext(payload, errors);
  if (!raw) errors.push({ field: "requirements", message: "is required" });
  if (errors.length) validationError("resolve payload validation failed", errors);
  return {
    includeYanked: Boolean(payload.includeYanked),
    context,
    requirements: dependencies.map((dep) => ({
      name: dep.name,
      req: dep.req,
      kind: dep.kind,
      features: dep.features || [],
      optional: Boolean(dep.optional),
      schemes: dep.schemes || [],
      implementations: dep.implementations || [],
      dialects: dep.dialects || [],
      targets: dep.targets || [],
      profiles: dep.profiles || [],
      compileModes: dep.compileModes || [],
    })),
  };
}

async function resolvePackages(req, res) {
  const url = new URL(req.url, "http://local");
  const requireSigned = url.searchParams.get("signed") === "1";
  const payload = normalizeResolvePayload(await readJson(req, 1024 * 1024));
  const constraints = new Map();
  for (const requirement of payload.requirements) {
    if (requirement.optional) continue;
    addResolveConstraint(
      constraints,
      requirement.name,
      requirement.req,
      "root",
      requirement.kind,
      requirement.features,
      false,
      requirement,
    );
  }
  const selected = solveResolveGraph(new Map(), constraints, payload.includeYanked, payload.context);
  const packages = [...selected.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([name, selectedPackage]) => resolveGraphPackage(name, selectedPackage));
  const response = {
    context: payload.context,
    packages,
    edges: resolveGraphEdges(payload.requirements, selected, payload.context),
  };
  const signed = signedPayload(response);
  if (requireSigned && !signed) {
    throw httpError(409, "registry signing is not configured");
  }
  if (signed) response.signed = signed;
  sendJson(res, 200, response);
}

  return { indexConfig, indexLines, publishPackage, resolvePackageVersion, packageVersionList, packageVersionMetadata, packageVersionManifest, resolvePackages };
}
