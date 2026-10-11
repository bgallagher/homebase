// Rackoon licence service (Cloudflare Worker). See docs/licence-setup.md and spec/licence-key.md.
//   POST /paddle/webhook  Paddle transaction.completed -> verify signature -> sign a key -> email it
//   GET/POST /resend      "Resend my key": emails the key to the address of a customer who bought (never shows it)
import { signLicence } from "./licence.ts";
import type { LicenceEnv } from "./licence.ts";
import { itemPriceIds, paddleApi, verifyPaddleSignature } from "./paddle.ts";
import type { PaddleApi } from "./paddle.ts";
import { resendMailer } from "./mail.ts";
import type { Mailer } from "./mail.ts";

export interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
}

export interface Env {
  PADDLE_ENV: string;
  PADDLE_PRICE_IDS: string;
  PADDLE_API_KEY: string;
  PADDLE_WEBHOOK_SECRET: string;
  LICENCE_PRIVATE_KEY: string;
  RESEND_API_KEY: string;
  MAIL_FROM: string;
  SEEN: KV;
}

export interface Deps {
  now: () => number;
  kv: KV;
  paddle: PaddleApi;
  mail: Mailer;
}

const NEUTRAL = "If a purchase exists for that address, we've emailed the licence key to it. Check your inbox (and spam) in a few minutes.";
const KEEP_SECONDS = 60 * 60 * 24 * 90;

function environment(env: Env): LicenceEnv {
  return env.PADDLE_ENV === "live" ? "live" : "sandbox";
}

function priceIds(env: Env): string[] {
  return env.PADDLE_PRICE_IDS.split(",").map((s) => s.trim()).filter(Boolean);
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function issueAndSend(env: Env, deps: Deps, email: string, txn: string): Promise<void> {
  const key = await signLicence(
    { v: 1, tier: "supporter", env: environment(env), email, txn, issued: new Date(deps.now()).toISOString() },
    env.LICENCE_PRIVATE_KEY,
  );
  await deps.mail.sendLicence(email, key);
}

export async function handleWebhook(request: Request, env: Env, deps: Deps): Promise<Response> {
  // Read the raw text once; the signature is over exactly these bytes.
  const raw = await request.text();
  const nowSeconds = Math.floor(deps.now() / 1000);
  if (!(await verifyPaddleSignature(raw, request.headers.get("Paddle-Signature"), env.PADDLE_WEBHOOK_SECRET, nowSeconds))) {
    return json(401, { error: "invalid signature" });
  }
  let event: any;
  try {
    event = JSON.parse(raw);
  } catch {
    return json(400, { error: "invalid json" });
  }
  if (event?.event_type !== "transaction.completed") return json(200, { ignored: "event type" });
  const data = event.data ?? {};
  const txn = typeof data.id === "string" ? data.id : "";
  const customerId = typeof data.customer_id === "string" ? data.customer_id : "";
  if (!txn || !customerId) return json(200, { ignored: "no transaction or customer" });
  if (!itemPriceIds(data.items).some((id) => priceIds(env).includes(id))) return json(200, { ignored: "other product" });
  if (await deps.kv.get(`issued:${txn}`)) return json(200, { duplicate: true });

  // Anything failing from here on answers 5xx, so Paddle retries (sandbox 3 times in 15 minutes, live 60 times in 3 days).
  try {
    const email = await deps.paddle.customerEmail(customerId);
    if (!email) return json(200, { ignored: "customer has no email" });
    await issueAndSend(env, deps, email, txn);
    await deps.kv.put(`issued:${txn}`, "1", { expirationTtl: KEEP_SECONDS });
    return json(200, { issued: true });
  } catch (error) {
    console.error("licence issue failed:", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "try again" });
  }
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Returns true while under the limit. Best effort (KV is eventually consistent), which is enough to blunt abuse. */
async function underLimit(kv: KV, key: string, limit: number, ttl: number): Promise<boolean> {
  const used = Number((await kv.get(key)) ?? "0");
  if (used >= limit) return false;
  await kv.put(key, String(used + 1), { expirationTtl: ttl });
  return true;
}

export async function handleResend(request: Request, env: Env, deps: Deps): Promise<Response> {
  if (request.method === "GET") return page("");
  let email = "";
  const type = request.headers.get("Content-Type") ?? "";
  try {
    if (type.includes("application/json")) email = String(((await request.json()) as { email?: unknown }).email ?? "");
    else email = String((await request.formData()).get("email") ?? "");
  } catch {
    return page("Enter your email address.", 400);
  }
  email = email.trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return page("Enter a valid email address.", 400);

  // From here on every outcome looks the same, so the page can't be used to find out who bought.
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const hour = Math.floor(deps.now() / 3_600_000);
  const day = Math.floor(deps.now() / 86_400_000);
  const allowed =
    (await underLimit(deps.kv, `rl:ip:${ip}:${hour}`, 10, 7200)) &&
    (await underLimit(deps.kv, `rl:email:${await sha256Hex(email)}:${day}`, 3, 172800));
  if (!allowed) return page(NEUTRAL);
  try {
    for (const customer of await deps.paddle.customersByEmail(email)) {
      const purchase = await deps.paddle.completedPurchase(customer.id, priceIds(env));
      if (purchase) {
        await issueAndSend(env, deps, customer.email, purchase.id);
        break;
      }
    }
  } catch (error) {
    console.error("resend failed:", error instanceof Error ? error.message : "unknown");
  }
  return page(NEUTRAL);
}

function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

function page(message: string, status = 200): Response {
  const html = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Resend my Rackoon key</title>
<style>body{font:16px system-ui,sans-serif;max-width:30rem;margin:4rem auto;padding:0 1rem;color:#222}input,button{font:inherit;padding:.6rem;width:100%;box-sizing:border-box;margin-top:.6rem}button{cursor:pointer}p.note{color:#555}</style>
<h1>Resend my Rackoon key</h1>
<p>Enter the email address you used at checkout. If it matches a purchase, the licence key is emailed to that address.</p>
<form method="post" action="/resend"><input type="email" name="email" placeholder="you@example.com" required autocomplete="email"><button type="submit">Email me my key</button></form>
${message ? `<p class="note" role="status">${escapeHtml(message)}</p>` : ""}</html>`;
  return new Response(html, { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
}

export async function handleRequest(request: Request, env: Env, deps: Deps): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (pathname === "/paddle/webhook" && request.method === "POST") return handleWebhook(request, env, deps);
  if (pathname === "/resend" && (request.method === "GET" || request.method === "POST")) return handleResend(request, env, deps);
  if (pathname === "/healthz") return new Response("ok");
  return new Response("Not found", { status: 404 });
}

export function makeDeps(env: Env): Deps {
  const base = environment(env) === "live" ? "https://api.paddle.com" : "https://sandbox-api.paddle.com";
  return {
    now: () => Date.now(),
    kv: env.SEEN,
    paddle: paddleApi(base, env.PADDLE_API_KEY, fetch),
    mail: resendMailer(env.RESEND_API_KEY, env.MAIL_FROM, fetch),
  };
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env, makeDeps(env));
  },
};
