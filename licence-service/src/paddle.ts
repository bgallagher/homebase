// Paddle side: webhook signature verification and the few read-only API calls the service needs.
// Signature scheme: https://developer.paddle.com/webhooks/about/signature-verification (HMAC-SHA256 over "ts:rawBody").

const encoder = new TextEncoder();

function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) return null;
  return Uint8Array.from(hex.match(/../g) ?? [], (h) => parseInt(h, 16));
}

/**
 * True only if the `Paddle-Signature` header (`ts=…;h1=…`) matches the raw body under `secret` and the timestamp is within
 * `toleranceSeconds` of now. `crypto.subtle.verify` compares in constant time.
 */
export async function verifyPaddleSignature(
  rawBody: string, header: string | null, secret: string, nowSeconds: number, toleranceSeconds = 60,
): Promise<boolean> {
  if (!header || !secret) return false;
  let ts = "";
  const signatures: string[] = [];
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const name = part.slice(0, eq).trim(), value = part.slice(eq + 1).trim();
    if (name === "ts") ts = value;
    else if (name === "h1") signatures.push(value);
  }
  const seconds = Number(ts);
  if (!ts || !Number.isFinite(seconds) || Math.abs(nowSeconds - seconds) > toleranceSeconds) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const message = encoder.encode(`${ts}:${rawBody}`);
  for (const h1 of signatures) {
    const bytes = hexToBytes(h1);
    if (bytes && (await crypto.subtle.verify("HMAC", key, bytes, message))) return true;
  }
  return false;
}

export interface PaddleApi {
  /** The customer's email, or null if Paddle has no such customer. Throws on any other failure (so the caller retries). */
  customerEmail(customerId: string): Promise<string | null>;
  /** Customers whose email exactly matches. */
  customersByEmail(email: string): Promise<{ id: string; email: string }[]>;
  /** The newest completed transaction of this customer that includes one of `priceIds`, or null. */
  completedPurchase(customerId: string, priceIds: string[]): Promise<{ id: string } | null>;
}

export function itemPriceIds(items: unknown): string[] {
  if (!Array.isArray(items)) return [];
  return items.flatMap((item) => {
    const o = item as { price_id?: unknown; price?: { id?: unknown } };
    const id = typeof o?.price_id === "string" ? o.price_id : typeof o?.price?.id === "string" ? o.price.id : null;
    return id ? [id] : [];
  });
}

export function paddleApi(baseUrl: string, apiKey: string, doFetch: typeof fetch): PaddleApi {
  async function get(path: string): Promise<{ status: number; body: any }> {
    const response = await doFetch(`${baseUrl}${path}`, { headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" } });
    if (response.status === 404) return { status: 404, body: null };
    if (!response.ok) throw new Error(`Paddle API ${path.split("?")[0]} answered ${response.status}`);
    return { status: response.status, body: await response.json() };
  }
  return {
    async customerEmail(customerId) {
      if (!/^ctm_[a-z0-9]+$/.test(customerId)) return null;
      const { body } = await get(`/customers/${customerId}`);
      return typeof body?.data?.email === "string" ? body.data.email : null;
    },
    async customersByEmail(email) {
      const { body } = await get(`/customers?email=${encodeURIComponent(email)}&status=active`);
      const list: any[] = Array.isArray(body?.data) ? body.data : [];
      return list.flatMap((c) => (typeof c?.id === "string" && typeof c?.email === "string" ? [{ id: c.id, email: c.email }] : []));
    },
    async completedPurchase(customerId, priceIds) {
      if (!/^ctm_[a-z0-9]+$/.test(customerId)) return null;
      const { body } = await get(`/transactions?customer_id=${customerId}&status=completed&order_by=billed_at[DESC]&per_page=30`);
      const list: any[] = Array.isArray(body?.data) ? body.data : [];
      for (const txn of list) {
        if (typeof txn?.id === "string" && itemPriceIds(txn.items).some((id) => priceIds.includes(id))) return { id: txn.id };
      }
      return null;
    },
  };
}
