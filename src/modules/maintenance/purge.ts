import type pg from 'pg';

/** Retention (04_Backend/03_Data_Model.md §8, ADR-021). */
export interface PurgeLimits {
  /** A deleted task, list or reminder stays restorable this long. */
  trashDays: number;
  /** Billing rows of transcriptions no message uses. */
  transcriptionDays: number;
}

export const DEFAULT_PURGE_LIMITS: PurgeLimits = { trashDays: 30, transcriptionDays: 90 };

export interface PurgeCounts {
  tasks: number;
  projects: number;
  reminders: number;
  aiActions: number;
  tombstones: number;
  receipts: number;
  transcriptions: number;
}

/**
 * Physical purge of what left the trash, in one transaction. A purged task or list leaves a tombstone,
 * so that a late command is rejected ENTITY_PURGED and its identifier is never reused. The AI journal
 * lives as long as the aggregate OR its source conversation. A list still used by a task is kept.
 * Receipts and tombstones are retained until sync can block and recover queues beyond its supported
 * offline horizon. Expiring them now would allow an old command to apply again or reuse a purged ID.
 */
export async function purgeExpired(pool: pg.Pool, now: Date, limits: PurgeLimits = DEFAULT_PURGE_LIMITS): Promise<PurgeCounts> {
  return (await runPurge(pool, now, limits, false))!;
}

async function runPurge(pool: pg.Pool, now: Date, limits: PurgeLimits, onlyIfDue: boolean): Promise<PurgeCounts | null> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Check the schedule after obtaining the lock: a concurrent process may just have finished.
    await client.query("SELECT pg_advisory_xact_lock(hashtext('planner.purge'))");
    if (onlyIfDue) {
      const last = await client.query<{ finished_at: Date | null }>(
        "SELECT max(finished_at) AS finished_at FROM maintenance_runs WHERE kind = 'purge' AND outcome = 'succeeded'");
      const previous = last.rows[0]?.finished_at;
      if (previous && now.getTime() - new Date(previous).getTime() < 24 * 3_600_000) {
        await client.query('COMMIT');
        return null;
      }
    }
    const trashBefore = new Date(now.getTime() - limits.trashDays * 86_400_000);
    const transcriptionsBefore = new Date(now.getTime() - limits.transcriptionDays * 86_400_000);

    const tasks = await client.query<{ id: string; user_id: string }>(
      'SELECT id, user_id FROM tasks WHERE deleted_at < $1 ORDER BY id FOR UPDATE', [trashBefore]);
    const taskIds = tasks.rows.map((row) => row.id);
    let reminders = 0;
    if (taskIds.length > 0) {
      await client.query('DELETE FROM task_occurrences WHERE task_id = ANY($1::uuid[])', [taskIds]);
      reminders += (await client.query('DELETE FROM reminders WHERE task_id = ANY($1::uuid[])', [taskIds])).rowCount ?? 0;
      await client.query('DELETE FROM tasks WHERE id = ANY($1::uuid[])', [taskIds]);
      await insertTombstones(client, 'task', tasks.rows, now);
    }

    reminders += (await client.query('DELETE FROM reminders WHERE deleted_at < $1', [trashBefore])).rowCount ?? 0;

    const projects = await client.query<{ id: string; user_id: string }>(
      `SELECT p.id, p.user_id FROM projects p
        WHERE p.deleted_at < $1 AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.user_id = p.user_id AND t.project_id = p.id)
        ORDER BY p.id FOR UPDATE`, [trashBefore]);
    const projectIds = projects.rows.map((row) => row.id);
    if (projectIds.length > 0) {
      await client.query('DELETE FROM projects WHERE id = ANY($1::uuid[])', [projectIds]);
      await insertTombstones(client, 'project', projects.rows, now);
    }

    // Also finds actions whose aggregate was purged earlier and whose conversation was deleted since.
    const aiActions = await removeOrphanJournal(client);
    // The monthly budget only reads the current month; a row a message still points to stays.
    const transcriptions = (await client.query(
      `DELETE FROM transcriptions t
        WHERE t.created_at < $1 AND t.status IN ('erased','failed','abandoned')
          AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.user_id = t.user_id AND m.transcription_id = t.id)`,
      [transcriptionsBefore])).rowCount ?? 0;

    const counts: PurgeCounts = {
      tasks: taskIds.length, projects: projectIds.length, reminders, aiActions, tombstones: 0, receipts: 0, transcriptions,
    };
    await client.query("INSERT INTO maintenance_runs (kind, outcome, details, finished_at) VALUES ('purge', 'succeeded', $1, $2)", [counts, now]);
    await client.query('COMMIT');
    return counts;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

async function removeOrphanJournal(client: pg.PoolClient): Promise<number> {
  const actions = await client.query<{ id: string }>(
    `DELETE FROM ai_actions a
      WHERE a.turn_id IS NULL AND a.proposal_id IS NULL
        AND NOT EXISTS (SELECT 1 FROM tasks t WHERE a.aggregate_type = 'task' AND t.id = a.aggregate_id AND t.user_id = a.user_id)
        AND NOT EXISTS (SELECT 1 FROM projects p WHERE a.aggregate_type = 'project' AND p.id = a.aggregate_id AND p.user_id = a.user_id)
      RETURNING a.id`);
  const actionIds = actions.rows.map((row) => row.id);
  if (actionIds.length > 0) await client.query('DELETE FROM assistant_undos WHERE action_id = ANY($1::uuid[])', [actionIds]);
  return actionIds.length;
}

async function insertTombstones(client: pg.PoolClient, entityType: 'task' | 'project', rows: Array<{ id: string; user_id: string }>, now: Date): Promise<void> {
  await client.query(
    `INSERT INTO tombstones (entity_type, entity_id, user_id, purged_at)
     SELECT $1, id, user_id, $4 FROM unnest($2::uuid[], $3::uuid[]) AS purged(id, user_id)
     ON CONFLICT (entity_type, entity_id) DO NOTHING`,
    [entityType, rows.map((row) => row.id), rows.map((row) => row.user_id), now]);
}

/**
 * Runs the purge at most once a day, whatever the number of API processes or restarts. A failure is
 * recorded without content and tried again at the next check.
 */
export async function purgeIfDue(pool: pg.Pool, now: Date, limits: PurgeLimits = DEFAULT_PURGE_LIMITS): Promise<PurgeCounts | null> {
  try {
    return await runPurge(pool, now, limits, true);
  } catch (error) {
    const code = typeof error === 'object' && error !== null && 'code' in error ? String((error as { code: unknown }).code) : 'UNKNOWN';
    await pool.query("INSERT INTO maintenance_runs (kind, outcome, details, finished_at) VALUES ('purge', 'failed', $1, $2)", [{ code }, now])
      .catch(() => undefined);
    throw error;
  }
}
