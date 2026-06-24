export function createPayloadValidation(ctx) {
  const { validationError, validatePackageName, validSemverRange, parseSemver } = ctx;

function normalizeStringList(value, field, errors, { maxItems = 64 } = {}) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) {
    errors.push({ field, message: "must be an array of strings" });
    return [];
  }
  if (value.length > maxItems) {
    errors.push({ field, message: `must contain at most ${maxItems} items` });
  }
  return value.slice(0, maxItems).map((item, index) => {
    if (typeof item !== "string" || !item.trim()) {
      errors.push({ field: `${field}[${index}]`, message: "must be a non-empty string" });
      return "";
    }
    return item.trim();
  }).filter(Boolean);
}

function normalizeKeywords(value, errors) {
  const seen = new Set();
  const out = [];
  for (const [index, keyword] of normalizeStringList(value, "keywords", errors, { maxItems: 12 }).entries()) {
    const normalized = keyword.toLowerCase();
    if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(normalized)) {
      errors.push({
        field: `keywords[${index}]`,
        message: "must contain lowercase letters, numbers, dot, underscore, or hyphen",
      });
      continue;
    }
    if (!seen.has(normalized)) {
      seen.add(normalized);
      out.push(normalized);
    }
  }
  return out;
}

function normalizeDependencies(raw, errors) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push({ field: "dependencies", message: "must be an array" });
    return [];
  }
  return raw.map((dep, index) => {
    const prefix = `dependencies[${index}]`;
    if (!dep || typeof dep !== "object" || Array.isArray(dep)) {
      errors.push({ field: prefix, message: "must be an object" });
      return null;
    }

    let name = "";
    try {
      name = validatePackageName(dep.name);
    } catch (error) {
      errors.push({ field: `${prefix}.name`, message: error.message });
    }

    const reqValue = dep.req ?? dep.version;
    const req = typeof reqValue === "string" ? reqValue.trim() : "";
    if (!req) errors.push({ field: `${prefix}.req`, message: "is required" });
    else if (!validSemverRange(req)) {
      errors.push({ field: `${prefix}.req`, message: "must be a valid SemVer requirement" });
    }

    const kind = dep.kind === undefined ? "normal" : String(dep.kind).trim();
    if (!["normal", "dev", "build"].includes(kind)) {
      errors.push({ field: `${prefix}.kind`, message: "must be normal, dev, or build" });
    }

    if (dep.optional !== undefined && typeof dep.optional !== "boolean") {
      errors.push({ field: `${prefix}.optional`, message: "must be a boolean" });
    }
    if (dep.registry !== undefined && (typeof dep.registry !== "string" || !dep.registry.trim())) {
      errors.push({ field: `${prefix}.registry`, message: "must be a non-empty string" });
    }
    if (dep.target !== undefined && (typeof dep.target !== "string" || !dep.target.trim())) {
      errors.push({ field: `${prefix}.target`, message: "must be a non-empty string" });
    }

    const features = normalizeStringList(dep.features, `${prefix}.features`, errors);
    const schemes = normalizeStringList(dep.schemes, `${prefix}.schemes`, errors);
    const implementations = normalizeStringList(dep.implementations, `${prefix}.implementations`, errors);
    const dialects = normalizeStringList(dep.dialects, `${prefix}.dialects`, errors);
    const targets = normalizeStringList(dep.targets, `${prefix}.targets`, errors);
    const profiles = normalizeStringList(dep.profiles, `${prefix}.profiles`, errors);
    const compileModes = normalizeStringList(dep.compileModes, `${prefix}.compileModes`, errors);
    const target = dep.target ? String(dep.target).trim() : null;
    const allTargets = target ? [target, ...targets.filter((item) => item !== target)] : targets;
    return {
      name,
      req,
      kind: ["normal", "dev", "build"].includes(kind) ? kind : "normal",
      registry: dep.registry ? String(dep.registry).trim() : null,
      optional: Boolean(dep.optional),
      target: target || allTargets[0] || null,
      schemes,
      implementations,
      dialects,
      targets: allTargets,
      profiles,
      compileModes,
      features,
    };
  }).filter((dep) => dep && dep.name && dep.req);
}

function normalizeFeatureDependencies(raw, errors) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push({ field: "featureDependencies", message: "must be an array" });
    return [];
  }
  return raw.map((item, index) => {
    const prefix = `featureDependencies[${index}]`;
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      errors.push({ field: prefix, message: "must be an object" });
      return null;
    }
    const feature = typeof item.feature === "string" ? item.feature.trim() : "";
    if (!feature) errors.push({ field: `${prefix}.feature`, message: "is required" });
    const dependencies = normalizeDependencies(item.dependencies, errors);
    return feature ? { feature, dependencies } : null;
  }).filter(Boolean);
}

function normalizeLibraryNameParts(value, field, errors) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) {
      errors.push({ field, message: "must not be empty" });
      return [];
    }
    return [trimmed];
  }
  if (!Array.isArray(value)) {
    errors.push({ field, message: "must be an array of strings or a string" });
    return [];
  }
  const parts = value.map((part, index) => {
    const text = String(part || "").trim();
    if (!text) {
      errors.push({ field: `${field}[${index}]`, message: "must be a non-empty string" });
      return "";
    }
    if (text.length > 120) {
      errors.push({ field: `${field}[${index}]`, message: "must be 120 characters or less" });
      return "";
    }
    return text;
  }).filter(Boolean);
  if (!parts.length) errors.push({ field, message: "must contain at least one part" });
  return parts;
}

function libraryDisplayName(parts) {
  return parts.length === 1 ? parts[0] : `(${parts.join(" ")})`;
}

function libraryKey(parts) {
  return parts.join("/");
}

function normalizeLibraryNameList(value, field, errors) {
  if (!Array.isArray(value)) {
    errors.push({ field, message: "must be an array" });
    return [];
  }
  return value.map((item, index) => {
    const parts = normalizeLibraryNameParts(item, `${field}[${index}]`, errors);
    return parts.length ? parts : null;
  }).filter(Boolean);
}

function normalizeLibraryField(value, maxLength = 80) {
  return typeof value === "string" ? value.trim().toLowerCase().slice(0, maxLength) : "";
}

function defaultLibraryDialect(kind) {
  return ["r7rs", "r6rs"].includes(kind) ? kind : "";
}

function defaultLibraryImplementation(kind) {
  return ["guile", "gauche"].includes(kind) ? kind : "";
}

function normalizeLibraries(raw, errors) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push({ field: "libraries", message: "must be an array" });
    return [];
  }
  if (raw.length > 512) errors.push({ field: "libraries", message: "must contain at most 512 entries" });
  return raw.slice(0, 512).map((library, index) => {
    const prefix = `libraries[${index}]`;
    if (!library || typeof library !== "object" || Array.isArray(library)) {
      errors.push({ field: prefix, message: "must be an object" });
      return null;
    }

    const kind = String(library.kind || "").trim();
    if (!["r7rs", "r6rs", "guile", "gauche"].includes(kind)) {
      errors.push({ field: `${prefix}.kind`, message: "must be r7rs, r6rs, guile, or gauche" });
    }

    const normalizedKind = ["r7rs", "r6rs", "guile", "gauche"].includes(kind) ? kind : "r7rs";
    const nameParts = normalizeLibraryNameParts(library.name, `${prefix}.name`, errors);
    const displayName = String(library.displayName || libraryDisplayName(nameParts)).trim().slice(0, 300);
    const key = String(library.key || libraryKey(nameParts)).trim().slice(0, 300);
    if (!key) errors.push({ field: `${prefix}.key`, message: "is required" });
    const sourcePath = typeof library.path === "string" ? library.path.trim().slice(0, 600) : "";
    const imports = normalizeLibraryNameList(library.imports || [], `${prefix}.imports`, errors);
    const exports = normalizeStringList(library.exports || [], `${prefix}.exports`, errors, { maxItems: 2048 });
    const implementation = normalizeLibraryField(library.implementation) || defaultLibraryImplementation(normalizedKind);
    const dialect = normalizeLibraryField(library.dialect) || defaultLibraryDialect(normalizedKind);

    return {
      kind: normalizedKind,
      name: displayName || libraryDisplayName(nameParts),
      key: key || libraryKey(nameParts),
      path: sourcePath,
      imports,
      exports,
      implementation,
      dialect,
    };
  }).filter((library) => library && library.key);
}

const spdxLicenseIds = new Set([
  "0BSD",
  "Apache-2.0",
  "Artistic-2.0",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "BSL-1.0",
  "CC-BY-4.0",
  "CC-BY-SA-4.0",
  "CC0-1.0",
  "CDDL-1.0",
  "CDDL-1.1",
  "EPL-1.0",
  "EPL-2.0",
  "EUPL-1.2",
  "GPL-2.0-only",
  "GPL-2.0-or-later",
  "GPL-3.0-only",
  "GPL-3.0-or-later",
  "ISC",
  "LGPL-2.1-only",
  "LGPL-2.1-or-later",
  "LGPL-3.0-only",
  "LGPL-3.0-or-later",
  "MIT",
  "MIT-0",
  "MPL-2.0",
  "NCSA",
  "OFL-1.1",
  "Unlicense",
  "Zlib",
]);

const spdxExceptionIds = new Set([
  "Autoconf-exception-2.0",
  "Autoconf-exception-3.0",
  "Bison-exception-2.2",
  "Classpath-exception-2.0",
  "GCC-exception-2.0",
  "GCC-exception-3.1",
  "LLVM-exception",
  "OpenSSL-exception",
]);

function tokenizeSpdxExpression(expression) {
  const tokens = [];
  let index = 0;
  while (index < expression.length) {
    const char = expression[index];
    if (/\s/.test(char)) {
      index += 1;
      continue;
    }
    if (char === "(" || char === ")") {
      tokens.push(char);
      index += 1;
      continue;
    }
    const start = index;
    while (index < expression.length && !/\s|\(|\)/.test(expression[index])) {
      index += 1;
    }
    tokens.push(expression.slice(start, index));
  }
  return tokens;
}

function isSpdxLicenseReference(token) {
  return /^LicenseRef-[A-Za-z0-9.-]+$/.test(token)
    || /^DocumentRef-[A-Za-z0-9.-]+:LicenseRef-[A-Za-z0-9.-]+$/.test(token);
}

function isKnownSpdxLicense(token) {
  if (spdxLicenseIds.has(token) || isSpdxLicenseReference(token)) return true;
  if (token.endsWith("+")) return spdxLicenseIds.has(token.slice(0, -1));
  return false;
}

function isKnownSpdxException(token) {
  return spdxExceptionIds.has(token);
}

function makeSpdxParser(tokens) {
  let position = 0;

  function peek() {
    return tokens[position];
  }

  function take() {
    const token = tokens[position];
    position += 1;
    return token;
  }

  function parsePrimary() {
    const token = take();
    if (!token) return false;
    if (token === "(") {
      if (!parseExpression()) return false;
      return take() === ")";
    }
    if (token === ")" || token === "AND" || token === "OR" || token === "WITH") return false;
    if (!isKnownSpdxLicense(token)) return false;
    if (peek() === "WITH") {
      take();
      return isKnownSpdxException(take());
    }
    return true;
  }

  function parseAndExpression() {
    if (!parsePrimary()) return false;
    while (peek() === "AND") {
      take();
      if (!parsePrimary()) return false;
    }
    return true;
  }

  function parseExpression() {
    if (!parseAndExpression()) return false;
    while (peek() === "OR") {
      take();
      if (!parseAndExpression()) return false;
    }
    return true;
  }

  return {
    valid() {
      return parseExpression() && position === tokens.length;
    },
  };
}

function validSpdxExpression(expression) {
  if (expression.length > 300) return false;
  const tokens = tokenizeSpdxExpression(expression);
  if (!tokens.length) return false;
  return makeSpdxParser(tokens).valid();
}

function validatePublishPayload(payload) {
  const errors = [];
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    validationError("publish payload must be a JSON object", [
      { field: "body", message: "must be a JSON object" },
    ]);
  }

  let name = "";
  try {
    name = validatePackageName(payload.name);
  } catch (error) {
    errors.push({ field: "name", message: error.message });
  }

  const version = typeof payload.version === "string" ? payload.version.trim() : "";
  if (!version) {
    errors.push({ field: "version", message: "is required" });
  } else if (!parseSemver(version)) {
    errors.push({ field: "version", message: "must be valid SemVer, for example 1.2.3" });
  }

  const description = typeof payload.description === "string" ? payload.description.trim() : "";
  if (!description) errors.push({ field: "description", message: "is required" });

  const license = typeof payload.license === "string" ? payload.license.trim() : "";
  if (!license) {
    errors.push({ field: "license", message: "is required" });
  } else if (!validSpdxExpression(license)) {
    errors.push({ field: "license", message: "must be a valid SPDX license expression" });
  }

  if (typeof payload.archiveBase64 !== "string" || !payload.archiveBase64.trim()) {
    errors.push({ field: "archiveBase64", message: "is required" });
  }

  const dialects = normalizeStringList(payload.dialects, "dialects", errors);
  const features = normalizeStringList(payload.features, "features", errors);
  const featureDependencies = normalizeFeatureDependencies(payload.featureDependencies, errors);
  const keywords = normalizeKeywords(payload.keywords, errors);
  const dependencies = normalizeDependencies(payload.dependencies, errors);
  const libraries = normalizeLibraries(payload.libraries, errors);

  if (errors.length) validationError("publish payload validation failed", errors);
  return { name, version, description, license, dialects, features, featureDependencies, keywords, dependencies, libraries };
}

  return { normalizeDependencies, validatePublishPayload };
}
