import { createHash, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto';
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { SYNC_TABLES, provisionSync, scramVerifier, type SyncProvisioning } from '../../src/infrastructure/db/provision-sync.js';
import { createTestDatabase } from './helpers.js';

describe('PowerSync provisioning', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let admin: pg.Pool;
  let options: SyncProvisioning;
  const suffix = randomBytes(6).toString('hex');

  beforeAll(async () => {
    db = await createTestDatabase();
    admin = new pg.Pool({ connectionString: process.env.DATABASE_ADMIN_URL ?? process.env.DATABASE_URL, max: 2 });
    options = {
      replicationRole: `planner_test_repl_${suffix}`,
      replicationPassword: randomBytes(32).toString('hex'),
      storageRole: `planner_test_store_${suffix}`,
      storagePassword: randomBytes(32).toString('hex'),
      storageDatabase: `planner_test_store_${suffix}`,
      publication: `planner_test_pub_${suffix}`,
      schema: db.schema,
      requireLogicalWal: false,
    };
  });

  afterAll(async () => {
    // Only the identifiers generated above are removed.
    if (admin && /^[a-f0-9]{12}$/.test(suffix)) {
      await admin.query(`DROP PUBLICATION IF EXISTS "planner_test_pub_${suffix}"`);
      await admin.query(`DROP DATABASE IF EXISTS "planner_test_store_${suffix}" WITH (FORCE)`);
      for (const role of [`planner_test_repl_${suffix}`, `planner_test_store_${suffix}`]) {
        const exists = await admin.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [role]);
        if (exists.rowCount) {
          await admin.query(`DROP OWNED BY "${role}"`);
          await admin.query(`DROP ROLE "${role}"`);
        }
      }
    }
    await admin?.end();
    await db?.close();
  });

  const loginAs = (user: string, password: string, database: string) => {
    const url = new URL(process.env.DATABASE_ADMIN_URL ?? process.env.DATABASE_URL!);
    url.username = user;
    url.password = password;
    url.pathname = `/${database}`;
    return new pg.Client({ connectionString: url.toString() });
  };

  it('builds a PostgreSQL SCRAM-SHA-256 verifier and refuses weak passwords', () => {
    const salt = Buffer.alloc(16, 7);
    const password = 'a'.repeat(40);
    const [, iterations, rest] = /^SCRAM-SHA-256\$(\d+):([^$]+\$.+)$/.exec(scramVerifier(password, salt))!;
    expect(iterations).toBe('4096');
    const salted = pbkdf2Sync(password, salt, 4096, 32, 'sha256');
    const storedKey = createHash('sha256').update(createHmac('sha256', salted).update('Client Key').digest()).digest('base64');
    expect(rest).toBe(`${salt.toString('base64')}$${storedKey}:${createHmac('sha256', salted).update('Server Key').digest('base64')}`);
    expect(() => scramVerifier('short')).toThrow();
    expect(() => scramVerifier(`${'a'.repeat(40)} `)).toThrow();
  });

  it('grants read access to the synced tables only and publishes exactly those', async () => {
    await provisionSync(admin, options);
    await provisionSync(admin, options);
    const published = await admin.query<{ tablename: string; schemaname: string }>(
      'SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = $1 ORDER BY tablename', [options.publication]);
    expect(published.rows).toEqual([...SYNC_TABLES].sort().map((tablename) => ({ schemaname: db.schema, tablename })));

    const privilege = async (table: string, kind: string) => (await admin.query<{ ok: boolean }>(
      'SELECT has_table_privilege($1, $2, $3) AS ok', [options.replicationRole, `"${db.schema}".${table}`, kind])).rows[0]!.ok;
    for (const table of SYNC_TABLES) expect(await privilege(table, 'SELECT'), table).toBe(true);
    for (const table of ['command_receipts', 'tombstones', 'auth_refresh_tokens', 'devices', 'planner_migrations', 'assistant_undos']) {
      expect(await privilege(table, 'SELECT'), table).toBe(false);
    }
    expect(await privilege('tasks', 'UPDATE')).toBe(false);

    const role = (await admin.query('SELECT rolreplication, rolsuper, rolcreatedb, rolcreaterole, rolbypassrls FROM pg_roles WHERE rolname = $1', [options.replicationRole])).rows[0];
    expect(role).toEqual({ rolreplication: true, rolsuper: false, rolcreatedb: false, rolcreaterole: false, rolbypassrls: false });
  });

  it('isolates bucket storage in its own database owned by its own role', async () => {
    await provisionSync(admin, options);
    const database = (await admin.query<{ name: string }>('SELECT current_database() AS name')).rows[0]!.name;
    const connect = async (role: string, target: string) => (await admin.query<{ ok: boolean }>(
      'SELECT has_database_privilege($1, $2, \'CONNECT\') AS ok', [role, target])).rows[0]!.ok;
    expect(await connect(options.storageRole, options.storageDatabase)).toBe(true);
    expect(await connect(options.storageRole, database)).toBe(false);
    expect(await connect(options.replicationRole, options.storageDatabase)).toBe(false);
    const owner = await admin.query('SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = $1', [options.storageDatabase]);
    expect(owner.rows[0].owner).toBe(options.storageRole);

    const storage = loginAs(options.storageRole, options.storagePassword, options.storageDatabase);
    await storage.connect();
    await storage.query('CREATE SCHEMA powersync_probe');
    await storage.end();
  });

  it('rotates passwords without leaving the old one valid', async () => {
    const previous = options.replicationPassword;
    options = { ...options, replicationPassword: randomBytes(32).toString('hex') };
    await provisionSync(admin, options);
    const database = (await admin.query<{ name: string }>('SELECT current_database() AS name')).rows[0]!.name;
    const current = loginAs(options.replicationRole, options.replicationPassword, database);
    await current.connect();
    expect((await current.query(`SELECT count(*)::int AS n FROM "${db.schema}".server_meta`)).rows[0].n).toBe(1);
    await expect(current.query(`SELECT count(*) FROM "${db.schema}".command_receipts`)).rejects.toMatchObject({ code: '42501' });
    await current.end();
    const stale = loginAs(options.replicationRole, previous, database);
    await expect(stale.connect()).rejects.toMatchObject({ code: '28P01' });
  });

  it('refuses to use the planner database as bucket storage', async () => {
    const database = (await admin.query<{ name: string }>('SELECT current_database() AS name')).rows[0]!.name;
    await expect(provisionSync(admin, { ...options, storageDatabase: database })).rejects.toThrow('own database');
  });
});
