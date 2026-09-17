import { createHash, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto';
import type pg from 'pg';

/** The only tables PowerSync may read (03_Data_Model.md §11). Receipts, auth and tombstones stay private. */
export const SYNC_TABLES = [
  'projects', 'tasks', 'task_occurrences', 'reminders', 'server_meta',
  'tags', 'task_tags', 'user_settings',
  'conversations', 'messages', 'assistant_turns', 'assistant_proposals', 'ai_actions',
] as const;

export interface SyncProvisioning {
  /** LOGIN REPLICATION role used by PowerSync to read the WAL of the planner database. */
  replicationRole: string;
  replicationPassword: string;
  /** Role owning the separate bucket-storage database. */
  storageRole: string;
  storagePassword: string;
  storageDatabase: string;
  /** PowerSync requires the name "powersync" in production. */
  publication: string;
  schema: string;
  /** Logical decoding is required; tests on a plain server may skip the check. */
  requireLogicalWal: boolean;
}

export const defaultSyncProvisioning = {
  replicationRole: 'planner_powersync',
  storageRole: 'planner_powersync_storage',
  storageDatabase: 'planner_powersync',
  publication: 'powersync',
  schema: 'public',
  requireLogicalWal: true,
} as const;

const IDENTIFIER = /^[a-z_][a-z0-9_]{0,62}$/;
function ident(name: string): string {
  if (!IDENTIFIER.test(name)) throw new Error('Unsafe SQL identifier');
  return `"${name}"`;
}

/** SCRAM-SHA-256 verifier, so the plaintext password never appears in a statement or server log. */
export function scramVerifier(password: string, salt: Buffer = randomBytes(16), iterations = 4096): string {
  if (!/^[\x21-\x7e]{32,}$/.test(password)) throw new Error('Sync passwords must be at least 32 printable ASCII characters.');
  const salted = pbkdf2Sync(password, salt, iterations, 32, 'sha256');
  const clientKey = createHmac('sha256', salted).update('Client Key').digest();
  const storedKey = createHash('sha256').update(clientKey).digest();
  const serverKey = createHmac('sha256', salted).update('Server Key').digest();
  return `SCRAM-SHA-256$${iterations}:${salt.toString('base64')}$${storedKey.toString('base64')}:${serverKey.toString('base64')}`;
}

async function ensureRole(client: pg.ClientBase, role: string, password: string, replication: boolean): Promise<void> {
  const verifier = scramVerifier(password).replaceAll("'", "''");
  const attributes = `LOGIN ${replication ? 'REPLICATION' : 'NOREPLICATION'} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS`;
  const exists = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [role]);
  await client.query(`${exists.rowCount ? 'ALTER' : 'CREATE'} ROLE ${ident(role)} WITH ${attributes} PASSWORD '${verifier}'`);
}

/** Idempotent; run with the database owner after migrations (npm run db:provision-sync). */
export async function provisionSync(admin: pg.Pool, options: SyncProvisioning): Promise<void> {
  const client = await admin.connect();
  try {
    if (options.requireLogicalWal) {
      const wal = await client.query<{ wal_level: string }>('SHOW wal_level');
      if (wal.rows[0]?.wal_level !== 'logical') throw new Error('PostgreSQL wal_level must be "logical" (see compose.yaml) before PowerSync can replicate.');
    }
    const { rows: [database] } = await client.query<{ name: string }>('SELECT current_database() AS name');
    if (database!.name === options.storageDatabase) throw new Error('Bucket storage must use its own database.');
    const tables = SYNC_TABLES.map((table) => `${ident(options.schema)}.${ident(table)}`).join(', ');

    await client.query('BEGIN');
    await ensureRole(client, options.replicationRole, options.replicationPassword, true);
    await ensureRole(client, options.storageRole, options.storagePassword, false);
    const planner = ident(database!.name);
    const replication = ident(options.replicationRole);
    await client.query(`REVOKE ALL ON DATABASE ${planner} FROM PUBLIC`);
    await client.query(`GRANT CONNECT ON DATABASE ${planner} TO ${replication}`);
    await client.query(`GRANT USAGE ON SCHEMA ${ident(options.schema)} TO ${replication}`);
    await client.query(`REVOKE ALL ON ALL TABLES IN SCHEMA ${ident(options.schema)} FROM ${replication}`);
    await client.query(`GRANT SELECT ON TABLE ${tables} TO ${replication}`);
    const publication = await client.query('SELECT 1 FROM pg_publication WHERE pubname = $1', [options.publication]);
    await client.query(publication.rowCount
      ? `ALTER PUBLICATION ${ident(options.publication)} SET TABLE ${tables}`
      : `CREATE PUBLICATION ${ident(options.publication)} FOR TABLE ${tables}`);
    await client.query('COMMIT');

    // CREATE DATABASE cannot run inside a transaction block.
    const storage = ident(options.storageDatabase);
    const exists = await client.query('SELECT 1 FROM pg_database WHERE datname = $1', [options.storageDatabase]);
    if (!exists.rowCount) {
      await client.query(`CREATE DATABASE ${storage} OWNER ${ident(options.storageRole)} TEMPLATE template0 ENCODING 'UTF8'`);
    } else {
      await client.query(`ALTER DATABASE ${storage} OWNER TO ${ident(options.storageRole)}`);
    }
    await client.query(`REVOKE ALL ON DATABASE ${storage} FROM PUBLIC`);
    await client.query(`GRANT CONNECT, CREATE, TEMPORARY ON DATABASE ${storage} TO ${ident(options.storageRole)}`);
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
