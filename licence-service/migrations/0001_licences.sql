-- One row per sold licence. `txn` is UNIQUE, so a Paddle webhook retry can never create a second licence.
-- `id` is the random licence id inside the key; the app sends only this to /status (no email, no machine details).
CREATE TABLE licences (
  id            TEXT PRIMARY KEY,
  txn           TEXT NOT NULL UNIQUE,
  customer_id   TEXT NOT NULL,
  email         TEXT NOT NULL,
  env           TEXT NOT NULL CHECK (env IN ('sandbox', 'live')),
  issued_at     TEXT NOT NULL,
  emailed_at    TEXT,
  status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  revoked_at    TEXT,
  revoke_reason TEXT
);
