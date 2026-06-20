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

const state = {
  meta: null,
  user: null,
  packages: [],
  total: 0,
  route: null,
  current: null,
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
  const host = (() => {
    try {
      return new URL(meta.baseUrl).host;
    } catch {
      return meta.baseUrl || "";
    }
  })();
  const label = meta.storage === "local" ? "Local registry" : `${meta.storage} registry`;
  $("registry-meta").textContent = [label, host].filter(Boolean).join(" · ");
}

async function loadMe() {
  state.user = await fetchMe();
  renderUserPill(state.user);
}

function handleRoute() {
  const hash = location.hash.replace(/^#\/?/, "");
  const match = hash.match(/^pkg\/(.+)$/);
  if (match) {
    const name = decodeURIComponent(match[1]);
    state.route = { view: "detail", name };
    showView("detail");
    loadDetail(name);
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
  list.innerHTML = skeletonRows(5);
  $("result-count").textContent = "Searching…";
  try {
    const query = encodeURIComponent(q);
    const data = await api(`/api/v1/search?q=${query}`);
    state.packages = data.packages;
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
  $("result-count").innerHTML = `<strong>${state.total}</strong> package${state.total === 1 ? "" : "s"}`;
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
    const data = await api(`/api/v1/packages/${encodeURIComponentName(name)}`);
    state.current = data.package;
    renderPackageDetail();
  } catch (error) {
    state.current = null;
    detail.innerHTML = `
      <div class="error-state">
        <span>${icon("warning")}</span>
        <span>${escapeHtml(error.message)}</span>
        <a class="btn btn-subtle btn-sm" href="#/">Back to packages</a>
      </div>
    `;
  }
}

async function refreshCurrent() {
  if (state.route?.view === "detail" && state.current) {
    await loadDetail(state.current.name);
    showToast("Package refreshed");
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
            <h4>Metadata</h4>
            <div class="meta-list">
              ${metaRow("Versions", String(pkg.versions.length))}
              ${metaRow("Downloads", countLabel(totalDownloads, "download"))}
              ${metaRow("Scheme name", `<code>${escapeHtml(schemeName(pkg.name))}</code>`)}
              ${metaRow("Created", formatDate(pkg.createdAt) || "—")}
              ${metaRow("Updated", formatDate(pkg.updatedAt) || "—")}
              ${metaRow("Index path", `<code>${escapeHtml(pkg.indexPath)}</code>`)}
            </div>
          </div>
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
          <code>${escapeHtml(String(version.checksum || "").slice(0, 16))}…</code>
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
