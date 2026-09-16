import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createTestDatabase } from './helpers.js';

// PostgreSQL error classes asserted by the contract (03_Data_Model.md [SQL] markers).
const CHECK = '23514';
const FOREIGN_KEY = '23503';
const UNIQUE = '23505';

describe('SQL constraints refuse impossible domain states', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let userId: string;
  let otherUserId: string;
  let taskId: string;

  const code = async (sql: string, params: unknown[] = []): Promise<string | undefined> => {
    try { await db.pool.query(sql, params); return undefined; }
    catch (error) { return (error as { code?: string }).code; }
  };
  const insertTask = (columns: Record<string, unknown>) => {
    const values = { id: randomUUID(), user_id: userId, title: 'Appeler le garage', ...columns };
    const names = Object.keys(values);
    return code(`INSERT INTO tasks (${names.join(',')}) VALUES (${names.map((_, i) => `$${i + 1}`).join(',')})`, Object.values(values));
  };
  const insertOccurrence = (columns: Record<string, unknown>) => {
    const values = { id: randomUUID(), user_id: userId, task_id: taskId, occurrence_key: '2026-09-17', ...columns };
    const names = Object.keys(values);
    return code(`INSERT INTO task_occurrences (${names.join(',')}) VALUES (${names.map((_, i) => `$${i + 1}`).join(',')})`, Object.values(values));
  };
  const insertReminder = (columns: Record<string, unknown>) => {
    const values = { id: randomUUID(), user_id: userId, task_id: taskId, ...columns };
    const names = Object.keys(values);
    return code(`INSERT INTO reminders (${names.join(',')}) VALUES (${names.map((_, i) => `$${i + 1}`).join(',')})`, Object.values(values));
  };
  const weekly = { v: 1, mode: 'fixed', freq: 'weekly', interval: 1, byWeekday: ['TH'] };

  beforeAll(async () => {
    db = await createTestDatabase();
    userId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    otherUserId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    taskId = randomUUID();
    await db.pool.query('INSERT INTO tasks (id,user_id,title,scheduled_date,recurrence) VALUES ($1,$2,$3,$4,$5)', [taskId, userId, 'Sortir les poubelles', '2026-09-17', weekly]);
  });
  afterAll(async () => { await db?.close(); });

  describe('tasks', () => {
    it('accepts every valid temporal shape', async () => {
      expect(await insertTask({})).toBeUndefined();
      expect(await insertTask({ scheduled_date: '2026-09-17' })).toBeUndefined();
      expect(await insertTask({ scheduled_date: '2026-09-17', scheduled_time: '17:00', scheduled_time_zone: 'Europe/Zurich', scheduled_start_at: '2026-09-17T15:00:00Z', duration_minutes: 60 })).toBeUndefined();
      expect(await insertTask({ scheduled_date: '2026-09-15', deadline_date: '2026-09-18' })).toBeUndefined();
      expect(await insertTask({ status: 'completed', completed_at: '2026-09-15T10:00:00Z' })).toBeUndefined();
    });

    it.each([
      ['completed without completion instant', { status: 'completed' }],
      ['completion instant on an active task', { completed_at: '2026-09-15T10:00:00Z' }],
      ['time without date or zone', { scheduled_time: '17:00' }],
      ['time without zone', { scheduled_date: '2026-09-17', scheduled_time: '17:00' }],
      ['zone on a date-only value', { scheduled_date: '2026-09-17', scheduled_time_zone: 'Europe/Zurich' }],
      ['numeric offset instead of IANA zone', { scheduled_date: '2026-09-17', scheduled_time: '17:00', scheduled_time_zone: '+02:00' }],
      ['unknown IANA zone', { scheduled_date: '2026-09-17', scheduled_time: '17:00', scheduled_time_zone: 'Europe/Imaginary' }],
      ['time with seconds', { scheduled_date: '2026-09-17', scheduled_time: '17:00:30', scheduled_time_zone: 'Europe/Zurich' }],
      ['incoherent deadline', { deadline_time: '18:00', deadline_time_zone: 'Europe/Zurich' }],
      ['derived instant on a date-only schedule', { scheduled_date: '2026-09-17', scheduled_start_at: '2026-09-17T00:00:00Z' }],
      ['derived deadline instant without time', { deadline_date: '2026-09-18', deadline_at: '2026-09-18T21:59:00Z' }],
      ['zero duration', { duration_minutes: 0 }],
      ['duration beyond one day', { duration_minutes: 1441 }],
      ['unknown priority', { priority: 'urgent' }],
      ['blank title', { title: '   ' }],
      ['recurrence without anchor date', { recurrence: weekly }],
      ['recurrence with a deadline (V1)', { scheduled_date: '2026-09-17', deadline_date: '2026-09-18', recurrence: weekly }],
      ['derived instant on a recurring series', { scheduled_date: '2026-09-17', scheduled_time: '17:00', scheduled_time_zone: 'Europe/Zurich', scheduled_start_at: '2026-09-17T15:00:00Z', recurrence: weekly }],
    ])('rejects %s', async (_label, columns) => {
      expect(await insertTask(columns)).toBe(CHECK);
    });

    it.each([
      { v: 1, mode: 'fixed', freq: 'daily', interval: 0 },
      { v: 1, mode: 'fixed', freq: 'daily', interval: 1.5 },
      { v: 1, mode: 'fixed', freq: 'daily', interval: '1' },
      { v: 1, mode: 'fixed', freq: 'daily', interval: 1, count: 3, until: '2026-12-31' },
      { v: 1, mode: 'fixed', freq: 'daily', interval: 1, until: '2026-02-30' },
      { v: 1, mode: 'fixed', freq: 'weekly', interval: 1, byWeekday: ['TH', 'TH'] },
      { v: 1, mode: 'fixed', freq: 'weekly', interval: 1, byWeekday: ['XX'] },
      { v: 1, mode: 'fixed', freq: 'monthly', interval: 1 },
      { v: 1, mode: 'fixed', freq: 'monthly', interval: 1, byMonthDay: 32 },
      { v: 1, mode: 'fixed', freq: 'monthly', interval: 1, byMonthDay: 31, lastDayOfMonth: true },
      { v: 1, mode: 'fixed', freq: 'yearly', interval: 1 },
      { v: 1, mode: 'fixed', freq: 'daily', interval: 1, dueAt: '2026-09-17' },
      { v: 2, mode: 'fixed', freq: 'daily', interval: 1 },
      { v: 1, mode: 'after_completion', unit: 'year', interval: 1 },
      { v: 1, mode: 'after_completion', unit: 'day', interval: 90, byWeekday: ['MO'] },
    ])('rejects malformed recurrence %j', async (rule) => {
      expect(await insertTask({ scheduled_date: '2026-09-17', recurrence: rule })).toBe(CHECK);
    });

    it('accepts the V1 recurrence shapes', async () => {
      for (const rule of [
        { v: 1, mode: 'fixed', freq: 'daily', interval: 1 },
        { v: 1, mode: 'fixed', freq: 'weekly', interval: 2, byWeekday: ['MO', 'TH'], until: '2027-06-30' },
        { v: 1, mode: 'fixed', freq: 'monthly', interval: 1, byMonthDay: 31, count: 12 },
        { v: 1, mode: 'fixed', freq: 'monthly', interval: 1, lastDayOfMonth: true },
        { v: 1, mode: 'after_completion', unit: 'day', interval: 90 },
      ]) expect(await insertTask({ scheduled_date: '2026-09-17', recurrence: rule })).toBeUndefined();
    });

    it('refuses a project owned by another user', async () => {
      const foreignProject = randomUUID();
      await db.pool.query('INSERT INTO projects (id,user_id,name) VALUES ($1,$2,$3)', [foreignProject, otherUserId, 'Autre']);
      expect(await insertTask({ project_id: foreignProject })).toBe(FOREIGN_KEY);
      const ownProject = randomUUID();
      await db.pool.query('INSERT INTO projects (id,user_id,name) VALUES ($1,$2,$3)', [ownProject, userId, 'Cours']);
      expect(await insertTask({ project_id: ownProject })).toBeUndefined();
    });
  });

  describe('occurrences', () => {
    it('keeps one row per task and occurrence key', async () => {
      expect(await insertOccurrence({ occurrence_key: '2026-09-24' })).toBeUndefined();
      expect(await insertOccurrence({ occurrence_key: '2026-09-24' })).toBe(UNIQUE);
    });

    it.each(['2026-02-30', '2026-09-17~01', '2026-09-17~-1', '2026-09-17~1~2', '17/09/2026', '2026-09-17~9007199254740992'])('rejects invalid occurrence key %s', async (key) => {
      expect(await insertOccurrence({ occurrence_key: key })).toBe(CHECK);
    });

    it.each([
      ['completed without instant', { occurrence_key: '2026-10-01', status: 'completed' }],
      ['successor on an open occurrence', { occurrence_key: '2026-10-08~0', successor_occurrence_key: '2026-10-09~1' }],
      ['successor equal to itself', { occurrence_key: '2026-10-15~0', status: 'skipped', successor_occurrence_key: '2026-10-15~0' }],
      ['override time without zone', { occurrence_key: '2026-10-22', override_date: '2026-10-23', override_time: '18:00' }],
    ])('rejects %s', async (_label, columns) => {
      expect(await insertOccurrence(columns)).toBe(CHECK);
    });

    it('refuses an occurrence attached to another user task', async () => {
      expect(await insertOccurrence({ user_id: otherUserId, occurrence_key: '2026-10-29' })).toBe(FOREIGN_KEY);
    });
  });

  describe('reminders', () => {
    it('accepts one row per reminder kind', async () => {
      expect(await insertReminder({ kind: 'before_start', offset_minutes: 0 })).toBeUndefined();
      expect(await insertReminder({ kind: 'before_deadline', offset_minutes: 60 })).toBeUndefined();
      expect(await insertReminder({ kind: 'on_scheduled_day_at', local_time: '09:00' })).toBeUndefined();
      expect(await insertReminder({ kind: 'absolute', occurrence_key: '2026-09-17', absolute_date: '2026-09-17', absolute_time: '08:00', absolute_time_zone: 'Europe/Zurich' })).toBeUndefined();
    });

    it.each([
      ['relative reminder without offset', { kind: 'before_start' }],
      ['negative offset', { kind: 'before_start', offset_minutes: -5 }],
      ['offset beyond one week', { kind: 'before_start', offset_minutes: 10081 }],
      ['relative reminder with a local time', { kind: 'before_start', offset_minutes: 0, local_time: '09:00' }],
      ['day reminder without local time', { kind: 'on_deadline_day_at' }],
      ['absolute reminder without zone', { kind: 'absolute', absolute_date: '2026-09-17', absolute_time: '08:00' }],
      ['absolute reminder with an offset', { kind: 'absolute', offset_minutes: 5, absolute_date: '2026-09-17', absolute_time: '08:00', absolute_time_zone: 'Europe/Zurich' }],
      ['unknown kind', { kind: 'after_start', offset_minutes: 5 }],
      ['unknown state', { kind: 'before_start', offset_minutes: 5, state: 'scheduled' }],
    ])('rejects %s', async (_label, columns) => {
      expect(await insertReminder(columns)).toBe(CHECK);
    });
  });

  describe('reliability tables', () => {
    it('stores only terminal receipt outcomes with a SHA-256 payload hash', async () => {
      const receipt = (outcome: string, hash: string) => code('INSERT INTO command_receipts (client_command_id,user_id,origin,command_type,payload_hash,outcome,result) VALUES ($1,$2,$3,$4,$5,$6,$7)', [randomUUID(), userId, 'manual', 'task.patch', hash, outcome, {}]);
      expect(await receipt('applied', 'a'.repeat(64))).toBeUndefined();
      expect(await receipt('rejected', 'b'.repeat(64))).toBeUndefined();
      expect(await receipt('duplicate', 'c'.repeat(64))).toBe(CHECK);
      expect(await receipt('applied', 'not-a-hash')).toBe(CHECK);
    });

    it('keeps exactly one server generation', async () => {
      expect(await code('INSERT INTO server_meta DEFAULT VALUES')).toBe(UNIQUE);
      expect(await code('INSERT INTO server_meta (singleton) VALUES (false)')).toBe(CHECK);
      expect((await db.pool.query('SELECT count(*)::int AS n FROM server_meta')).rows[0].n).toBe(1);
    });
  });
});
