import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { runImportCommand } from '../../src/cli/import.js';
import { buildExport } from '../../src/modules/export/archive.js';
import { ImportError, MAX_IMPORT_BYTES } from '../../src/modules/import/formats.js';
import { readImportJson, writeImportPlan } from '../../src/modules/import/files.js';
import { commandsForPlan, importIdFor, planHash, readImportPlan, type ImportPlan } from '../../src/modules/import/plan.js';
import { applyImport, previewImport } from '../../src/modules/import/service.js';
import { createTestDatabase } from '../db/helpers.js';
import { command, commandRunner } from './helpers.js';

const API = 'https://planner.test/api';
const now = new Date('2026-09-17T18:00:00Z');
const emptySelection = { taskIds: [] as string[], projectIds: [] as string[], tagIds: [] as string[] };
const hash = (value: unknown) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const archive = (tasks: unknown[] = []) => ({ exportVersion: 1, exportedAt: now.toISOString(), serverGeneration: randomUUID(),
  projects: [] as unknown[], tags: [] as unknown[], tasks, taskTags: [] as unknown[], reminders: [] as unknown[], taskOccurrences: [] as unknown[], conversations: [] as unknown[] });
const task = (overrides: Record<string, unknown> = {}) => ({ id: randomUUID(), title: 'Tâche synthétique', notes: 'Description de test', projectId: null,
  priority: 'medium', status: 'active', completedAt: null, schedule: { date: '2026-10-02' }, deadline: null, durationMinutes: 45,
  recurrence: null, subtasks: [], revision: 0, deletedAt: null, createdAt: null, updatedAt: null, ...overrides });

describe('selective console import', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let directory: string;
  beforeAll(async () => { db = await createTestDatabase(); directory = await mkdtemp(join(tmpdir(), 'planner-import-test-')); });
  afterAll(async () => {
    await db?.close();
    // Only the directory freshly allocated by this suite, never a caller-provided path.
    if (directory && (resolve(directory).startsWith(resolve(tmpdir()) + '\\') || resolve(directory).startsWith(resolve(tmpdir()) + '/'))) {
      await rm(directory, { recursive: true, force: true });
    }
  });
  async function owner() {
    const userId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    return { userId, ...commandRunner(db.pool, { userId, deviceId: null, origin: 'manual' }, () => now) };
  }
  const preview = (userId: string, source: unknown, selection: unknown) => previewImport(db.pool, { userId, apiUrl: API, source,
    sourceSha256: hash(source), selection, now });
  const apply = (plan: ImportPlan, extra: Partial<{ userId: string; apiUrl: string; planHash: string }> = {}) =>
    applyImport(db.pool, plan, { userId: plan.target.userId, apiUrl: API, planHash: plan.planHash, ...extra });
  const count = async (userId: string, table = 'tasks') => {
    if (!['tasks', 'projects', 'tags', 'command_receipts', 'reminders', 'user_settings'].includes(table)) throw new Error('Unexpected test table');
    return (await db.pool.query<{ n: number }>(`SELECT count(*)::int AS n FROM ${table} WHERE ${table === 'user_settings' ? 'id' : 'user_id'}=$1`, [userId])).rows[0]!.n;
  };

  it('previews a real server export without effects and imports selected graphs under entirely new IDs', async () => {
    const source = await owner(); const destination = await owner(); const projectId = randomUUID(); const tagId = randomUUID(); const taskId = randomUUID();
    const subtaskId = randomUUID(); const reminderId = randomUUID();
    await source.apply(command('project.create', projectId, { name: 'Liste source', colorKey: 'red', sortOrder: 8 }));
    await source.apply(command('project.archive', projectId));
    await source.apply(command('tag.create', tagId, { name: 'Maison' }));
    await source.apply(command('task.create', taskId, { title: 'Titre source', notes: 'Notes source', projectId, tagIds: [tagId],
      schedule: { date: '2026-10-02', time: '09:00', timeZone: 'Europe/Zurich' },
      subtasks: [{ id: subtaskId, title: 'Étape', isCompleted: true }], reminders: [{ id: reminderId, rule: { kind: 'before_start', offsetMinutes: 10 } }] }));
    await source.apply(command('task.complete', taskId));
    const exported = await buildExport(db.pool, source.userId, now);
    const before = JSON.stringify(exported);
    const plan = await preview(destination.userId, exported, { taskIds: [taskId], projectIds: [projectId], tagIds: [tagId] });
    expect(await count(destination.userId)).toBe(0);
    expect(await count(destination.userId, 'command_receipts')).toBe(0);
    expect(plan.tasks[0]).toMatchObject({ completed: true, notes: 'Notes source', subtasks: [{ sourceId: subtaskId, isCompleted: true }] });
    expect(plan.tasks[0]!.id).not.toBe(taskId);
    expect(plan.tasks[0]!.subtasks[0]!.id).not.toBe(subtaskId);
    expect(plan.tasks[0]!.reminders[0]!.id).not.toBe(reminderId);
    expect(await apply(plan)).toMatchObject({ outcome: 'applied', projects: 1, tags: 1, tasks: 1 });
    const result = await buildExport(db.pool, destination.userId, now);
    expect(result.projects).toMatchObject([{ id: plan.projects[0]!.id, archivedAt: expect.any(String) }]);
    expect(result.tasks).toMatchObject([{ id: plan.tasks[0]!.id, projectId: plan.projects[0]!.id, status: 'completed', notes: 'Notes source' }]);
    expect(result.reminders).toMatchObject([{ id: plan.tasks[0]!.reminders[0]!.id, taskId: plan.tasks[0]!.id }]);
    expect(result.taskTags).toMatchObject([{ taskId: plan.tasks[0]!.id, tagId: plan.tags[0]!.id }]);
    expect(JSON.stringify(exported)).toBe(before);
    expect(await count(source.userId)).toBe(1);
  });

  it('accepts historical iPhone snapshots but never executes pending, rejected, assistant or auth-like content', async () => {
    const user = await owner(); const row = task({ createdAt: '2026-09-17 14:05:12.123Z', updatedAt: '2026-09-17 14:05:12.123Z',
      status: 'completed', completedAt: '2026-09-17 14:05:12.123Z' }); const victim = randomUUID();
    await user.apply(command('task.create', victim, { title: 'Intacte' }));
    const source = { ...archive([row]), localExportVersion: 1, exportSource: 'iphone', serverGeneration: null,
      localState: { initialSync: 'incomplete' }, pendingCommands: [{ command: command('task.delete', victim), storedCommand: 'SECRET_PENDING' }],
      syncRejections: [{ storedCommand: 'SECRET_REJECTED' }], drafts: { assistantText: 'SECRET_DRAFT', pendingAssistant: { text: 'SECRET_AUTH' } },
      assistantSettings: { autoTags: true }, conversations: [{ messages: [{ text: 'SECRET_MESSAGE' }] }], unlinkedMessages: [] };
    const plan = await preview(user.userId, source, { ...emptySelection, taskIds: [row.id] });
    expect(plan.excluded).toMatchObject({ pendingCommands: 1, syncRejections: 1, drafts: 1, conversations: 1, assistantSettings: 1 });
    expect(plan.warnings).toContainEqual({ code: 'LOCAL_SNAPSHOT_MAY_BE_INCOMPLETE' });
    expect(JSON.stringify(plan)).not.toContain('SECRET_');
    await apply(plan);
    expect((await db.pool.query('SELECT deleted_at FROM tasks WHERE id=$1', [victim])).rows[0].deleted_at).toBeNull();
    expect(await count(user.userId, 'user_settings')).toBe(0);
    expect((await db.pool.query('SELECT status FROM tasks WHERE id=$1', [plan.tasks[0]!.id])).rows[0].status).toBe('completed');
  });

  it('records omitted references and restores selected trash entries without old deletion markers', async () => {
    const user = await owner(); const projectId = randomUUID(); const tagId = randomUUID();
    const row = task({ projectId, deletedAt: now.toISOString(), deletedByCommandId: randomUUID() });
    const source = archive([row]);
    source.projects = [{ id: projectId, name: 'Non choisie', deletedAt: now.toISOString() }];
    source.tags = [{ id: tagId, name: 'Non choisi' }];
    source.taskTags = [{ id: randomUUID(), taskId: row.id, tagId, deletedAt: null }];
    const plan = await preview(user.userId, source, { ...emptySelection, taskIds: [row.id] });
    expect(plan.tasks[0]).toMatchObject({ projectId: null, tagIds: [] });
    expect(plan.warnings.map((item) => item.code)).toEqual(expect.arrayContaining(['PROJECT_OMITTED_TASK_MOVED_TO_INBOX', 'TRASHED_TASK_RECREATED_ACTIVE', 'TAG_RELATION_OMITTED']));
    await apply(plan);
    expect((await db.pool.query('SELECT deleted_at,deleted_by_command_id FROM tasks WHERE id=$1', [plan.tasks[0]!.id])).rows[0])
      .toEqual({ deleted_at: null, deleted_by_command_id: null });
  });

  it('counts every excluded reminder and relation, including objects belonging to unselected tasks', async () => {
    const user = await owner(); const chosen = task({ schedule: { date: '2026-10-02', time: '09:00', timeZone: 'Europe/Zurich' } }), omitted = task(); const tagId = randomUUID();
    const source = archive([chosen, omitted]); source.tags = [{ id: tagId, name: 'Choisi' }];
    source.taskTags = [chosen, omitted].map((row) => ({ id: randomUUID(), taskId: row.id, tagId, deletedAt: null }));
    const reminder = (taskId: string, extra: Record<string, unknown> = {}) => ({ id: randomUUID(), taskId, occurrenceKey: null,
      kind: 'before_start', offsetMinutes: 10, localTime: null, absolute: null, state: 'active', ...extra });
    source.reminders = [reminder(chosen.id), reminder(omitted.id), reminder(chosen.id, { deletedAt: now.toISOString() }),
      reminder(chosen.id, { state: 'inactive_base_missing' }), reminder(chosen.id, { occurrenceKey: '2026-10-02' })];
    const plan = await preview(user.userId, source, { ...emptySelection, taskIds: [chosen.id], tagIds: [tagId] });
    expect(plan.excluded).toMatchObject({ tasks: 1, reminders: 4, tagRelations: 1 });
    expect(plan.tasks[0]!.reminders).toHaveLength(1);
    expect(plan.tasks[0]!.tagIds).toHaveLength(1);
    const malformed = structuredClone(source);
    malformed.reminders[0] = reminder(chosen.id, { localTime: '08:00' });
    await expect(preview(user.userId, malformed, { ...emptySelection, taskIds: [chosen.id] })).rejects.toThrow('IMPORT_INVALID_REMINDER');
  });

  it('makes retries and simultaneous apply calls idempotent after a lost reply', async () => {
    const user = await owner(); const row = task();
    const plan = await preview(user.userId, archive([row]), { ...emptySelection, taskIds: [row.id] });
    const results = await Promise.all([apply(plan), apply(plan)]);
    expect(results.map((result) => result.outcome).sort()).toEqual(['already_applied', 'applied']);
    expect(await apply(plan)).toMatchObject({ outcome: 'already_applied' });
    expect(await count(user.userId)).toBe(1);
    expect(await count(user.userId, 'command_receipts')).toBe(1);
  });

  it('rolls back an entire application when a catalog conflict appears after preview', async () => {
    const user = await owner(); const source = archive(); const listId = randomUUID(); const tagId = randomUUID();
    source.projects = [{ id: listId, name: 'Doit être annulée' }]; source.tags = [{ id: tagId, name: 'Conflit' }];
    const plan = await preview(user.userId, source, { ...emptySelection, projectIds: [listId], tagIds: [tagId] });
    await user.apply(command('tag.create', randomUUID(), { name: 'CONFLIT' }));
    await expect(apply(plan)).rejects.toMatchObject({ importCode: 'IMPORT_COMMAND_TAG_NAME_TAKEN' });
    expect(await count(user.userId, 'projects')).toBe(0);
    expect(await count(user.userId, 'tags')).toBe(1);
    expect(await count(user.userId, 'command_receipts')).toBe(1);
  });

  it('requires explicit tag renaming rather than merging a colliding existing tag', async () => {
    const user = await owner(); await user.apply(command('tag.create', randomUUID(), { name: 'Café' }));
    const id = randomUUID(); const source = archive(); source.tags = [{ id, name: 'Cafe\u0301' }];
    await expect(preview(user.userId, source, { ...emptySelection, tagIds: [id] })).rejects.toMatchObject({ importCode: 'IMPORT_COMMAND_TAG_NAME_TAKEN' });
    const plan = await preview(user.userId, source, { ...emptySelection, tagIds: [id], tagNames: { [id]: 'Café importé' } });
    await apply(plan);
    expect(await count(user.userId, 'tags')).toBe(2);
  });

  it('requires an explicit valid series restart and excludes every previous occurrence', async () => {
    const user = await owner(); const row = task({ recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 2 }, missedIgnoredBefore: '2026-09-15' });
    const source = archive([row]); source.taskOccurrences = [{ id: randomUUID(), taskId: row.id, status: 'completed', occurrenceKey: '2026-09-16' }];
    await expect(preview(user.userId, source, { ...emptySelection, taskIds: [row.id] })).rejects.toMatchObject({ importCode: 'IMPORT_SERIES_RESTART_REQUIRED' });
    const plan = await preview(user.userId, source, { ...emptySelection, taskIds: [row.id], restartSeries: { [row.id]: { date: '2026-12-01' } } });
    expect(plan.warnings).toContainEqual({ code: 'SERIES_RESTARTED_WITHOUT_HISTORY', sourceId: row.id });
    expect(plan.excluded.occurrences).toBe(1);
    await apply(plan);
    const imported = (await buildExport(db.pool, user.userId, now));
    expect(imported.tasks).toMatchObject([{ schedule: { date: '2026-12-01' }, status: 'active', missedIgnoredBefore: null }]);
    expect(imported.taskOccurrences).toEqual([]);
    const expired = { ...source, tasks: [{ ...row, recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 1, until: '2026-10-01' } }] };
    await expect(preview(user.userId, expired, { ...emptySelection, taskIds: [row.id], restartSeries: { [row.id]: { date: '2026-12-01' } } }))
      .rejects.toMatchObject({ importCode: 'IMPORT_RESTART_AFTER_SERIES_END' });
  });

  it('blocks a different confirmed hash, user, server or generation before effects', async () => {
    const user = await owner(); const row = task(); const plan = await preview(user.userId, archive([row]), { ...emptySelection, taskIds: [row.id] });
    await expect(apply(plan, { planHash: '0'.repeat(64) })).rejects.toMatchObject({ importCode: 'IMPORT_PLAN_HASH_MISMATCH' });
    await expect(apply(plan, { userId: randomUUID() })).rejects.toMatchObject({ importCode: 'IMPORT_TARGET_USER_CHANGED' });
    await expect(apply(plan, { apiUrl: 'https://another.test' })).rejects.toMatchObject({ importCode: 'IMPORT_TARGET_SERVER_CHANGED' });
    await db.pool.query('UPDATE server_meta SET generation=$1', [randomUUID()]); // disposable suite schema only
    await expect(apply(plan)).rejects.toMatchObject({ importCode: 'IMPORT_SERVER_GENERATION_CHANGED' });
    expect(await count(user.userId)).toBe(0);
  });

  it('rejects tampering, arbitrary commands, foreign references and substituted destination IDs', async () => {
    const user = await owner(); const row = task(); const plan = await preview(user.userId, archive([row]), { ...emptySelection, taskIds: [row.id] });
    expect(() => readImportPlan({ ...plan, tasks: [{ ...plan.tasks[0], title: 'Modifié' }] }, plan.planHash)).toThrow('IMPORT_PLAN_HASH_MISMATCH');
    expect(() => readImportPlan({ ...plan, commands: [command('task.delete', row.id)] })).toThrow('IMPORT_INVALID_PLAN');
    const foreign = structuredClone(plan); foreign.tasks[0]!.projectId = randomUUID();
    const { planHash: _hash, ...body } = foreign; foreign.planHash = planHash(body);
    expect(() => readImportPlan(foreign)).toThrow('IMPORT_FOREIGN_REFERENCE');
    await expect(apply(foreign)).rejects.toMatchObject({ importCode: 'IMPORT_FOREIGN_REFERENCE' });
    const idChanged = structuredClone(plan); idChanged.tasks[0]!.id = row.id;
    const { planHash: _other, ...otherBody } = idChanged; idChanged.planHash = planHash(otherBody);
    expect(() => readImportPlan(idChanged)).toThrow('IMPORT_INVALID_DERIVED_ID');
    await expect(apply(idChanged)).rejects.toMatchObject({ importCode: 'IMPORT_INVALID_DERIVED_ID' });
    expect(await count(user.userId)).toBe(0);
  });

  it('rejects unsupported versions, malformed selected rows, duplicates and empty/unknown selection', async () => {
    const user = await owner(); const row = task(); const source = archive([row]);
    for (const changed of [{ ...source, exportVersion: 2 }, { ...source, taskDetailsVersion: 2 }, { ...source, localExportVersion: 3, exportSource: 'iphone' },
      { ...source, tasks: [{ ...row, subtasks: 'not JSON' }] }, { ...source, tasks: [{ ...row, authToken: 'SECRET' }] }, { ...source, tasks: [row, row] }]) {
      await expect(preview(user.userId, changed, { ...emptySelection, taskIds: [row.id] })).rejects.toBeInstanceOf(ImportError);
    }
    await expect(preview(user.userId, source, emptySelection)).rejects.toMatchObject({ importCode: 'IMPORT_EMPTY_SELECTION' });
    await expect(preview(user.userId, source, { ...emptySelection, taskIds: [randomUUID()] })).rejects.toMatchObject({ importCode: 'IMPORT_SOURCE_NOT_FOUND' });
    await expect(preview(user.userId, source, { ...emptySelection, taskIds: [row.id, row.id] })).rejects.toMatchObject({ importCode: 'IMPORT_DUPLICATE_SELECTION' });
    const tagId = 'a1234567-1234-4123-8123-123456789abc';
    await expect(preview(user.userId, source, { ...emptySelection, taskIds: [row.id], tagNames: { [tagId]: 'Un', [tagId.toUpperCase()]: 'Deux' } }))
      .rejects.toMatchObject({ importCode: 'IMPORT_INVALID_SELECTION' });
    expect(await count(user.userId, 'command_receipts')).toBe(0);
  });

  it('bounds commands at 500 before any handler runs, including archive/complete follow-ups', async () => {
    const user = await owner(); const rows = Array.from({ length: 251 }, () => task({ status: 'completed', completedAt: now.toISOString() }));
    await expect(preview(user.userId, archive(rows), { ...emptySelection, taskIds: rows.map((item) => item.id) }))
      .rejects.toMatchObject({ importCode: 'IMPORT_COMMAND_LIMIT' });
    expect(await count(user.userId)).toBe(0);
  });

  it('keeps stable command identities when a plan file is read back', async () => {
    const user = await owner(); const row = task(); const plan = await preview(user.userId, archive([row]), { ...emptySelection, taskIds: [row.id] });
    const path = join(directory, 'roundtrip.json');
    await writeImportPlan(path, plan);
    expect(commandsForPlan(readImportPlan((await readImportJson(path)).value))).toEqual(commandsForPlan(plan));
    expect(plan.tasks[0]!.id).toBe(importIdFor(plan.importId, 'task', row.id));
    await expect(writeImportPlan(path, plan)).rejects.toMatchObject({ importCode: 'IMPORT_PLAN_FILE_EXISTS' });
    if (process.platform !== 'win32') expect((await stat(path)).mode & 0o777).toBe(0o600);
  });

  it('rejects invalid UTF-8/JSON and oversized input without exposing its content', async () => {
    const path = join(directory, 'bad.json');
    await writeFile(path, 'SECRET_INVALID_JSON');
    await expect(readImportJson(path)).rejects.toThrow('IMPORT_INVALID_JSON');
    await writeFile(path, Buffer.from([0xff, 0xfe]));
    await expect(readImportJson(path)).rejects.toThrow('IMPORT_INVALID_JSON');
    await writeFile(path, Buffer.alloc(MAX_IMPORT_BYTES + 1));
    await expect(readImportJson(path)).rejects.toThrow('IMPORT_FILE_TOO_LARGE');
  });

  it('uses console preview/apply explicitly, prints no task contents and never rewrites the source', async () => {
    const user = await owner(); const row = task({ title: 'PRIVATE_TITLE', notes: 'PRIVATE_NOTES' });
    const source = archive([row]); const input = join(directory, 'source.json'), choice = join(directory, 'selection.json'), output = join(directory, 'console.json');
    const content = JSON.stringify(source);
    await writeFile(input, content); await writeFile(choice, JSON.stringify({ ...emptySelection, taskIds: [row.id] }));
    const spy = vi.spyOn(process.stdout, 'write').mockReturnValue(true);
    try {
      await runImportCommand(db.pool, { mode: 'preview', file: input, selection: choice, output, userId: user.userId, apiUrl: API });
      expect(await count(user.userId)).toBe(0);
      const plan = readImportPlan((await readImportJson(output)).value);
      await expect(runImportCommand(db.pool, { mode: 'apply', file: output, userId: user.userId, apiUrl: API })).rejects.toThrow('IMPORT_CONFIRM_PLAN_REQUIRED');
      await runImportCommand(db.pool, { mode: 'apply', file: output, confirmedHash: plan.planHash, userId: user.userId, apiUrl: API });
      expect(await count(user.userId)).toBe(1);
      expect(spy.mock.calls.map((call) => call[0]).join('')).not.toContain('PRIVATE_');
      expect(await readFile(input, 'utf8')).toBe(content);
    } finally { spy.mockRestore(); }
  });
});
