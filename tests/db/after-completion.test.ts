import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mutateAfterCompletion, type AfterCompletionCommand } from '../../src/modules/domain/index.js';
import { occurrenceId } from '../../src/modules/time/index.js';
import { createTestDatabase } from './helpers.js';

const ZURICH = 'Europe/Zurich';
const EVERY_90_DAYS = { v: 1, mode: 'after_completion', unit: 'day', interval: 90 };
const EVERY_DAY = { v: 1, mode: 'after_completion', unit: 'day', interval: 1 };

describe('after-completion occurrences in PostgreSQL', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let userId: string;
  let otherUserId: string;

  beforeAll(async () => {
    db = await createTestDatabase();
    userId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    otherUserId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
  });
  afterAll(async () => { await db?.close(); });

  async function createSeries(rule: object = EVERY_90_DAYS, anchor = '2026-09-16', owner = userId): Promise<string> {
    const id = randomUUID();
    await db.pool.query('INSERT INTO tasks (id,user_id,title,scheduled_date,recurrence) VALUES ($1,$2,$3,$4,$5)', [id, owner, 'Changer le filtre', anchor, rule]);
    return id;
  }
  const command = (taskId: string, overrides: Partial<AfterCompletionCommand> = {}): AfterCompletionCommand => ({
    userId, commandId: randomUUID(), taskId, occurrenceKey: '2026-09-16~0', action: 'complete',
    referenceInstant: '2026-09-15T22:30:00Z', deviceTimeZone: ZURICH, ...overrides,
  });
  const revision = async (taskId: string) => (await db.pool.query<{ revision: string }>('SELECT revision::text FROM tasks WHERE id=$1', [taskId])).rows[0]!.revision;
  const occurrences = async (taskId: string) => (await db.pool.query<{ occurrence_key: string; status: string; successor_occurrence_key: string | null; id: string }>(
    'SELECT id, occurrence_key, status, successor_occurrence_key FROM task_occurrences WHERE task_id=$1 ORDER BY occurrence_key', [taskId])).rows;

  it('completes the current cycle from the device civil date and writes a durable receipt', async () => {
    const taskId = await createSeries();
    const input = command(taskId);
    const result = await mutateAfterCompletion(db.pool, input);
    // 22:30 UTC on 15 September is already 16 September in Zurich: +90 days = 15 December.
    expect(result).toMatchObject({ outcome: 'applied', receiptOutcome: 'applied', result: { status: 'completed', successorOccurrenceKey: '2026-12-15~1', revision: '2' } });
    expect(result.result.occurrenceId).toBe(occurrenceId(taskId, '2026-09-16~0'));
    expect(await occurrences(taskId)).toEqual([{ id: occurrenceId(taskId, '2026-09-16~0'), occurrence_key: '2026-09-16~0', status: 'completed', successor_occurrence_key: '2026-12-15~1' }]);
    const receipt = (await db.pool.query('SELECT outcome, command_type, origin FROM command_receipts WHERE client_command_id=$1', [input.commandId])).rows[0];
    expect(receipt).toEqual({ outcome: 'applied', command_type: 'occurrence.complete', origin: 'manual' });
  });

  it('replays the same command without a second effect and refuses a reused key with another payload', async () => {
    const taskId = await createSeries();
    const input = command(taskId);
    const first = await mutateAfterCompletion(db.pool, input);
    const replay = await mutateAfterCompletion(db.pool, input);
    expect(replay).toEqual({ outcome: 'duplicate', receiptOutcome: 'applied', result: first.result });
    expect(await revision(taskId)).toBe('2');
    const reused = await mutateAfterCompletion(db.pool, { ...input, action: 'skip' });
    expect(reused).toMatchObject({ outcome: 'rejected', result: { code: 'IDEMPOTENCY_KEY_REUSED' } });
    expect(await revision(taskId)).toBe('2');
    const foreign = await mutateAfterCompletion(db.pool, { ...input, userId: otherUserId });
    expect(foreign).toMatchObject({ outcome: 'rejected', result: { code: 'IDEMPOTENCY_KEY_REUSED' } });
  });

  it('creates exactly one successor when different commands complete the same cycle concurrently', async () => {
    const taskId = await createSeries();
    const results = await Promise.all(Array.from({ length: 6 }, () => mutateAfterCompletion(db.pool, command(taskId))));
    expect(results.filter((r) => r.outcome === 'applied')).toHaveLength(1);
    expect(results.filter((r) => r.outcome === 'duplicate')).toHaveLength(5);
    expect(new Set(results.map((r) => r.result.successorOccurrenceKey))).toEqual(new Set(['2026-12-15~1']));
    expect(await occurrences(taskId)).toHaveLength(1);
    expect(await revision(taskId)).toBe('2');
  });

  it('serializes concurrent retries of one command into one effect and one receipt', async () => {
    const taskId = await createSeries();
    const input = command(taskId);
    const results = await Promise.all(Array.from({ length: 6 }, () => mutateAfterCompletion(db.pool, input)));
    expect(results.map((r) => r.outcome).sort()).toEqual(['applied', 'duplicate', 'duplicate', 'duplicate', 'duplicate', 'duplicate']);
    expect((await db.pool.query('SELECT count(*)::int AS n FROM command_receipts WHERE client_command_id=$1', [input.commandId])).rows[0].n).toBe(1);
    expect(await revision(taskId)).toBe('2');
  });

  it('gives an early completion on the same date a distinct identity', async () => {
    const taskId = await createSeries(EVERY_DAY, '2026-09-16');
    const morning = '2026-09-15T08:00:00Z';
    const first = await mutateAfterCompletion(db.pool, command(taskId, { referenceInstant: morning }));
    expect(first.result.successorOccurrenceKey).toBe('2026-09-16~1');
    const second = await mutateAfterCompletion(db.pool, command(taskId, { occurrenceKey: '2026-09-16~1', referenceInstant: morning }));
    expect(second).toMatchObject({ outcome: 'applied', result: { successorOccurrenceKey: '2026-09-16~2' } });
    const rows = await occurrences(taskId);
    expect(rows.map((row) => row.occurrence_key)).toEqual(['2026-09-16~0', '2026-09-16~1']);
    expect(new Set(rows.map((row) => row.id)).size).toBe(2);
    expect(await revision(taskId)).toBe('3');
  });

  it('only accepts the current cycle and keeps closed cycles idempotent', async () => {
    const taskId = await createSeries();
    await mutateAfterCompletion(db.pool, command(taskId));
    expect(await mutateAfterCompletion(db.pool, command(taskId, { occurrenceKey: '2027-01-01~1' })))
      .toMatchObject({ outcome: 'rejected', result: { code: 'OCCURRENCE_NOT_CURRENT' } });
    expect(await mutateAfterCompletion(db.pool, command(taskId, { occurrenceKey: '2026-09-16~0', action: 'skip' })))
      .toMatchObject({ outcome: 'duplicate', result: { status: 'completed' } });
    expect(await mutateAfterCompletion(db.pool, command(taskId, { occurrenceKey: '2026-12-15~1', action: 'skip' })))
      .toMatchObject({ outcome: 'applied', result: { status: 'skipped' } });
    expect(await revision(taskId)).toBe('3');
  });

  it('reopens a cycle whose successor is intact, and refuses once the successor changed', async () => {
    const taskId = await createSeries();
    await mutateAfterCompletion(db.pool, command(taskId));
    const reopened = await mutateAfterCompletion(db.pool, command(taskId, { action: 'reopen' }));
    expect(reopened).toMatchObject({ outcome: 'applied', result: { status: 'open', successorOccurrenceKey: null, revision: '3' } });
    expect(await mutateAfterCompletion(db.pool, command(taskId, { action: 'reopen' })))
      .toMatchObject({ outcome: 'duplicate', result: { status: 'open' } });
    // The reopened cycle is current again; closing it recomputes a fresh successor.
    await mutateAfterCompletion(db.pool, command(taskId, { referenceInstant: '2026-09-20T10:00:00Z' }));
    await mutateAfterCompletion(db.pool, command(taskId, { occurrenceKey: '2026-12-19~1', referenceInstant: '2026-12-19T10:00:00Z' }));
    expect(await mutateAfterCompletion(db.pool, command(taskId, { action: 'reopen' })))
      .toMatchObject({ outcome: 'rejected', result: { code: 'SUCCESSOR_ALREADY_CHANGED' } });
    expect(await mutateAfterCompletion(db.pool, command(taskId, { occurrenceKey: '2026-12-19~1', action: 'reopen' })))
      .toMatchObject({ outcome: 'applied', result: { status: 'open' } });
  });

  it('checks preconditions, ownership, deletion and series type before any effect', async () => {
    const taskId = await createSeries();
    expect(await mutateAfterCompletion(db.pool, command(taskId, { expectedRevision: '7' })))
      .toMatchObject({ outcome: 'rejected', result: { code: 'REVISION_MISMATCH', currentRevision: '1' } });
    expect(await mutateAfterCompletion(db.pool, command(taskId, { expectedRevision: '1' })))
      .toMatchObject({ outcome: 'applied' });

    const foreignTask = await createSeries(EVERY_90_DAYS, '2026-09-16', otherUserId);
    expect(await mutateAfterCompletion(db.pool, command(foreignTask)))
      .toMatchObject({ outcome: 'rejected', result: { code: 'ENTITY_NOT_FOUND' } });

    const deleted = await createSeries();
    await db.pool.query('UPDATE tasks SET deleted_at = now() WHERE id=$1', [deleted]);
    expect(await mutateAfterCompletion(db.pool, command(deleted)))
      .toMatchObject({ outcome: 'rejected', result: { code: 'TASK_DELETED' } });

    const fixed = await createSeries({ v: 1, mode: 'fixed', freq: 'daily', interval: 1 });
    expect(await mutateAfterCompletion(db.pool, command(fixed)))
      .toMatchObject({ outcome: 'rejected', result: { code: 'NOT_AFTER_COMPLETION_SERIES' } });

    const rejected = command(deleted);
    await mutateAfterCompletion(db.pool, rejected);
    const stored = (await db.pool.query('SELECT outcome FROM command_receipts WHERE client_command_id=$1', [rejected.commandId])).rows[0];
    expect(stored).toEqual({ outcome: 'rejected' });
    expect(await occurrences(foreignTask)).toHaveLength(0);
  });

  it('rejects malformed commands before touching the database', async () => {
    const taskId = await createSeries();
    await expect(mutateAfterCompletion(db.pool, command(taskId, { occurrenceKey: '2026-09-16' }))).rejects.toThrow();
    await expect(mutateAfterCompletion(db.pool, command(taskId, { deviceTimeZone: '+02:00' }))).rejects.toThrow();
    await expect(mutateAfterCompletion(db.pool, { ...command(taskId), ownerId: userId } as AfterCompletionCommand)).rejects.toThrow();
    expect(await revision(taskId)).toBe('1');
  });
});
