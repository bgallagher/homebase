// The licence table (Cloudflare D1, see migrations/0001_licences.sql). Everything the service remembers lives here.

export interface LicenceRow {
  id: string;
  txn: string;
  customerId: string;
  email: string;
  env: "sandbox" | "live";
  issuedAt: string;
  emailedAt: string | null;
  status: "active" | "revoked";
  revokedAt: string | null;
  revokeReason: string | null;
}

export interface LicenceStore {
  byTxn(txn: string): Promise<LicenceRow | null>;
  byId(id: string): Promise<LicenceRow | null>;
  /** False if a licence for this transaction already exists (nothing is changed). */
  insert(row: LicenceRow): Promise<boolean>;
  markEmailed(txn: string, at: string): Promise<void>;
  /** Revokes or restores the licence bought in `txn`. A transaction we never issued for is simply not found. */
  setStatus(txn: string, status: "active" | "revoked", reason: string | null, at: string): Promise<boolean>;
}

/** The slice of the D1 API used here (so tests and Node need no Workers types). */
export interface D1 {
  prepare(sql: string): {
    bind(...values: unknown[]): {
      first<T>(): Promise<T | null>;
      run(): Promise<{ meta: { changes: number } }>;
    };
  };
}

interface Raw {
  id: string; txn: string; customer_id: string; email: string; env: "sandbox" | "live"; issued_at: string;
  emailed_at: string | null; status: "active" | "revoked"; revoked_at: string | null; revoke_reason: string | null;
}

function toRow(r: Raw): LicenceRow {
  return {
    id: r.id, txn: r.txn, customerId: r.customer_id, email: r.email, env: r.env, issuedAt: r.issued_at,
    emailedAt: r.emailed_at, status: r.status, revokedAt: r.revoked_at, revokeReason: r.revoke_reason,
  };
}

export function d1Store(db: D1): LicenceStore {
  return {
    async byTxn(txn) {
      const r = await db.prepare("SELECT * FROM licences WHERE txn = ?").bind(txn).first<Raw>();
      return r ? toRow(r) : null;
    },
    async byId(id) {
      const r = await db.prepare("SELECT * FROM licences WHERE id = ?").bind(id).first<Raw>();
      return r ? toRow(r) : null;
    },
    async insert(row) {
      const result = await db
        .prepare("INSERT OR IGNORE INTO licences (id, txn, customer_id, email, env, issued_at) VALUES (?, ?, ?, ?, ?, ?)")
        .bind(row.id, row.txn, row.customerId, row.email, row.env, row.issuedAt)
        .run();
      return result.meta.changes > 0;
    },
    async markEmailed(txn, at) {
      await db.prepare("UPDATE licences SET emailed_at = ? WHERE txn = ?").bind(at, txn).run();
    },
    async setStatus(txn, status, reason, at) {
      const result = await db
        .prepare("UPDATE licences SET status = ?, revoked_at = ?, revoke_reason = ? WHERE txn = ?")
        .bind(status, status === "revoked" ? at : null, status === "revoked" ? reason : null, txn)
        .run();
      return result.meta.changes > 0;
    },
  };
}
