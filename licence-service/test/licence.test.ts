import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { verifyLicence } from "../src/licence.ts";

const dir = resolve(dirname(fileURLToPath(import.meta.url)), "../../spec/fixtures/licence");
const keys = JSON.parse(readFileSync(resolve(dir, "test-keypair.json"), "utf8"));

test("every spec fixture gives the documented answer", async () => {
  const names = readdirSync(dir).filter((f) => f.endsWith(".key.txt")).map((f) => f.slice(0, -".key.txt".length));
  assert.ok(names.length >= 12);
  for (const name of names) {
    const text = readFileSync(resolve(dir, `${name}.key.txt`), "utf8");
    const expected = JSON.parse(readFileSync(resolve(dir, `${name}.expected.json`), "utf8"));
    const result = await verifyLicence(text, { sandbox: keys.publicKey, live: keys.publicKey });
    if (expected.valid) {
      assert.ok(result.ok, name);
      if (result.ok) assert.deepEqual(result.payload, expected.payload, name);
    } else {
      assert.ok(!result.ok, name);
      if (!result.ok) assert.equal(result.error, expected.error, name);
    }
  }
});

test("a key signed for one environment does not verify as the other", async () => {
  const sandbox = readFileSync(resolve(dir, "valid-sandbox.key.txt"), "utf8");
  const live = readFileSync(resolve(dir, "valid-live.key.txt"), "utf8");
  // only a live public key available: the sandbox key must not pass
  assert.equal((await verifyLicence(sandbox, { live: keys.publicKey })).ok, false);
  assert.equal((await verifyLicence(live, { sandbox: keys.publicKey })).ok, false);
  assert.ok((await verifyLicence(live, { live: keys.publicKey })).ok);
});
