import { sendMail, smtpConfigured } from "./smtp.js";

export function createAuth(ctx) {
  const { db, config, publicBaseUrl, configuredPublicUrl, randomToken, sha256, safeEqual, send, sendJson, redirect, httpError, readJson, requestedUsername, requireRequestedUsername, ensureUsernameAvailable, userFromRow, isAdminEmail, getUserById, upsertIdentityUser, createSession, sessionCookie, requireUser, nowIso } = ctx;
  const env = process.env;

const oauthProviders = {
  google: {
    label: "Google",
    clientId: env.KONS_AUTH_GOOGLE_CLIENT_ID,
    clientSecret: env.KONS_AUTH_GOOGLE_CLIENT_SECRET,
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    userUrl: "https://openidconnect.googleapis.com/v1/userinfo",
    scope: "openid email profile",
    map(profile) {
      return {
        providerId: String(profile.sub),
        username: profile.email ? profile.email.split("@")[0] : `google-${profile.sub}`,
        displayName: profile.name || profile.email || `google-${profile.sub}`,
        email: profile.email || "",
        avatarUrl: profile.picture || "",
      };
    },
  },
  github: {
    label: "GitHub",
    clientId: env.KONS_AUTH_GITHUB_CLIENT_ID,
    clientSecret: env.KONS_AUTH_GITHUB_CLIENT_SECRET,
    authorizeUrl: "https://github.com/login/oauth/authorize",
    tokenUrl: "https://github.com/login/oauth/access_token",
    userUrl: "https://api.github.com/user",
    emailsUrl: "https://api.github.com/user/emails",
    scope: "read:user user:email",
    async map(profile, token) {
      let email = profile.email || "";
      if (!email && token) {
        const emails = await oauthJson("https://api.github.com/user/emails", token);
        const primary = Array.isArray(emails)
          ? emails.find((item) => item.primary && item.verified) || emails.find((item) => item.verified)
          : null;
        email = primary?.email || "";
      }
      return {
        providerId: String(profile.id),
        username: profile.login || `github-${profile.id}`,
        displayName: profile.name || profile.login || `github-${profile.id}`,
        email,
        avatarUrl: profile.avatar_url || "",
      };
    },
  },
  codeberg: {
    label: "Codeberg",
    clientId: env.KONS_AUTH_CODEBERG_CLIENT_ID,
    clientSecret: env.KONS_AUTH_CODEBERG_CLIENT_SECRET,
    authorizeUrl: "https://codeberg.org/login/oauth/authorize",
    tokenUrl: "https://codeberg.org/login/oauth/access_token",
    userUrl: "https://codeberg.org/api/v1/user",
    scope: "read:user read:email",
    map(profile) {
      return {
        providerId: String(profile.id),
        username: profile.login || `codeberg-${profile.id}`,
        displayName: profile.full_name || profile.login || `codeberg-${profile.id}`,
        email: profile.email || "",
        avatarUrl: profile.avatar_url || "",
      };
    },
  },
  discord: {
    label: "Discord",
    clientId: env.KONS_AUTH_DISCORD_CLIENT_ID,
    clientSecret: env.KONS_AUTH_DISCORD_CLIENT_SECRET,
    authorizeUrl: "https://discord.com/api/oauth2/authorize",
    tokenUrl: "https://discord.com/api/oauth2/token",
    userUrl: "https://discord.com/api/users/@me",
    scope: "identify email",
    map(profile) {
      const avatarUrl = profile.avatar
        ? `https://cdn.discordapp.com/avatars/${profile.id}/${profile.avatar}.png`
        : "";
      return {
        providerId: String(profile.id),
        username: profile.username || `discord-${profile.id}`,
        displayName: profile.global_name || profile.username || `discord-${profile.id}`,
        email: profile.email || "",
        avatarUrl,
      };
    },
  },
};

async function oauthJson(url, token) {
  const response = await fetch(url, {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${token}`,
      "user-agent": "kons-registry",
    },
  });
  if (!response.ok) throw httpError(502, "OAuth profile request failed");
  return response.json();
}

async function exchangeOAuthCode(provider, code, redirectUri) {
  const body = new URLSearchParams({
    client_id: provider.clientId,
    client_secret: provider.clientSecret,
    code,
    grant_type: "authorization_code",
    redirect_uri: redirectUri,
  });
  const response = await fetch(provider.tokenUrl, {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
      "user-agent": "kons-registry",
    },
    body,
  });
  if (!response.ok) throw httpError(502, "OAuth token exchange failed");
  const payload = await response.json();
  if (!payload.access_token) throw httpError(502, "OAuth provider did not return an access token");
  return payload.access_token;
}

function configuredProviders() {
  return Object.entries(oauthProviders)
    .filter(([, provider]) => provider.clientId && provider.clientSecret)
    .map(([id, provider]) => ({ id, label: provider.label, url: `/auth/${id}/start` }));
}

function isEmailAllowed(email) {
  const normalized = String(email || "").toLowerCase();
  if (!config.emailRegistration || !normalized.includes("@")) return false;
  if (config.emailOpenRegistration) return true;
  if (!config.emailAllowlist.length) return false;
  return config.emailAllowlist.some((entry) => {
    const item = entry.toLowerCase();
    if (item === "*") return true;
    return item.startsWith("@") ? normalized.endsWith(item) : normalized === item;
  });
}

function emailAuthInfo() {
  const smtp = smtpConfigured(config.smtp);
  return {
    enabled: config.emailRegistration,
    openRegistration: config.emailOpenRegistration,
    showCodes: config.emailShowCodes,
    delivery: smtp ? "smtp" : "log",
  };
}

async function deliverVerificationEmail(email, code) {
  const ttl = config.emailCodeTtlMinutes;
  const verifyUrl = `${config.baseUrl || "http://127.0.0.1:8787"}/account`;
  const text = [
    "Your (kons) verification code:",
    "",
    code,
    "",
    `This code expires in ${ttl} minutes.`,
    `Sign in at ${verifyUrl}`,
  ].join("\n");

  if (!smtpConfigured(config.smtp)) {
    console.log(`[kons] email verification code for ${email}: ${code}`);
    return { delivered: false, method: "log" };
  }

  await sendMail(config.smtp, {
    from: config.smtp.from,
    to: email,
    subject: "Your (kons) verification code",
    text,
  });
  console.log(`[kons] sent verification email to ${email}`);
  return { delivered: true, method: "smtp" };
}

function emailCodeHash(email, code) {
  return sha256(`${config.sessionSecret}:${email.toLowerCase()}:${code}`);
}

async function handleAuthStart(req, res, providerId, url) {
  const provider = oauthProviders[providerId];
  if (!provider?.clientId || !provider?.clientSecret) throw httpError(404, "OAuth provider is not configured");
  const username = requestedUsername(url.searchParams.get("username") || url.searchParams.get("nickname") || "");
  const state = randomToken(24);
  const createdAt = nowIso();
  const expiresAt = new Date(Date.now() + 1000 * 60 * 10).toISOString();
  db.prepare("INSERT INTO auth_states (state, provider, return_to, username, created_at, expires_at) VALUES (?, ?, '/', ?, ?, ?)")
    .run(state, providerId, username, createdAt, expiresAt);
  const redirectUri = `${publicBaseUrl(req)}/auth/${providerId}/callback`;
  const authUrl = new URL(provider.authorizeUrl);
  authUrl.searchParams.set("client_id", provider.clientId);
  authUrl.searchParams.set("redirect_uri", redirectUri);
  authUrl.searchParams.set("response_type", "code");
  authUrl.searchParams.set("scope", provider.scope);
  authUrl.searchParams.set("state", state);
  redirect(res, authUrl.toString());
}

async function handleAuthCallback(req, res, providerId, url) {
  const provider = oauthProviders[providerId];
  if (!provider?.clientId || !provider?.clientSecret) throw httpError(404, "OAuth provider is not configured");
  const state = url.searchParams.get("state") || "";
  const code = url.searchParams.get("code") || "";
  const stateRow = db.prepare("SELECT * FROM auth_states WHERE state = ? AND provider = ? AND expires_at > ?")
    .get(state, providerId, nowIso());
  if (!stateRow || !code) throw httpError(400, "invalid OAuth callback state");
  db.prepare("DELETE FROM auth_states WHERE state = ?").run(state);
  const redirectUri = `${publicBaseUrl(req)}/auth/${providerId}/callback`;
  const token = await exchangeOAuthCode(provider, code, redirectUri);
  const rawProfile = await oauthJson(provider.userUrl, token);
  const mapped = await provider.map(rawProfile, token);
  const user = upsertIdentityUser(providerId, mapped, rawProfile, { username: stateRow.username || "" });
  const session = createSession(user.id);
  send(res, 302, "", {
    location: "/account?auth=ok",
    "set-cookie": sessionCookie(session),
  });
}

async function handleEmailStart(req, res) {
  const payload = await readJson(req, 16 * 1024);
  const email = String(payload.email || "").trim().toLowerCase();
  const username = requestedUsername(payload.username || payload.nickname || "");
  if (!isEmailAllowed(email)) throw httpError(403, "email registration is not enabled for this address");
  const existingUser = userFromRow(db.prepare("SELECT * FROM users WHERE lower(email) = lower(?)").get(email));
  if (!existingUser) {
    if (!username) throw httpError(400, "username is required");
    ensureUsernameAvailable(username);
  }
  const code = String(Math.floor(100000 + Math.random() * 900000));
  const state = randomToken(18);
  const createdAt = nowIso();
  const expiresAt = new Date(Date.now() + 1000 * 60 * config.emailCodeTtlMinutes).toISOString();
  db.prepare(`
    INSERT INTO auth_states (state, provider, return_to, email, username, code_hash, created_at, expires_at)
    VALUES (?, 'email', '/account', ?, ?, ?, ?, ?)
  `).run(state, email, username, emailCodeHash(email, code), createdAt, expiresAt);
  const delivery = await deliverVerificationEmail(email, code);
  sendJson(res, 200, {
    ok: true,
    message: delivery.delivered
      ? "verification code sent by email"
      : "verification code created; check the registry server log",
    delivery: delivery.method,
    code: !delivery.delivered && config.emailShowCodes ? code : undefined,
  });
}

async function handleEmailVerify(req, res) {
  const payload = await readJson(req, 16 * 1024);
  const email = String(payload.email || "").trim().toLowerCase();
  const code = String(payload.code || "").trim();
  const requested = requestedUsername(payload.username || payload.nickname || "");
  const row = db.prepare(`
    SELECT * FROM auth_states
    WHERE provider = 'email' AND lower(email) = lower(?) AND expires_at > ?
    ORDER BY created_at DESC
  `).get(email, nowIso());
  if (!row || !safeEqual(row.code_hash, emailCodeHash(email, code))) {
    throw httpError(400, "invalid or expired verification code");
  }
  const username = row.username || requested;
  const profile = {
    providerId: email,
    username: email.split("@")[0],
    displayName: username || email,
    email,
    avatarUrl: "",
  };
  const user = upsertIdentityUser("email", profile, { email }, { username, displayName: username || email });
  db.prepare("DELETE FROM auth_states WHERE state = ?").run(row.state);
  const session = createSession(user.id);
  sendJson(res, 200, { user }, { "set-cookie": sessionCookie(session) });
}

function listTokens(user) {
  return db.prepare(`
    SELECT id, name, prefix, created_at, last_used_at FROM api_tokens
    WHERE user_id = ? ORDER BY created_at DESC
  `).all(user.id).map((row) => ({
    id: row.id,
    name: row.name,
    prefix: row.prefix,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at,
  }));
}

async function createToken(req, res) {
  const user = requireUser(req);
  const payload = await readJson(req, 16 * 1024);
  const name = String(payload.name || "default").slice(0, 80);
  const raw = `kons_${randomToken(32)}`;
  const prefix = raw.slice(0, 14);
  db.prepare(`
    INSERT INTO api_tokens (user_id, name, token_hash, prefix, created_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(user.id, name, sha256(raw), prefix, nowIso());
  sendJson(res, 201, { token: raw, tokens: listTokens(user) });
}

function deleteToken(req, res, id) {
  const user = requireUser(req);
  db.prepare("DELETE FROM api_tokens WHERE id = ? AND user_id = ?").run(id, user.id);
  sendJson(res, 200, { tokens: listTokens(user) });
}

  return { configuredProviders, emailAuthInfo, handleAuthStart, handleAuthCallback, handleEmailStart, handleEmailVerify, listTokens, createToken, deleteToken };
}
