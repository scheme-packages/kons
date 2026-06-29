import fs from "node:fs/promises";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

function ensureColumn(db, table, column, definition) {
  const found = db.prepare(`PRAGMA table_info(${table})`).all().some((row) => row.name === column);
  if (!found) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}

export async function openRegistryDatabase(config) {
  await fs.mkdir(config.dataDir, { recursive: true });
  await fs.mkdir(path.join(config.dataDir, "archives"), { recursive: true });
  await fs.mkdir(path.join(config.dataDir, "tmp"), { recursive: true });

  const db = new DatabaseSync(path.join(config.dataDir, "registry.sqlite"));
  db.exec(`
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  email TEXT UNIQUE,
  avatar_url TEXT NOT NULL DEFAULT '',
  is_admin INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS identities (
  provider TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  username TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  raw_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (provider, provider_id)
);
CREATE TABLE IF NOT EXISTS sessions (
  id_hash TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS api_tokens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  prefix TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT
);
CREATE TABLE IF NOT EXISTS packages (
  name TEXT PRIMARY KEY,
  description TEXT NOT NULL DEFAULT '',
  homepage TEXT NOT NULL DEFAULT '',
  repository TEXT NOT NULL DEFAULT '',
  documentation TEXT NOT NULL DEFAULT '',
  keywords_json TEXT NOT NULL DEFAULT '[]',
  created_by INTEGER NOT NULL REFERENCES users(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS package_owners (
  package_name TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'owner',
  created_at TEXT NOT NULL,
  PRIMARY KEY (package_name, user_id)
);
CREATE TABLE IF NOT EXISTS versions (
  package_name TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
  version TEXT NOT NULL,
  checksum TEXT NOT NULL,
  size INTEGER NOT NULL,
  archive_key TEXT NOT NULL,
  archive_filename TEXT NOT NULL,
  published_by INTEGER NOT NULL REFERENCES users(id),
  published_at TEXT NOT NULL,
  yanked INTEGER NOT NULL DEFAULT 0,
  yanked_at TEXT,
  yanked_by INTEGER REFERENCES users(id),
  description TEXT NOT NULL DEFAULT '',
  license TEXT NOT NULL DEFAULT '',
  dialects_json TEXT NOT NULL DEFAULT '[]',
  features_json TEXT NOT NULL DEFAULT '[]',
  feature_dependencies_json TEXT NOT NULL DEFAULT '[]',
  readme TEXT NOT NULL DEFAULT '',
  manifest_json TEXT NOT NULL DEFAULT '{}',
  download_count INTEGER NOT NULL DEFAULT 0,
  last_downloaded_at TEXT,
  PRIMARY KEY (package_name, version)
);
CREATE TABLE IF NOT EXISTS dependencies (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  dep_type TEXT NOT NULL DEFAULT 'registry',
  dep_name TEXT NOT NULL,
  dep_name_json TEXT NOT NULL DEFAULT '',
  req TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'normal',
  registry TEXT,
  source TEXT,
  optional INTEGER NOT NULL DEFAULT 0,
  target TEXT,
  schemes_json TEXT NOT NULL DEFAULT '[]',
  implementations_json TEXT NOT NULL DEFAULT '[]',
  dialects_json TEXT NOT NULL DEFAULT '[]',
  targets_json TEXT NOT NULL DEFAULT '[]',
  profiles_json TEXT NOT NULL DEFAULT '[]',
  compile_modes_json TEXT NOT NULL DEFAULT '[]',
  condition_json TEXT NOT NULL DEFAULT '#f',
  features_json TEXT NOT NULL DEFAULT '[]',
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS version_libraries (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  kind TEXT NOT NULL,
  library_name TEXT NOT NULL,
  library_key TEXT NOT NULL,
  path TEXT NOT NULL DEFAULT '',
  imports_json TEXT NOT NULL DEFAULT '[]',
  exports_json TEXT NOT NULL DEFAULT '[]',
  implementation TEXT NOT NULL DEFAULT '',
  dialect TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_version_libraries_key_kind ON version_libraries(library_key, kind);
CREATE INDEX IF NOT EXISTS idx_version_libraries_package_version ON version_libraries(package_name, version);
CREATE TABLE IF NOT EXISTS version_identifiers (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  kind TEXT NOT NULL,
  library_name TEXT NOT NULL,
  identifier TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'export',
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_version_identifiers_identifier ON version_identifiers(identifier);
CREATE INDEX IF NOT EXISTS idx_version_identifiers_package_version ON version_identifiers(package_name, version);
CREATE TABLE IF NOT EXISTS package_search_terms (
  package_name TEXT NOT NULL,
  version TEXT NOT NULL,
  term TEXT NOT NULL,
  field TEXT NOT NULL,
  FOREIGN KEY (package_name, version) REFERENCES versions(package_name, version) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_package_search_terms_term ON package_search_terms(term);
CREATE INDEX IF NOT EXISTS idx_package_search_terms_package_version ON package_search_terms(package_name, version);
CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action TEXT NOT NULL,
  package_name TEXT NOT NULL DEFAULT '',
  version TEXT NOT NULL DEFAULT '',
  actor_id INTEGER,
  actor_username TEXT NOT NULL DEFAULT '',
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_package ON audit_log(package_name, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action, created_at);
CREATE TRIGGER IF NOT EXISTS audit_log_no_update
BEFORE UPDATE ON audit_log
BEGIN
  SELECT RAISE(ABORT, 'audit_log is append-only');
END;
CREATE TRIGGER IF NOT EXISTS audit_log_no_delete
BEFORE DELETE ON audit_log
BEGIN
  SELECT RAISE(ABORT, 'audit_log is append-only');
END;
CREATE TABLE IF NOT EXISTS auth_states (
  state TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  return_to TEXT NOT NULL DEFAULT '/',
  email TEXT,
  username TEXT,
  code_hash TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
`);
  ensureColumn(db, "auth_states", "username", "TEXT");
  ensureColumn(db, "packages", "keywords_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "versions", "readme", "TEXT NOT NULL DEFAULT ''");
  ensureColumn(db, "versions", "feature_dependencies_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "versions", "download_count", "INTEGER NOT NULL DEFAULT 0");
  ensureColumn(db, "versions", "last_downloaded_at", "TEXT");
  ensureColumn(db, "dependencies", "dep_type", "TEXT NOT NULL DEFAULT 'registry'");
  ensureColumn(db, "dependencies", "dep_name_json", "TEXT NOT NULL DEFAULT ''");
  ensureColumn(db, "dependencies", "source", "TEXT");
  ensureColumn(db, "dependencies", "schemes_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "dependencies", "implementations_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "dependencies", "dialects_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "dependencies", "targets_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "dependencies", "profiles_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "dependencies", "compile_modes_json", "TEXT NOT NULL DEFAULT '[]'");
  ensureColumn(db, "dependencies", "condition_json", "TEXT NOT NULL DEFAULT '#f'");
  ensureColumn(db, "version_libraries", "implementation", "TEXT NOT NULL DEFAULT ''");
  ensureColumn(db, "version_libraries", "dialect", "TEXT NOT NULL DEFAULT ''");
  return db;
}
