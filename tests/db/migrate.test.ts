import { cp, mkdtemp, readdir, rm, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { migrate } from '../../src/infrastructure/db/migrate.js';
import { createTestDatabase } from './helpers.js';

const sourceDirectory = fileURLToPath(new URL('../../migrations/', import.meta.url));

describe('numbered migration runner', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let workDirectory: string | undefined;

  beforeAll(async () => {
    db = await createTestDatabase();
    workDirectory = await mkdtemp(join(tmpdir(), 'planner-migrations-'));
  });
  afterAll(async () => {
    await db?.close();
    if (workDirectory) await rm(workDirectory, { recursive: true, force: true });
  });

  let copies = 0;
  async function copyOfMigrations(): Promise<string> {
    const directory = join(workDirectory!, `copy-${++copies}`);
    await cp(sourceDirectory, directory, { recursive: true });
    return directory;
  }

  it('records every migration with its SHA-256 and is idempotent', async () => {
    const files = (await readdir(sourceDirectory)).filter((name) => name.endsWith('.sql')).sort();
    const ledger = await db.pool.query<{ name: string; sha256: string }>('SELECT name, sha256 FROM planner_migrations ORDER BY name');
    expect(ledger.rows.map((row) => row.name)).toEqual(files);
    expect(ledger.rows.every((row) => /^[0-9a-f]{64}$/.test(row.sha256))).toBe(true);
    await migrate(db.pool);
    expect((await db.pool.query('SELECT count(*)::int AS n FROM planner_migrations')).rows[0].n).toBe(files.length);
  });

  it('refuses an applied migration whose content changed', async () => {
    const directory = await copyOfMigrations();
    await writeFile(join(directory, '0001_domain.sql'), '-- rewritten history\nSELECT 1;\n');
    await expect(migrate(db.pool, { directory })).rejects.toThrow(/Applied migration was changed: 0001_domain\.sql/);
  });

  it('refuses a missing applied migration', async () => {
    const directory = await copyOfMigrations();
    await unlink(join(directory, '0002_auth.sql'));
    await expect(migrate(db.pool, { directory })).rejects.toThrow(/Applied migration is missing: 0002_auth\.sql/);
  });

  it('refuses a migration inserted before applied history and rolls back new files', async () => {
    const directory = await copyOfMigrations();
    await writeFile(join(directory, '0000_early.sql'), 'CREATE TABLE should_not_exist (id int);\n');
    await expect(migrate(db.pool, { directory })).rejects.toThrow(/inserted before applied history: 0000_early\.sql/);
    expect((await db.pool.query("SELECT to_regclass('should_not_exist') AS t")).rows[0].t).toBeNull();
  });

  it('refuses two migrations sharing a number', async () => {
    const directory = await copyOfMigrations();
    await writeFile(join(directory, '0002_duplicate.sql'), 'SELECT 1;\n');
    await expect(migrate(db.pool, { directory })).rejects.toThrow(/Migration number repeated/);
  });

  it('applies a new migration and its ledger row atomically', async () => {
    const directory = await copyOfMigrations();
    await writeFile(join(directory, '0099_failing.sql'), 'CREATE TABLE half_applied (id int);\nSELECT 1/0;\n');
    await expect(migrate(db.pool, { directory })).rejects.toThrow();
    expect((await db.pool.query("SELECT to_regclass('half_applied') AS t")).rows[0].t).toBeNull();
    expect((await db.pool.query("SELECT count(*)::int AS n FROM planner_migrations WHERE name = '0099_failing.sql'")).rows[0].n).toBe(0);
  });
});
