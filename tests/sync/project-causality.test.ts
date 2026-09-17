import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { CommandActor } from '../../src/modules/sync/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { afterCommand, atRevision, command, commandRunner, taskRow } from './helpers.js';

describe('list commands as causal barriers for the tasks they actually changed', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let actor: CommandActor;
  let other: CommandActor;
  let run: ReturnType<typeof commandRunner>['run'];
  let apply: ReturnType<typeof commandRunner>['apply'];
  const now = new Date('2026-09-17T10:00:00Z');

  beforeAll(async () => {
    db = await createTestDatabase();
    const users = await db.pool.query<{ id: string }>('INSERT INTO users (id) VALUES (gen_random_uuid()), (gen_random_uuid()) RETURNING id');
    actor = { userId: users.rows[0]!.id, deviceId: null, origin: 'manual' };
    other = { userId: users.rows[1]!.id, deviceId: null, origin: 'manual' };
    ({ run, apply } = commandRunner(db.pool, actor, () => now));
  });
  afterAll(async () => { await db?.close(); });

  async function fixture(as = actor, sameId = false) {
    const projectId = randomUUID();
    const taskId = sameId ? projectId : randomUUID();
    await apply(command('project.create', projectId, { name: 'Liste synthétique' }), as);
    await apply(command('task.create', taskId, { title: 'Tâche synthétique', projectId }), as);
    return { projectId, taskId };
  }

  it('records actual secondary revisions, accepts the offline chain and replays the original map unchanged', async () => {
    const { projectId, taskId } = await fixture();
    const earlier = command('task.patch', taskId, { set: { notes: 'Avant la suppression' } }, atRevision(1));
    await apply(earlier);
    const remove = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    const result = await run(remove);
    expect(result).toMatchObject({ outcome: 'applied', revision: 2, aggregateId: projectId, affectedTaskIds: [taskId], affectedTaskRevisions: { [taskId]: 3 } });
    const receipt = (await db.pool.query('SELECT result FROM command_receipts WHERE client_command_id = $1', [remove.clientCommandId])).rows[0]!.result;
    expect(receipt.affectedTaskRevisions).toEqual({ [taskId]: 3 });
    // The old task-only dependency is stale; the list deletion is the latest local cause.
    expect(await run(command('task.patch', taskId, { set: { title: 'Obsolète' } }, afterCommand(earlier))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 3 });
    const next = command('task.patch', taskId, { set: { title: 'Après la suppression' } }, afterCommand(remove));
    expect(await apply(next)).toMatchObject({ revision: 4 });
    expect(await taskRow(db.pool, taskId)).toMatchObject({ title: 'Après la suppression', project_id: null, revision: 4 });
    expect(await run(remove)).toEqual({ clientCommandId: remove.clientCommandId, outcome: 'duplicate', original: { outcome: 'applied', ...receipt } });
    expect(await run(command('task.complete', taskId, undefined, afterCommand(remove))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 4 });
    expect(await apply(command('task.complete', taskId, undefined, afterCommand(next)))).toMatchObject({ revision: 5 });
  });

  it('includes trashed tasks moved to Inbox but only restores tasks trashed by that list deletion', async () => {
    const { projectId, taskId } = await fixture();
    await apply(command('task.delete', taskId));
    const move = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    expect(await apply(move)).toMatchObject({ affectedTaskRevisions: { [taskId]: 3 } });
    expect(await apply(command('task.restore', taskId, undefined, afterCommand(move)))).toMatchObject({ revision: 4 });

    const second = await fixture();
    const seriesId = randomUUID();
    await apply(command('task.create', seriesId, {
      title: 'Série synthétique', projectId: second.projectId, schedule: { date: '2026-09-17' },
      recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 1 },
    }));
    await apply(command('task.delete', second.taskId));
    const trash = command('project.delete', second.projectId, { taskPolicy: 'trash_tasks_with_project' }, atRevision(1));
    expect(await apply(trash)).toMatchObject({ affectedTaskIds: [seriesId], affectedTaskRevisions: { [seriesId]: 2 } });
    const restore = command('project.restore', second.projectId, undefined, afterCommand(trash));
    expect(await apply(restore)).toMatchObject({ affectedTaskIds: [seriesId], affectedTaskRevisions: { [seriesId]: 3 } });
    expect(await run(command('task.restore', second.taskId, undefined, afterCommand(restore))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 2 });
    expect(await apply(command('series.end', seriesId, undefined, afterCommand(restore)))).toMatchObject({ revision: 4 });
  });

  it('does not turn an unrelated task or a no-op list receipt into a task dependency', async () => {
    const { projectId, taskId } = await fixture();
    const unrelated = randomUUID();
    await apply(command('task.create', unrelated, { title: 'Autre tâche' }));
    const remove = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    await apply(remove);
    expect(await run(command('task.patch', unrelated, { set: { title: 'Refusé' } }, afterCommand(remove))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 1 });
    const noop = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, afterCommand(remove));
    expect(await apply(noop)).toMatchObject({ noop: true, revision: 2, affectedTaskIds: [], affectedTaskRevisions: {} });
    expect(await run(command('task.patch', taskId, { set: { title: 'Refusé' } }, afterCommand(noop))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 2 });
    const restore = command('project.restore', projectId, undefined, afterCommand(noop));
    expect(await apply(restore)).toMatchObject({ revision: 3, affectedTaskRevisions: {} });
    expect(await apply(command('project.restore', projectId, undefined, afterCommand(restore))))
      .toMatchObject({ noop: true, revision: 3, affectedTaskRevisions: {} });
  });

  it('rejects unknown, rejected and foreign receipts without changing the target', async () => {
    const own = await fixture();
    const foreign = await fixture(other);
    const foreignRemove = command('project.delete', foreign.projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    await apply(foreignRemove, other);
    const rejected = command('project.delete', own.projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(99));
    expect(await run(rejected)).toMatchObject({ outcome: 'rejected' });
    const unknown = command('project.delete', randomUUID(), { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    for (const cited of [foreignRemove, rejected, unknown]) {
      expect(await run(command('task.patch', own.taskId, { set: { title: 'Refusé' } }, afterCommand(cited))))
        .toMatchObject({ outcome: 'rejected', code: 'DEPENDENCY_REJECTED', currentRevision: 1 });
    }
    expect(await run(command('task.patch', foreign.taskId, { set: { title: 'Interdit' } }, afterCommand(foreignRemove))))
      .toMatchObject({ outcome: 'rejected', code: 'ENTITY_NOT_FOUND' });
    expect(await taskRow(db.pool, own.taskId)).toMatchObject({ revision: 1, title: 'Tâche synthétique' });
  });

  it('distinguishes aggregate types even when a task, list and tag share a UUID', async () => {
    const { projectId, taskId } = await fixture(actor, true);
    await apply(command('tag.create', taskId, { name: 'Même UUID synthétique' }));
    await apply(command('task.patch', taskId, { set: { priority: 'high' } }));
    await apply(command('task.patch', taskId, { set: { notes: 'Révision différente' } }));
    const remove = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    expect(await apply(remove)).toMatchObject({ revision: 2, affectedTaskRevisions: { [taskId]: 4 } });
    expect(await apply(command('task.patch', taskId, { set: { title: 'Révision de tâche' } }, afterCommand(remove))))
      .toMatchObject({ revision: 5 });
    expect(await run(command('tag.patch', taskId, { set: { name: 'Refusé' } }, afterCommand(remove))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 1 });
    const restore = command('project.restore', projectId, undefined, afterCommand(remove));
    expect(await apply(restore)).toMatchObject({ revision: 3, affectedTaskRevisions: {} });
  });

  it('allows only one concurrent edit based on the same recorded secondary revision', async () => {
    const { projectId, taskId } = await fixture();
    const remove = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    await apply(remove);
    const edits = ['Première intention', 'Seconde intention'].map((title) => command('task.patch', taskId, { set: { title } }, afterCommand(remove)));
    const results = await Promise.all(edits.map((edit) => run(edit)));
    const appliedIndex = results.findIndex((result) => result.outcome === 'applied');
    expect(results.filter((result) => result.outcome === 'applied')).toHaveLength(1);
    expect(results.filter((result) => result.outcome === 'rejected')).toEqual([
      expect.objectContaining({ code: 'REVISION_MISMATCH', currentRevision: 3 }),
    ]);
    expect(await taskRow(db.pool, taskId)).toMatchObject({ revision: 3, title: (edits[appliedIndex]!.payload as { set: { title: string } }).set.title });
  });

  it('keeps older receipts without a secondary map immutable and refuses to infer a task revision', async () => {
    const { projectId, taskId } = await fixture();
    const remove = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, atRevision(1));
    await apply(remove);
    // A receipt from the previous version carries IDs, but no evidence of their resulting revisions.
    await db.pool.query("UPDATE command_receipts SET result = result - 'affectedTaskRevisions' WHERE client_command_id = $1", [remove.clientCommandId]);
    const duplicate = await run(remove);
    expect(duplicate).toMatchObject({ outcome: 'duplicate', original: { affectedTaskIds: [taskId] } });
    if (duplicate.outcome !== 'duplicate') throw new Error('Expected duplicate');
    expect(duplicate.original).not.toHaveProperty('affectedTaskRevisions');
    expect(await run(command('task.patch', taskId, { set: { title: 'Non déduit' } }, afterCommand(remove))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 2 });
  });

  it('never accepts a secondary map from a different command type or a malformed revision value', async () => {
    const { projectId, taskId } = await fixture();
    const rename = command('project.patch', projectId, { set: { name: 'Nom synthétique' } });
    await apply(rename);
    // These are deliberately malformed stored fixtures, never client payloads. Future additive fields
    // must not accidentally grant a new cross-aggregate dependency to other command types.
    await db.pool.query("UPDATE command_receipts SET result = result || jsonb_build_object('affectedTaskRevisions', $2::jsonb) WHERE client_command_id = $1", [rename.clientCommandId, JSON.stringify({ [taskId]: 1 })]);
    expect(await run(command('task.patch', taskId, { set: { title: 'Refusé' } }, afterCommand(rename))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH' });
    const remove = command('project.delete', projectId, { taskPolicy: 'move_tasks_to_inbox' }, afterCommand(rename));
    await apply(remove);
    await db.pool.query("UPDATE command_receipts SET result = result || jsonb_build_object('affectedTaskRevisions', $2::jsonb) WHERE client_command_id = $1", [remove.clientCommandId, JSON.stringify({ [taskId]: '2' })]);
    expect(await run(command('task.patch', taskId, { set: { title: 'Refusé' } }, afterCommand(remove))))
      .toMatchObject({ outcome: 'rejected', code: 'REVISION_MISMATCH', currentRevision: 2 });
  });
});
