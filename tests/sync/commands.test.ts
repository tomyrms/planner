import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { CommandActor, RawCommand } from '../../src/modules/sync/index.js';
import { occurrenceId } from '../../src/modules/time/index.js';
import { createTestDatabase } from '../db/helpers.js';
import {
  RECORDED_AT, ZURICH, afterCommand, atRevision, command, commandRunner, occurrenceRows, reminderRows, taskRow,
} from './helpers.js';

const WEEKLY_THURSDAY = { v: 1, mode: 'fixed', freq: 'weekly', interval: 1, byWeekday: ['TH'] };
const DAILY = { v: 1, mode: 'fixed', freq: 'daily', interval: 1 };
const EVERY_90_DAYS = { v: 1, mode: 'after_completion', unit: 'day', interval: 90 };
const EVERY_DAY = { v: 1, mode: 'after_completion', unit: 'day', interval: 1 };
const at = (date: string, time: string) => ({ date, time, timeZone: ZURICH });
const day = (date: string) => ({ date, time: null, timeZone: null });

describe('sync command executor in PostgreSQL', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let actor: CommandActor;
  let other: CommandActor;
  let now: Date;
  let run: ReturnType<typeof commandRunner>['run'];
  let outcome: ReturnType<typeof commandRunner>['outcome'];
  let apply: ReturnType<typeof commandRunner>['apply'];

  beforeAll(async () => {
    db = await createTestDatabase();
    const userId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    const otherId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    actor = { userId, deviceId: null, origin: 'manual' };
    other = { userId: otherId, deviceId: null, origin: 'manual' };
    ({ run, outcome, apply } = commandRunner(db.pool, actor, () => now));
  });
  beforeEach(() => { now = new Date('2026-09-16T08:30:00Z'); });
  afterAll(async () => { await db?.close(); });

  async function createTask(payload: Record<string, unknown> = {}, as: CommandActor = actor): Promise<string> {
    const id = randomUUID();
    await apply(command('task.create', id, { title: 'Appeler le garage', ...payload }), as);
    return id;
  }
  async function createList(name = 'Cours C#', as: CommandActor = actor): Promise<string> {
    const id = randomUUID();
    await apply(command('project.create', id, { name }), as);
    return id;
  }
  const receipt = async (clientCommandId: string) => (await db.pool.query(
    'SELECT outcome, command_type, origin, result FROM command_receipts WHERE client_command_id = $1', [clientCommandId])).rows[0];

  describe('receipts and idempotency', () => {
    it('applies a task lifecycle with one revision per accepted change and a durable receipt', async () => {
      const id = randomUUID();
      const create = command('task.create', id, { title: '  Réviser le devoir  ', notes: 'Chapitre 3', schedule: at('2026-09-18', '17:00') });
      expect(await run(create)).toEqual({ clientCommandId: create.clientCommandId, outcome: 'applied', revision: 1, aggregateId: id });
      expect(await taskRow(db.pool, id)).toMatchObject({
        title: 'Réviser le devoir', status: 'active', scheduled_date: '2026-09-18', scheduled_time: '17:00:00',
        scheduled_time_zone: ZURICH, search_text: 'reviser le devoir chapitre 3', revision: 1,
      });
      expect((await taskRow(db.pool, id))!.scheduled_start_at).toEqual(new Date('2026-09-18T15:00:00Z'));
      expect(await receipt(create.clientCommandId)).toEqual({
        outcome: 'applied', command_type: 'task.create', origin: 'manual', result: { revision: 1, aggregateId: id },
      });

      expect(await apply(command('task.patch', id, { set: { priority: 'high' } }))).toMatchObject({ revision: 2 });
      expect(await apply(command('task.complete', id))).toMatchObject({ revision: 3 });
      expect((await taskRow(db.pool, id))!.completed_at).toEqual(new Date(RECORDED_AT));
      expect(await apply(command('task.complete', id))).toEqual(expect.objectContaining({ revision: 3, noop: true }));
      expect(await apply(command('task.reopen', id))).toMatchObject({ revision: 4 });
      expect(await apply(command('task.delete', id))).toMatchObject({ revision: 5 });
      expect(await outcome(command('task.patch', id, { set: { title: 'Trop tard' } }))).toMatchObject({ outcome: 'rejected', code: 'TASK_DELETED' });
      expect(await outcome(command('task.complete', id))).toMatchObject({ outcome: 'rejected', code: 'TASK_DELETED' });
      expect(await apply(command('task.restore', id))).toMatchObject({ revision: 6 });
      expect(await taskRow(db.pool, id)).toMatchObject({ deleted_at: null, deleted_by_command_id: null, title: 'Réviser le devoir', revision: 6 });
    });

    it('replays a known command, refuses a reused identifier and treats UUID case as the same identifier', async () => {
      const id = await createTask();
      const patch = command('task.patch', id, { set: { title: 'Nouveau titre' } });
      const first = await run(patch);
      expect(await run(patch)).toEqual({ clientCommandId: patch.clientCommandId, outcome: 'duplicate', original: { outcome: 'applied', revision: 2, aggregateId: id } });
      expect(await run({ ...patch, clientCommandId: patch.clientCommandId.toUpperCase() })).toMatchObject({ outcome: 'duplicate' });
      expect(first).toMatchObject({ outcome: 'applied', revision: 2 });
      expect(await run({ ...patch, payload: { set: { title: 'Autre' } } })).toMatchObject({ outcome: 'rejected', code: 'IDEMPOTENCY_KEY_REUSED' });
      expect(await run(patch, other)).toMatchObject({ outcome: 'rejected', code: 'IDEMPOTENCY_KEY_REUSED' });
      expect(await taskRow(db.pool, id)).toMatchObject({ title: 'Nouveau titre', revision: 2 });
    });

    it('serializes concurrent retries of one command into one effect and one receipt', async () => {
      const id = await createTask();
      const patch = command('task.patch', id, { set: { notes: 'Une seule fois' } });
      const results = await Promise.all(Array.from({ length: 6 }, () => run(patch)));
      expect(results.map((result) => result.outcome).sort()).toEqual(['applied', 'duplicate', 'duplicate', 'duplicate', 'duplicate', 'duplicate']);
      expect((await db.pool.query('SELECT count(*)::int AS n FROM command_receipts WHERE client_command_id = $1', [patch.clientCommandId])).rows[0].n).toBe(1);
      expect((await taskRow(db.pool, id))!.revision).toBe(2);
    });

    it('keeps every concurrent patch of one task and never loses a revision', async () => {
      const id = await createTask();
      const results = await Promise.all(Array.from({ length: 8 }, (_, index) => run(command('task.patch', id, { set: { notes: `note ${index}` } }))));
      expect(results.every((result) => result.outcome === 'applied')).toBe(true);
      expect(results.map((result) => (result as { revision: number }).revision).sort((a, b) => a - b)).toEqual([2, 3, 4, 5, 6, 7, 8, 9]);
      expect((await taskRow(db.pool, id))!.revision).toBe(9);
    });

    it('stores explicit rejections for unsupported types, versions and malformed payloads', async () => {
      const id = await createTask();
      const cases: Array<[RawCommand, string]> = [
        [command('task.archive', id), 'PAYLOAD_VERSION_UNSUPPORTED'],
        [{ ...command('task.patch', id, { set: { title: 'x' } }), payloadVersion: 2 }, 'PAYLOAD_VERSION_UNSUPPORTED'],
        [command('task.patch', id, { set: {} }), 'VALIDATION_FAILED'],
        [command('task.patch', id, { set: { title: 'x', userId: other.userId } }), 'VALIDATION_FAILED'],
        [command('task.patch', id, { set: { schedule: { date: '2026-02-30', time: null, timeZone: null } } }), 'VALIDATION_FAILED'],
        [command('task.patch', id, { set: { schedule: { date: '2026-09-18', time: '17:00', timeZone: '+02:00' } } }), 'VALIDATION_FAILED'],
        [{ ...command('task.complete', id), aggregate: { type: 'project', id } }, 'VALIDATION_FAILED'],
        [command('series.end', id), 'VALIDATION_FAILED'],
        [command('task.create', randomUUID(), { title: 'x' }, atRevision(1)), 'VALIDATION_FAILED'],
      ];
      for (const [input, code] of cases) {
        expect(await run(input), input.type).toMatchObject({ outcome: 'rejected', code });
        expect(await receipt(input.clientCommandId)).toMatchObject({ outcome: 'rejected', result: { code } });
      }
      expect((await taskRow(db.pool, id))!.revision).toBe(1);
    });

    it('clamps a client action time to five minutes after the server clock', async () => {
      const id = await createTask();
      await apply(command('task.complete', id, undefined, { clientRecordedAt: '2030-01-01T00:00:00Z' }));
      expect((await taskRow(db.pool, id))!.completed_at).toEqual(new Date('2026-09-16T08:35:00Z'));
    });
  });

  describe('preconditions and ownership', () => {
    it('checks revision preconditions and chains offline edits with afterCommand', async () => {
      const id = await createTask();
      expect(await outcome(command('task.patch', id, { set: { title: 'x' } }, atRevision(7)))).toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 1 });
      const first = command('task.patch', id, { set: { title: 'Étape 1' } }, atRevision(1));
      const second = command('task.patch', id, { set: { title: 'Étape 2' } }, afterCommand(first));
      const third = command('task.patch', id, { set: { title: 'Étape 3' } }, afterCommand(second));
      for (const input of [first, second, third]) await apply(input);
      expect(await taskRow(db.pool, id)).toMatchObject({ title: 'Étape 3', revision: 4 });

      // Another device changed the task in between: the stale chain is refused.
      const stale = command('task.patch', id, { set: { title: 'Obsolète' } }, afterCommand(second));
      expect(await outcome(stale)).toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 4 });
      // A no-op keeps the revision, so a command chained after it still applies.
      const unchanged = command('task.patch', id, { set: { title: 'Étape 3' } }, afterCommand(third));
      expect(await apply(unchanged)).toMatchObject({ revision: 4, noop: true });
      expect(await apply(command('task.patch', id, { set: { title: 'Étape 4' } }, afterCommand(unchanged)))).toMatchObject({ revision: 5 });
    });

    it('rejects a dependency on a rejected, unknown, foreign or unrelated command', async () => {
      const id = await createTask();
      const otherTask = await createTask();
      const rejected = command('task.patch', id, { set: { title: 'x' } }, atRevision(9));
      await run(rejected);
      expect(await outcome(command('task.patch', id, { set: { title: 'y' } }, afterCommand(rejected)))).toMatchObject({ code: 'DEPENDENCY_REJECTED', currentRevision: 1 });
      expect(await outcome(command('task.patch', id, { set: { title: 'y' } }, { precondition: { kind: 'afterCommand', clientCommandId: randomUUID() } })))
        .toMatchObject({ code: 'DEPENDENCY_REJECTED' });
      const unrelated = command('task.patch', otherTask, { set: { title: 'autre' } });
      await apply(unrelated);
      expect(await outcome(command('task.patch', id, { set: { title: 'y' } }, afterCommand(unrelated)))).toMatchObject({ code: 'REVISION_MISMATCH' });
      const foreignTask = await createTask({}, other);
      const foreign = command('task.patch', foreignTask, { set: { title: 'autre' } });
      await apply(foreign, other);
      expect(await outcome(command('task.patch', id, { set: { title: 'y' } }, afterCommand(foreign)))).toMatchObject({ code: 'DEPENDENCY_REJECTED' });
      expect((await taskRow(db.pool, id))!.revision).toBe(1);
    });

    it('never reveals, updates or creates through another user or a purged identifier', async () => {
      const foreign = await createTask({}, other);
      expect(await outcome(command('task.patch', foreign, { set: { title: 'volé' } }))).toMatchObject({ code: 'ENTITY_NOT_FOUND' });
      expect(await outcome(command('task.delete', foreign))).toMatchObject({ code: 'ENTITY_NOT_FOUND' });
      expect(await outcome(command('task.create', foreign, { title: 'collision' }))).toMatchObject({ code: 'ENTITY_ALREADY_EXISTS' });
      expect(await taskRow(db.pool, foreign)).toMatchObject({ title: 'Appeler le garage', revision: 1 });

      const unknown = randomUUID();
      expect(await outcome(command('task.patch', unknown, { set: { title: 'x' } }))).toMatchObject({ code: 'ENTITY_NOT_FOUND' });
      expect(await taskRow(db.pool, unknown)).toBeUndefined();
      const purged = randomUUID();
      await db.pool.query("INSERT INTO tombstones (entity_type, entity_id, user_id) VALUES ('task', $1, $2)", [purged, actor.userId]);
      expect(await outcome(command('task.patch', purged, { set: { title: 'x' } }))).toMatchObject({ code: 'ENTITY_PURGED' });
      expect(await outcome(command('task.create', purged, { title: 'x' }))).toMatchObject({ code: 'ENTITY_PURGED' });
      expect(await outcome(command('project.patch', randomUUID(), { set: { name: 'x' } }))).toMatchObject({ code: 'ENTITY_NOT_FOUND' });
    });

    it('validates list references on create and move', async () => {
      const foreignList = await createList('Privé', other);
      expect(await outcome(command('task.create', randomUUID(), { title: 'x', projectId: foreignList }))).toMatchObject({ code: 'FORBIDDEN_REFERENCE' });
      expect(await outcome(command('task.create', randomUUID(), { title: 'x', projectId: randomUUID() }))).toMatchObject({ code: 'FORBIDDEN_REFERENCE' });
      const list = await createList();
      const id = await createTask({ title: 'Devoir', projectId: list.toUpperCase() });
      expect(await taskRow(db.pool, id)).toMatchObject({ project_id: list, search_text: 'devoir cours c#' });
      expect(await outcome(command('task.patch', id, { set: { projectId: foreignList } }))).toMatchObject({ code: 'FORBIDDEN_REFERENCE' });
      expect(await apply(command('task.patch', id, { set: { projectId: null } }))).toMatchObject({ revision: 2 });
      expect(await taskRow(db.pool, id)).toMatchObject({ project_id: null, search_text: 'devoir' });
    });
  });

  describe('one-off tasks and reminders', () => {
    it('derives projections and keeps a reminder inactive while its base is missing', async () => {
      const reminderId = randomUUID();
      const id = await createTask({
        schedule: at('2026-10-25', '02:30'), deadline: at('2026-10-30', '18:00'),
        reminders: [{ id: reminderId, rule: { kind: 'before_start', offsetMinutes: 30 } }],
      });
      expect(await taskRow(db.pool, id)).toMatchObject({ deadline_date: '2026-10-30' });
      // 25 October 2026 02:30 happens twice in Zurich: the first instant (CEST) is used.
      expect((await taskRow(db.pool, id))!.scheduled_start_at).toEqual(new Date('2026-10-25T00:30:00Z'));
      expect((await taskRow(db.pool, id))!.deadline_at).toEqual(new Date('2026-10-30T17:00:00Z'));

      await apply(command('task.patch', id, { set: { schedule: day('2026-10-26') } }));
      expect(await taskRow(db.pool, id)).toMatchObject({ scheduled_time: null, scheduled_start_at: null, revision: 2 });
      expect(await reminderRows(db.pool, id)).toEqual([expect.objectContaining({ id: reminderId, state: 'inactive_base_missing', deleted: false })]);
      await apply(command('task.patch', id, { set: { schedule: at('2026-10-26', '09:00') } }));
      expect(await reminderRows(db.pool, id)).toEqual([expect.objectContaining({ state: 'active' })]);
      expect(await apply(command('task.patch', id, { set: { schedule: at('2026-10-26', '09:00'), deadline: at('2026-10-30', '18:00') } })))
        .toMatchObject({ revision: 3, noop: true });
      await apply(command('task.patch', id, { set: { deadline: null } }));
      expect(await taskRow(db.pool, id)).toMatchObject({ deadline_date: null, deadline_at: null, revision: 4 });
    });

    it('refuses a reminder without its base and leaves no partial task', async () => {
      const id = randomUUID();
      expect(await outcome(command('task.create', id, { title: 'x', reminders: [{ id: randomUUID(), rule: { kind: 'before_deadline', offsetMinutes: 60 } }] })))
        .toMatchObject({ code: 'REMINDER_BASE_MISSING' });
      expect(await outcome(command('task.create', id, { title: 'x', schedule: day('2026-09-20'), reminders: [{ id: randomUUID(), rule: { kind: 'before_start', offsetMinutes: 0 } }] })))
        .toMatchObject({ code: 'REMINDER_BASE_MISSING' });
      expect(await outcome(command('task.create', id, { title: 'x', reminders: [{ id: randomUUID(), rule: { kind: 'absolute', absolute: at('2026-09-20', '08:00') }, occurrenceKey: '2026-09-20' }] })))
        .toMatchObject({ code: 'VALIDATION_FAILED' });
      const duplicated = randomUUID();
      expect(await outcome(command('task.create', id, { title: 'x', reminders: [
        { id: duplicated, rule: { kind: 'absolute', absolute: at('2026-09-20', '08:00') } },
        { id: duplicated.toUpperCase(), rule: { kind: 'absolute', absolute: at('2026-09-21', '08:00') } },
      ] }))).toMatchObject({ code: 'VALIDATION_FAILED' });
      expect(await taskRow(db.pool, id)).toBeUndefined();
    });

    it('sets, updates, removes and revives a reminder under the task revision', async () => {
      const id = await createTask({ schedule: at('2026-09-20', '17:00') });
      const reminderId = randomUUID();
      const rule = { kind: 'before_start', offsetMinutes: 15 };
      expect(await apply(command('reminder.set', id, { id: reminderId, rule }))).toMatchObject({ revision: 2, reminderId });
      expect(await apply(command('reminder.set', id, { id: reminderId, rule }))).toMatchObject({ revision: 2, noop: true });
      expect(await apply(command('reminder.set', id, { id: reminderId, rule: { kind: 'before_start', offsetMinutes: 45 } }))).toMatchObject({ revision: 3 });
      // A date-only kind needs a date-only schedule; this one has a time.
      expect(await outcome(command('reminder.set', id, { id: reminderId, rule: { kind: 'on_scheduled_day_at', localTime: '08:00' } })))
        .toMatchObject({ outcome: 'rejected', code: 'REMINDER_BASE_MISSING' });
      expect(await apply(command('reminder.remove', id, { id: reminderId }))).toMatchObject({ revision: 4 });
      expect(await apply(command('reminder.remove', id, { id: reminderId }))).toMatchObject({ revision: 4, noop: true });
      expect(await reminderRows(db.pool, id)).toEqual([expect.objectContaining({ kind: 'before_start', offset_minutes: 45, deleted: true })]);
      expect(await apply(command('reminder.set', id, { id: reminderId, rule }))).toMatchObject({ revision: 5 });
      expect(await reminderRows(db.pool, id)).toEqual([expect.objectContaining({ offset_minutes: 15, deleted: false, state: 'active' })]);
      expect(await outcome(command('reminder.remove', id, { id: randomUUID() }))).toMatchObject({ code: 'ENTITY_NOT_FOUND' });

      const otherTask = await createTask({ schedule: at('2026-09-21', '17:00') });
      expect(await outcome(command('reminder.set', otherTask, { id: reminderId, rule }))).toMatchObject({ code: 'FORBIDDEN_REFERENCE' });
      expect(await outcome(command('reminder.remove', otherTask, { id: reminderId }))).toMatchObject({ code: 'FORBIDDEN_REFERENCE' });
      expect(await reminderRows(db.pool, otherTask)).toEqual([]);
    });

    it('limits a task to ten live reminders', async () => {
      const reminders = Array.from({ length: 10 }, (_, index) => ({ id: randomUUID(), rule: { kind: 'absolute', absolute: at('2026-09-20', `0${index}:00`) } }));
      const id = await createTask({ reminders });
      expect(await outcome(command('reminder.set', id, { id: randomUUID(), rule: { kind: 'absolute', absolute: at('2026-09-21', '10:00') } })))
        .toMatchObject({ code: 'VALIDATION_FAILED' });
      await apply(command('reminder.remove', id, { id: reminders[0]!.id }));
      await apply(command('reminder.set', id, { id: randomUUID(), rule: { kind: 'absolute', absolute: at('2026-09-21', '10:00') } }));
    });
  });

  describe('fixed series', () => {
    it('guards the series template and one-off commands', async () => {
      expect(await outcome(command('task.create', randomUUID(), { title: 'x', recurrence: DAILY }))).toMatchObject({ code: 'VALIDATION_FAILED' });
      expect(await outcome(command('task.create', randomUUID(), { title: 'x', recurrence: DAILY, schedule: day('2026-09-17'), deadline: day('2026-09-20') })))
        .toMatchObject({ code: 'RECURRING_TASK_DEADLINE_UNSUPPORTED' });
      const id = await createTask({ recurrence: WEEKLY_THURSDAY, schedule: at('2026-09-17', '08:00') });
      expect(await taskRow(db.pool, id)).toMatchObject({ scheduled_start_at: null, recurrence: WEEKLY_THURSDAY });
      expect(await outcome(command('task.patch', id, { set: { schedule: day('2026-09-18') } }))).toMatchObject({ code: 'SERIES_COMMAND_REQUIRED' });
      expect(await outcome(command('task.patch', id, { set: { durationMinutes: 30 } }))).toMatchObject({ code: 'SERIES_COMMAND_REQUIRED' });
      expect(await outcome(command('task.complete', id))).toMatchObject({ code: 'SERIES_COMMAND_REQUIRED' });
      expect(await apply(command('task.patch', id, { set: { title: 'Sport', priority: 'low' } }))).toMatchObject({ revision: 2 });
      const oneOff = await createTask();
      expect(await outcome(command('occurrence.complete', oneOff, { occurrenceKey: '2026-09-17', actionLocalDate: '2026-09-16' }))).toMatchObject({ code: 'NOT_A_SERIES' });
      expect(await outcome(command('series.end', oneOff, {}, atRevision(1)))).toMatchObject({ code: 'NOT_A_SERIES' });
    });

    it('closes, reopens and moves occurrences by their original key', async () => {
      const id = await createTask({ recurrence: WEEKLY_THURSDAY, schedule: at('2026-09-17', '08:00') });
      const complete = (occurrenceKey: string) => command('occurrence.complete', id, { occurrenceKey, actionLocalDate: '2026-09-16' });
      expect(await outcome(complete('2026-09-18'))).toMatchObject({ code: 'OCCURRENCE_NOT_IN_SERIES' });
      expect(await outcome(complete('2026-09-17~0'))).toMatchObject({ code: 'OCCURRENCE_NOT_IN_SERIES' });
      expect(await outcome(complete('2026-09-10'))).toMatchObject({ code: 'OCCURRENCE_NOT_IN_SERIES' });
      expect(await outcome(command('occurrence.complete', id, { occurrenceKey: '2026-09-17', actionLocalDate: '2026-09-20' }))).toMatchObject({ code: 'VALIDATION_FAILED' });

      expect(await apply(complete('2026-09-17'))).toEqual(expect.objectContaining({
        revision: 2, occurrenceKey: '2026-09-17', occurrenceId: occurrenceId(id, '2026-09-17'), status: 'completed', successorOccurrenceKey: null,
      }));
      expect(await apply(complete('2026-09-17'))).toMatchObject({ revision: 2, noop: true, status: 'completed' });
      expect(await apply(command('occurrence.skip', id, { occurrenceKey: '2026-09-17', actionLocalDate: '2026-09-16' }))).toMatchObject({ revision: 2, noop: true, status: 'completed' });
      expect(await occurrenceRows(db.pool, id)).toEqual([expect.objectContaining({ occurrence_key: '2026-09-17', status: 'completed', completed: true })]);
      expect(await apply(command('occurrence.reopen', id, { occurrenceKey: '2026-09-17' }))).toMatchObject({ revision: 3, status: 'open' });
      expect(await occurrenceRows(db.pool, id)).toEqual([]);
      expect(await apply(command('occurrence.reopen', id, { occurrenceKey: '2026-09-17' }))).toMatchObject({ revision: 3, noop: true });

      const moved = command('occurrence.reschedule', id, { occurrenceKey: '2026-09-24', schedule: at('2026-09-25', '18:30') });
      expect(await apply(moved)).toMatchObject({ revision: 4, status: 'open', occurrenceId: occurrenceId(id, '2026-09-24') });
      expect(await apply(command('occurrence.reschedule', id, { occurrenceKey: '2026-09-24', schedule: at('2026-09-25', '18:30') }))).toMatchObject({ revision: 4, noop: true });
      expect(await apply(command('occurrence.skip', id, { occurrenceKey: '2026-09-24', actionLocalDate: '2026-09-16' }))).toMatchObject({ revision: 5, status: 'skipped' });
      expect(await occurrenceRows(db.pool, id)).toEqual([expect.objectContaining({
        id: occurrenceId(id, '2026-09-24'), occurrence_key: '2026-09-24', status: 'skipped', override_date: '2026-09-25', override_time: '18:30:00',
      })]);
      expect(await outcome(command('occurrence.reschedule', id, { occurrenceKey: '2026-09-24', schedule: null }))).toMatchObject({ code: 'OCCURRENCE_NOT_CURRENT' });
      // Reopening a moved occurrence keeps the move.
      await apply(command('occurrence.reopen', id, { occurrenceKey: '2026-09-24' }));
      expect(await occurrenceRows(db.pool, id)).toEqual([expect.objectContaining({ status: 'open', override_date: '2026-09-25' })]);
      await apply(command('occurrence.reschedule', id, { occurrenceKey: '2026-09-24', schedule: null }));
      expect(await occurrenceRows(db.pool, id)).toEqual([]);
      expect((await taskRow(db.pool, id))!.revision).toBe(7);
    });

    it('ignores previous missed occurrences once, and only forward', async () => {
      const id = await createTask({ recurrence: DAILY, schedule: day('2026-09-01') });
      expect(await apply(command('occurrence.skip_missed_before', id, { occurrenceKey: '2026-09-15' }))).toMatchObject({ revision: 2, missedIgnoredBefore: '2026-09-15' });
      expect(await apply(command('occurrence.skip_missed_before', id, { occurrenceKey: '2026-09-10' }))).toMatchObject({ revision: 2, noop: true, missedIgnoredBefore: '2026-09-15' });
      expect((await taskRow(db.pool, id))!.missed_ignored_before).toBe('2026-09-15');
      expect(await outcome(command('occurrence.skip_missed_before', id, { occurrenceKey: '2026-08-31' }))).toMatchObject({ code: 'OCCURRENCE_NOT_IN_SERIES' });
      const cycle = await createTask({ recurrence: EVERY_DAY, schedule: day('2026-09-01') });
      expect(await outcome(command('occurrence.skip_missed_before', cycle, { occurrenceKey: '2026-09-01~0' }))).toMatchObject({ code: 'OCCURRENCE_NOT_IN_SERIES' });
    });

    it('edits the whole series, drops open occurrences it no longer produces and keeps history', async () => {
      const onDate = randomUUID();
      const onMoved = randomUUID();
      const everyTime = randomUUID();
      const id = await createTask({
        recurrence: WEEKLY_THURSDAY, schedule: at('2026-09-17', '08:00'),
        reminders: [
          { id: onDate, rule: { kind: 'absolute', absolute: at('2026-09-30', '20:00') }, occurrenceKey: '2026-10-01' },
          { id: everyTime, rule: { kind: 'before_start', offsetMinutes: 10 } },
        ],
      });
      await apply(command('occurrence.complete', id, { occurrenceKey: '2026-09-17', actionLocalDate: '2026-09-16' }));
      await apply(command('occurrence.reschedule', id, { occurrenceKey: '2026-09-24', schedule: day('2026-09-25') }));
      await apply(command('reminder.set', id, { id: onMoved, rule: { kind: 'on_scheduled_day_at', localTime: '07:00' }, occurrenceKey: '2026-09-24' }));
      expect(await outcome(command('reminder.set', id, { id: randomUUID(), rule: { kind: 'on_scheduled_day_at', localTime: '07:00' }, occurrenceKey: '2026-10-08' })))
        .toMatchObject({ code: 'REMINDER_BASE_MISSING' });
      expect(await outcome(command('reminder.set', id, { id: randomUUID(), rule: { kind: 'absolute', absolute: at('2026-09-30', '20:00') } })))
        .toMatchObject({ code: 'VALIDATION_FAILED' });
      expect(await outcome(command('reminder.set', id, { id: randomUUID(), rule: { kind: 'before_start', offsetMinutes: 5 }, occurrenceKey: '2026-10-02' })))
        .toMatchObject({ code: 'OCCURRENCE_NOT_IN_SERIES' });
      const revision = (await taskRow(db.pool, id))!.revision as number;

      expect(await outcome(command('series.update', id, { recurrence: EVERY_DAY }, atRevision(revision)))).toMatchObject({ code: 'VALIDATION_FAILED' });
      expect(await outcome(command('series.update', id, { set: { title: 'x' } }, atRevision(revision - 1)))).toMatchObject({ code: 'REVISION_MISMATCH', currentRevision: revision });
      expect(await apply(command('series.update', id, { recurrence: { ...WEEKLY_THURSDAY }, set: { title: 'Appeler le garage' } }, atRevision(revision))))
        .toMatchObject({ revision, noop: true });

      const update = command('series.update', id, { recurrence: { ...WEEKLY_THURSDAY, byWeekday: ['FR'] }, set: { schedule: day('2026-09-17'), durationMinutes: 45 } }, atRevision(revision));
      expect(await apply(update)).toEqual(expect.objectContaining({ revision: revision + 1, removedOccurrenceKeys: ['2026-09-24'] }));
      expect(await taskRow(db.pool, id)).toMatchObject({ scheduled_time: null, scheduled_start_at: null, recurrence: { ...WEEKLY_THURSDAY, byWeekday: ['FR'] } });
      expect(await occurrenceRows(db.pool, id)).toEqual([expect.objectContaining({ occurrence_key: '2026-09-17', status: 'completed' })]);
      const reminders = await reminderRows(db.pool, id);
      expect(reminders.find((row) => row.id === onDate)).toMatchObject({ deleted: true });
      expect(reminders.find((row) => row.id === onMoved)).toMatchObject({ deleted: true });
      // The every-occurrence reminder lost its time base but is kept and flagged.
      expect(reminders.find((row) => row.id === everyTime)).toMatchObject({ deleted: false, state: 'inactive_base_missing' });

      const end = command('series.end', id, {}, afterCommand(update));
      expect(await apply(end)).toMatchObject({ revision: revision + 2 });
      expect(await outcome(command('occurrence.complete', id, { occurrenceKey: '2026-09-18', actionLocalDate: '2026-09-16' }))).toMatchObject({ code: 'SERIES_ENDED' });
      expect(await apply(command('task.reopen', id))).toMatchObject({ revision: revision + 3 });
      expect(await apply(command('occurrence.complete', id, { occurrenceKey: '2026-09-18', actionLocalDate: '2026-09-16' }))).toMatchObject({ status: 'completed' });
    });
  });

  describe('after-completion series', () => {
    const close = (id: string, occurrenceKey: string, actionLocalDate = '2026-09-16', type = 'occurrence.complete') =>
      command(type, id, { occurrenceKey, actionLocalDate });

    it('closes the current cycle from the device civil date', async () => {
      const id = await createTask({ recurrence: EVERY_90_DAYS, schedule: day('2026-09-16') });
      expect(await outcome(close(id, '2026-09-16'))).toMatchObject({ code: 'OCCURRENCE_NOT_IN_SERIES' });
      const first = close(id, '2026-09-16~0');
      expect(await apply(first)).toEqual(expect.objectContaining({
        revision: 2, occurrenceKey: '2026-09-16~0', occurrenceId: occurrenceId(id, '2026-09-16~0'),
        status: 'completed', successorOccurrenceKey: '2026-12-15~1',
      }));
      expect(await occurrenceRows(db.pool, id)).toEqual([expect.objectContaining({ occurrence_key: '2026-09-16~0', status: 'completed', successor_occurrence_key: '2026-12-15~1' })]);
      expect(await receipt(first.clientCommandId)).toMatchObject({ outcome: 'applied', command_type: 'occurrence.complete' });
    });

    it('creates exactly one successor when different commands close the same cycle concurrently', async () => {
      const id = await createTask({ recurrence: EVERY_90_DAYS, schedule: day('2026-09-16') });
      const results = await Promise.all(Array.from({ length: 6 }, (_, index) => outcome(close(id, '2026-09-16~0', index % 2 ? '2026-09-16' : '2026-09-17', index % 3 ? 'occurrence.complete' : 'occurrence.skip'))));
      expect(results.every((result) => result.outcome === 'applied')).toBe(true);
      expect(results.filter((result) => result.noop !== true)).toHaveLength(1);
      expect(new Set(results.map((result) => result.successorOccurrenceKey)).size).toBe(1);
      expect(await occurrenceRows(db.pool, id)).toHaveLength(1);
      expect((await taskRow(db.pool, id))!.revision).toBe(2);
    });

    it('gives an early completion on the same date a distinct identity', async () => {
      const id = await createTask({ recurrence: EVERY_DAY, schedule: day('2026-09-16') });
      expect(await apply(close(id, '2026-09-16~0', '2026-09-15'))).toMatchObject({ successorOccurrenceKey: '2026-09-16~1' });
      expect(await apply(close(id, '2026-09-16~1', '2026-09-15'))).toMatchObject({ successorOccurrenceKey: '2026-09-16~2', revision: 3 });
      const rows = await occurrenceRows(db.pool, id);
      expect(rows.map((row) => row.occurrence_key)).toEqual(['2026-09-16~0', '2026-09-16~1']);
      expect(new Set(rows.map((row) => row.id)).size).toBe(2);
    });

    it('only accepts the current cycle and leaves closed cycles as they are', async () => {
      const id = await createTask({ recurrence: EVERY_90_DAYS, schedule: day('2026-09-16') });
      await apply(close(id, '2026-09-16~0'));
      expect(await outcome(close(id, '2027-01-01~1'))).toMatchObject({ code: 'OCCURRENCE_NOT_CURRENT' });
      expect(await apply(close(id, '2026-09-16~0', '2026-09-16', 'occurrence.skip'))).toMatchObject({ noop: true, status: 'completed', revision: 2 });
      expect(await apply(close(id, '2026-12-15~1', '2026-09-16', 'occurrence.skip'))).toMatchObject({ status: 'skipped', successorOccurrenceKey: '2026-12-15~2', revision: 3 });
      expect(await outcome(command('occurrence.reschedule', id, { occurrenceKey: '2026-12-15~1', schedule: day('2026-12-20') }))).toMatchObject({ code: 'OCCURRENCE_NOT_CURRENT' });
      expect(await apply(command('occurrence.reschedule', id, { occurrenceKey: '2026-12-15~2', schedule: day('2026-12-20') }))).toMatchObject({ status: 'open', revision: 4 });
      expect(await outcome(command('series.update', id, { set: { schedule: day('2026-09-20') } }, atRevision(4)))).toMatchObject({ code: 'VALIDATION_FAILED' });
      expect(await apply(command('series.update', id, { recurrence: { ...EVERY_90_DAYS, interval: 30 }, set: { schedule: at('2026-09-16', '07:30') } }, atRevision(4))))
        .toMatchObject({ revision: 5 });
    });

    it('reopens a cycle whose successor is intact, and refuses once the successor changed', async () => {
      const id = await createTask({ recurrence: EVERY_90_DAYS, schedule: day('2026-09-16') });
      await apply(close(id, '2026-09-16~0'));
      expect(await apply(command('occurrence.reopen', id, { occurrenceKey: '2026-09-16~0' }))).toMatchObject({ status: 'open', successorOccurrenceKey: null, revision: 3 });
      expect(await occurrenceRows(db.pool, id)).toEqual([]);
      expect(await apply(command('occurrence.reopen', id, { occurrenceKey: '2026-09-16~0' }))).toMatchObject({ noop: true, status: 'open' });
      expect(await outcome(command('occurrence.reopen', id, { occurrenceKey: '2026-12-15~1' }))).toMatchObject({ code: 'OCCURRENCE_NOT_CURRENT' });

      // The reopened cycle is current again; closing it computes a fresh successor.
      expect(await apply(close(id, '2026-09-16~0', '2026-09-17'))).toMatchObject({ successorOccurrenceKey: '2026-12-16~1' });
      const reminderId = randomUUID();
      await apply(command('reminder.set', id, { id: reminderId, rule: { kind: 'on_scheduled_day_at', localTime: '09:00' }, occurrenceKey: '2026-12-16~1' }));
      expect(await outcome(command('occurrence.reopen', id, { occurrenceKey: '2026-09-16~0' }))).toMatchObject({ code: 'SUCCESSOR_ALREADY_CHANGED' });
      await apply(command('reminder.remove', id, { id: reminderId }));

      now = new Date('2026-12-16T09:00:00Z');
      await apply(command('occurrence.complete', id, { occurrenceKey: '2026-12-16~1', actionLocalDate: '2026-12-16' }, { clientRecordedAt: '2026-12-16T10:00:00+01:00' }));
      expect(await outcome(command('occurrence.reopen', id, { occurrenceKey: '2026-09-16~0' }))).toMatchObject({ code: 'SUCCESSOR_ALREADY_CHANGED' });
      expect(await apply(command('occurrence.reopen', id, { occurrenceKey: '2026-12-16~1' }))).toMatchObject({ status: 'open' });
    });
  });

  describe('lists', () => {
    it('renames a list, refreshes search text without touching task revisions, and archives idempotently', async () => {
      const list = await createList('Maison');
      const id = await createTask({ title: 'Réparer', projectId: list });
      expect(await apply(command('project.patch', list, { set: { name: 'Bricolage & Maison' } }))).toMatchObject({ revision: 2 });
      expect(await taskRow(db.pool, id)).toMatchObject({ search_text: 'reparer bricolage maison', revision: 1 });
      expect(await apply(command('project.patch', list, { set: { name: 'Bricolage & Maison', colorKey: null } }))).toMatchObject({ revision: 2, noop: true });
      expect(await apply(command('project.archive', list))).toMatchObject({ revision: 3 });
      expect(await apply(command('project.archive', list))).toMatchObject({ revision: 3, noop: true });
      await apply(command('task.create', randomUUID(), { title: 'Dans une liste archivée', projectId: list }));
      expect(await apply(command('project.unarchive', list))).toMatchObject({ revision: 4 });
      expect(await outcome(command('project.create', list, { name: 'Doublon' }))).toMatchObject({ code: 'ENTITY_ALREADY_EXISTS' });
    });

    it('trashes a list with its live tasks and restores exactly those', async () => {
      const list = await createList();
      const live = await createTask({ title: 'Exercice 1', projectId: list });
      const alreadyTrashed = await createTask({ title: 'Exercice 2', projectId: list });
      await apply(command('task.delete', alreadyTrashed));
      const inbox = await createTask({ title: 'Courses' });

      expect(await outcome(command('project.delete', list, { taskPolicy: 'trash_tasks_with_project' }))).toMatchObject({ code: 'VALIDATION_FAILED' });
      const remove = command('project.delete', list, { taskPolicy: 'trash_tasks_with_project' }, atRevision(1));
      expect(await apply(remove)).toEqual(expect.objectContaining({ revision: 2, taskPolicy: 'trash_tasks_with_project', affectedTaskIds: [live] }));
      expect(await taskRow(db.pool, live)).toMatchObject({ deleted_by_command_id: remove.clientCommandId, revision: 2 });
      expect(await apply(command('project.delete', list, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(2)))).toMatchObject({ noop: true, affectedTaskIds: [] });

      expect(await outcome(command('task.restore', live))).toMatchObject({ code: 'PROJECT_DELETED' });
      expect(await outcome(command('task.patch', inbox, { set: { projectId: list } }))).toMatchObject({ code: 'PROJECT_DELETED' });
      expect(await outcome(command('task.create', randomUUID(), { title: 'x', projectId: list }))).toMatchObject({ code: 'PROJECT_DELETED' });
      expect(await outcome(command('project.patch', list, { set: { name: 'x' } }))).toMatchObject({ code: 'PROJECT_DELETED' });
      expect(await outcome(command('project.archive', list))).toMatchObject({ code: 'PROJECT_DELETED' });

      expect(await apply(command('project.restore', list))).toEqual(expect.objectContaining({ revision: 3, affectedTaskIds: [live] }));
      expect(await taskRow(db.pool, live)).toMatchObject({ deleted_at: null, deleted_by_command_id: null, revision: 3 });
      expect((await taskRow(db.pool, alreadyTrashed))!.deleted_at).not.toBeNull();
      expect(await apply(command('project.restore', list))).toMatchObject({ noop: true, affectedTaskIds: [] });
      expect(await apply(command('task.restore', alreadyTrashed))).toMatchObject({ revision: 3 });
    });

    it('moves every task of a deleted list to the inbox, trashed ones included', async () => {
      const list = await createList('Projet');
      const live = await createTask({ title: 'Plan', projectId: list });
      const trashed = await createTask({ title: 'Brouillon', projectId: list });
      await apply(command('task.delete', trashed));
      const result = await apply(command('project.delete', list, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1)));
      expect([...(result.affectedTaskIds as string[])].sort()).toEqual([live, trashed].sort());
      expect(await taskRow(db.pool, live)).toMatchObject({ project_id: null, search_text: 'plan', deleted_at: null, revision: 2 });
      expect(await taskRow(db.pool, trashed)).toMatchObject({ project_id: null, search_text: 'brouillon', revision: 3 });
      expect(await apply(command('project.restore', list))).toMatchObject({ affectedTaskIds: [] });
      expect(await apply(command('task.restore', trashed))).toMatchObject({ revision: 4 });
      expect((await taskRow(db.pool, live))!.project_id).toBeNull();
    });

    it('serializes a list deletion with a concurrent move into that list', async () => {
      for (let attempt = 0; attempt < 5; attempt++) {
        const list = await createList(`Course ${attempt}`);
        const id = await createTask();
        const [move, remove] = await Promise.all([
          outcome(command('task.patch', id, { set: { projectId: list } })),
          outcome(command('project.delete', list, { taskPolicy: 'trash_tasks_with_project' }, atRevision(1))),
        ]);
        expect(remove).toMatchObject({ outcome: 'applied' });
        const row = await taskRow(db.pool, id);
        if (move.outcome === 'applied') {
          // The move committed first, so the deletion trashed the moved task.
          expect(remove.affectedTaskIds).toEqual([id]);
          expect(row).toMatchObject({ project_id: list, deleted_by_command_id: expect.any(String) });
        } else {
          expect(move).toMatchObject({ code: 'PROJECT_DELETED' });
          expect(row).toMatchObject({ project_id: null, deleted_at: null });
        }
      }
    });
  });
});
