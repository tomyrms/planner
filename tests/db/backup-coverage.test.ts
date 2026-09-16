import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { REQUIRED_TABLES, TRANSIENT_TABLES } from '../../src/infrastructure/db/backup-plan.js';
import { createTestDatabase } from './helpers.js';

// A table added by a migration must be declared: either its data is required in every dump, or it is transient.
describe('backup coverage', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  beforeAll(async () => { db = await createTestDatabase(); });
  afterAll(async () => { await db?.close(); });

  it('classifies every table created by the migrations', async () => {
    const { rows } = await db.pool.query<{ name: string }>('SELECT tablename AS name FROM pg_tables WHERE schemaname = $1 ORDER BY 1', [db.schema]);
    const declared = [...REQUIRED_TABLES, ...TRANSIENT_TABLES];
    expect(rows.map((row) => row.name)).toEqual([...declared].sort());
    expect(new Set(declared).size).toBe(declared.length);
  });
});
