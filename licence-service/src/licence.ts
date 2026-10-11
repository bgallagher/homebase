// Supporter licence keys: see spec/licence-key.md. Only Web APIs here (WebCrypto, TextEncoder), so the same file runs
// in Cloudflare Workers, Node (tests, tools/licence-keygen) and browsers.

export const KEY_PREFIX = "RKN1-";
const SIGN_DOMAIN = "rackoon-licence-v1\n";

export type LicenceEnv = "sandbox" | "live";

export interface LicencePayload {
  v: 1;
  tier: "supporter";
  env: LicenceEnv;
  email: string;
  txn: string;
  issued: string;
}

export type LicenceError = "malformed" | "bad-signature" | "invalid-payload" | "unsupported-version";

export type LicenceCheck =
  | { ok: true; payload: LicencePayload }
  | { ok: false; error: LicenceError };

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function b64urlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlDecode(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  try {
    const binary = atob(padded);
    return Uint8Array.from(binary, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function b64Decode(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

function signedMessage(payloadBytes: Uint8Array): Uint8Array {
  const prefix = encoder.encode(SIGN_DOMAIN);
  const message = new Uint8Array(prefix.length + payloadBytes.length);
  message.set(prefix, 0);
  message.set(payloadBytes, prefix.length);
  return message;
}

/** Fields in a fixed order, so the same purchase always gives the same bytes. */
export function payloadBytes(payload: LicencePayload): Uint8Array {
  const { v, tier, env, email, txn, issued } = payload;
  return encoder.encode(JSON.stringify({ v, tier, env, email, txn, issued }));
}

/** `privateKeyB64` is the PKCS#8 DER of an Ed25519 private key, base64 (what tools/licence-keygen writes). */
export async function signLicence(payload: LicencePayload, privateKeyB64: string): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", b64Decode(privateKeyB64), { name: "Ed25519" }, false, ["sign"]);
  return signWithKey(payloadBytes(payload), key);
}

/** Signs raw payload bytes: tests and tools use it to build deliberately odd keys. */
export async function signWithKey(bytes: Uint8Array, key: CryptoKey): Promise<string> {
  const signature = new Uint8Array(await crypto.subtle.sign("Ed25519", key, signedMessage(bytes)));
  return `${KEY_PREFIX}${b64urlEncode(bytes)}.${b64urlEncode(signature)}`;
}

export function stripWhitespace(text: string): string {
  return text.replace(/\s+/g, "");
}

/** `publicKeys` holds the raw 32-byte Ed25519 public key (base64) of each environment. */
export async function verifyLicence(text: string, publicKeys: Partial<Record<LicenceEnv, string>>): Promise<LicenceCheck> {
  const clean = stripWhitespace(text);
  if (!clean.startsWith(KEY_PREFIX)) return { ok: false, error: "malformed" };
  const parts = clean.slice(KEY_PREFIX.length).split(".");
  if (parts.length !== 2) return { ok: false, error: "malformed" };
  const bytes = b64urlDecode(parts[0]);
  const signature = b64urlDecode(parts[1]);
  if (!bytes || !signature || bytes.length === 0 || signature.length !== 64) return { ok: false, error: "malformed" };

  // The environment is read from the unverified bytes only to pick which public key to check against.
  let claimed: unknown;
  try {
    claimed = (JSON.parse(decoder.decode(bytes)) as { env?: unknown }).env;
  } catch {
    claimed = undefined;
  }
  const candidates: LicenceEnv[] = claimed === "sandbox" || claimed === "live" ? [claimed] : ["sandbox", "live"];
  let valid = false;
  for (const env of candidates) {
    const raw = publicKeys[env];
    if (!raw) continue;
    const key = await crypto.subtle.importKey("raw", b64Decode(raw), { name: "Ed25519" }, false, ["verify"]);
    if (await crypto.subtle.verify("Ed25519", key, signature, signedMessage(bytes))) {
      valid = true;
      break;
    }
  }
  if (!valid) return { ok: false, error: "bad-signature" };

  let parsed: unknown;
  try {
    parsed = JSON.parse(decoder.decode(bytes));
  } catch {
    return { ok: false, error: "invalid-payload" };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return { ok: false, error: "invalid-payload" };
  const o = parsed as Record<string, unknown>;
  if (typeof o.v !== "number") return { ok: false, error: "invalid-payload" };
  if (o.v !== 1) return { ok: false, error: "unsupported-version" };
  if (
    o.tier !== "supporter" ||
    (o.env !== "sandbox" && o.env !== "live") ||
    typeof o.email !== "string" || o.email === "" ||
    typeof o.txn !== "string" || o.txn === "" ||
    typeof o.issued !== "string" || o.issued === ""
  ) {
    return { ok: false, error: "invalid-payload" };
  }
  return { ok: true, payload: { v: 1, tier: "supporter", env: o.env, email: o.email, txn: o.txn, issued: o.issued } };
}
