import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { taskTagId, type TaskSubtask } from '../../src/modules/domain/details.js';
import { buildExport } from '../../src/modules/export/archive.js';
import { purgeExpired } from '../../src/modules/maintenance/purge.js';
import type { CommandActor } from '../../src/modules/sync/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { afterCommand, atRevision, command, commandRunner } from './helpers.js';

describe('task details and personal tags', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  const now = new Date('2026-09-17T12:00:00Z');
  beforeAll(async () => { db = await createTestDatabase(); });
  afterAll(async () => { await db?.close(); });
  async function owner() {
    const userId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    const actor: CommandActor = { userId, deviceId: null, origin: 'manual' };
    return { actor, ...commandRunner(db.pool, actor, () => now) };
  }
  async function details(id: string) {
    return (await db.pool.query<{ subtasks: TaskSubtask[]; revision: number; status: string }>(
      'SELECT subtasks, revision::int, status FROM tasks WHERE id=$1', [id])).rows[0]!;
  }

  it('shares a stable relation identity with Swift', () => {
    expect(taskTagId('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002'))
      .toBe('516867fc-e615-5368-8b25-962ecda6adf5');
    expect(taskTagId('DDE7B206-F035-4C41-8DCD-855E84622D3F', '4865AB3F-71A3-4689-A77F-5DC4FF1E80C2'))
      .toBe(taskTagId('dde7b206-f035-4c41-8dcd-855e84622d3f', '4865ab3f-71a3-4689-a77f-5dc4ff1e80c2'));
  });

  it('creates parent, ordered checklist and relations atomically and replays its receipt', async () => {
    const user = await owner(); const taskId = randomUUID(); const tagId = randomUUID(); const subtaskId = randomUUID();
    await user.apply(command('tag.create', tagId, { name: 'Travail' }));
    const input = command('task.create', taskId, { title: 'Présentation', notes: 'Détails',
      subtasks: [{ id: subtaskId.toUpperCase(), title: ' Préparer ' }], tagIds: [tagId] });
    expect(await user.apply(input)).toMatchObject({ revision: 1 });
    expect(await user.run(input)).toMatchObject({ outcome: 'duplicate', original: { outcome: 'applied', revision: 1 } });
    expect((await details(taskId)).subtasks).toEqual([{ id: subtaskId, title: 'Préparer', isCompleted: false, sortOrder: 0 }]);
    expect((await db.pool.query('SELECT id,task_id,tag_id FROM task_tags WHERE task_id=$1', [taskId])).rows)
      .toEqual([{ id: taskTagId(taskId, tagId), task_id: taskId, tag_id: tagId }]);
    const failedId = randomUUID();
    expect(await user.outcome(command('task.create', failedId, { title: 'Refus', subtasks: [{ id: randomUUID(), title: 'Ligne' }], tagIds: [randomUUID()] })))
      .toMatchObject({ outcome: 'rejected', code: 'FORBIDDEN_REFERENCE' });
    expect((await db.pool.query('SELECT 1 FROM tasks WHERE id=$1', [failedId])).rowCount).toBe(0);
  });

  it('edits different IDs concurrently without losing either edit, and enforces parent revisions', async () => {
    const user = await owner(); const id = randomUUID(); const first = randomUUID(); const second = randomUUID();
    const create = command('task.create', id, { title: 'Dossier', subtasks: [{ id: first, title: 'Un' }, { id: second, title: 'Deux' }] });
    await user.apply(create);
    const outcomes = await Promise.all([
      user.outcome(command('task.subtask.patch', id, { subtaskId: first, set: { isCompleted: true } })),
      user.outcome(command('task.subtask.patch', id, { subtaskId: second, set: { title: 'Deux corrigé' } })),
    ]);
    expect(outcomes.every((value) => value.outcome === 'applied')).toBe(true);
    expect(await details(id)).toMatchObject({ revision: 3, status: 'active', subtasks: [
      { id: first, isCompleted: true }, { id: second, title: 'Deux corrigé' },
    ] });
    expect(await user.outcome(command('task.subtask.remove', id, { subtaskId: first }, atRevision(1))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 3 });
    expect(await user.outcome(command('task.subtask.patch', id, { subtaskId: first, set: { sortOrder: -2 } })))
      .toMatchObject({ code: 'VALIDATION_FAILED' });
    const add = command('task.subtask.add', id, { subtask: { id: randomUUID(), title: 'Trois', sortOrder: -1 } }, atRevision(3));
    await user.apply(add);
    expect(await user.apply(command('task.subtask.patch', id, { subtaskId: first, set: { sortOrder: -2 } }, afterCommand(add))))
      .toMatchObject({ revision: 5 });
    await user.apply(command('task.complete', id));
    expect((await details(id)).subtasks.find((item) => item.id === second)?.isCompleted).toBe(false);
  });

  it('removes exactly one item, allows guarded re-add and rejects missing or duplicate IDs', async () => {
    const user = await owner(); const id = randomUUID(); const line = { id: randomUUID(), title: 'À garder', sortOrder: 7, isCompleted: true };
    await user.apply(command('task.create', id, { title: 'Dossier', subtasks: [line] }));
    expect(await user.outcome(command('task.subtask.add', id, { subtask: line }))).toMatchObject({ code: 'SUBTASK_ALREADY_EXISTS' });
    await user.apply(command('task.subtask.remove', id, { subtaskId: line.id }));
    expect(await user.apply(command('task.subtask.remove', id, { subtaskId: line.id }))).toMatchObject({ noop: true, revision: 2 });
    expect(await user.outcome(command('task.subtask.patch', id, { subtaskId: line.id, set: { title: 'Absent' } })))
      .toMatchObject({ code: 'SUBTASK_NOT_FOUND' });
    await user.apply(command('task.subtask.add', id, { subtask: line }, atRevision(2)));
    expect((await details(id)).subtasks).toEqual([line]);
  });

  it('rejects checklist series, invalid shapes and overflow; deleted tasks preserve their checklist', async () => {
    const user = await owner(); const id = randomUUID(); const subtask = { id: randomUUID(), title: 'Un' };
    const repeating = { title: 'Série', schedule: { date: '2026-09-18' }, recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 1 } };
    expect(await user.outcome(command('task.create', randomUUID(), { ...repeating, subtasks: [subtask] })))
      .toMatchObject({ code: 'SUBTASKS_ON_RECURRING_TASK' });
    await user.apply(command('task.create', id, repeating));
    expect(await user.outcome(command('task.subtask.add', id, { subtask }))).toMatchObject({ code: 'SUBTASKS_ON_RECURRING_TASK' });
    const full = randomUUID();
    await user.apply(command('task.create', full, { title: '50', subtasks: Array.from({ length: 50 }, (_, i) => ({ id: randomUUID(), title: `${i}` })) }));
    expect(await user.outcome(command('task.subtask.add', full, { subtask }))).toMatchObject({ code: 'SUBTASK_LIMIT_REACHED' });
    expect(await user.outcome(command('task.subtask.patch', full, { subtaskId: subtask.id, set: {} }))).toMatchObject({ code: 'VALIDATION_FAILED' });
    expect(await user.outcome(command('task.create', randomUUID(), { title: 'Duplicate', subtasks: [subtask, subtask] }))).toMatchObject({ code: 'VALIDATION_FAILED' });
    await user.apply(command('task.delete', full));
    expect(await user.outcome(command('task.subtask.remove', full, { subtaskId: subtask.id }))).toMatchObject({ code: 'TASK_DELETED' });
    await user.apply(command('task.restore', full));
    expect((await details(full)).subtasks).toHaveLength(50);
  });

  it('checks strict checklist invariants in PostgreSQL and remains valid with an empty restore search_path', async () => {
    const user = await owner(); const id = randomUUID(); const line = { id: randomUUID(), title: 'Valide', isCompleted: false, sortOrder: 0 };
    await user.apply(command('task.create', id, { title: 'Contrainte' }));
    for (const invalid of [null, {}, [line, line], [{ ...line, extra: true }], [{ ...line, title: '' }], [{ ...line, sortOrder: '0' }], [{ ...line, isCompleted: null }]]) {
      await expect(db.pool.query('UPDATE tasks SET subtasks=$1 WHERE id=$2', [JSON.stringify(invalid), id]))
        .rejects.toMatchObject({ code: '23514' });
    }
    const connection = await db.pool.connect();
    try {
      await connection.query('SET search_path TO pg_catalog');
      await connection.query(`UPDATE "${db.schema}".tasks SET subtasks=$1 WHERE id=$2`, [JSON.stringify([line]), id]);
    } finally {
      await connection.query(`SET search_path TO "${db.schema}", public`);
      connection.release();
    }
    expect((await details(id)).subtasks).toEqual([line]);
  });

  it('uses Unicode casefold/NFC names, rejects collisions and allows another owner to use the same name', async () => {
    const user = await owner(); const other = await owner(); const id = randomUUID();
    await user.apply(command('tag.create', id, { name: ' Straße ' }));
    expect(await user.outcome(command('tag.create', randomUUID(), { name: 'STRASSE' }))).toMatchObject({ code: 'TAG_NAME_TAKEN' });
    await other.apply(command('tag.create', randomUUID(), { name: 'STRASSE' }));
    await user.apply(command('tag.create', randomUUID(), { name: 'Café' }));
    expect(await user.outcome(command('tag.create', randomUUID(), { name: 'Cafe\u0301' }))).toMatchObject({ code: 'TAG_NAME_TAKEN' });
    await user.apply(command('tag.create', randomUUID(), { name: 'cafe' }));
    expect(await user.outcome(command('tag.patch', id, { set: { name: 'CAFÉ' } }))).toMatchObject({ code: 'TAG_NAME_TAKEN' });
    await user.apply(command('tag.delete', id));
    const replacement = randomUUID(); await user.apply(command('tag.create', replacement, { name: 'strasse' }));
    expect(await user.outcome(command('tag.restore', id))).toMatchObject({ code: 'TAG_NAME_TAKEN' });
    await user.apply(command('tag.delete', replacement));
    expect(await user.apply(command('tag.restore', id))).toMatchObject({ revision: 3 });
  });

  it('serializes catalog names and the 200 active-tag capacity across concurrent creations', async () => {
    const user = await owner();
    const same = await Promise.all([user.outcome(command('tag.create', randomUUID(), { name: 'École' })), user.outcome(command('tag.create', randomUUID(), { name: 'ÉCOLE' }))]);
    expect(same.filter((result) => result.outcome === 'applied')).toHaveLength(1);
    expect(same.find((result) => result.outcome === 'rejected')).toMatchObject({ code: 'TAG_NAME_TAKEN' });
    for (let i = 1; i < 199; i++) await user.apply(command('tag.create', randomUUID(), { name: `Tag ${i}` }));
    const capacity = await Promise.all([user.outcome(command('tag.create', randomUUID(), { name: 'Avant dernier' })), user.outcome(command('tag.create', randomUUID(), { name: 'Dernier' }))]);
    expect(capacity.filter((result) => result.outcome === 'applied')).toHaveLength(1);
    expect(capacity.find((result) => result.outcome === 'rejected')).toMatchObject({ code: 'TAG_LIMIT_REACHED' });
  });

  it('retains tag membership across delete/restore, detaches deleted tags, and reuses the same relation ID', async () => {
    const user = await owner(); const id = randomUUID(); const tagId = randomUUID();
    await user.apply(command('tag.create', tagId, { name: 'Maison' }));
    await user.apply(command('task.create', id, { title: 'Détails', tagIds: [tagId] }));
    expect(await user.apply(command('task.tag.add', id, { tagId }))).toMatchObject({ noop: true, revision: 1 });
    await user.apply(command('tag.delete', tagId));
    expect(await user.outcome(command('task.tag.add', id, { tagId }))).toMatchObject({ code: 'TAG_DELETED' });
    expect((await db.pool.query('SELECT deleted_at FROM task_tags WHERE task_id=$1', [id])).rows).toEqual([{ deleted_at: null }]);
    await user.apply(command('tag.restore', tagId));
    await user.apply(command('tag.delete', tagId));
    await user.apply(command('task.tag.remove', id, { tagId }));
    await user.apply(command('tag.restore', tagId));
    await user.apply(command('task.tag.add', id, { tagId }));
    expect((await db.pool.query('SELECT id,deleted_at FROM task_tags WHERE task_id=$1', [id])).rows)
      .toEqual([{ id: taskTagId(id, tagId), deleted_at: null }]);
    expect((await details(id)).revision).toBe(3);
  });

  it('enforces ownership, caps active tags and refuses a restoration that would overflow a linked task', async () => {
    const user = await owner(); const other = await owner(); const id = randomUUID(); const foreignTag = randomUUID();
    await other.apply(command('tag.create', foreignTag, { name: 'Privé' }));
    await user.apply(command('task.create', id, { title: 'Dossier' }));
    expect(await user.outcome(command('task.tag.add', id, { tagId: foreignTag }))).toMatchObject({ code: 'FORBIDDEN_REFERENCE' });
    expect(await user.outcome(command('tag.patch', foreignTag, { set: { name: 'Interdit' } }))).toMatchObject({ code: 'ENTITY_NOT_FOUND' });
    await expect(db.pool.query('INSERT INTO task_tags(id,user_id,task_id,tag_id) VALUES($1,$2,$3,$4)', [randomUUID(), user.actor.userId, id, foreignTag]))
      .rejects.toMatchObject({ code: '23503' });
    const ids = Array.from({ length: 11 }, () => randomUUID());
    for (const [i, tagId] of ids.entries()) await user.apply(command('tag.create', tagId, { name: `T${i}` }));
    for (const tagId of ids.slice(0, 10)) await user.apply(command('task.tag.add', id, { tagId }));
    expect(await user.outcome(command('task.tag.add', id, { tagId: ids[10] }))).toMatchObject({ code: 'TASK_TAG_LIMIT_REACHED' });
    await user.apply(command('tag.delete', ids[0]!));
    await user.apply(command('task.tag.add', id, { tagId: ids[10] }));
    expect(await user.outcome(command('tag.restore', ids[0]!))).toMatchObject({ code: 'TASK_TAG_LIMIT_REACHED' });
    await user.apply(command('task.tag.remove', id, { tagId: ids[10] }));
    await user.apply(command('tag.restore', ids[0]!));
    expect((await db.pool.query('SELECT id FROM task_tags WHERE task_id=$1 AND deleted_at IS NULL', [id])).rowCount).toBe(10);
  });

  it('only changes authenticated settings, defaults to false, and preserves receipt/revision behavior', async () => {
    const user = await owner(); const other = await owner();
    expect((await buildExport(db.pool, user.actor.userId, now)).assistantSettings).toEqual({ autoTags: false, revision: 1, createdAt: null, updatedAt: null });
    expect(await user.outcome(command('settings.patch', other.actor.userId, { set: { autoTags: true } })))
      .toMatchObject({ code: 'FORBIDDEN_REFERENCE' });
    const input = command('settings.patch', user.actor.userId, { set: { autoTags: true } }, atRevision(1));
    expect(await user.apply(input)).toMatchObject({ revision: 2 });
    expect(await user.run(input)).toMatchObject({ outcome: 'duplicate' });
    expect(await user.outcome(command('settings.patch', user.actor.userId, { set: { autoTags: false } }, atRevision(1))))
      .toMatchObject({ code: 'REVISION_MISMATCH' });
    expect((await buildExport(db.pool, user.actor.userId, now)).assistantSettings).toMatchObject({ autoTags: true, revision: 2 });
    expect((await buildExport(db.pool, other.actor.userId, now)).assistantSettings.autoTags).toBe(false);
  });

  it('exports retained details without foreign data and cascades relations only on final task purge', async () => {
    const user = await owner(); const other = await owner(); const id = randomUUID(); const tagId = randomUUID(); const subtaskId = randomUUID();
    await user.apply(command('tag.create', tagId, { name: 'Local' }));
    await other.apply(command('tag.create', randomUUID(), { name: 'Foreign' }));
    await user.apply(command('task.create', id, { title: 'Dossier', subtasks: [{ id: subtaskId, title: 'Détail' }], tagIds: [tagId] }));
    await user.apply(command('task.tag.remove', id, { tagId }));
    await user.apply(command('tag.delete', tagId));
    await user.apply(command('task.delete', id));
    const archive = await buildExport(db.pool, user.actor.userId, now);
    expect(archive).toMatchObject({ exportVersion: 1, taskDetailsVersion: 1 });
    expect(archive.tags).toHaveLength(1);
    expect(archive.tasks[0]!.subtasks).toMatchObject([{ id: subtaskId, title: 'Détail' }]);
    expect(archive.taskTags).toMatchObject([{ id: taskTagId(id, tagId), taskId: id, tagId, deletedAt: now.toISOString() }]);
    expect(JSON.stringify(archive)).not.toContain('Foreign');
    await purgeExpired(db.pool, new Date('2026-11-17T12:00:00Z'));
    expect((await db.pool.query('SELECT 1 FROM task_tags WHERE task_id=$1', [id])).rowCount).toBe(0);
    expect((await db.pool.query('SELECT 1 FROM tags WHERE id=$1', [tagId])).rowCount).toBe(1);
    expect(await user.outcome(command('task.subtask.add', id, { subtask: { id: randomUUID(), title: 'Trop tard' } })))
      .toMatchObject({ code: 'ENTITY_PURGED' });
  });
});
