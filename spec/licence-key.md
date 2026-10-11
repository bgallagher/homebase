# Supporter licence key format (v1)

A licence key proves that a purchase happened, without the app ever contacting Paddle. The licence service (Cloudflare
Worker, `licence-service/`) signs it; the app checks it offline against a built-in public key. Swift (`LicenceKey.swift`),
the Worker (`licence-service/src/licence.ts`, built on `jose`) and any future Kotlin app must agree with this file and with
`spec/fixtures/licence/`.

## Shape: a standard compact JWS

```
<header>.<payload>.<signature>
```

A JSON Web Signature in compact serialization (RFC 7515) with EdDSA / Ed25519 (RFC 8037). Each part is **base64url without
padding**. The signature covers the ASCII text `<header>.<payload>` exactly as it appears in the key. Any JOSE library can
verify a key; only the claims below are specific to Rackoon.

- The text may arrive wrapped or padded by email clients: strip **all** whitespace (spaces, tabs, line breaks) before parsing.

## Header

Exactly this JSON object, with exactly these two members (in any order, no others):

```json
{"alg":"EdDSA","typ":"rackoon-licence+jwt"}
```

`alg` is pinned to `EdDSA`. A key with `alg: none`, `HS256` or any other value, a different `typ`, or any extra member
(`crit`, `b64`, `kid`...) is refused as `invalid-header` **before** any signature work. This closes the classic JWS
algorithm-confusion attacks (an attacker choosing `none` or an HMAC keyed with the public key).

## Payload

A JSON object with exactly these fields:

| field | type | meaning |
|---|---|---|
| `v` | number | payload version, `1` |
| `tier` | string | `"supporter"` (the only tier today; unknown tiers are rejected) |
| `env` | string | `"sandbox"` or `"live"`: which Paddle environment sold it |
| `email` | string | the checkout email (shown in the app, never used to log in) |
| `txn` | string | the Paddle transaction id (`txn_…`) |
| `issued` | string | ISO 8601 UTC time the key was issued |
| `id` | string | random licence id (UUID); what the app sends to the status endpoint, see Revocation |

## Verification (in this order)

1. Strip whitespace. Split on `.`: exactly three parts, each valid base64url, payload not empty, else `malformed`. A header
   that is not a JSON object is `malformed` too.
2. Check the header as above, else `invalid-header`.
3. Verify the Ed25519 signature over `<header>.<payload>` with the public key for the payload's `env`. The environment is read
   from the unverified payload only to choose the key; a forged `env` fails because each environment has its own key pair.
   Failure (including a signature that is not 64 bytes) is `bad-signature`.
4. Only now check the payload: not a JSON object, a missing or mistyped field, or an unknown `env`/`tier` is
   `invalid-payload`; `v` other than `1` is `unsupported-version`.
5. App policy (not part of the format): release builds accept only `env == "live"`, dev builds accept both.

Separate key pairs for sandbox and live. Private keys live only as Worker secrets (and one local file on the
maintainer's machine, outside the repo); the repo contains public keys and **test** key pairs only.

## Fixtures

`spec/fixtures/licence/test-keypair.json` is a throwaway TEST pair (never used for real keys). Each `NAME.key.txt` has a
`NAME.expected.json`: `{"valid":true,"payload":{…}}` or `{"valid":false,"error":"…"}`. Regenerate with
`node tools/licence-keygen fixtures`. Cases: valid sandbox and live, whitespace-wrapped, tampered payload, bad signature,
signed by another key, malformed (wrong number of parts, bad base64, header not JSON), header attacks (`alg: none`,
`alg: HS256`, wrong `typ`, extra `crit` member), unsupported version, payload not JSON, missing field, missing `id`, unknown tier.

## Revocation

A key is proof of purchase and is checked offline, so a refund can't make it stop verifying. The licence service keeps one row per
licence (Cloudflare D1, keyed by the payload's `id` and the Paddle `txn`) and the app asks whether it was revoked.

- **Service.** A full refund Paddle has approved (`adjustment.created`/`adjustment.updated`, `action: refund`, `type: full`,
  `status: approved`) or a chargeback revokes the licence bought in `data.transaction_id`; `chargeback_reverse` restores it.
  Pending or rejected refunds, partial refunds, credits and chargeback warnings change nothing.
- **Endpoint.** `GET /status/<id>` answers `200 {"status":"active"|"revoked"}`. An unknown or malformed id is `active`. The answer
  holds no personal data. A server problem is any other status code.
- **App.** After a key verifies it asks at most once every 7 days (and when no answer is stored; a clock set back asks again),
  with a 5 second timeout, over HTTPS, sending only the id. **Fail open:** no answer (offline, timeout, any non-200, an
  unreadable body) never changes anything; only an explicit `revoked` stops the key counting, and a later `active` restores it.
  The last answer (`checkedAt`, `revoked`) is stored beside the key and is forgotten when a different key is saved.
- No feature is gated, so a revoked key only loses the Supporter label.
