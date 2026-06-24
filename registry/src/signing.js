// Optional Ed25519 signing for registry metadata.
import crypto from "node:crypto";
import fs from "node:fs";

export function createSigning(ctx) {
  const { config } = ctx;

  function signingConfigured() {
    return Boolean(config.signing.keyId && config.signing.privateKeyFile);
  }

  function publicSigningKey() {
    if (!config.signing.publicKeyFile) return null;
    if (!fs.existsSync(config.signing.publicKeyFile)) return null;
    return fs.readFileSync(config.signing.publicKeyFile, "utf8");
  }

  function signedPayload(value) {
    if (!signingConfigured()) return null;

    const payload = Buffer.from(JSON.stringify(value), "utf8");
    const privateKey = fs.readFileSync(config.signing.privateKeyFile, "utf8");
    const signature = crypto.sign(null, payload, privateKey);

    return {
      version: 1,
      alg: "ed25519",
      keyId: config.signing.keyId,
      payloadBase64: payload.toString("base64"),
      signatureBase64: signature.toString("base64"),
    };
  }

  function signingConfig() {
    if (!signingConfigured()) return null;
    return {
      alg: "ed25519",
      keyId: config.signing.keyId,
      publicKey: publicSigningKey(),
    };
  }

  return { signingConfigured, publicSigningKey, signedPayload, signingConfig };
}
