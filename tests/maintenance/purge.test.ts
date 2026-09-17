import { randomUUID } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { purgeExpired, purgeIfDue } from '../../src/modules/maintenance/index.js';
import type { CommandActor } from '../../src/modules/sync/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { monthlyVoiceMilliseconds } from '../../src/modules/voice/usage.js';
import { atRevision, command, commandRunner } from '../sync/helpers.js';

const DAY = 86_400_000;

describe('daily purge (03_Data_Model.md §8)', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let actor: CommandActor;
  let now = new Date('2026-08-01T10:00:00Z');
  let runner: ReturnType<typeof commandRunner>;

  beforeEach(async () => {
    db = await createTestDatabase();
    now = new Date('2026-08-01T10:00:00Z');
    const user = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    actor = { userId: user, deviceId: null, origin: 'manual' };
    runner = commandRunner(db.pool, actor, () => now);
  });
  afterEach(async () => { await db?.close(); });

  const count = async (sql: string, params: unknown[]) => Number((await db.pool.query<{ n: string }>(sql, params)).rows[0]!.n);

  it('removes what stayed 30 days in the trash, leaves tombstones, keeps the rest', async () => {
    const listId = randomUUID();
    const oldSeries = randomUUID();
    const recentTask = randomUUID();
    const liveTask = randomUUID();
    const liveReminder = randomUUID();
    const removedReminder = randomUUID();
    await runner.apply(command('project.create', listId, { name: 'Ancienne liste' }));
    await runner.apply(command('task.create', oldSeries, {
      title: 'Arroser', projectId: listId, schedule: { date: '2026-07-01', time: '08:00', timeZone: 'Europe/Zurich' },
      recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 1 },
      reminders: [{ id: randomUUID(), rule: { kind: 'before_start', offsetMinutes: 10 } }],
    }));
    await runner.apply(command('occurrence.reschedule', oldSeries, {
      occurrenceKey: '2026-07-02', schedule: { date: '2026-07-03', time: '08:00', timeZone: 'Europe/Zurich' },
    }));
    await runner.apply(command('task.create', liveTask, {
      title: 'Garder', schedule: { date: '2026-08-02', time: '09:00', timeZone: 'Europe/Zurich' },
      reminders: [
        { id: liveReminder, rule: { kind: 'before_start', offsetMinutes: 5 } },
        { id: removedReminder, rule: { kind: 'before_start', offsetMinutes: 60 } },
      ],
    }));
    await runner.apply(command('task.create', recentTask, { title: 'Supprimée récemment' }));
    await runner.apply(command('task.delete', oldSeries));
    await runner.apply(command('reminder.remove', liveTask, { id: removedReminder }));
    await runner.apply(command('project.delete', listId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1)));
    await db.pool.query(
      `INSERT INTO ai_actions (id, user_id, group_id, plan_index, client_command_id, aggregate_type, aggregate_id, command_type, changes, resulting_revision, undo_state)
       VALUES ($1, $2, $3, 0, $4, 'task', $5, 'task.create', '{}', 1, 'not_undoable')`,
      [randomUUID(), actor.userId, randomUUID(), randomUUID(), oldSeries]);
    await db.pool.query(
      `INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, created_at)
       VALUES ($1, $2, 'erased', 5000, 100, $3, $4), ($5, $2, 'erased', 5000, 100, $3, $6)`,
      [randomUUID(), actor.userId, 'a'.repeat(64), new Date(now.getTime() - 120 * DAY), randomUUID(), now]);
    await db.pool.query('UPDATE command_receipts SET created_at = $1 WHERE command_type = $2', [new Date(now.getTime() - 91 * DAY), 'project.create']);

    now = new Date(now.getTime() + 20 * DAY);
    await runner.apply(command('task.delete', recentTask));
    now = new Date(now.getTime() + 11 * DAY);

    const counts = await purgeExpired(db.pool, now);
    expect(counts).toEqual({ tasks: 1, projects: 1, reminders: 2, aiActions: 1, tombstones: 0, receipts: 0, transcriptions: 1 });
    expect(await count('SELECT count(*) AS n FROM tasks WHERE id = $1', [oldSeries])).toBe(0);
    expect(await count('SELECT count(*) AS n FROM task_occurrences WHERE task_id = $1', [oldSeries])).toBe(0);
    expect(await count('SELECT count(*) AS n FROM tasks WHERE id = ANY($1::uuid[])', [[recentTask, liveTask]])).toBe(2);
    expect(await count('SELECT count(*) AS n FROM reminders WHERE task_id = $1', [liveTask])).toBe(1);
    expect(await count('SELECT count(*) AS n FROM projects WHERE id = $1', [listId])).toBe(0);
    expect(await count("SELECT count(*) AS n FROM tombstones WHERE entity_id = ANY($1::uuid[])", [[oldSeries, listId]])).toBe(2);
    expect(await count("SELECT count(*) AS n FROM maintenance_runs WHERE kind = 'purge' AND outcome = 'succeeded'", [])).toBe(1);

    // A late command on a purged task is refused, and its identifier is never reused.
    expect(await runner.outcome(command('task.patch', oldSeries, { set: { title: 'Trop tard' } }))).toMatchObject({ outcome: 'rejected', code: 'ENTITY_PURGED' });
    expect(await runner.outcome(command('task.create', oldSeries, { title: 'Réutilisée' }))).toMatchObject({ outcome: 'rejected', code: 'ENTITY_PURGED' });
  });

  it('keeps the AI journal while its aggregate or conversation exists, then removes orphans on a later run', async () => {
    const liveTask = randomUUID();
    const deletedTask = randomUUID();
    const deletedList = randomUUID();
    await runner.apply(command('task.create', liveTask, { title: 'Garder' }));
    await runner.apply(command('task.create', deletedTask, { title: 'Supprimer' }));
    await runner.apply(command('project.create', deletedList, { name: 'Supprimer' }));
    await runner.apply(command('task.delete', deletedTask));
    await runner.apply(command('project.delete', deletedList, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1)));
    const conversationId = randomUUID();
    const turnId = randomUUID();
    await db.pool.query('INSERT INTO conversations (id, user_id) VALUES ($1, $2)', [conversationId, actor.userId]);
    await db.pool.query(`INSERT INTO assistant_turns (id, user_id, conversation_id, request_hash, status, reference_instant, time_zone, finished_at)
      VALUES ($1, $2, $3, $4, 'completed', $5, 'Europe/Zurich', $5)`, [turnId, actor.userId, conversationId, 'a'.repeat(64), now]);
    const insertAction = async (type: 'task' | 'project', aggregateId: string, sourceTurn: string | null) => {
      const id = randomUUID();
      await db.pool.query(`INSERT INTO ai_actions (id, user_id, group_id, plan_index, client_command_id, aggregate_type, aggregate_id,
        command_type, changes, resulting_revision, undo_state, turn_id)
        VALUES ($1, $2, $3, 0, $4, $5, $6, $7, '{}', 1, 'not_undoable', $8)`,
      [id, actor.userId, randomUUID(), randomUUID(), type, aggregateId, `${type}.create`, sourceTurn]);
      return id;
    };
    const liveAction = await insertAction('task', liveTask, turnId);
    const taskAction = await insertAction('task', deletedTask, turnId);
    const listAction = await insertAction('project', deletedList, turnId);
    await insertAction('task', deletedTask, null);

    now = new Date(now.getTime() + 31 * DAY);
    expect(await purgeExpired(db.pool, now)).toMatchObject({ tasks: 1, projects: 1, aiActions: 1 });
    expect(await count('SELECT count(*) AS n FROM ai_actions WHERE id = ANY($1::uuid[])', [[liveAction, taskAction, listAction]])).toBe(3);

    // Deleting the conversation nulls source links. The already-purged aggregate must not be needed
    // to find the newly orphaned journal on the next maintenance run.
    await db.pool.query('DELETE FROM conversations WHERE id = $1', [conversationId]);
    expect(await purgeExpired(db.pool, now)).toMatchObject({ tasks: 0, projects: 0, aiActions: 2 });
    expect(await count('SELECT count(*) AS n FROM ai_actions WHERE id = $1', [liveAction])).toBe(1);
    await runner.apply(command('task.delete', liveTask));
    now = new Date(now.getTime() + 31 * DAY);
    expect(await purgeExpired(db.pool, now)).toMatchObject({ tasks: 1, aiActions: 1 });
    expect(await count('SELECT count(*) AS n FROM ai_actions', [])).toBe(0);
  });

  it('retains old receipts and tombstones until an offline-horizon recovery protocol prevents stale replays', async () => {
    const id = randomUUID();
    const create = command('task.create', id, { title: 'Ancienne tâche' });
    await runner.apply(create);
    const remove = command('task.delete', id);
    await runner.apply(remove);
    await db.pool.query('UPDATE command_receipts SET created_at = $1', [now]);
    now = new Date(now.getTime() + 31 * DAY);
    await purgeExpired(db.pool, now);
    now = new Date(now.getTime() + 91 * DAY);
    expect(await purgeExpired(db.pool, now)).toMatchObject({ tombstones: 0, receipts: 0 });
    expect(await count('SELECT count(*) AS n FROM tombstones WHERE entity_id = $1', [id])).toBe(1);
    expect(await runner.run(create)).toMatchObject({ outcome: 'duplicate', original: { outcome: 'applied' } });
    expect(await runner.run(remove)).toMatchObject({ outcome: 'duplicate', original: { outcome: 'applied' } });
    expect(await runner.outcome(command('task.create', id, { title: 'Réutilisée' }))).toMatchObject({ outcome: 'rejected', code: 'ENTITY_PURGED' });
    expect(await count('SELECT count(*) AS n FROM tasks WHERE id = $1', [id])).toBe(0);
  });

  it('waits a full day after a successful run', async () => {
    expect(await purgeIfDue(db.pool, now)).not.toBeNull();
    expect(await purgeIfDue(db.pool, new Date(now.getTime() + DAY - 1))).toBeNull();
    expect(await purgeIfDue(db.pool, new Date(now.getTime() + DAY))).not.toBeNull();
    expect(await count("SELECT count(*) AS n FROM maintenance_runs WHERE kind = 'purge' AND outcome = 'succeeded'", [])).toBe(2);
  });

  it('keeps a recent voice attempt on an old recording so purge cannot refund this month', async () => {
    const id = randomUUID();
    await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, attempts, created_at)
      VALUES ($1, $2, 'erased', 3000, 100, $3, 2, $4)`, [id, actor.userId, 'b'.repeat(64), new Date(now.getTime() - 120 * DAY)]);
    await db.pool.query(`INSERT INTO transcription_attempts (transcription_id, attempt, user_id, duration_ms, state, reserved_at, budget_at, dispatched_at)
      VALUES ($1, 1, $2, 3000, 'legacy', $3, $3, NULL), ($1, 2, $2, 3000, 'dispatched', $4, $4, $4)`,
    [id, actor.userId, new Date(now.getTime() - 120 * DAY), now]);
    expect(await monthlyVoiceMilliseconds(db.pool, actor.userId, now)).toBe(3000);
    expect(await purgeExpired(db.pool, now)).toMatchObject({ transcriptions: 0 });
    expect(await monthlyVoiceMilliseconds(db.pool, actor.userId, now)).toBe(3000);
    expect(await count('SELECT count(*) AS n FROM transcription_attempts WHERE transcription_id = $1', [id])).toBe(2);

    now = new Date(now.getTime() + 91 * DAY);
    expect(await purgeExpired(db.pool, now)).toMatchObject({ transcriptions: 1 });
    expect(await count('SELECT count(*) AS n FROM transcription_attempts WHERE transcription_id = $1', [id])).toBe(0);
  });

  it('rechecks the daily schedule under the database lock when two processes start together', async () => {
    const blocker = await db.pool.connect();
    let checks: Promise<unknown[]> | undefined;
    try {
      await blocker.query('BEGIN');
      await blocker.query("SELECT pg_advisory_xact_lock(hashtext('planner.purge'))");
      checks = Promise.all([purgeIfDue(db.pool, now), purgeIfDue(db.pool, now)]);
      // Hold the real PostgreSQL lock until both independent connections are waiting. With the old
      // implementation both have already read the same last-run timestamp before reaching this point.
      await vi.waitFor(async () => {
        const waiting = await blocker.query<{ n: number }>(`SELECT count(*)::int AS n FROM pg_locks waiting
          JOIN pg_locks held ON held.locktype = waiting.locktype AND held.database = waiting.database
            AND held.classid = waiting.classid AND held.objid = waiting.objid AND held.objsubid = waiting.objsubid
          WHERE held.pid = pg_backend_pid() AND held.locktype = 'advisory' AND held.granted AND NOT waiting.granted`);
        expect(waiting.rows[0]!.n).toBe(2);
      }, { timeout: 5000, interval: 20 });
      await blocker.query('COMMIT');
      const results = await checks;
      expect(results.filter((result) => result !== null)).toHaveLength(1);
      expect(results.filter((result) => result === null)).toHaveLength(1);
      expect(await count("SELECT count(*) AS n FROM maintenance_runs WHERE kind = 'purge' AND outcome = 'succeeded'", [])).toBe(1);
    } finally {
      await blocker.query('ROLLBACK');
      blocker.release();
      await checks?.catch(() => undefined);
    }
  });
});
