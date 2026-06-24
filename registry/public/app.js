import {
  $,
  api,
  applyRegistryChrome,
  avatarHtml,
  bindCopyButtons,
  bindThemeToggle,
  chip,
  encodeURIComponentName,
  escapeAttr,
  escapeHtml,
  fetchMe,
  formatBytes,
  formatDate,
  icon,
  initTheme,
  majorMinor,
  renderUserPill,
  renderRegistryMessages,
  skeletonRows,
  showToast,
  timeAgo,
} from "./shared.js";
import {
  identifierPageHtml,
  libraryTags,
  libraryPageHtml,
  libraryRoute,
  routeForTypedResult,
} from "./route-views.js";

function urlHost(value) {
  try {
    return new URL(value).host;
  } catch {
    return value || "";
  }
}

const state = {
  meta: null,
  user: null,
  packages: [],
  results: [],
  total: 0,
  route: null,
  current: null,
  currentDependents: [],
  currentLibrary: null,
  currentIdentifier: null,
};

init();

async function init() {
  initTheme();
  bindThemeToggle();
  bindEvents();
  await Promise.all([loadMeta(), loadMe()]);
  handleRoute();
  await search();
}

function bindEvents() {
  $("search-input").addEventListener("input", debounce(search, 200));
  $("search-input").addEventListener("keydown", (event) => {
    if (event.key === "Enter") search();
  });
  $("search-type").addEventListener("change", search);
  $("refresh-button").addEventListener("click", refreshCurrent);
  window.addEventListener("hashchange", handleRoute);
}

function debounce(fn, wait) {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
}

async function loadMeta() {
  state.meta = await api("/api/v1/meta");
  const meta = state.meta;
  applyRegistryChrome(meta);
  renderRegistryMessages(meta.messages);
  const label = meta.storage === "local" ? "Local registry" : `${meta.storage} registry`;
  $("registry-meta").textContent = [label, urlHost(meta.baseUrl)].filter(Boolean).join(" · ");
}

async function loadMe() {
  state.user = await fetchMe();
  renderUserPill(state.user);
}

function handleRoute() {
  const hash = location.hash.replace(/^#\/?/, "");
  const packageMatch = hash.match(/^pkg\/(.+)$/);
  const libraryMatch = hash.match(/^lib\/(.+)$/);
  const identifierMatch = hash.match(/^identifier\/(.+)$/);
  if (packageMatch) {
    const name = decodeURIComponent(packageMatch[1]);
    state.route = { view: "detail", name };
    showView("detail");
    loadDetail(name);
  } else if (libraryMatch) {
    const key = decodeURIComponent(libraryMatch[1]);
    state.route = { view: "library", key };
    showView("detail");
    loadLibraryPage(key);
  } else if (identifierMatch) {
    const name = decodeURIComponent(identifierMatch[1]);
    state.route = { view: "identifier", name };
    showView("detail");
    loadIdentifierPage(name);
  } else {
    state.route = { view: "home" };
    showView("home");
  }
}

function showView(view) {
  $("home-view").classList.toggle("hidden", view !== "home");
  $("detail-view").classList.toggle("hidden", view !== "detail");
}

async function search() {
  const list = $("results");
  const q = $("search-input").value.trim();
  const type = $("search-type").value || "package";
  list.innerHTML = skeletonRows(5);
  $("result-count").textContent = "Searching…";
  try {
    const query = encodeURIComponent(q);
    const data = await api(`/api/v1/search?q=${query}&type=${encodeURIComponent(type)}`);
    state.packages = data.packages;
    state.results = data.results || [];
    state.total = data.total;
    renderResults();
  } catch (error) {
    $("result-count").textContent = "";
    list.innerHTML = errorStateHtml(`Could not reach registry: ${error.message}`, "retry-search");
    document.getElementById("retry-search")?.addEventListener("click", search);
  }
}

function renderResults() {
  const results = $("results");
  const type = $("search-type").value || "package";
  const typedResults = type === "package" ? [] : state.results;
  const count = type === "package" ? state.total : typedResults.length;
  $("result-count").innerHTML = `<strong>${count}</strong> ${resultTypeLabel(type, count)}`;
  if (type !== "package") {
    if (!typedResults.length) {
      results.innerHTML = emptyPackagesHtml();
      return;
    }
    results.innerHTML = typedResults.map(typedResultRowHtml).join("");
    bindTypedResultRows(results);
    return;
  }
  if (!state.packages.length) {
    results.innerHTML = emptyPackagesHtml();
    return;
  }
  results.innerHTML = state.packages.map(resultRowHtml).join("");
  results.querySelectorAll("[data-pkg]").forEach((row) => {
    row.addEventListener("click", () => {
      location.hash = `#/pkg/${encodeURIComponent(row.dataset.pkg)}`;
    });
  });
}

function resultTypeLabel(type, count) {
  const labels = {
    library: ["library result", "library results"],
    identifier: ["identifier result", "identifier results"],
    all: ["result", "results"],
    package: ["package", "packages"],
  };
  const pair = labels[type] || labels.package;
  return count === 1 ? pair[0] : pair[1];
}

function typedResultRowHtml(item) {
  if (item.type === "package") {
    return `
      <button class="result-row" type="button" data-route="${escapeAttr(routeForTypedResult(item))}">
        <span class="result-main">
          <span class="result-top">
            <span class="result-name">${packagePathHtml(item.package || item.name)}</span>
            <span class="version-badge">${item.version ? `v${escapeHtml(item.version)}` : "package"}</span>
          </span>
          <span class="result-desc">${escapeHtml(item.description || "No description")}</span>
        </span>
      </button>
    `;
  }
  if (item.type === "library") {
    return `
      <button class="result-row" type="button" data-route="${escapeAttr(routeForTypedResult(item))}">
        <span class="result-main">
          <span class="result-top">
            <span class="result-name">${escapeHtml(item.name)}</span>
            <span class="version-badge">${escapeHtml(item.kind || "library")}</span>
          </span>
          <span class="result-desc">Provided by ${escapeHtml(item.package)}${item.version ? ` v${escapeHtml(item.version)}` : ""}</span>
          <span class="result-sub">${escapeHtml(item.description || "")}</span>
        </span>
      </button>
    `;
  }
  if (item.type === "identifier") {
    return `
      <button class="result-row" type="button" data-route="${escapeAttr(routeForTypedResult(item))}">
        <span class="result-main">
          <span class="result-top">
            <span class="result-name">${escapeHtml(item.identifier || item.name)}</span>
            <span class="version-badge">identifier</span>
          </span>
          <span class="result-desc">${escapeHtml(item.library || "")}</span>
          <span class="result-sub">Exported by ${escapeHtml(item.package)}${item.version ? ` v${escapeHtml(item.version)}` : ""}</span>
        </span>
      </button>
    `;
  }
  return "";
}

function bindTypedResultRows(results) {
  results.querySelectorAll("[data-route]").forEach((row) => {
    row.addEventListener("click", () => {
      location.hash = row.dataset.route;
    });
  });
}

function resultRowHtml(pkg) {
  const latest = pkg.latest;
  const version = latest ? escapeHtml(latest.version) : "—";
  const updated = timeAgo(pkg.updatedAt);
  const dialects = latest?.dialects?.length ? latest.dialects.slice(0, 2).map(escapeHtml).join(" · ") : "";
  const dependencyCount = latest?.dependencies?.length || 0;
  const downloads = Number(pkg.downloads || 0);
  const yanked = latest?.yanked ? chip("yanked", "warning") : "";
  const meta = [
    dialects,
    updated,
    countLabel(dependencyCount, "dep"),
    countLabel(downloads, "download"),
  ].filter(Boolean).join(" · ");
  return `
    <button class="result-row" type="button" data-pkg="${escapeAttr(pkg.name)}">
      <span class="result-main">
        <span class="result-top">
          <span class="result-name" title="Scheme name: ${escapeAttr(schemeName(pkg.name))}">${packagePathHtml(pkg.name)}</span>
          <span class="version-badge">${version}</span>
        </span>
        <span class="result-desc">${escapeHtml(pkg.description || "No description")}</span>
        <span class="result-sub">${meta}</span>
      </span>
      <span class="result-meta">
        ${ownerSummaryHtml(pkg.owners || [])}
        ${yanked}
      </span>
    </button>
  `;
}

function packagePathHtml(name) {
  return String(name || "")
    .split("/")
    .map((part) => `<span>${escapeHtml(part)}</span>`)
    .join(`<span class="result-path-separator">/</span>`);
}

function schemeName(name) {
  const parts = String(name || "").split("/").filter(Boolean);
  return parts.length ? `(${parts.join(" ")})` : "()";
}

function ownerSummaryHtml(owners) {
  const list = Array.isArray(owners) ? owners : [];
  if (!list.length) return `<span class="result-owner-pill">No owner</span>`;
  const shown = list.slice(0, 2);
  const names = shown.map((owner) => owner.displayName || owner.username).filter(Boolean);
  const extra = list.length - shown.length;
  const label = `${names.join(", ")}${extra > 0 ? ` +${extra}` : ""}`;
  const title = `Owners: ${list.map((owner) => owner.displayName || owner.username).filter(Boolean).join(", ")}`;
  return `
    <span class="result-owner-pill" title="${escapeAttr(title)}">
      ${shown.map((owner) => avatarHtml(owner, 20)).join("")}
      <span>${escapeHtml(label)}</span>
    </span>
  `;
}

function countLabel(value, singular) {
  const count = Number(value || 0);
  const label = count === 1 ? singular : `${singular}s`;
  return `${new Intl.NumberFormat().format(count)} ${label}`;
}

function emptyPackagesHtml() {
  const q = $("search-input").value.trim();
  const title = q ? `No packages match "${q}"` : "No packages yet";
  const text = q
    ? "Try a different search term, or check the index config."
    : "Published packages will appear here once you publish one.";
  return `
    <div class="empty">
      <span class="empty-icon">${icon("package")}</span>
      <span class="empty-title">${escapeHtml(title)}</span>
      <span>${escapeHtml(text)}</span>
    </div>
  `;
}

function errorStateHtml(message, retryId) {
  return `
    <div class="error-state">
      <span>${icon("warning")}</span>
      <span>${escapeHtml(message)}</span>
      <button class="btn btn-subtle btn-sm" type="button" id="${retryId}">Retry</button>
    </div>
  `;
}

async function loadDetail(name) {
  const detail = $("package-detail");
  detail.innerHTML = skeletonRows(3);
  try {
    const [data, dependents] = await Promise.all([
      api(`/api/v1/packages/${encodeURIComponentName(name)}`),
      api(`/api/v1/packages/${encodeURIComponentName(name)}/dependents`),
    ]);
    state.current = data.package;
    state.currentDependents = dependents.dependents || [];
    renderPackageDetail();
  } catch (error) {
    state.current = null;
    state.currentDependents = [];
    detail.innerHTML = `
      <div class="error-state">
        <span>${icon("warning")}</span>
        <span>${escapeHtml(error.message)}</span>
        <a class="btn btn-subtle btn-sm" href="#/">Back to packages</a>
      </div>
    `;
  }
}

async function loadLibraryPage(key) {
  const detail = $("package-detail");
  detail.innerHTML = skeletonRows(3);
  try {
    const data = await api(`/api/v1/libraries/${encodeURIComponent(key)}`);
    state.currentLibrary = data;
    renderLibraryPage();
  } catch (error) {
    state.currentLibrary = null;
    detail.innerHTML = errorDetailHtml(error.message);
  }
}

async function loadIdentifierPage(name) {
  const detail = $("package-detail");
  detail.innerHTML = skeletonRows(3);
  try {
    const data = await api(`/api/v1/identifiers?q=${encodeURIComponent(name)}`);
    state.currentIdentifier = { name, results: data.identifiers || [] };
    renderIdentifierPage();
  } catch (error) {
    state.currentIdentifier = null;
    detail.innerHTML = errorDetailHtml(error.message);
  }
}

function errorDetailHtml(message) {
  return `
    <div class="error-state">
      <span>${icon("warning")}</span>
      <span>${escapeHtml(message)}</span>
      <a class="btn btn-subtle btn-sm" href="#/">Back to packages</a>
    </div>
  `;
}

async function refreshCurrent() {
  if (state.route?.view === "detail" && state.current) {
    await loadDetail(state.current.name);
    showToast("Package refreshed");
  } else if (state.route?.view === "library") {
    await loadLibraryPage(state.route.key);
    showToast("Library refreshed");
  } else if (state.route?.view === "identifier") {
    await loadIdentifierPage(state.route.name);
    showToast("Identifier refreshed");
  } else {
    await search();
  }
}

function renderPackageDetail() {
  const detail = $("package-detail");
  const pkg = state.current;
  if (!pkg) {
    detail.innerHTML = `<div class="empty"><span class="empty-icon">${icon("package")}</span><span class="empty-title">Select a package.</span></div>`;
    return;
  }

  const latest = pkg.latest;
  const latestVersion = latest?.version || "";
  const majorMin = latestVersion ? majorMinor(latestVersion) : "";
  const addCommand = latestVersion ? `kons add ${pkg.name} --version ^${majorMin}` : `kons add ${pkg.name}`;
  const exactCommand = latestVersion ? `kons add ${pkg.name} --version =${latestVersion}` : `kons add ${pkg.name}`;
  const indexCommand = `kons registry index ${state.meta?.baseUrl || ""}/index/config.json`;
  const latestDeps = latest?.dependencies || [];
  const latestLibraries = latest?.libraries || [];
  const dependents = state.currentDependents || [];
  const totalDownloads = Number(pkg.downloads || 0);

  const dialectChips = (latest?.dialects || []).map((d) => chip(d, "muted")).join("");
  const keywordChips = (pkg.keywords || []).map((k) => chip(k, "muted")).join("");
  const latestChip = latestVersion ? chip(`latest ${latestVersion}`, "accent") : "";

  const links = [
    pkg.repository || pkg.repo ? `<a class="btn btn-subtle btn-sm" href="${escapeAttr(pkg.repository || pkg.repo)}" target="_blank" rel="noopener">${icon("link")} Repo</a>` : "",
    pkg.homepage || pkg.site ? `<a class="btn btn-subtle btn-sm" href="${escapeAttr(pkg.homepage || pkg.site)}" target="_blank" rel="noopener">${icon("link")} Site</a>` : "",
    pkg.documentation || pkg.docs ? `<a class="btn btn-subtle btn-sm" href="${escapeAttr(pkg.documentation || pkg.docs)}" target="_blank" rel="noopener">${icon("link")} Docs</a>` : "",
  ].filter(Boolean).join("");
  const readme = pkg.readme || latest?.readme || "";

  detail.innerHTML = `
    <div class="card">
      <div class="card-body detail-view">
        <div class="detail-header">
          <div class="detail-title">
            <h1>${escapeHtml(pkg.name)}</h1>
            ${latestChip}
            ${latest?.yanked ? chip("latest yanked", "warning") : ""}
          </div>
          <p class="detail-desc">${escapeHtml(pkg.description || "No description")}</p>
          <div class="chip-row">${dialectChips}${keywordChips}${latest?.license ? chip(latest.license, "muted") : ""}</div>
          <div class="detail-actions">
            ${links}
          </div>
        </div>

        <div class="detail-grid">
          <div class="detail-section">
            <h4>Install</h4>
            <div class="install-tabs">
              ${copyLineHtml("Compatible", addCommand)}
              ${copyLineHtml("Exact", exactCommand)}
              ${copyLineHtml("Index", indexCommand)}
            </div>
          </div>

          <div class="detail-section">
            <h4>Owners</h4>
            ${ownersHtml(pkg.owners)}
          </div>

          <div class="detail-section">
            <h4>Dependencies <span class="muted" style="text-transform:none;font-weight:400">(${latestVersion || "none"})</span></h4>
            <div class="dependency-list">
              ${latestDeps.length ? latestDeps.map(dependencyHtml).join("") : `<div class="muted" style="font-size:0.88rem">No dependencies for the latest version.</div>`}
            </div>
          </div>

          <div class="detail-section">
            <h4>Dependents</h4>
            <div class="dependency-list">
              ${dependents.length ? dependents.slice(0, 12).map(dependentHtml).join("") : `<div class="muted" style="font-size:0.88rem">No packages depend on this package yet.</div>`}
            </div>
          </div>

          <div class="detail-section">
            <h4>Metadata</h4>
            <div class="meta-list">
              ${metaRow("Versions", String(pkg.versions.length))}
              ${metaRow("Downloads", countLabel(totalDownloads, "download"))}
              ${metaRow("Scheme name", `<code>${escapeHtml(schemeName(pkg.name))}</code>`)}
              ${metaRow("Created", formatDate(pkg.createdAt) || "—")}
              ${metaRow("Updated", formatDate(pkg.updatedAt) || "—")}
              ${metaRow("Index path", `<code>${escapeHtml(pkg.indexPath)}</code>`)}
              ${metaRow("Signature status", signatureStatusHtml(pkg))}
              ${signedMetadata(pkg) && pkg.trust?.alg ? metaRow("Signing algorithm", `<code>${escapeHtml(pkg.trust.alg)}</code>`) : ""}
              ${signedMetadata(pkg) && pkg.trust?.keyId ? metaRow("Signing key", `<code>${escapeHtml(pkg.trust.keyId)}</code>`) : ""}
              ${latest?.checksum ? metaRow("Latest checksum", checksumHtml(latest.checksum)) : ""}
              ${latest?.publishedBy?.username ? metaRow("Latest published by", escapeHtml(latest.publishedBy.username)) : ""}
            </div>
          </div>
        </div>

        <div class="detail-section">
          <h4>Libraries</h4>
          ${latestLibraries.length ? `<div class="library-list">${latestLibraries.map(libraryHtml).join("")}</div>` : `<div class="muted" style="font-size:0.88rem">No library metadata published for the latest version.</div>`}
        </div>

        <div class="detail-section">
          <h4>README</h4>
          ${readme ? `<article class="readme-body">${renderMarkdown(readme)}</article>` : `<div class="muted" style="font-size:0.88rem">No README published for the latest version.</div>`}
        </div>

        <div class="detail-section">
          <h4>Versions</h4>
          <div class="timeline">
            ${pkg.versions.map((version) => versionHtml(pkg, version)).join("")}
          </div>
        </div>
      </div>
    </div>
  `;

  bindCopyButtons(detail);
  detail.querySelectorAll("[data-yank]").forEach((button) => {
    button.addEventListener("click", () => yank(pkg.name, button.dataset.yank, false));
  });
  detail.querySelectorAll("[data-unyank]").forEach((button) => {
    button.addEventListener("click", () => yank(pkg.name, button.dataset.unyank, true));
  });
  detail.querySelectorAll("[data-dependency]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      location.hash = `#/pkg/${encodeURIComponent(link.dataset.dependency)}`;
    });
  });
}

function renderLibraryPage() {
  const detail = $("package-detail");
  const data = state.currentLibrary || {};
  detail.innerHTML = libraryPageHtml(data, state.route?.key);
  bindPackageLinks(detail);
}

function renderIdentifierPage() {
  const detail = $("package-detail");
  const data = state.currentIdentifier || {};
  detail.innerHTML = identifierPageHtml(data, state.route?.name);
  bindPackageLinks(detail);
  bindLibraryLinks(detail);
}

function bindPackageLinks(root) {
  root.querySelectorAll("[data-package-link]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      location.hash = `#/pkg/${encodeURIComponent(link.dataset.packageLink)}`;
    });
  });
}

function bindLibraryLinks(root) {
  root.querySelectorAll("[data-library-link]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      location.hash = libraryRoute(link.dataset.libraryLink);
    });
  });
}

function safeHref(value) {
  const href = String(value || "").trim();
  if (/^(https?:|mailto:|#|\/)/i.test(href)) return href;
  return "#";
}

function renderInlineMarkdown(value) {
  return escapeHtml(value)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_match, label, href) => (
      `<a href="${escapeAttr(safeHref(href))}" target="_blank" rel="noopener">${label}</a>`
    ));
}

function renderMarkdown(markdown) {
  const lines = String(markdown || "").replace(/\r\n?/g, "\n").split("\n");
  const html = [];
  let paragraph = [];
  let list = [];
  let inCode = false;
  let code = [];

  const flushParagraph = () => {
    if (!paragraph.length) return;
    html.push(`<p>${renderInlineMarkdown(paragraph.join(" "))}</p>`);
    paragraph = [];
  };
  const flushList = () => {
    if (!list.length) return;
    html.push(`<ul>${list.map((item) => `<li>${renderInlineMarkdown(item)}</li>`).join("")}</ul>`);
    list = [];
  };
  const flushCode = () => {
    html.push(`<pre><code>${escapeHtml(code.join("\n"))}</code></pre>`);
    code = [];
  };

  for (const line of lines) {
    if (line.trim().startsWith("```")) {
      if (inCode) flushCode();
      else {
        flushParagraph();
        flushList();
      }
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      code.push(line);
      continue;
    }

    const heading = line.match(/^(#{1,3})\s+(.+)$/);
    const bullet = line.match(/^\s*[-*]\s+(.+)$/);
    if (!line.trim()) {
      flushParagraph();
      flushList();
    } else if (heading) {
      flushParagraph();
      flushList();
      html.push(`<h${heading[1].length}>${renderInlineMarkdown(heading[2].trim())}</h${heading[1].length}>`);
    } else if (bullet) {
      flushParagraph();
      list.push(bullet[1].trim());
    } else {
      flushList();
      paragraph.push(line.trim());
    }
  }
  if (inCode) flushCode();
  flushParagraph();
  flushList();
  return html.join("");
}

function copyLineHtml(label, command) {
  return `
    <div>
      <div class="muted" style="font-size:0.78rem;margin-bottom:0.3rem">${escapeHtml(label)}</div>
      <div class="copy-line">
        <code class="code-block">${escapeHtml(command)}</code>
        <button class="btn btn-subtle btn-sm" type="button" data-copy="${escapeAttr(command)}">${icon("copy")}<span>Copy</span></button>
      </div>
    </div>
  `;
}

function metaRow(key, value) {
  return `<div class="meta-row"><span class="meta-key">${escapeHtml(key)}</span><span class="meta-val">${value}</span></div>`;
}

function signedMetadata(pkg) {
  const trust = pkg.trust || {};
  return Boolean(trust.signedMetadata);
}

function signatureStatusHtml(pkg) {
  return signedMetadata(pkg) ? "Signed metadata" : "Unsigned metadata";
}

function signatureDetailHtml(pkg) {
  const trust = pkg.trust || {};
  if (!trust.signedMetadata) return "signature unsigned";
  if (trust.keyId) return `signature <code>${escapeHtml(trust.keyId)}</code>`;
  if (trust.alg) return `signature <code>${escapeHtml(trust.alg)}</code>`;
  return "signature signed";
}

function checksumHtml(checksum) {
  return `<code>${escapeHtml(String(checksum))}</code>`;
}

function ownersHtml(owners) {
  if (!owners.length) return `<div class="muted" style="font-size:0.88rem">No owners</div>`;
  return `<div class="owner-list">${owners.map((owner) => `
    <span class="owner-chip">
      ${avatarHtml(owner)}
      <span class="owner-name">${escapeHtml(owner.displayName || owner.username)}</span>
      <span class="owner-handle">@${escapeHtml(owner.username)}</span>
    </span>
  `).join("")}</div>`;
}

function versionHtml(pkg, version) {
  const download = `/api/v1/packages/${encodeURIComponentName(pkg.name)}/${encodeURIComponent(version.version)}/download`;
  const statusChip = version.yanked ? chip("yanked", "danger") : chip("active", "success");
  const checksum = version.checksum || "";
  const checksumSummary = checksum ? String(checksum).slice(0, 16) : "no-checksum";
  const publisher = version.publishedBy?.username || "";
  const actions = `
    <div class="version-actions">
      <a class="btn btn-subtle btn-sm" href="${download}">${icon("download")} Download</a>
      ${pkg.canManage && !version.yanked ? `<button class="btn btn-danger btn-sm" type="button" data-yank="${escapeAttr(version.version)}">${icon("yank")} Yank</button>` : ""}
      ${pkg.canManage && version.yanked ? `<button class="btn btn-subtle btn-sm" type="button" data-unyank="${escapeAttr(version.version)}">${icon("refresh")} Unyank</button>` : ""}
    </div>
  `;
  return `
    <div class="version-row${version.yanked ? " is-yanked" : ""}">
      <span class="version-dot" aria-hidden="true"></span>
      <div class="version-body">
        <div class="version-top">
          <strong>${escapeHtml(version.version)}</strong>
          ${statusChip}
        </div>
        <div class="version-sub">
          <span>${formatDate(version.publishedAt)}</span>
          <span>${escapeHtml(version.license || "unlicensed")}</span>
          <span>${countLabel(version.downloads || 0, "download")}</span>
          <span>${formatBytes(version.size)}</span>
          <code>${escapeHtml(checksumSummary)}${checksum ? "…" : ""}</code>
        </div>
        <div class="version-meta">
          ${checksum ? `<span>checksum ${checksumHtml(checksum)}</span>` : `<span>checksum unavailable</span>`}
          <span>${signatureDetailHtml(pkg)}</span>
          ${publisher ? `<span>published by <code>${escapeHtml(publisher)}</code></span>` : ""}
        </div>
      </div>
      ${actions}
    </div>
  `;
}

function dependencyHtml(dep) {
  return `
    <div class="dependency-row">
      <a href="#/pkg/${encodeURIComponent(dep.name)}" data-dependency="${escapeAttr(dep.name)}">${escapeHtml(dep.name)}</a>
      <span class="dependency-req">${escapeHtml(dep.req || "*")}${dep.kind && dep.kind !== "normal" ? ` · ${escapeHtml(dep.kind)}` : ""}</span>
    </div>
  `;
}

function dependentHtml(dep) {
  return `
    <div class="dependency-row">
      <a href="#/pkg/${encodeURIComponent(dep.package)}" data-dependency="${escapeAttr(dep.package)}">${escapeHtml(dep.package)}</a>
      <span class="dependency-req">${escapeHtml(dep.req || "*")}${dep.version ? ` · v${escapeHtml(dep.version)}` : ""}</span>
    </div>
  `;
}

function libraryMetaHtml(label, values, total) {
  if (!values.length) return "";
  const remaining = Math.max(0, total - values.length);
  return `
    <div class="library-meta">
      <span class="library-meta-label">${escapeHtml(label)}</span>
      <span class="library-token-list">
        ${values.map((item) => `<code>${escapeHtml(item)}</code>`).join("")}
        ${remaining ? `<span class="library-more">+${remaining} more</span>` : ""}
      </span>
    </div>
  `;
}

function libraryHtml(library) {
  const exportValues = library.exports || [];
  const importValues = (library.imports || []).map((name) => Array.isArray(name) ? `(${name.join(" ")})` : String(name));
  const exports = exportValues.slice(0, 24);
  const imports = importValues.slice(0, 8);
  const tags = libraryTags(library);
  return `
    <div class="library-row">
      <div class="library-head">
        <div class="library-title">
          <strong>${escapeHtml(library.name)}</strong>
          ${library.path ? `<span class="library-path">${escapeHtml(library.path)}</span>` : ""}
        </div>
        <div class="library-tags">${tags.map((tag) => chip(tag, "muted")).join("")}</div>
      </div>
      ${libraryMetaHtml("exports", exports, exportValues.length)}
      ${libraryMetaHtml("imports", imports, importValues.length)}
    </div>
  `;
}

async function yank(name, version, unyank) {
  if (!state.user) {
    showToast("Sign in on the account page to yank versions", "warning");
    return;
  }
  const method = unyank ? "PUT" : "DELETE";
  const action = unyank ? "unyank" : "yank";
  try {
    await api(`/api/v1/packages/${encodeURIComponentName(name)}/${encodeURIComponent(version)}/${action}`, { method });
    await loadDetail(name);
    showToast(unyank ? "Version unyanked" : "Version yanked");
  } catch (error) {
    showToast(error.message, "danger");
  }
}
