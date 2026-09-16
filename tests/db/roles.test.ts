import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { migrate } from '../../src/infrastructure/db/migrate.js';

const adminUrl = process.env.DATABASE_ADMIN_URL;
const apiUrl = process.env.DATABASE_URL;
const apiRole = apiUrl ? decodeURIComponent(new URL(apiUrl).username) : '';
const distinctRoles = Boolean(adminUrl && apiUrl && apiRole && decodeURIComponent(new URL(adminUrl).username) !== apiRole);
const INSUFFICIENT_PRIVILEGE = '42501';

// Runs only against the local compose database, where setup:local creates two roles.
describe.runIf(distinctRoles)('runtime database role', () => {
  const schema = `planner_test_${randomUUID().replaceAll('-', '')}`;
  let admin: pg.Pool;
  let api: pg.Pool;

  const code = async (sql: string): Promise<string | undefined> => {
    try { await api.query(sql); return undefined; }
    catch (error) { return (error as { code?: string }).code; }
  };

  beforeAll(async () => {
    admin = new pg.Pool({ connectionString: adminUrl, max: 1, options: `-c search_path=${schema},public` });
    await admin.query(`CREATE SCHEMA "${schema}"`);
    await migrate(admin);
    // Mirror the production grants: data access only, no ownership and no CREATE.
    await admin.query(`GRANT USAGE ON SCHEMA "${schema}" TO "${apiRole}"`);
    await admin.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "${schema}" TO "${apiRole}"`);
    // Every migration run removes runtime access to the ledger, as after default privileges.
    await migrate(admin);
    api = new pg.Pool({ connectionString: apiUrl, max: 1, options: `-c search_path=${schema},public` });
  });
  afterAll(async () => {
    await api?.end();
    if (/^planner_test_[a-f0-9]{32}$/.test(schema)) await admin?.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
    await admin?.end();
  });

  it('is not a superuser and cannot create roles or databases', async () => {
    const role = (await api.query<{ rolsuper: boolean; rolcreaterole: boolean; rolcreatedb: boolean; rolreplication: boolean }>(
      'SELECT rolsuper, rolcreaterole, rolcreatedb, rolreplication FROM pg_roles WHERE rolname = current_user')).rows[0];
    expect(role).toEqual({ rolsuper: false, rolcreaterole: false, rolcreatedb: false, rolreplication: false });
  });

  it('reads and writes domain rows', async () => {
    const user = await api.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id');
    expect(user.rowCount).toBe(1);
    expect((await api.query('SELECT generation FROM server_meta')).rowCount).toBe(1);
  });

  it('cannot change the schema or the migration ledger history', async () => {
    expect(await code('CREATE TABLE api_created (id int)')).toBe(INSUFFICIENT_PRIVILEGE);
    expect(await code('CREATE TABLE public.api_created (id int)')).toBe(INSUFFICIENT_PRIVILEGE);
    expect(await code('ALTER TABLE tasks DROP CONSTRAINT task_completion_consistent')).toBe(INSUFFICIENT_PRIVILEGE);
    expect(await code('DROP TABLE tasks')).toBe(INSUFFICIENT_PRIVILEGE);
    expect(await code('CREATE FUNCTION api_fn() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$')).toBe(INSUFFICIENT_PRIVILEGE);
    expect(await code("UPDATE planner_migrations SET sha256 = repeat('0', 64)")).toBe(INSUFFICIENT_PRIVILEGE);
    expect(await code('DELETE FROM planner_migrations')).toBe(INSUFFICIENT_PRIVILEGE);
  });
});
