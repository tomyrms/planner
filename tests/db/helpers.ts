import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { migrate } from '../../src/infrastructure/db/migrate.js';

/** A fresh owned schema per suite; never truncates or drops existing data. */
export async function createTestDatabase(): Promise<{ pool: pg.Pool; schema: string; close: () => Promise<void> }> {
  const connectionString = process.env.DATABASE_ADMIN_URL ?? process.env.DATABASE_URL;
  if (!connectionString) throw new Error('Integration tests require DATABASE_ADMIN_URL (or DATABASE_URL) for a local test PostgreSQL with CREATE SCHEMA permission.');
  const schema = `planner_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new pg.Pool({ connectionString, max: 1 });
  await admin.query(`CREATE SCHEMA "${schema}"`);
  const pool = new pg.Pool({ connectionString, options: `-c search_path=${schema},public`, max: 6 });
  async function close(): Promise<void> {
    await pool.end();
    // Only the literal identifier generated above is ever dropped.
    if (!/^planner_test_[a-f0-9]{32}$/.test(schema)) throw new Error('Unsafe test schema identifier');
    try { await admin.query(`DROP SCHEMA "${schema}" CASCADE`); } finally { await admin.end(); }
  }
  try { await migrate(pool); } catch (error) { await close(); throw error; }
  return { pool, schema, close };
}
