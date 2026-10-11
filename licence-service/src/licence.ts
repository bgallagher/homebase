// Supporter licence keys: a standard compact JWS (RFC 7515) signed with EdDSA/Ed25519 (RFC 8037). See spec/licence-key.md.
// Signing and verification go through `jose`; only Web APIs otherwise, so this runs in Cloudflare Workers, Node (tests,
// tools/licence-keygen) and browsers.
import { CompactSign, compactVerify } from "jose";

export const KEY_TYP = "rackoon-licence+jwt";

export type LicenceEnv = "sandbox" | "live";

export interface LicencePayload {
  v: 1;
  tier: "supporter";
  env: LicenceEnv;
  email: string;
  txn: string;
  issued: string;
  /** Random licence id (UUID): what the app sends to /status to learn whether the key was refunded. */
  id: string;
}

export type LicenceError = "malformed" | "invalid-header" | "bad-signature" | "invalid-payload" | "unsupported-version";

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
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function b64Decode(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

/** Fields in a fixed order, so the same purchase always gives the same bytes. */
export function payloadBytes(payload: LicencePayload): Uint8Array {
  const { v, tier, env, email, txn, issued, id } = payload;
  return encoder.encode(JSON.stringify({ v, tier, env, email, txn, issued, id }));
}

/** The protected header every key carries. Verification accepts exactly this and nothing else. */
export const KEY_HEADER = { alg: "EdDSA", typ: KEY_TYP } as const;

/** `privateKeyB64` is the PKCS#8 DER of an Ed25519 private key, base64 (what tools/licence-keygen writes). */
export async function signLicence(payload: LicencePayload, privateKeyB64: string): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", b64Decode(privateKeyB64), { name: "Ed25519" }, false, ["sign"]);
  return signBytes(payloadBytes(payload), key);
}

/** Signs raw payload bytes: tests and tools use it to build deliberately odd keys. */
export async function signBytes(bytes: Uint8Array, key: CryptoKey): Promise<string> {
  return new CompactSign(bytes).setProtectedHeader({ ...KEY_HEADER }).sign(key);
}

export function stripWhitespace(text: string): string {
  return text.replace(/\s+/g, "");
}

/** `publicKeys` holds the raw 32-byte Ed25519 public key (base64) of each environment. */
export async function verifyLicence(text: string, publicKeys: Partial<Record<LicenceEnv, string>>): Promise<LicenceCheck> {
  const clean = stripWhitespace(text);
  const parts = clean.split(".");
  if (parts.length !== 3) return { ok: false, error: "malformed" };
  const [headerPart, payloadPart, signaturePart] = parts;
  const headerBytes = b64urlDecode(headerPart);
  const bytes = b64urlDecode(payloadPart);
  const signature = b64urlDecode(signaturePart);
  if (!headerBytes || !bytes || !signature || bytes.length === 0) return { ok: false, error: "malformed" };

  // Header first, before any signature work: exactly {alg: EdDSA, typ: rackoon-licence+jwt}. This rejects `none`, HS256 (the
  // classic algorithm-confusion attack), `crit`, `b64` and anything else a JWS header could carry.
  let header: unknown;
  try {
    header = JSON.parse(decoder.decode(headerBytes));
  } catch {
    return { ok: false, error: "malformed" };
  }
  if (typeof header !== "object" || header === null || Array.isArray(header)) return { ok: false, error: "malformed" };
  const h = header as Record<string, unknown>;
  if (Object.keys(h).length !== 2 || h.alg !== KEY_HEADER.alg || h.typ !== KEY_HEADER.typ) return { ok: false, error: "invalid-header" };

  // The environment is read from the unverified payload only to pick which public key to check against.
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
    try {
      await compactVerify(clean, key, { algorithms: ["EdDSA"] });
      valid = true;
      break;
    } catch {
      // not this environment's key
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
    typeof o.issued !== "string" || o.issued === "" ||
    typeof o.id !== "string" || o.id === ""
  ) {
    return { ok: false, error: "invalid-payload" };
  }
  return { ok: true, payload: { v: 1, tier: "supporter", env: o.env, email: o.email, txn: o.txn, issued: o.issued, id: o.id } };
}
