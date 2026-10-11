# Supporter licence key format (v1)

A licence key proves that a purchase happened, without the app ever contacting Paddle. The licence service (Cloudflare
Worker, `licence-service/`) signs it; the app checks it offline against a built-in public key. Swift (`LicenceKey.swift`),
the Worker (`licence-service/src/licence.ts`) and any future Kotlin app must agree with this file and with
`spec/fixtures/licence/`.

## Shape

```
RKN1-<payload>.<signature>
```

- `RKN1-` is a fixed prefix (format version 1).
- `<payload>` is the payload JSON, UTF-8, encoded as **base64url without padding**.
- `<signature>` is an **Ed25519** signature (64 bytes), base64url without padding, over the bytes
  `"rackoon-licence-v1\n"` (UTF-8) followed by the exact payload bytes. The domain prefix keeps a signature for this
  format from being valid for anything else.
- The text may arrive wrapped or padded by email clients: strip **all** whitespace (spaces, tabs, line breaks) before parsing.

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

## Verification (in this order)

1. Strip whitespace. The text must start with `RKN1-` and have exactly one `.` after it, else `malformed`.
2. Decode both parts from base64url, else `malformed`.
3. Verify the signature over the **decoded payload bytes** (not a re-serialised object) with the public key for the
   payload's `env`. The environment is read from the bytes only to choose the key; a forged `env` fails because each
   environment has its own key pair. Failure is `bad-signature`.
4. Only now parse the JSON: not an object, a missing or mistyped field, or a bad `env`/`tier` is `invalid-payload`;
   `v` other than `1` is `unsupported-version`.
5. App policy (not part of the format): release builds accept only `env == "live"`, dev builds accept both.

Separate key pairs for sandbox and live. Private keys live only as Worker secrets (and one local file on the
maintainer's machine, outside the repo); the repo contains public keys and **test** key pairs only.

## Fixtures

`spec/fixtures/licence/test-keypair.json` is a throwaway TEST pair (never used for real keys). Each `NAME.key.txt` has a
`NAME.expected.json`: `{"valid":true,"payload":{…}}` or `{"valid":false,"error":"…"}`. Cases: valid sandbox, valid live,
valid but whitespace-wrapped, tampered payload, bad signature, signed by another key, malformed (no prefix, wrong
parts, bad base64), unsupported version, non-JSON payload.
