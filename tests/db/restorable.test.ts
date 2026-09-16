import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createTestDatabase } from './helpers.js';

// pg_restore loads data with an empty search_path; CHECK helpers must still resolve each other.
describe('constraints under a restore search_path', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  beforeAll(async () => { db = await createTestDatabase(); });
  afterAll(async () => { await db?.close(); });

  it('validates every CHECK helper with search_path = empty', async () => {
    const client = await db.pool.connect();
    const table = (name: string) => `"${db.schema}".${name}`;
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('search_path', '', true)");
      const userId = (await client.query<{ id: string }>(`INSERT INTO ${table('users')} DEFAULT VALUES RETURNING id`)).rows[0]!.id;
      const taskId = randomUUID();
      await client.query(`INSERT INTO ${table('tasks')} (id, user_id, title, scheduled_date, scheduled_time, scheduled_time_zone, recurrence)
        VALUES ($1, $2, 'Série', '2026-09-17', '08:00', 'Europe/Zurich', '{"v":1,"mode":"fixed","freq":"daily","interval":1,"until":"2026-12-31"}')`, [taskId, userId]);
      await client.query(`INSERT INTO ${table('task_occurrences')} (id, user_id, task_id, occurrence_key, override_date, override_time, override_time_zone)
        VALUES ($1, $2, $3, '2026-09-18', '2026-09-19', '09:00', 'Europe/Lisbon')`, [randomUUID(), userId, taskId]);
      await expect(client.query(`INSERT INTO ${table('tasks')} (id, user_id, title, scheduled_date, scheduled_time, scheduled_time_zone)
        VALUES ($1, $2, 'Fuseau invalide', '2026-09-17', '08:00', 'Mars/Olympus')`, [randomUUID(), userId])).rejects.toMatchObject({ code: '23514' });
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
