import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { migrate } from '../../src/infrastructure/db/migrate.js';
import { monthlyVoiceMilliseconds } from '../../src/modules/voice/usage.js';
import { createTestDatabase } from '../db/helpers.js';

describe('migration 0008 voice accounting', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  beforeAll(async () => { db = await createTestDatabase(); });
  afterAll(async () => { await db?.close(); });

  it('backfills historical attempts without inventing dispatch dates and runs only once', async () => {
    // Only this fresh, disposable schema is rewound to the immediately preceding schema.
    // Production migrations are never rolled back or rewritten by this test.
    await db.pool.query('DROP TABLE transcription_attempts');
    await db.pool.query("DELETE FROM planner_migrations WHERE name = '0008_voice_attempt_accounting.sql'");
    const user = (await db.pool.query('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0].id as string;
    const id = randomUUID();
    const neverSent = randomUUID();
    const created = new Date('2026-08-31T23:59:59Z');
    const updated = new Date('2026-09-01T00:00:01Z');
    await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, attempts, created_at, updated_at)
      VALUES ($1, $2, 'failed', 3000, 100, $3, 2, $4, $5), ($6, $2, 'received', 3000, 100, $3, 0, $5, $5)`,
    [id, user, 'a'.repeat(64), created, updated, neverSent]);
    await migrate(db.pool);
    const attempts = (await db.pool.query('SELECT transcription_id, attempt, state, reserved_at, budget_at, dispatched_at, released_at FROM transcription_attempts ORDER BY attempt')).rows;
    expect(attempts).toEqual([1, 2].map((attempt) => ({ transcription_id: id, attempt, state: 'legacy', reserved_at: created, budget_at: created, dispatched_at: null, released_at: null })));
    // The previous schema only knew creation date and attempt count; updated_at is not evidence of an HTTP call.
    expect(await monthlyVoiceMilliseconds(db.pool, user, created)).toBe(6000);
    expect(await monthlyVoiceMilliseconds(db.pool, user, updated)).toBe(0);
    await migrate(db.pool);
    expect((await db.pool.query('SELECT count(*)::int AS n FROM transcription_attempts')).rows[0].n).toBe(2);

    const other = (await db.pool.query('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0].id as string;
    await expect(db.pool.query(`INSERT INTO transcription_attempts (transcription_id, attempt, user_id, duration_ms, state, reserved_at, budget_at)
      VALUES ($1, 3, $2, 3000, 'reserved', $3, $3)`, [id, other, updated])).rejects.toMatchObject({ code: '23503' });
    await expect(db.pool.query(`INSERT INTO transcription_attempts (transcription_id, attempt, user_id, duration_ms, state, reserved_at, budget_at)
      VALUES ($1, 3, $2, 3000, 'dispatched', $3, $3)`, [id, user, updated])).rejects.toMatchObject({ code: '23514' });
  });
});
