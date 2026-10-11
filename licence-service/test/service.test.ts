import { test } from "node:test";
import assert from "node:assert/strict";
import { handleRequest } from "../src/index.ts";
import type { Deps, Env } from "../src/index.ts";
import type { LicenceRow, LicenceStore } from "../src/store.ts";
import { verifyLicence } from "../src/licence.ts";
import { verifyWithSdk } from "../src/paddle.ts";
import type { PaddleApi } from "../src/paddle.ts";

const PRICE = "pri_01m4k470p76n1yj2nk29rkpvpq";
const SECRET = "pdl_ntfset_test_secret";
// The SDK checks the signature timestamp against the real clock (5 s tolerance), so tests sign with real time.
const now = () => Date.now();

async function makeKeys() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const raw = Buffer.from(await crypto.subtle.exportKey("raw", pair.publicKey)).toString("base64");
  return { pkcs8, raw };
}

function memoryStore(): LicenceStore & { rows: Map<string, LicenceRow> } {
  const rows = new Map<string, LicenceRow>();   // by txn
  return {
    rows,
    async byTxn(txn) { return rows.get(txn) ?? null; },
    async byId(id) { return [...rows.values()].find((r) => r.id === id) ?? null; },
    async insert(row) { if (rows.has(row.txn)) return false; rows.set(row.txn, { ...row }); return true; },
    async markEmailed(txn, at) { const r = rows.get(txn); if (r) r.emailedAt = at; },
    async setStatus(txn, status, reason, at) {
      const r = rows.get(txn);
      if (!r) return false;
      r.status = status; r.revokedAt = status === "revoked" ? at : null; r.revokeReason = status === "revoked" ? reason : null;
      return true;
    },
  };
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message))).toString("hex");
}

async function signedWebhook(body: unknown, opts: { secret?: string; ts?: number; tamper?: boolean } = {}): Promise<Request> {
  const raw = JSON.stringify(body);
  const ts = opts.ts ?? Math.floor(now() / 1000);
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
  const store = memoryStore();
  const env: Env = {
    PADDLE_ENV: "sandbox", PADDLE_PRICE_IDS: PRICE, PADDLE_API_KEY: "pdl_sdbx_x", PADDLE_WEBHOOK_SECRET: SECRET,
    LICENCE_PRIVATE_KEY: keys.pkcs8, RESEND_API_KEY: "re_x", MAIL_FROM: "Rackoon <licences@example.com>",
    DB: undefined as never,   // the store is injected through `deps`
  };
  const paddle: PaddleApi = {
    verifySignature: verifyWithSdk,   // the real SDK verification, so these tests prove the integration
    async customerEmail() { return "buyer@example.com"; },
    ...paddleOver,
  };
  let failMail = mailFails;
  const deps: Deps = {
    now, store, paddle,
    mail: { async sendLicence(to, key) { if (failMail) throw new Error("mail down"); sent.push({ to, key }); } },
  };
  return { env, deps, sent, store, publicKey: keys.raw, mailWorks() { failMail = false; } };
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
    assert.match(check.payload.id, /^[0-9a-f-]{36}$/);
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
    await signedWebhook(event(), { ts: Math.floor(now() / 1000) - 3600 }),
    await signedWebhook(event(), { ts: Math.floor(now() / 1000) - 60 }),
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

test("when the mail provider fails the webhook answers 5xx, and the retry sends the very same licence", async () => {
  const s = await setup({}, true);
  assert.equal((await handleRequest(await signedWebhook(event()), s.env, s.deps)).status, 500);
  assert.equal(s.sent.length, 0);
  const row = s.store.rows.get("txn_1")!;
  assert.equal(row.emailedAt, null, "recorded, but not yet marked as emailed");
  s.mailWorks();
  assert.equal((await handleRequest(await signedWebhook(event()), s.env, s.deps)).status, 200);
  assert.equal(s.sent.length, 1);
  const check = await verifyLicence(s.sent[0].key, { sandbox: s.publicKey });
  assert.ok(check.ok && check.payload.id === row.id, "same licence id as the stored row");
  assert.equal(s.store.rows.size, 1);
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

function adjustment(over: Record<string, unknown> = {}, type = "adjustment.updated") {
  return {
    event_id: "evt_2", event_type: type, occurred_at: "2026-10-11T10:00:00Z",
    data: { id: "adj_1", action: "refund", type: "full", status: "approved", transaction_id: "txn_1", customer_id: "ctm_abc", ...over },
  };
}

const statusOf = async (s: Awaited<ReturnType<typeof setup>>, id: string) =>
  (await (await handleRequest(new Request(`https://licence.example/status/${id}`), s.env, s.deps)).json() as { status: string }).status;

async function issued() {
  const s = await setup();
  await handleRequest(await signedWebhook(event()), s.env, s.deps);
  return { s, id: s.store.rows.get("txn_1")!.id };
}

test("the licence row is stored with the buyer, transaction and environment", async () => {
  const { s, id } = await issued();
  const row = s.store.rows.get("txn_1")!;
  assert.equal(row.email, "buyer@example.com");
  assert.equal(row.customerId, "ctm_abc");
  assert.equal(row.env, "sandbox");
  assert.equal(row.status, "active");
  assert.ok(row.emailedAt);
  assert.equal(await statusOf(s, id), "active");
});

test("an approved full refund revokes the licence; created and updated events both work", async () => {
  for (const type of ["adjustment.created", "adjustment.updated"]) {
    const { s, id } = await issued();
    const response = await handleRequest(await signedWebhook(adjustment({}, type)), s.env, s.deps);
    assert.equal(response.status, 200);
    assert.equal(await statusOf(s, id), "revoked", type);
    assert.equal(s.store.rows.get("txn_1")!.revokeReason, "refund");
  }
});

test("a pending or rejected refund, a partial refund and a credit do not revoke", async () => {
  const { s, id } = await issued();
  for (const over of [{ status: "pending_approval" }, { status: "rejected" }, { type: "partial" }, { action: "credit" }, { action: "chargeback_warning" }]) {
    assert.equal((await handleRequest(await signedWebhook(adjustment(over)), s.env, s.deps)).status, 200);
    assert.equal(await statusOf(s, id), "active", JSON.stringify(over));
  }
});

test("a chargeback revokes and a reversed chargeback restores", async () => {
  const { s, id } = await issued();
  await handleRequest(await signedWebhook(adjustment({ action: "chargeback", type: "full", status: "approved" }, "adjustment.created")), s.env, s.deps);
  assert.equal(await statusOf(s, id), "revoked");
  await handleRequest(await signedWebhook(adjustment({ action: "chargeback_reverse" }, "adjustment.created")), s.env, s.deps);
  assert.equal(await statusOf(s, id), "active");
  assert.equal(s.store.rows.get("txn_1")!.revokedAt, null);
});

test("an adjustment for a transaction we never licensed is acknowledged and changes nothing", async () => {
  const { s, id } = await issued();
  const response = await handleRequest(await signedWebhook(adjustment({ transaction_id: "txn_other" })), s.env, s.deps);
  assert.equal(response.status, 200);
  assert.equal(await statusOf(s, id), "active");
});

test("adjustment webhooks need a valid signature", async () => {
  const { s, id } = await issued();
  assert.equal((await handleRequest(await signedWebhook(adjustment(), { secret: "wrong" }), s.env, s.deps)).status, 401);
  assert.equal(await statusOf(s, id), "active");
});

test("status: unknown and malformed ids are active, answers are cacheable and carry no personal data", async () => {
  const { s, id } = await issued();
  assert.equal(await statusOf(s, "5b0d8a4e-3c1f-4d7a-9e26-7f1c2a9b6d30"), "active");
  assert.equal(await statusOf(s, "not-a-uuid"), "active");
  const response = await handleRequest(new Request(`https://licence.example/status/${id}`), s.env, s.deps);
  assert.match(response.headers.get("Cache-Control") ?? "", /max-age/);
  assert.deepEqual(Object.keys(await response.json() as object), ["status"]);
  assert.equal((await handleRequest(new Request(`https://licence.example/status/${id}`, { method: "POST" }), s.env, s.deps)).status, 404);
});

test("status: a database failure answers 503, never a revocation", async () => {
  const { s, id } = await issued();
  s.deps.store = { ...s.deps.store, async byId() { throw new Error("db down"); } };
  const response = await handleRequest(new Request(`https://licence.example/status/${id}`), s.env, s.deps);
  assert.equal(response.status, 503);
});

test("unknown paths are 404 and healthz is ok", async () => {
  const s = await setup();
  assert.equal((await handleRequest(new Request("https://licence.example/nope"), s.env, s.deps)).status, 404);
  assert.equal((await handleRequest(new Request("https://licence.example/healthz"), s.env, s.deps)).status, 200);
  assert.equal((await handleRequest(new Request("https://licence.example/paddle/webhook"), s.env, s.deps)).status, 404, "GET is not a webhook");
});
