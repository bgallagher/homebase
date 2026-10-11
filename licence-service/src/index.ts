// Rackoon licence service (Cloudflare Worker). See docs/licence-setup.md and spec/licence-key.md.
//   POST /paddle/webhook   transaction.completed -> record the licence, sign a key, email it
//                          adjustment.created/updated -> a full refund or a chargeback revokes the licence
//   GET  /status/<id>      {"status":"active"|"revoked"} for the app's occasional check (id = the random id in the key)
import { signLicence } from "./licence.ts";
import type { LicenceEnv } from "./licence.ts";
import { itemPriceIds, paddleApi } from "./paddle.ts";
import type { PaddleApi } from "./paddle.ts";
import { resendMailer } from "./mail.ts";
import type { Mailer } from "./mail.ts";
import { d1Store } from "./store.ts";
import type { D1, LicenceRow, LicenceStore } from "./store.ts";

export interface Env {
  PADDLE_ENV: string;
  PADDLE_PRICE_IDS: string;
  PADDLE_API_KEY: string;
  PADDLE_WEBHOOK_SECRET: string;
  LICENCE_PRIVATE_KEY: string;
  RESEND_API_KEY: string;
  MAIL_FROM: string;
  /** Cloudflare D1 database (see wrangler.toml and migrations/). */
  DB: D1;
}

export interface Deps {
  now: () => number;
  store: LicenceStore;
  paddle: PaddleApi;
  mail: Mailer;
}

function environment(env: Env): LicenceEnv {
  return env.PADDLE_ENV === "live" ? "live" : "sandbox";
}

function priceIds(env: Env): string[] {
  return env.PADDLE_PRICE_IDS.split(",").map((s) => s.trim()).filter(Boolean);
}

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

async function sendKey(env: Env, deps: Deps, row: LicenceRow): Promise<void> {
  const key = await signLicence(
    { v: 1, tier: "supporter", env: row.env, email: row.email, txn: row.txn, issued: row.issuedAt, id: row.id },
    env.LICENCE_PRIVATE_KEY,
  );
  await deps.mail.sendLicence(row.email, key);
  await deps.store.markEmailed(row.txn, new Date(deps.now()).toISOString());
}

async function handleCompleted(data: any, env: Env, deps: Deps): Promise<Response> {
  const txn = typeof data.id === "string" ? data.id : "";
  const customerId = typeof data.customer_id === "string" ? data.customer_id : "";
  if (!txn || !customerId) return json(200, { ignored: "no transaction or customer" });
  if (!itemPriceIds(data.items).some((id) => priceIds(env).includes(id))) return json(200, { ignored: "other product" });

  // Anything failing from here on answers 5xx, so Paddle retries (sandbox 3 times in 15 minutes, live 60 times in 3 days).
  try {
    let row = await deps.store.byTxn(txn);
    if (row?.emailedAt) return json(200, { duplicate: true });
    if (!row) {
      const email = await deps.paddle.customerEmail(customerId);
      if (!email) return json(200, { ignored: "customer has no email" });
      row = {
        id: crypto.randomUUID(), txn, customerId, email, env: environment(env), issuedAt: new Date(deps.now()).toISOString(),
        emailedAt: null, status: "active", revokedAt: null, revokeReason: null,
      };
      // A concurrent delivery of the same webhook may have inserted first: use its row, so both agree on one licence id.
      if (!(await deps.store.insert(row))) row = (await deps.store.byTxn(txn)) ?? row;
    }
    // The row exists before the email goes out. If mailing fails the retry finds it and sends the identical key.
    await sendKey(env, deps, row);
    return json(200, { issued: true });
  } catch (error) {
    console.error("licence issue failed:", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "try again" });
  }
}

/** A refund counts only when it covers the whole purchase and Paddle has approved it; a chargeback always counts. */
export function adjustmentDecision(data: any): "revoke" | "restore" | null {
  const action = data?.action;
  if (action === "chargeback") return data?.status === "rejected" ? null : "revoke";
  if (action === "chargeback_reverse") return "restore";
  if (action === "refund" && data?.type === "full" && data?.status === "approved") return "revoke";
  return null;
}

async function handleAdjustment(data: any, deps: Deps): Promise<Response> {
  const decision = adjustmentDecision(data);
  const txn = typeof data?.transaction_id === "string" ? data.transaction_id : "";
  if (!decision || !txn) return json(200, { ignored: "not a revoking adjustment" });
  try {
    const found = await deps.store.setStatus(txn, decision === "revoke" ? "revoked" : "active", String(data.action), new Date(deps.now()).toISOString());
    return json(200, { [decision === "revoke" ? "revoked" : "restored"]: found });
  } catch (error) {
    console.error("licence status update failed:", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "try again" });
  }
}

export async function handleWebhook(request: Request, env: Env, deps: Deps): Promise<Response> {
  // Read the raw text once; the signature is over exactly these bytes.
  const raw = await request.text();
  if (!(await deps.paddle.verifySignature(raw, request.headers.get("Paddle-Signature"), env.PADDLE_WEBHOOK_SECRET))) {
    return json(401, { error: "invalid signature" });
  }
  let event: any;
  try {
    event = JSON.parse(raw);
  } catch {
    return json(400, { error: "invalid json" });
  }
  const data = event?.data ?? {};
  switch (event?.event_type) {
    case "transaction.completed": return handleCompleted(data, env, deps);
    case "adjustment.created":
    case "adjustment.updated": return handleAdjustment(data, deps);
    default: return json(200, { ignored: "event type" });
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** What the app asks. Unknown or malformed ids are "active": a key this service doesn't know is never punished. */
export async function handleStatus(id: string, deps: Deps): Promise<Response> {
  const cache = { "Cache-Control": "public, max-age=300" };
  if (!UUID.test(id)) return json(200, { status: "active" }, cache);
  try {
    const row = await deps.store.byId(id);
    return json(200, { status: row?.status === "revoked" ? "revoked" : "active" }, cache);
  } catch (error) {
    console.error("status lookup failed:", error instanceof Error ? error.message : "unknown");
    return json(503, { error: "try again" });   // the app treats anything but 200 as "no answer" and keeps the licence
  }
}

export async function handleRequest(request: Request, env: Env, deps: Deps): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (pathname === "/paddle/webhook" && request.method === "POST") return handleWebhook(request, env, deps);
  if (pathname.startsWith("/status/") && request.method === "GET") return handleStatus(pathname.slice("/status/".length), deps);
  if (pathname === "/healthz") return new Response("ok");
  return new Response("Not found", { status: 404 });
}

export function makeDeps(env: Env): Deps {
  return {
    now: () => Date.now(),
    store: d1Store(env.DB),
    paddle: paddleApi(env.PADDLE_API_KEY, environment(env)),
    mail: resendMailer(env.RESEND_API_KEY, env.MAIL_FROM, fetch),
  };
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env, makeDeps(env));
  },
};
