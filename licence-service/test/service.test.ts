import { test } from "node:test";
import assert from "node:assert/strict";
import { handleRequest } from "../src/index.ts";
import type { Deps, Env, KV } from "../src/index.ts";
import { verifyLicence } from "../src/licence.ts";
import type { PaddleApi } from "../src/paddle.ts";

const PRICE = "pri_01m4k470p76n1yj2nk29rkpvpq";
const SECRET = "pdl_ntfset_test_secret";
const NOW = 1_791_628_000_000;

async function makeKeys() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const raw = Buffer.from(await crypto.subtle.exportKey("raw", pair.publicKey)).toString("base64");
  return { pkcs8, raw };
}

function memoryKV(): KV & { data: Map<string, string> } {
  const data = new Map<string, string>();
  return { data, async get(k) { return data.get(k) ?? null; }, async put(k, v) { data.set(k, v); } };
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message))).toString("hex");
}

async function signedWebhook(body: unknown, opts: { secret?: string; ts?: number; tamper?: boolean } = {}): Promise<Request> {
  const raw = JSON.stringify(body);
  const ts = opts.ts ?? Math.floor(NOW / 1000);
  const h1 = await hmacHex(opts.secret ?? SECRET, `${ts}:${raw}`);
  return new Request("https://licence.example/paddle/webhook", {
    method: "POST",
    headers: { "Paddle-Signature": `ts=${ts};h1=${h1}`, "Content-Type": "application/json" },
    body: opts.tamper ? raw.replace("txn_1", "txn_2") : raw,
  });
}

const event = (over: Record<string, unknown> = {}, items: unknown = [{ price_id: PRICE, quantity: 1 }]) => ({
  event_id: "evt_1", event_type: "transaction.completed", occurred_at: "2026-10-10T14:00:00Z",
  data: { id: "txn_1", status: "completed", customer_id: "ctm_abc", items, ...over },
});

async function setup(paddleOver: Partial<PaddleApi> = {}, mailFails = false) {
  const keys = await makeKeys();
  const sent: { to: string; key: string }[] = [];
  const kv = memoryKV();
  const env: Env = {
    PADDLE_ENV: "sandbox", PADDLE_PRICE_IDS: PRICE, PADDLE_API_KEY: "pdl_sdbx_x", PADDLE_WEBHOOK_SECRET: SECRET,
    LICENCE_PRIVATE_KEY: keys.pkcs8, RESEND_API_KEY: "re_x", MAIL_FROM: "Rackoon <licences@example.com>", SEEN: kv,
  };
  const paddle: PaddleApi = {
    async customerEmail() { return "buyer@example.com"; },
    async customersByEmail() { return []; },
    async completedPurchase() { return null; },
    ...paddleOver,
  };
  const deps: Deps = {
    now: () => NOW, kv, paddle,
    mail: { async sendLicence(to, key) { if (mailFails) throw new Error("mail down"); sent.push({ to, key }); } },
  };
  return { env, deps, sent, kv, publicKey: keys.raw };
}

test("a valid transaction.completed webhook emails a key that verifies", async () => {
  const { env, deps, sent, publicKey } = await setup();
  const response = await handleRequest(await signedWebhook(event()), env, deps);
  assert.equal(response.status, 200);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, "buyer@example.com");
  const check = await verifyLicence(sent[0].key, { sandbox: publicKey });
  assert.ok(check.ok);
  if (check.ok) {
    assert.equal(check.payload.email, "buyer@example.com");
    assert.equal(check.payload.txn, "txn_1");
    assert.equal(check.payload.env, "sandbox");
    assert.equal(check.payload.tier, "supporter");
  }
  assert.equal(await verifyLicence(sent[0].key, {}).then((r) => r.ok), false, "needs the public key");
});

test("price may arrive as a nested object", async () => {
  const { env, deps, sent } = await setup();
  const response = await handleRequest(await signedWebhook(event({}, [{ price: { id: PRICE } }])), env, deps);
  assert.equal(response.status, 200);
  assert.equal(sent.length, 1);
});

test("bad signature, wrong secret, old timestamp and a tampered body are all refused and send nothing", async () => {
  const { env, deps, sent } = await setup();
  for (const request of [
    await signedWebhook(event(), { secret: "wrong" }),
    await signedWebhook(event(), { ts: Math.floor(NOW / 1000) - 3600 }),
    await signedWebhook(event(), { ts: Math.floor(NOW / 1000) + 3600 }),
    await signedWebhook(event(), { tamper: true }),
    new Request("https://licence.example/paddle/webhook", { method: "POST", body: JSON.stringify(event()) }),
  ]) {
    assert.equal((await handleRequest(request, env, deps)).status, 401);
  }
  assert.equal(sent.length, 0);
});

test("other events, other products and incomplete data are acknowledged but ignored", async () => {
  const { env, deps, sent } = await setup();
  for (const body of [
    { ...event(), event_type: "transaction.updated" },
    event({}, [{ price_id: "pri_other" }]),
    event({ customer_id: undefined }),
    event({}, []),
  ]) {
    assert.equal((await handleRequest(await signedWebhook(body), env, deps)).status, 200);
  }
  assert.equal(sent.length, 0);
});

test("a retried webhook does not send a second email", async () => {
  const { env, deps, sent } = await setup();
  await handleRequest(await signedWebhook(event()), env, deps);
  const again = await handleRequest(await signedWebhook(event()), env, deps);
  assert.equal(again.status, 200);
  assert.equal(sent.length, 1);
});

test("when the mail provider fails the webhook answers 5xx (so Paddle retries) and records nothing", async () => {
  const { env, deps, sent, kv } = await setup({}, true);
  const response = await handleRequest(await signedWebhook(event()), env, deps);
  assert.equal(response.status, 500);
  assert.equal(sent.length, 0);
  assert.equal(kv.data.size, 0);
});

test("when Paddle's API fails the webhook answers 5xx", async () => {
  const { env, deps } = await setup({ async customerEmail() { throw new Error("paddle down"); } });
  assert.equal((await handleRequest(await signedWebhook(event()), env, deps)).status, 500);
});

test("errors never leak the key or the secrets in the response body", async () => {
  const { env, deps } = await setup({}, true);
  const body = await (await handleRequest(await signedWebhook(event()), env, deps)).text();
  for (const secret of [env.LICENCE_PRIVATE_KEY, env.PADDLE_API_KEY, env.PADDLE_WEBHOOK_SECRET, env.RESEND_API_KEY]) {
    assert.ok(!body.includes(secret));
  }
});

function resendRequest(email: string, ip = "203.0.113.5"): Request {
  return new Request("https://licence.example/resend", {
    method: "POST", headers: { "CF-Connecting-IP": ip, "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ email }),
  });
}

test("resend emails the key to a real buyer and says the same thing to everyone", async () => {
  const buyer = await setup({
    async customersByEmail(email) { return email === "buyer@example.com" ? [{ id: "ctm_abc", email: "Buyer@Example.com" }] : []; },
    async completedPurchase() { return { id: "txn_9" }; },
  });
  const known = await handleRequest(resendRequest("Buyer@example.com"), buyer.env, buyer.deps);
  const unknown = await handleRequest(resendRequest("nobody@example.com", "203.0.113.6"), buyer.env, buyer.deps);
  assert.equal(known.status, 200);
  assert.equal(await known.text(), await unknown.text(), "identical pages: no way to tell who bought");
  assert.equal(buyer.sent.length, 1);
  assert.equal(buyer.sent[0].to, "Buyer@Example.com");
  const check = await verifyLicence(buyer.sent[0].key, { sandbox: buyer.publicKey });
  assert.ok(check.ok && check.payload.txn === "txn_9");
});

test("resend: a customer who never bought this product gets nothing", async () => {
  const s = await setup({ async customersByEmail() { return [{ id: "ctm_x", email: "other@example.com" }]; } });
  await handleRequest(resendRequest("other@example.com"), s.env, s.deps);
  assert.equal(s.sent.length, 0);
});

test("resend: lookup failures look the same and send nothing", async () => {
  const s = await setup({ async customersByEmail() { throw new Error("paddle down"); } });
  const response = await handleRequest(resendRequest("x@example.com"), s.env, s.deps);
  assert.equal(response.status, 200);
  assert.equal(s.sent.length, 0);
});

test("resend is rate limited per email and per address", async () => {
  const s = await setup({
    async customersByEmail() { return [{ id: "ctm_abc", email: "buyer@example.com" }]; },
    async completedPurchase() { return { id: "txn_1" }; },
  });
  for (let i = 0; i < 6; i++) await handleRequest(resendRequest("buyer@example.com", `198.51.100.${i}`), s.env, s.deps);
  assert.equal(s.sent.length, 3, "three per email per day");
  const t = await setup({
    async customersByEmail(e) { return [{ id: "ctm_abc", email: e }]; },
    async completedPurchase() { return { id: "txn_1" }; },
  });
  for (let i = 0; i < 15; i++) await handleRequest(resendRequest(`person${i}@example.com`, "192.0.2.1"), t.env, t.deps);
  assert.equal(t.sent.length, 10, "ten per address per hour");
});

test("resend rejects a malformed address and the form page renders", async () => {
  const s = await setup();
  assert.equal((await handleRequest(resendRequest("not-an-email"), s.env, s.deps)).status, 400);
  const page = await handleRequest(new Request("https://licence.example/resend"), s.env, s.deps);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /Resend my Rackoon key/);
});

test("unknown paths are 404 and healthz is ok", async () => {
  const s = await setup();
  assert.equal((await handleRequest(new Request("https://licence.example/nope"), s.env, s.deps)).status, 404);
  assert.equal((await handleRequest(new Request("https://licence.example/healthz"), s.env, s.deps)).status, 200);
  assert.equal((await handleRequest(new Request("https://licence.example/paddle/webhook"), s.env, s.deps)).status, 404, "GET is not a webhook");
});
