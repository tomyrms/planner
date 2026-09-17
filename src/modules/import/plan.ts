import { createHash, randomUUID } from 'node:crypto';
import { v5 as uuidv5 } from 'uuid';
import { z } from 'zod';
import { canonicalJson, payloadSchemasV1, type RawCommand } from '../sync/index.js';
import { reminderRuleSchema, type ReminderRule } from '../time/index.js';
import {
  checked, ImportError, MAX_IMPORT_COMMANDS, selectionSchema, sourceExportSchema, sourceProjectSchema,
  sourceReminderSchema, sourceRows, sourceSubtaskSchema, sourceTagSchema, sourceTaskSchema, sourceTaskTagSchema,
} from './formats.js';

const uuid = z.uuid().transform((value) => value.toLowerCase());
const timestamp = z.iso.datetime({ offset: true });
const identity = { sourceId: uuid, id: uuid };
const planSubtaskSchema = sourceSubtaskSchema.extend({ sourceId: uuid });
const planReminderSchema = z.strictObject({ ...identity, rule: reminderRuleSchema });
const planProjectSchema = payloadSchemasV1['project.create'].extend({ ...identity, archived: z.boolean() });
const planTagSchema = payloadSchemasV1['tag.create'].extend(identity);
const planTaskSchema = payloadSchemasV1['task.create'].omit({ subtasks: true, reminders: true }).extend({
  ...identity, subtasks: z.array(planSubtaskSchema).max(50), reminders: z.array(planReminderSchema).max(10),
  completed: z.boolean(), restartedSeries: z.boolean(),
});
const warningSchema = z.strictObject({ code: z.string().regex(/^[A-Z_]+$/), sourceId: uuid.optional(), count: z.number().int().min(0).optional() });
export const planBodySchema = z.strictObject({
  planVersion: z.literal(1), importId: uuid, createdAt: timestamp,
  sourceSha256: z.string().regex(/^[a-f0-9]{64}$/), sourceKind: z.enum(['server', 'iphone']),
  target: z.strictObject({ userId: uuid, serverGeneration: uuid, apiUrl: z.url() }),
  projects: z.array(planProjectSchema).max(500), tags: z.array(planTagSchema).max(200), tasks: z.array(planTaskSchema).max(500),
  warnings: z.array(warningSchema).max(5000), excluded: z.record(z.string().regex(/^[A-Za-z]+$/), z.number().int().min(0)),
});
export const importPlanSchema = planBodySchema.extend({ planHash: z.string().regex(/^[a-f0-9]{64}$/) });
export type ImportPlan = z.infer<typeof importPlanSchema>;
type PlanBody = z.infer<typeof planBodySchema>;
type Warning = z.infer<typeof warningSchema>;

export function importIdFor(importId: string, kind: string, sourceId: string): string {
  return uuidv5(`${kind}:${sourceId.toLowerCase()}`, importId);
}
export const planHash = (body: PlanBody): string => createHash('sha256').update(canonicalJson(body)).digest('hex');

function unique(ids: readonly string[]) {
  if (new Set(ids).size !== ids.length) throw new ImportError('IMPORT_DUPLICATE_SELECTION');
}
function selected<T>(rows: Map<string, unknown>, id: string, schema: z.ZodType<T>): T {
  if (!rows.has(id)) throw new ImportError('IMPORT_SOURCE_NOT_FOUND', id);
  return checked(schema, rows.get(id), 'IMPORT_INVALID_SELECTED_OBJECT', id);
}

function byTask<T extends { taskId: string }>(rows: readonly unknown[], schema: z.ZodType<T>, error: string): Map<string, T[]> {
  const grouped = new Map<string, T[]>();
  for (const value of sourceRows(rows).values()) {
    const row = checked(schema, value, error);
    const group = grouped.get(row.taskId) ?? [];
    group.push(row);
    grouped.set(row.taskId, group);
  }
  return grouped;
}

function ruleFor(reminder: z.infer<typeof sourceReminderSchema>): ReminderRule {
  let value: unknown;
  switch (reminder.kind) {
    case 'before_start': case 'before_deadline': value = { kind: reminder.kind, offsetMinutes: reminder.offsetMinutes }; break;
    case 'on_scheduled_day_at': case 'on_deadline_day_at': value = { kind: reminder.kind, localTime: reminder.localTime }; break;
    case 'absolute': value = { kind: reminder.kind, absolute: reminder.absolute }; break;
  }
  return checked(reminderRuleSchema, value, 'IMPORT_INVALID_REMINDER', reminder.id);
}

/** Builds a closed, inspectable document; neither source commands nor source auth metadata are copied. */
export function buildImportPlan(source: unknown, sourceSha256: string, selection: unknown, target: ImportPlan['target'], now = new Date(), importId: string = randomUUID()): ImportPlan {
  const archive = checked(sourceExportSchema, source, 'IMPORT_UNSUPPORTED_EXPORT');
  const choice = checked(selectionSchema, selection, 'IMPORT_INVALID_SELECTION');
  for (const ids of [choice.taskIds, choice.projectIds, choice.tagIds]) unique(ids);
  if (choice.taskIds.length + choice.projectIds.length + choice.tagIds.length === 0) throw new ImportError('IMPORT_EMPTY_SELECTION');
  if (Object.keys(choice.tagNames ?? {}).some((id) => !choice.tagIds.includes(id))
    || Object.keys(choice.restartSeries ?? {}).some((id) => !choice.taskIds.includes(id))) throw new ImportError('IMPORT_UNUSED_OVERRIDE');
  const sourceProjects = sourceRows(archive.projects), sourceTags = sourceRows(archive.tags ?? []), sourceTasks = sourceRows(archive.tasks);
  const sourceReminders = byTask(archive.reminders, sourceReminderSchema, 'IMPORT_INVALID_REMINDER');
  const relations = byTask(archive.taskTags ?? [], sourceTaskTagSchema, 'IMPORT_INVALID_TAG_RELATION');
  const warnings: Warning[] = [];
  const warn = (code: string, sourceId: string) => warnings.push({ code, sourceId });
  if (archive.localExportVersion === 1) warnings.push({ code: 'LOCAL_SNAPSHOT_MAY_BE_INCOMPLETE' });
  const projects = choice.projectIds.map((sourceId) => {
    const row = selected(sourceProjects, sourceId, sourceProjectSchema);
    if (row.deletedAt) warn('TRASHED_PROJECT_RECREATED_ACTIVE', sourceId);
    return { sourceId, id: importIdFor(importId, 'project', sourceId), name: row.name, colorKey: row.colorKey ?? null,
      sortOrder: row.sortOrder ?? null, archived: row.archivedAt != null };
  });
  const tags = choice.tagIds.map((sourceId) => {
    const row = selected(sourceTags, sourceId, sourceTagSchema);
    if (row.deletedAt) warn('DELETED_TAG_RECREATED_ACTIVE', sourceId);
    return { sourceId, id: importIdFor(importId, 'tag', sourceId), name: choice.tagNames?.[sourceId] ?? row.name };
  });
  const projectMap = new Map(projects.map((row) => [row.sourceId, row.id]));
  const tagMap = new Map(tags.map((row) => [row.sourceId, row.id]));
  let includedReminders = 0, includedLinks = 0;
  const tasks = choice.taskIds.map((sourceId) => {
    const row = selected(sourceTasks, sourceId, sourceTaskSchema);
    const restart = choice.restartSeries?.[sourceId];
    if (row.recurrence !== null && !restart) throw new ImportError('IMPORT_SERIES_RESTART_REQUIRED', sourceId);
    if (row.recurrence === null && restart) throw new ImportError('IMPORT_UNUSED_RESTART', sourceId);
    if (row.recurrence?.mode === 'fixed' && row.recurrence.until && restart && row.recurrence.until < restart.date) {
      throw new ImportError('IMPORT_RESTART_AFTER_SERIES_END', sourceId);
    }
    if (row.recurrence !== null) warn('SERIES_RESTARTED_WITHOUT_HISTORY', sourceId);
    if (row.deletedAt) warn('TRASHED_TASK_RECREATED_ACTIVE', sourceId);
    if (row.status === 'completed' && row.recurrence === null) warn('COMPLETION_TIMESTAMP_REPLACED', sourceId);
    if (row.projectId !== null && !projectMap.has(row.projectId)) warn('PROJECT_OMITTED_TASK_MOVED_TO_INBOX', sourceId);
    const tagIds: string[] = [];
    for (const relation of relations.get(sourceId) ?? []) {
      const tag = tagMap.get(relation.tagId);
      if (relation.deletedAt || !tag) { warn('TAG_RELATION_OMITTED', sourceId); continue; }
      if (tagIds.includes(tag)) throw new ImportError('IMPORT_DUPLICATE_TAG_RELATION', sourceId);
      tagIds.push(tag);
      includedLinks++;
    }
    const subtasks = (row.subtasks ?? []).map((item) => ({ ...item, sourceId: item.id, id: importIdFor(importId, `subtask/${sourceId}`, item.id) }));
    unique(subtasks.map((item) => item.sourceId));
    const reminders: z.infer<typeof planReminderSchema>[] = [];
    for (const reminder of sourceReminders.get(sourceId) ?? []) {
      if (reminder.deletedAt || reminder.state !== 'active' || reminder.occurrenceKey !== null) {
        warn('REMINDER_OMITTED', reminder.id); continue;
      }
      reminders.push({ sourceId: reminder.id, id: importIdFor(importId, `reminder/${sourceId}`, reminder.id), rule: ruleFor(reminder) });
      includedReminders++;
    }
    return { sourceId, id: importIdFor(importId, 'task', sourceId), title: row.title, notes: row.notes, priority: row.priority,
      projectId: row.projectId ? projectMap.get(row.projectId) ?? null : null, schedule: restart ?? row.schedule,
      deadline: row.deadline, durationMinutes: row.durationMinutes, recurrence: row.recurrence,
      completed: row.status === 'completed' && row.recurrence === null, restartedSeries: row.recurrence !== null,
      subtasks, tagIds: tagIds.sort(), reminders };
  });
  const body = checked(planBodySchema, {
    planVersion: 1, importId, createdAt: now.toISOString(), sourceSha256, sourceKind: archive.localExportVersion === 1 ? 'iphone' : 'server',
    target, projects, tags, tasks, warnings,
    excluded: { projects: archive.projects.length - projects.length, tags: (archive.tags?.length ?? 0) - tags.length,
      tasks: archive.tasks.length - tasks.length, tagRelations: (archive.taskTags?.length ?? 0) - includedLinks,
      reminders: archive.reminders.length - includedReminders,
      occurrences: archive.taskOccurrences.length, conversations: archive.conversations.length,
      unlinkedMessages: archive.unlinkedMessages?.length ?? 0, pendingCommands: archive.pendingCommands?.length ?? 0,
      syncRejections: archive.syncRejections?.length ?? 0, drafts: archive.drafts == null ? 0 : 1,
      assistantSettings: archive.assistantSettings == null ? 0 : 1 },
  }, 'IMPORT_INVALID_PLAN');
  const plan = { ...body, planHash: planHash(body) };
  commandsForPlan(plan); // Check the very same closed surface before it is ever written.
  return plan;
}

export function readImportPlan(value: unknown, confirmedHash?: string): ImportPlan {
  const plan = checked(importPlanSchema, value, 'IMPORT_INVALID_PLAN');
  const { planHash: hash, ...body } = plan;
  if (planHash(body) !== hash || (confirmedHash !== undefined && hash !== confirmedHash)) throw new ImportError('IMPORT_PLAN_HASH_MISMATCH');
  commandsForPlan(plan);
  return plan;
}

/** Source data becomes creation commands only. Files cannot supply executable command envelopes. */
export function commandsForPlan(plan: ImportPlan): RawCommand[] {
  const commands: RawCommand[] = [];
  const projectIds = new Set(plan.projects.map((row) => row.id)), tagIds = new Set(plan.tags.map((row) => row.id));
  const checkId = (kind: string, row: { sourceId: string; id: string }) => {
    if (row.id !== importIdFor(plan.importId, kind, row.sourceId)) throw new ImportError('IMPORT_INVALID_DERIVED_ID', row.sourceId);
  };
  const push = (type: keyof typeof payloadSchemasV1, id: string, payload: unknown, after?: string) => {
    const aggregateType = type.startsWith('project.') ? 'project' : type.startsWith('tag.') ? 'tag' : 'task';
    const parsed = payloadSchemasV1[type].safeParse(payload);
    if (!parsed.success) throw new ImportError('IMPORT_INVALID_PAYLOAD', id);
    const validated = parsed.data;
    const command: RawCommand = { clientCommandId: importIdFor(plan.importId, `command/${type}`, id), type, payloadVersion: 1,
      aggregate: { type: aggregateType, id }, clientRecordedAt: plan.createdAt, payload: validated,
      ...(after ? { precondition: { kind: 'afterCommand' as const, clientCommandId: after } } : {}) };
    commands.push(command);
    return command.clientCommandId;
  };
  for (const rows of [plan.projects, plan.tags, plan.tasks]) { unique(rows.map((row) => row.id)); unique(rows.map((row) => row.sourceId)); }
  for (const { sourceId, id, archived, ...payload } of plan.projects) {
    checkId('project', { sourceId, id });
    const create = push('project.create', id, payload);
    if (archived) push('project.archive', id, {}, create);
  }
  for (const { sourceId, id, ...payload } of plan.tags) { checkId('tag', { sourceId, id }); push('tag.create', id, payload); }
  for (const { sourceId, id, completed, restartedSeries, subtasks, reminders, ...payload } of plan.tasks) {
    checkId('task', { sourceId, id });
    if ((payload.projectId != null && !projectIds.has(payload.projectId)) || payload.tagIds?.some((tag) => !tagIds.has(tag))) {
      throw new ImportError('IMPORT_FOREIGN_REFERENCE', sourceId);
    }
    if ((payload.recurrence != null) !== restartedSeries || (restartedSeries && completed)) throw new ImportError('IMPORT_INVALID_SERIES_POLICY', sourceId);
    if (restartedSeries && payload.schedule == null) throw new ImportError('IMPORT_INVALID_SERIES_POLICY', sourceId);
    if (payload.recurrence?.mode === 'fixed' && payload.recurrence.until && payload.schedule && payload.recurrence.until < payload.schedule.date) {
      throw new ImportError('IMPORT_RESTART_AFTER_SERIES_END', sourceId);
    }
    unique(subtasks.map((row) => row.sourceId)); unique(reminders.map((row) => row.sourceId));
    const create = push('task.create', id, { ...payload,
      subtasks: subtasks.map(({ sourceId: childSource, ...item }) => { checkId(`subtask/${sourceId}`, { sourceId: childSource, id: item.id }); return item; }),
      reminders: reminders.map(({ sourceId: reminderSource, ...item }) => { checkId(`reminder/${sourceId}`, { sourceId: reminderSource, id: item.id }); return item; }),
    });
    if (completed) push('task.complete', id, {}, create);
  }
  if (commands.length === 0 || commands.length > MAX_IMPORT_COMMANDS) throw new ImportError('IMPORT_COMMAND_LIMIT');
  return commands;
}
