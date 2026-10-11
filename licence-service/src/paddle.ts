// Paddle side, through the official SDK (@paddle/paddle-node-sdk): webhook signature verification and the few read-only
// API calls the service needs. The SDK ships a Workers build (WebCrypto) that Wrangler picks automatically.
import { Environment, Paddle } from "@paddle/paddle-node-sdk";

export interface PaddleApi {
  /**
   * True only if `Paddle-Signature` matches the raw body under `secret` and the timestamp is recent (the SDK allows 5 s).
   * Never throws: a malformed header is simply "not valid".
   */
  verifySignature(rawBody: string, header: string | null, secret: string): Promise<boolean>;
  /** The customer's email, or null if Paddle has no such customer. Throws on any other failure (so the caller retries). */
  customerEmail(customerId: string): Promise<string | null>;
}

/** Price ids in a transaction's `items`, from either the raw webhook shape or the SDK's. */
export function itemPriceIds(items: unknown): string[] {
  if (!Array.isArray(items)) return [];
  return items.flatMap((item) => {
    const o = item as { price_id?: unknown; priceId?: unknown; price?: { id?: unknown } | null };
    const id =
      typeof o?.price_id === "string" ? o.price_id :
      typeof o?.priceId === "string" ? o.priceId :
      typeof o?.price?.id === "string" ? o.price.id : null;
    return id ? [id] : [];
  });
}

/** Webhook verification needs no API call, so it works with any key (even none). */
export async function verifyWithSdk(rawBody: string, header: string | null, secret: string): Promise<boolean> {
  if (!header || !secret) return false;
  try {
    return await new Paddle("unused").webhooks.isSignatureValid(rawBody, secret, header);
  } catch {
    return false;
  }
}

function isNotFound(error: unknown): boolean {
  const e = error as { code?: unknown; type?: unknown } | null;
  return `${e?.code ?? ""}`.includes("not_found") || `${e?.type ?? ""}`.includes("not_found");
}

export function paddleApi(apiKey: string, environment: "sandbox" | "live"): PaddleApi {
  const paddle = new Paddle(apiKey, { environment: environment === "live" ? Environment.production : Environment.sandbox });
  return {
    verifySignature: verifyWithSdk,
    async customerEmail(customerId) {
      if (!/^ctm_[a-z0-9]+$/.test(customerId)) return null;
      try {
        return (await paddle.customers.get(customerId)).email || null;
      } catch (error) {
        if (isNotFound(error)) return null;
        throw error;
      }
    },
  };
}
