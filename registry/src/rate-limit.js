// Small in-memory fixed-window rate limiter for single-process registry deployments.
export function createRateLimiter(ctx) {
  const { config, httpError } = ctx;
  const windows = new Map();

  function clientAddress(req) {
    const forwarded = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();
    return forwarded || req.socket?.remoteAddress || "unknown";
  }

  function bucketConfig(bucket) {
    return config.rateLimits?.[bucket] || { limit: 0, windowMs: 0 };
  }

  function windowKey(bucket, address, windowId) {
    return `${bucket}:${address}:${windowId}`;
  }

  function cleanup(now) {
    for (const [key, entry] of windows.entries()) {
      if (entry.expiresAt <= now) windows.delete(key);
    }
  }

  function enforceRateLimit(req, bucket) {
    const settings = bucketConfig(bucket);
    const limit = Number(settings.limit || 0);
    const windowMs = Number(settings.windowMs || 0);
    if (!config.rateLimits?.enabled || limit <= 0 || windowMs <= 0) return;

    const now = Date.now();
    const address = clientAddress(req);
    const windowId = Math.floor(now / windowMs);
    const key = windowKey(bucket, address, windowId);
    const entry = windows.get(key) || { count: 0, expiresAt: (windowId + 1) * windowMs };
    entry.count += 1;
    windows.set(key, entry);

    if (entry.count > limit) {
      cleanup(now);
      throw httpError(429, "rate limit exceeded", {
        bucket,
        limit,
        windowSeconds: Math.ceil(windowMs / 1000),
      });
    }
  }

  return { enforceRateLimit };
}
