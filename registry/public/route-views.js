import {
  chip,
  escapeAttr,
  escapeHtml,
} from "./shared.js";

export function libraryKey(name) {
  return String(name || "")
    .replace(/^\(/, "")
    .replace(/\)$/, "")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .join("/");
}

export function packageRoute(name) {
  return `#/pkg/${encodeURIComponent(name || "")}`;
}

export function libraryRoute(key) {
  return `#/lib/${encodeURIComponent(key || "")}`;
}

export function identifierRoute(name) {
  return `#/identifier/${encodeURIComponent(name || "")}`;
}

export function routeForTypedResult(item) {
  if (item.type === "library") return libraryRoute(item.key || item.name);
  if (item.type === "identifier") return identifierRoute(item.identifier || item.name);
  return packageRoute(item.package || item.name);
}

export function libraryTags(library) {
  const tags = [];
  const seen = new Set();
  const add = (value) => {
    const tag = String(value || "").trim();
    const key = tag.toLowerCase();
    if (!tag || seen.has(key)) return;
    seen.add(key);
    tags.push(tag);
  };

  const dialect = String(library?.dialect || "").trim();
  const implementation = String(library?.implementation || "").trim();
  add(dialect && implementation ? `${dialect}/${implementation}` : (dialect || library?.kind));
  if (String(library?.kind || "").trim().toLowerCase() !== dialect.toLowerCase()) add(library?.kind);
  return tags;
}

export function libraryPageHtml(data, routeKey) {
  const providers = data?.libraries || [];
  const title = providers[0]?.name || data?.key || routeKey || "library";
  return `
    <div class="card">
      <div class="card-body detail-view">
        <div class="detail-header">
          <div class="detail-title">
            <h1>${escapeHtml(title)}</h1>
            ${chip("library", "accent")}
          </div>
          <p class="detail-desc">Packages and versions that publish this library.</p>
        </div>

        <div class="detail-section">
          <h4>Providers</h4>
          ${providers.length
            ? `<div class="dependency-list">${providers.map(libraryProviderHtml).join("")}</div>`
            : `<div class="muted" style="font-size:0.88rem">No providers found for this library.</div>`}
        </div>
      </div>
    </div>
  `;
}

export function identifierPageHtml(data, routeName) {
  const identifier = data?.name || routeName || "identifier";
  const exporters = (data?.results || []).filter((item) => (
    String(item.identifier || item.name || "") === identifier
  ));
  return `
    <div class="card">
      <div class="card-body detail-view">
        <div class="detail-header">
          <div class="detail-title">
            <h1>${escapeHtml(identifier)}</h1>
            ${chip("identifier", "accent")}
          </div>
          <p class="detail-desc">Libraries and packages that export this identifier.</p>
        </div>

        <div class="detail-section">
          <h4>Exporters</h4>
          ${exporters.length
            ? `<div class="dependency-list">${exporters.map(identifierExporterHtml).join("")}</div>`
            : `<div class="muted" style="font-size:0.88rem">No exporters found for this identifier.</div>`}
        </div>
      </div>
    </div>
  `;
}

function libraryProviderHtml(provider) {
  const tags = libraryTags(provider);
  return `
    <div class="dependency-row">
      <a href="${packageRoute(provider.package)}" data-package-link="${escapeAttr(provider.package)}">${escapeHtml(provider.package)}</a>
      <span class="dependency-req">
        ${provider.version ? `v${escapeHtml(provider.version)}` : ""}
        ${tags.length ? ` · ${tags.map(escapeHtml).join(" · ")}` : ""}
      </span>
      ${provider.path ? `<span class="result-sub">${escapeHtml(provider.path)}</span>` : ""}
    </div>
  `;
}

function identifierExporterHtml(exporter) {
  const key = libraryKey(exporter.library || "");
  return `
    <div class="dependency-row">
      <a href="${libraryRoute(key)}" data-library-link="${escapeAttr(key)}">${escapeHtml(exporter.library || "")}</a>
      <span class="dependency-req">
        ${escapeHtml(exporter.package || "")}
        ${exporter.version ? ` · v${escapeHtml(exporter.version)}` : ""}
      </span>
      <a class="result-sub" href="${packageRoute(exporter.package || "")}" data-package-link="${escapeAttr(exporter.package || "")}">Open package</a>
    </div>
  `;
}
