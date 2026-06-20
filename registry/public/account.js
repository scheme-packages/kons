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
  formatDate,
  icon,
  initTheme,
  publicHref,
  renderUserPill,
  renderRegistryMessages,
  showToast,
  timeAgo,
} from "./shared.js";

const state = {
  user: null,
  providers: null,
  packages: [],
};

init();

async function init() {
  initTheme();
  bindThemeToggle();
  state.providers = await api("/api/v1/auth/providers");
  applyRegistryChrome(state.providers);
  renderRegistryMessages(state.providers.messages);
  await refreshSession();
  scrollToHash();
}

function scrollToHash() {
  const hash = location.hash.replace(/^#/, "");
  if (!hash || !state.user) return;
  const el = document.getElementById(`${hash}-card`) || document.getElementById(hash);
  el?.scrollIntoView({ behavior: "smooth", block: "start" });
}

async function refreshSession() {
  state.user = await fetchMe();
  renderUserPill(state.user);
  renderPage();
  if (state.user) {
    await Promise.all([loadTokens(), loadPackages()]);
  }
}

function renderPage() {
  const root = $("account-content");
  if (state.user) {
    $("account-title").textContent = state.user.displayName || state.user.username;
    $("account-subtitle").textContent = "Manage your profile and API tokens.";
    root.innerHTML = signedInHtml();
    bindSignedInEvents();
  } else {
    const emailInfo = state.providers?.email || {};
    const registrationHint = emailInfo.openRegistration
      ? "Register or sign in with any allowed email address."
      : "Register or sign in with an allowlisted email address.";
    const deliveryHint = emailInfo.delivery === "smtp"
      ? "A verification code will be emailed to you."
      : "Verification codes are written to the server log in this environment.";
    $("account-title").textContent = "Register or sign in";
    $("account-subtitle").textContent = `${registrationHint} ${deliveryHint}`;
    root.innerHTML = signInHtml();
    bindSignInEvents();
  }
}

/* Sign-in */

function signInHtml() {
  const providers = state.providers?.oauth || [];
  const providerHtml = providers.length
    ? `<div class="auth-buttons">${providers.map((p) => `
        <a class="provider-btn" href="${escapeAttr(p.url)}" data-provider-url="${escapeAttr(p.url)}">${icon(p.id)}<span>Continue with ${escapeHtml(p.label)}</span></a>
      `).join("")}</div>`
    : `<div class="empty"><span class="empty-icon">${icon("info")}</span><span class="empty-title">No OAuth providers configured</span><span>Ask the registry operator to enable a provider, or use email below.</span></div>`;

  const email = state.providers?.email || {};
  const emailHtml = email.enabled
    ? `
      <form id="email-start-form" class="stack" style="display:grid;gap:0.75rem">
        <label class="field">
          <span class="field-label">Email</span>
          <input id="email-input" type="email" placeholder="you@example.com" required>
        </label>
        <button class="btn btn-primary" type="submit">Send verification code</button>
      </form>
      <form id="email-verify-form" class="stack hidden" style="display:grid;gap:0.75rem">
        <label class="field">
          <span class="field-label">Verification code</span>
          <input id="email-code-input" type="text" inputmode="numeric" placeholder="123456" required>
        </label>
        <button class="btn btn-primary" type="submit">Verify code</button>
      </form>
      <div id="email-status" class="status"></div>
    `
    : `<div class="muted" style="font-size:0.9rem">Email registration is disabled.</div>`;

  const divider = providers.length && email.enabled
    ? `<div class="auth-divider">or use email</div>`
    : "";

  return `
    <div class="card" id="login-card">
      <div class="card-head"><h2>${icon("user")} Sign in</h2></div>
      <div class="card-body">
        <label class="field" style="margin-bottom:0.75rem">
          <span class="field-label">Username</span>
          <input id="username-input" type="text" placeholder="alice" autocomplete="username" pattern="[A-Za-z0-9_-]+" maxlength="64" required>
        </label>
        ${providerHtml}
        ${divider}
        ${emailHtml}
      </div>
    </div>
  `;
}

function bindSignInEvents() {
  $("email-start-form")?.addEventListener("submit", startEmailLogin);
  $("email-verify-form")?.addEventListener("submit", verifyEmailLogin);
  document.querySelectorAll("[data-provider-url]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      const url = new URL(link.dataset.providerUrl, window.location.origin);
      const username = usernameValue();
      if (!username) {
        showToast("Username is required", "warning");
        $("username-input")?.focus();
        return;
      }
      url.searchParams.set("username", username);
      window.location.href = publicHref(`${url.pathname}${url.search}${url.hash}`, state.providers?.publicUrl);
    });
  });
}

function usernameValue() {
  return ($("username-input")?.value || "").trim().toLowerCase();
}

async function startEmailLogin(event) {
  event.preventDefault();
  const email = $("email-input").value.trim();
  const username = usernameValue();
  const status = $("email-status");
  setStatus(status, "Sending code…", "info");
  try {
    const data = await api("/api/v1/auth/email/start", {
      method: "POST",
      body: JSON.stringify({ email, username }),
    });
    $("email-verify-form").classList.remove("hidden");
    const msg = data.delivery === "smtp"
      ? "Verification code sent. Check your email."
      : data.code
        ? `Your code: ${data.code}`
        : "Code created. Check the registry server log.";
    setStatus(status, msg, "success");
  } catch (error) {
    setStatus(status, error.message, "danger");
  }
}

async function verifyEmailLogin(event) {
  event.preventDefault();
  const email = $("email-input").value.trim();
  const code = $("email-code-input").value.trim();
  const username = usernameValue();
  const status = $("email-status");
  try {
    await api("/api/v1/auth/email/verify", {
      method: "POST",
      body: JSON.stringify({ email, code, username }),
    });
    await refreshSession();
    showToast("Signed in");
  } catch (error) {
    setStatus(status, error.message, "danger");
  }
}

function setStatus(el, message, kind) {
  if (!el) return;
  el.textContent = message;
  el.className = `status ${kind} is-visible`;
}

/* Account */

function signedInHtml() {
  return `
    <div class="account-grid">
      <div class="account-col full">
        <div class="card" id="profile-card">
          <div class="card-head">
            <h2>${icon("user")} Profile</h2>
            <button id="logout-button" class="btn btn-ghost btn-sm" type="button">${icon("logout")}<span>Sign out</span></button>
          </div>
          <div class="card-body">${profileHtml()}</div>
        </div>

        <div class="card" id="tokens-card">
          <div class="card-head"><h2>${icon("key")} API tokens</h2></div>
          <div class="card-body">
            <p class="muted" style="margin-bottom:1rem;font-size:0.9rem">Create tokens for CLI publishing and yank operations.</p>
            <form id="token-form" style="display:grid;gap:0.75rem;margin-bottom:1rem">
              <label class="field">
                <span class="field-label">Token name</span>
                <input id="token-name" type="text" placeholder="local cli" value="local cli">
              </label>
              <button class="btn btn-primary" type="submit">${icon("key")} Create token</button>
            </form>
            <div id="new-token-wrap"></div>
            <div id="token-list" class="token-list"></div>
          </div>
        </div>

        <div class="card" id="packages-card">
          <div class="card-head"><h2>${icon("package")} Packages</h2></div>
          <div class="card-body">
            <p class="muted" style="margin-bottom:1rem;font-size:0.9rem">Manage packages you own or can administer.</p>
            <div id="account-package-list" class="account-package-list"></div>
          </div>
        </div>
      </div>
    </div>
  `;
}

function profileHtml() {
  const user = state.user;
  return `
    <div class="profile-card">
      ${avatarHtml(user, 56)}
      <div class="profile-main">
        <span class="profile-name">${escapeHtml(user.displayName || user.username)}</span>
        <span class="profile-handle">@${escapeHtml(user.username)}</span>
        <div class="chip-row" style="margin-top:0.35rem">
          ${user.email ? chip(user.email, "muted") : ""}
          ${user.isAdmin ? chip("admin", "accent") : ""}
        </div>
      </div>
    </div>
    <p class="muted" style="margin-top:1rem;font-size:0.88rem">Use API tokens with <code class="code-block" style="display:inline;padding:0.1rem 0.4rem">Authorization: Bearer kons_…</code> for CLI publish and yank requests on this registry.</p>
  `;
}

function bindSignedInEvents() {
  $("logout-button").addEventListener("click", logout);
  $("token-form").addEventListener("submit", createToken);
}

async function logout() {
  await api("/api/v1/auth/logout", { method: "POST" });
  state.user = null;
  renderUserPill(null);
  renderPage();
  showToast("Signed out");
}

/* Tokens */

async function loadTokens() {
  if (!state.user) return;
  const data = await api("/api/v1/tokens");
  renderTokens(data.tokens);
}

async function createToken(event) {
  event.preventDefault();
  const name = $("token-name").value.trim() || "default";
  try {
    const data = await api("/api/v1/tokens", {
      method: "POST",
      body: JSON.stringify({ name }),
    });
    renderNewToken(data.token);
    renderTokens(data.tokens);
    showToast("Token created");
  } catch (error) {
    showToast(error.message, "danger");
  }
}

function renderNewToken(token) {
  const wrap = $("new-token-wrap");
  wrap.innerHTML = `
    <div class="secret-warn">${icon("warning")} This token is shown once. Save it now.</div>
    <div class="secret-banner">
      <span class="secret-icon">${icon("key")}</span>
      <pre>${escapeHtml(token)}</pre>
      <button class="btn btn-subtle btn-sm" type="button" data-copy="${escapeAttr(token)}">${icon("copy")}<span>Copy</span></button>
    </div>
  `;
  bindCopyButtons(wrap);
}

function renderTokens(tokens) {
  const list = $("token-list");
  if (!tokens.length) {
    list.innerHTML = `<div class="muted" style="font-size:0.88rem;padding:0.5rem 0">No tokens yet.</div>`;
    return;
  }
  list.innerHTML = tokens.map((token) => `
    <div class="token-row">
      <div>
        <div class="token-name">${icon("key")} ${escapeHtml(token.name)}</div>
        <div class="token-sub">${escapeHtml(token.prefix)}… · created ${formatDate(token.createdAt)}${token.lastUsedAt ? ` · used ${timeAgo(token.lastUsedAt)}` : ""}</div>
      </div>
      <button class="btn btn-danger btn-sm" type="button" data-delete-token="${token.id}">${icon("trash")}<span>Delete</span></button>
    </div>
  `).join("");
  list.querySelectorAll("[data-delete-token]").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        const data = await api(`/api/v1/tokens/${button.dataset.deleteToken}`, { method: "DELETE" });
        renderTokens(data.tokens);
        showToast("Token deleted");
      } catch (error) {
        showToast(error.message, "danger");
      }
    });
  });
}

/* Packages */

async function loadPackages() {
  if (!state.user) return;
  try {
    const data = await api("/api/v1/me/packages");
    state.packages = data.packages || [];
    renderPackages();
  } catch (error) {
    const list = $("account-package-list");
    if (list) list.innerHTML = `<div class="error-state"><span>${icon("warning")}</span><span>${escapeHtml(error.message)}</span></div>`;
  }
}

function renderPackages() {
  const list = $("account-package-list");
  if (!list) return;
  if (!state.packages.length) {
    list.innerHTML = `<div class="muted" style="font-size:0.88rem;padding:0.5rem 0">No published packages yet.</div>`;
    return;
  }
  list.innerHTML = state.packages.map(accountPackageHtml).join("");
  list.querySelectorAll("[data-yank-version]").forEach((button) => {
    button.addEventListener("click", () => setYank(button.dataset.package, button.dataset.yankVersion, false));
  });
  list.querySelectorAll("[data-unyank-version]").forEach((button) => {
    button.addEventListener("click", () => setYank(button.dataset.package, button.dataset.unyankVersion, true));
  });
  list.querySelectorAll("[data-delete-version]").forEach((button) => {
    button.addEventListener("click", () => deleteVersion(button.dataset.package, button.dataset.deleteVersion));
  });
  list.querySelectorAll("[data-delete-package]").forEach((button) => {
    button.addEventListener("click", () => deletePackage(button.dataset.deletePackage));
  });
}

function accountPackageHtml(pkg) {
  const versions = pkg.versions || [];
  return `
    <div class="account-package">
      <div class="account-package-head">
        <div>
          <a class="account-package-name" href="${escapeAttr(publicHref(`/#/pkg/${encodeURIComponent(pkg.name)}`, state.providers?.publicUrl))}">${escapeHtml(pkg.name)}</a>
          <div class="account-package-sub">${escapeHtml(pkg.description || "No description")}</div>
        </div>
        <button class="btn btn-danger btn-sm" type="button" data-delete-package="${escapeAttr(pkg.name)}">${icon("trash")}<span>Delete package</span></button>
      </div>
      <div class="account-version-list">
        ${versions.map((version) => accountVersionHtml(pkg, version)).join("")}
      </div>
    </div>
  `;
}

function accountVersionHtml(pkg, version) {
  const status = version.yanked ? chip("yanked", "danger") : chip("active", "success");
  return `
    <div class="account-version-row">
      <div class="account-version-main">
        <strong>${escapeHtml(version.version)}</strong>
        ${status}
        <span class="muted">${formatDate(version.publishedAt)}</span>
      </div>
      <div class="version-actions">
        <a class="btn btn-subtle btn-sm" href="${escapeAttr(publicHref(`/api/v1/packages/${encodeURIComponentName(pkg.name)}/${encodeURIComponent(version.version)}/download`, state.providers?.publicUrl))}">${icon("download")}<span>Download</span></a>
        ${version.yanked
          ? `<button class="btn btn-subtle btn-sm" type="button" data-package="${escapeAttr(pkg.name)}" data-unyank-version="${escapeAttr(version.version)}">${icon("refresh")}<span>Unyank</span></button>`
          : `<button class="btn btn-danger btn-sm" type="button" data-package="${escapeAttr(pkg.name)}" data-yank-version="${escapeAttr(version.version)}">${icon("yank")}<span>Yank</span></button>`}
        <button class="btn btn-danger btn-sm" type="button" data-package="${escapeAttr(pkg.name)}" data-delete-version="${escapeAttr(version.version)}">${icon("trash")}<span>Delete</span></button>
      </div>
    </div>
  `;
}

async function setYank(name, version, unyank) {
  const action = unyank ? "unyank" : "yank";
  const method = unyank ? "PUT" : "DELETE";
  try {
    await api(`/api/v1/packages/${encodeURIComponentName(name)}/${encodeURIComponent(version)}/${action}`, { method });
    await loadPackages();
    showToast(unyank ? "Version unyanked" : "Version yanked");
  } catch (error) {
    showToast(error.message, "danger");
  }
}

async function deleteVersion(name, version) {
  if (!window.confirm(`Delete ${name} ${version}? This cannot be undone.`)) return;
  try {
    await api(`/api/v1/packages/${encodeURIComponentName(name)}/${encodeURIComponent(version)}`, { method: "DELETE" });
    await loadPackages();
    showToast("Version deleted");
  } catch (error) {
    showToast(error.message, "danger");
  }
}

async function deletePackage(name) {
  if (!window.confirm(`Delete ${name} and all published versions? This cannot be undone.`)) return;
  try {
    await api(`/api/v1/packages/${encodeURIComponentName(name)}/delete`, { method: "DELETE" });
    await loadPackages();
    showToast("Package deleted");
  } catch (error) {
    showToast(error.message, "danger");
  }
}
