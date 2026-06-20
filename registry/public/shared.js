export const $ = (id) => document.getElementById(id);

const TOAST_TIMEOUT = 2200;
let toastTimer = null;

const ICONS = {
  search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.2-3.2"/></svg>',
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12 5 5 9-11"/></svg>',
  sun: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
  moon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8Z"/></svg>',
  package: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m12 2 9 5v10l-9 5-9-5V7z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 12v10"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg>',
  yank: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M9 9l6 6M15 9l-6 6"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M6 6l1 14a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-14"/></svg>',
  arrowLeft: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 12H5"/><path d="m12 19-7-7 7-7"/></svg>',
  link: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1"/><path d="M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/></svg>',
  warning: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3 2 20h20L12 3z"/><path d="M12 9v5M12 17.5v.5"/></svg>',
  info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 7.5v.5"/></svg>',
  logout: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5M21 12H9"/></svg>',
  key: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="8" cy="15" r="4"/><path d="m10.8 12.2 8.2-8.2M16 4l3 3M14 6l3 3"/></svg>',
  upload: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 15V3"/><path d="m7 8 5-5 5 5"/><path d="M5 21h14"/></svg>',
  refresh: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/></svg>',
  user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>',
  github: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2C6.5 2 2 6.6 2 12.3c0 4.5 2.9 8.3 6.8 9.7.5.1.7-.2.7-.5v-1.7c-2.8.6-3.4-1.4-3.4-1.4-.5-1.2-1.1-1.5-1.1-1.5-.9-.6.1-.6.1-.6 1 .1 1.5 1.1 1.5 1.1.9 1.6 2.4 1.1 3 .9.1-.7.3-1.1.6-1.4-2.2-.3-4.6-1.1-4.6-5 0-1.1.4-2 1-2.7-.1-.3-.5-1.3.1-2.7 0 0 .8-.3 2.7 1a9.4 9.4 0 0 1 5 0c1.9-1.3 2.7-1 2.7-1 .6 1.4.2 2.4.1 2.7.6.7 1 1.6 1 2.7 0 3.9-2.3 4.7-4.6 5 .4.3.7.9.7 1.9v2.8c0 .3.2.6.7.5 3.9-1.4 6.8-5.2 6.8-9.7C22 6.6 17.5 2 12 2Z"/></svg>',
  google: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 11v3.2h5.3c-.2 1.3-1.6 3.8-5.3 3.8-3.2 0-5.8-2.6-5.8-5.9S8.8 6.2 12 6.2c1.8 0 3 .8 3.7 1.4l2.5-2.4C16.6 3.7 14.5 2.8 12 2.8 6.9 2.8 2.8 6.9 2.8 12s4.1 9.2 9.2 9.2c5.3 0 8.8-3.7 8.8-9 0-.6-.1-1-.2-1.5H12Z" fill="#4285F4"/></svg>',
  codeberg: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 4.3L20 18.5H4L12 6.3Zm-.7 5 1.5 2.6-3.1 4.3h5.7l-.8 1.2H7.2l4.1-8.1Z"/></svg>',
  discord: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M19.6 5.3A16.9 16.9 0 0 0 15.4 4l-.2.4a13 13 0 0 1 3.7 1.2c-3.9-1.8-8.5-1.8-12.4 0A13 13 0 0 1 10.2 4.4L10 4a16.9 16.9 0 0 0-4.2 1.3C3 9 2.3 12.6 2.6 16.2A17 17 0 0 0 7.8 19l.5-.7c-.7-.3-1.4-.6-2-1l.5-.4a12 12 0 0 0 10.4 0l.5.4c-.6.4-1.3.7-2 1l.5.7a17 17 0 0 0 5.2-2.8c.4-4.2-.6-7.8-2.8-10.9ZM9 14.3c-.8 0-1.5-.8-1.5-1.7s.7-1.7 1.5-1.7 1.5.8 1.5 1.7-.7 1.7-1.5 1.7Zm6 0c-.8 0-1.5-.8-1.5-1.7s.7-1.7 1.5-1.7 1.5.8 1.5 1.7-.7 1.7-1.5 1.7Z"/></svg>',
};

export function icon(name) {
  return ICONS[name] || "";
}

export function iconButton(name, label, attrs = "") {
  return `<button class="btn btn-icon" type="button" aria-label="${escapeAttr(label)}" title="${escapeAttr(label)}" ${attrs}>${icon(name)}</button>`;
}

export function initTheme() {
  const stored = localStorage.getItem("kons-theme");
  const theme = stored || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  applyTheme(theme);
}

export function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  const toggle = $("theme-toggle");
  if (toggle) {
    toggle.setAttribute("aria-pressed", String(theme === "dark"));
    toggle.innerHTML = icon(theme === "dark" ? "sun" : "moon");
  }
}

export function currentTheme() {
  return document.documentElement.dataset.theme === "dark" ? "dark" : "light";
}

export function bindThemeToggle() {
  const toggle = $("theme-toggle");
  if (!toggle) return;
  toggle.addEventListener("click", () => {
    const next = currentTheme() === "dark" ? "light" : "dark";
    applyTheme(next);
    localStorage.setItem("kons-theme", next);
  });
}

export function showToast(message, kind = "success") {
  const toast = $("toast");
  if (!toast) return;
  const glyph = kind === "warning" ? icon("warning") : kind === "danger" ? icon("warning") : icon("check");
  toast.innerHTML = `<span class="toast-icon">${glyph}</span><span>${escapeHtml(message)}</span>`;
  toast.className = `toast toast-${kind}`;
  toast.classList.toggle("is-visible", true);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.classList.remove("is-visible");
  }, TOAST_TIMEOUT);
}

export async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: {
      ...(options.body && !(options.body instanceof FormData) ? { "content-type": "application/json" } : {}),
      ...(options.headers || {}),
    },
    ...options,
  });
  const type = response.headers.get("content-type") || "";
  const data = type.includes("application/json") ? await response.json() : await response.text();
  if (!response.ok) {
    const message = data?.error || data || `HTTP ${response.status}`;
    throw new Error(message);
  }
  return data;
}

export async function fetchMe() {
  const data = await api("/api/v1/auth/me");
  return data.user;
}

export function renderUserPill(user) {
  const pill = $("user-pill");
  if (!pill) return;
  if (!user) {
    pill.innerHTML = `<a class="btn btn-subtle btn-sm" href="/account">${icon("user")}<span>Sign in</span></a>`;
    return;
  }
  pill.innerHTML = `<a class="user-chip" href="/account">${avatarHtml(user)}<span>${escapeHtml(user.displayName || user.username)}</span></a>`;
}

export function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[char]));
}

export function escapeAttr(value) {
  return escapeHtml(value).replace(/`/g, "&#96;");
}

export function splitCsv(value) {
  return String(value || "").split(",").map((item) => item.trim()).filter(Boolean);
}

export function readFileBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1]);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

export function encodeURIComponentName(name) {
  return name.split("/").map(encodeURIComponent).join("/");
}

export function majorMinor(version) {
  const [major, minor] = String(version).split(".");
  return `${major}.${minor || "0"}`;
}

export function formatBytes(bytes) {
  const value = Number(bytes || 0);
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 / 1024).toFixed(1)} MiB`;
}

export function timeAgo(date) {
  const then = new Date(date).getTime();
  if (!then) return "";
  const seconds = Math.max(1, Math.floor((Date.now() - then) / 1000));
  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months}mo ago`;
  const years = Math.floor(days / 365);
  return `${years}y ago`;
}

export function formatDate(date) {
  const value = new Date(date);
  if (Number.isNaN(value.getTime())) return "";
  return value.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

export function initials(name) {
  const cleaned = String(name || "").trim().replace(/^@/, "");
  if (!cleaned) return "?";
  const parts = cleaned.split(/[\s_.-]+/).filter(Boolean);
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

const AVATAR_COLORS = ["#d97706", "#0e7490", "#6d28d9", "#be123c", "#15803d", "#b45309", "#1d4ed8", "#9d174d"];

function colorFor(seed) {
  let hash = 0;
  for (let i = 0; i < seed.length; i++) hash = (hash * 31 + seed.charCodeAt(i)) | 0;
  return AVATAR_COLORS[Math.abs(hash) % AVATAR_COLORS.length];
}

export function avatarHtml(owner, size = 28) {
  const name = owner?.displayName || owner?.username || "?";
  const url = owner?.avatarUrl;
  const baseStyle = `--avatar-size:${size}px;--avatar-color:${colorFor(name)}`;
  const initialsHtml = `<span class="avatar avatar-initials" style="${baseStyle}">${escapeHtml(initials(name))}</span>`;
  if (!url) return initialsHtml;
  return `<span class="avatar avatar-initials" style="${baseStyle}">${escapeHtml(initials(name))}<img class="avatar-img" src="${escapeAttr(url)}" alt="" loading="lazy" width="${size}" height="${size}" onerror="this.style.display='none'"></span>`;
}

export function avatarStack(owners, max = 4) {
  const shown = owners.slice(0, max);
  const extra = owners.length - shown.length;
  const stack = shown.map((owner) => avatarHtml(owner, 28)).join("");
  const extraChip = extra > 0
    ? `<span class="avatar avatar-extra" style="--avatar-size:28px">+${extra}</span>`
    : "";
  return `<span class="avatar-stack">${stack}${extraChip}</span>`;
}

export async function copy(text, button) {
  try {
    await navigator.clipboard.writeText(text);
    if (button) {
      const original = button.innerHTML;
      button.classList.add("is-copied");
      button.innerHTML = `${icon("check")}<span>Copied</span>`;
      setTimeout(() => {
        button.classList.remove("is-copied");
        button.innerHTML = original;
      }, 1500);
    }
    showToast("Copied to clipboard");
  } catch {
    showToast("Copy failed", "danger");
  }
}

export function bindCopyButtons(root = document) {
  root.querySelectorAll("[data-copy]").forEach((button) => {
    if (button.dataset.copyBound) return;
    button.dataset.copyBound = "1";
    button.addEventListener("click", () => copy(button.dataset.copy, button));
  });
}

export function chip(label, variant = "muted", title = "") {
  return `<span class="chip chip-${variant}"${title ? ` title="${escapeAttr(title)}"` : ""}>${escapeHtml(label)}</span>`;
}

export function publicHref(path, publicUrl = "") {
  const value = String(path || "/");
  const base = String(publicUrl || "").replace(/\/$/, "");
  if (!base || /^https?:\/\//i.test(value)) return value;
  return `${base}${value.startsWith("/") ? value : `/${value}`}`;
}

export function applyRegistryChrome(meta = {}) {
  const publicUrl = meta.publicUrl || "";
  document.querySelectorAll("[data-public-path]").forEach((link) => {
    link.href = publicHref(link.dataset.publicPath || link.getAttribute("href") || "/", publicUrl);
  });
  document.querySelectorAll("[data-source-link]").forEach((link) => {
    link.href = meta.sourceUrl || "https://github.com/scheme-packages/kons";
  });
}

export function renderRegistryMessages(messages = [], targetId = "registry-messages") {
  const target = $(targetId);
  if (!target) return;
  const items = Array.isArray(messages) ? messages.filter((item) => item && (item.title || item.body)) : [];
  target.innerHTML = items.map((item) => `
    <div class="notice notice-${escapeAttr(item.kind || "info")}">
      <div>
        ${item.title ? `<strong>${escapeHtml(item.title)}</strong>` : ""}
        ${item.body ? `<p>${escapeHtml(item.body)}</p>` : ""}
      </div>
      ${item.url ? `<a class="btn btn-subtle btn-sm" href="${escapeAttr(item.url)}" target="_blank" rel="noopener">${icon("link")}<span>${escapeHtml(item.label || "Learn more")}</span></a>` : ""}
    </div>
  `).join("");
}

export function skeletonRows(count = 5) {
  return Array.from({ length: count })
    .map(() => `<div class="skeleton-row"><div class="skeleton skeleton-title"></div><div class="skeleton skeleton-meta"></div></div>`)
    .join("");
}
