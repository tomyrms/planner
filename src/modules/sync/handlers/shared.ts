import { and, eq, inArray, isNull } from 'drizzle-orm';
import { projects, reminders, taskOccurrences, tasks, tombstones } from '../../../infrastructure/db/schema.js';
import { fromTimeValue, reminderHasBase, reminderRuleFromColumns, toTimeValue } from '../../domain/derive.js';
import { normalizeSearchText } from '../../domain/search.js';
import {
  afterCompletionKey, afterCompletionRecurrenceSchema, civilDateSchema, fixedRecurrenceSchema, isFixedOccurrence,
  occurrenceDate, occurrenceId,
  type AfterCompletionRecurrence, type FixedRecurrence, type ReminderRule, type TimeValue,
} from '../../time/index.js';
import type { CommandType, PayloadOf } from '../commands.js';
import { CommandRejection, type CommandContext, type HandlerResult } from '../types.js';

export type TaskRow = typeof tasks.$inferSelect;
export type TaskChanges = Partial<typeof tasks.$inferInsert>;
export type ProjectRow = typeof projects.$inferSelect;
export type OccurrenceRow = typeof taskOccurrences.$inferSelect;
export type Occurrences = Map<string, OccurrenceRow>;
/** The task columns that decide series membership and reminder bases. */
export type TaskShape = Pick<TaskRow, 'id' | 'recurrence' | 'scheduledDate' | 'scheduledTime' | 'scheduledTimeZone' | 'deadlineDate' | 'deadlineTime' | 'deadlineTimeZone'>;
/** Same bound as task.create (commands.ts). */
export const MAX_REMINDERS_PER_TASK = 10;
export type Series = { mode: 'fixed'; rule: FixedRecurrence } | { mode: 'after_completion'; rule: AfterCompletionRecurrence };

/** The executor already parsed the payload with the schema of `type`. */
export const payloadOf = <T extends CommandType>(context: CommandContext, _type: T): PayloadOf<T> => context.payload as PayloadOf<T>;

export const revisionOf = (row: { revision: bigint }): number => Number(row.revision);
export const noop = (row: { revision: bigint }, extra: Record<string, unknown> = {}): HandlerResult => ({ revision: revisionOf(row), noop: true, ...extra });

/** A serialization failure makes the executor retry the whole command. */
export function retryable(): Error {
  return Object.assign(new Error('Concurrent change; retry the command.'), { code: '40001' });
}

/** Missing aggregate: purged if a tombstone remains, unknown otherwise. Other users' rows are never revealed. */
export async function rejectMissing(context: CommandContext, entityType: 'task' | 'project' | 'tag', id: string): Promise<never> {
  const [tombstone] = await context.db.select({ id: tombstones.entityId }).from(tombstones)
    .where(and(eq(tombstones.entityType, entityType), eq(tombstones.entityId, id), eq(tombstones.userId, context.actor.userId)));
  throw new CommandRejection(tombstone ? 'ENTITY_PURGED' : 'ENTITY_NOT_FOUND');
}

/** Creation never reuses an identifier, even a purged one. */
export async function assertNewAggregate(context: CommandContext, entityType: 'task' | 'project' | 'tag'): Promise<void> {
  const table = { task: 'tasks', project: 'projects', tag: 'tags' }[entityType];
  const existing = await context.client.query(`SELECT 1 FROM ${table} WHERE id = $1`, [context.aggregateId]);
  if (existing.rowCount) throw new CommandRejection('ENTITY_ALREADY_EXISTS');
  const purged = await context.client.query('SELECT 1 FROM tombstones WHERE entity_type = $1 AND entity_id = $2', [entityType, context.aggregateId]);
  if (purged.rowCount) throw new CommandRejection('ENTITY_PURGED');
}

const presentIds = (ids: ReadonlyArray<string | null | undefined>): string[] =>
  [...new Set(ids.filter((id): id is string => typeof id === 'string').map((id) => id.toLowerCase()))].sort();

/** Lists are locked in id order, in share mode, before any task. */
export async function lockLists(context: CommandContext, ids: ReadonlyArray<string | null | undefined>): Promise<Map<string, ProjectRow>> {
  const wanted = presentIds(ids);
  if (wanted.length === 0) return new Map();
  const rows = await context.db.select().from(projects)
    .where(and(inArray(projects.id, wanted), eq(projects.userId, context.actor.userId)))
    .orderBy(projects.id).for('share');
  return new Map(rows.map((row) => [row.id, row]));
}

export function requireLiveList(lists: Map<string, ProjectRow>, projectId: string): ProjectRow {
  const list = lists.get(projectId.toLowerCase());
  if (!list) throw new CommandRejection('FORBIDDEN_REFERENCE');
  if (list.deletedAt !== null) throw new CommandRejection('PROJECT_DELETED');
  return list;
}

/** Locks the command's task. With `lists`, its current list and `extraLists` are locked first. */
export async function lockTask(context: CommandContext, options: { lists?: boolean; extraLists?: ReadonlyArray<string | null | undefined> } = {}): Promise<{ task: TaskRow; lists: Map<string, ProjectRow> }> {
  const target = and(eq(tasks.id, context.aggregateId), eq(tasks.userId, context.actor.userId));
  let lists = new Map<string, ProjectRow>();
  let expectedProject: string | null | undefined;
  if (options.lists) {
    const [peek] = await context.db.select({ projectId: tasks.projectId }).from(tasks).where(target);
    if (!peek) return rejectMissing(context, 'task', context.aggregateId);
    expectedProject = peek.projectId;
    lists = await lockLists(context, [peek.projectId, ...(options.extraLists ?? [])]);
  }
  const [task] = await context.db.select().from(tasks).where(target).for('update');
  if (!task) return rejectMissing(context, 'task', context.aggregateId);
  if (expectedProject !== undefined && task.projectId !== expectedProject) throw retryable();
  context.observedRevision = revisionOf(task);
  return { task, lists };
}

export async function saveTask(context: CommandContext, task: TaskRow, changes: TaskChanges): Promise<number> {
  const revision = task.revision + 1n;
  await context.db.update(tasks).set({ ...changes, revision, updatedAt: context.now.toISOString() })
    .where(and(eq(tasks.id, task.id), eq(tasks.userId, context.actor.userId)));
  return Number(revision);
}

export function assertLive(task: TaskRow): void {
  if (task.deletedAt !== null) throw new CommandRejection('TASK_DELETED');
}

export const taskSchedule = (task: Pick<TaskRow, 'scheduledDate' | 'scheduledTime' | 'scheduledTimeZone'>): TimeValue | null =>
  toTimeValue({ date: task.scheduledDate, time: task.scheduledTime, zone: task.scheduledTimeZone });
export const taskDeadline = (task: Pick<TaskRow, 'deadlineDate' | 'deadlineTime' | 'deadlineTimeZone'>): TimeValue | null =>
  toTimeValue({ date: task.deadlineDate, time: task.deadlineTime, zone: task.deadlineTimeZone });
export const overrideOf = (row: OccurrenceRow | undefined): TimeValue | null =>
  row === undefined ? null : toTimeValue({ date: row.overrideDate, time: row.overrideTime, zone: row.overrideTimeZone });

export function sameTime(left: TimeValue | null | undefined, right: TimeValue | null | undefined): boolean {
  if (left == null || right == null) return left == null && right == null;
  return left.date === right.date && (left.time ?? null) === (right.time ?? null) && (left.timeZone ?? null) === (right.timeZone ?? null);
}

export function scheduleColumns(value: TimeValue | null, recurring: boolean): TaskChanges {
  const columns = fromTimeValue(value);
  return {
    scheduledDate: columns.date, scheduledTime: columns.time, scheduledTimeZone: columns.zone,
    // The projection is only meaningful for one-off timed tasks (task_schedule_projection).
    scheduledStartAt: recurring ? null : columns.instant,
  };
}

export function deadlineColumns(value: TimeValue | null): TaskChanges {
  const columns = fromTimeValue(value);
  return { deadlineDate: columns.date, deadlineTime: columns.time, deadlineTimeZone: columns.zone, deadlineAt: columns.instant };
}

export function searchTextFor(task: Pick<TaskRow, 'title' | 'notes'>, list: Pick<ProjectRow, 'name'> | null | undefined): string {
  return normalizeSearchText(task.title, task.notes, list?.name);
}

/** Template fields shared by task.patch and series.update. Only real changes are returned. */
export function templateChanges(
  task: TaskRow,
  set: {
    title?: string | undefined; notes?: string | null | undefined; priority?: TaskRow['priority'] | undefined;
    projectId?: string | null | undefined; durationMinutes?: number | null | undefined;
  },
  lists: Map<string, ProjectRow>,
): TaskChanges {
  const changes: TaskChanges = {};
  if (set.title !== undefined && set.title !== task.title) changes.title = set.title;
  if (set.notes !== undefined && set.notes !== task.notes) changes.notes = set.notes;
  if (set.priority !== undefined && set.priority !== task.priority) changes.priority = set.priority;
  if (set.projectId !== undefined) {
    const projectId = set.projectId === null ? null : requireLiveList(lists, set.projectId).id;
    if (projectId !== task.projectId) changes.projectId = projectId;
  }
  if (set.durationMinutes !== undefined && set.durationMinutes !== task.durationMinutes) changes.durationMinutes = set.durationMinutes;
  if (changes.title !== undefined || changes.notes !== undefined || changes.projectId !== undefined) {
    const merged = { ...task, ...changes };
    const searchText = searchTextFor({ title: merged.title, notes: merged.notes ?? null }, merged.projectId ? lists.get(merged.projectId) : null);
    if (searchText !== task.searchText) changes.searchText = searchText;
  }
  return changes;
}

export function seriesOf(task: Pick<TaskRow, 'recurrence'>): Series {
  if (task.recurrence === null) throw new CommandRejection('NOT_A_SERIES');
  const fixed = fixedRecurrenceSchema.safeParse(task.recurrence);
  if (fixed.success) return { mode: 'fixed', rule: fixed.data };
  return { mode: 'after_completion', rule: afterCompletionRecurrenceSchema.parse(task.recurrence) };
}

export async function loadOccurrences(context: CommandContext, taskId: string): Promise<Occurrences> {
  // Protected by the task lock: every writer of these rows locks the task first.
  const rows = await context.db.select().from(taskOccurrences)
    .where(and(eq(taskOccurrences.taskId, taskId), eq(taskOccurrences.userId, context.actor.userId)));
  return new Map(rows.map((row) => [row.occurrenceKey, row]));
}

/** The single open cycle of an after-completion series (03_Data_Model.md §4.5). */
export function currentCycleKey(anchor: string, rows: Occurrences): string {
  let current = afterCompletionKey(anchor, 0);
  const visited = new Set<string>();
  for (let row = rows.get(current); row !== undefined && row.status !== 'open'; row = rows.get(current)) {
    if (visited.has(current) || row.successorOccurrenceKey === null) throw new Error('Corrupt after-completion chain');
    visited.add(current);
    current = row.successorOccurrenceKey;
  }
  return current;
}

/** Fixed series: the rule must produce the date. After completion: a stored cycle or the current one. */
export function assertInSeries(task: TaskShape, series: Series, key: string, rows: Occurrences): void {
  if (series.mode === 'fixed') {
    if (key.includes('~') || !isFixedOccurrence({ anchor: task.scheduledDate!, rule: series.rule, date: key })) {
      throw new CommandRejection('OCCURRENCE_NOT_IN_SERIES');
    }
    return;
  }
  if (!key.includes('~')) throw new CommandRejection('OCCURRENCE_NOT_IN_SERIES');
  if (!rows.has(key) && key !== currentCycleKey(task.scheduledDate!, rows)) throw new CommandRejection('OCCURRENCE_NOT_CURRENT');
}

/** Schedule of one occurrence: its override, otherwise the template time on the key's date. */
export function occurrenceSchedule(task: TaskShape, key: string, row: OccurrenceRow | undefined): TimeValue {
  const moved = overrideOf(row);
  if (moved !== null) return moved;
  const template = taskSchedule(task);
  if (template === null) throw new Error('Series without anchor');
  return { ...template, date: occurrenceDate(key) };
}

function reminderBase(task: TaskShape, occurrenceKey: string | null, rows: Occurrences): TimeValue | null {
  if (task.recurrence === null || occurrenceKey === null) return taskSchedule(task);
  return occurrenceSchedule(task, occurrenceKey, rows.get(occurrenceKey));
}

/** Rules for a reminder attached to a task (03_Data_Model.md §3, reminders). */
export function checkReminder(task: TaskShape, input: { rule: ReminderRule; occurrenceKey: string | null }, rows: Occurrences): void {
  if (task.recurrence === null) {
    if (input.occurrenceKey !== null) throw new CommandRejection('VALIDATION_FAILED');
  } else if (input.occurrenceKey === null) {
    if (input.rule.kind === 'absolute') throw new CommandRejection('VALIDATION_FAILED');
  } else {
    assertInSeries(task, seriesOf(task), input.occurrenceKey, rows);
  }
  if (!reminderHasBase(input.rule, reminderBase(task, input.occurrenceKey, rows), taskDeadline(task))) {
    throw new CommandRejection('REMINDER_BASE_MISSING');
  }
}

/** A reminder whose base disappeared is kept but marked, never deleted or left floating. */
export async function refreshReminderStates(context: CommandContext, task: TaskShape, rows: Occurrences): Promise<void> {
  const live = await context.db.select().from(reminders)
    .where(and(eq(reminders.taskId, task.id), eq(reminders.userId, context.actor.userId), isNull(reminders.deletedAt)))
    .orderBy(reminders.id).for('update');
  for (const reminder of live) {
    const base = reminderHasBase(reminderRuleFromColumns(reminder), reminderBase(task, reminder.occurrenceKey, rows), taskDeadline(task));
    const state = base ? 'active' : 'inactive_base_missing';
    if (state === reminder.state) continue;
    await context.db.update(reminders).set({ state, updatedAt: context.now.toISOString() })
      .where(and(eq(reminders.id, reminder.id), eq(reminders.userId, context.actor.userId)));
  }
}

export async function writeOccurrence(
  context: CommandContext, task: TaskRow, key: string, existing: OccurrenceRow | undefined,
  values: Partial<Pick<OccurrenceRow, 'status' | 'completedAt' | 'successorOccurrenceKey' | 'overrideDate' | 'overrideTime' | 'overrideTimeZone'>>,
): Promise<OccurrenceRow> {
  if (existing) {
    const [row] = await context.db.update(taskOccurrences).set({ ...values, updatedAt: context.now.toISOString() })
      .where(and(eq(taskOccurrences.id, existing.id), eq(taskOccurrences.userId, context.actor.userId))).returning();
    return row!;
  }
  const [row] = await context.db.insert(taskOccurrences)
    .values({ id: occurrenceId(task.id, key), userId: context.actor.userId, taskId: task.id, occurrenceKey: key, ...values })
    .returning();
  return row!;
}

/** Open rows without an override carry no state and are not kept (03_Data_Model.md §3). */
export async function removeOccurrence(context: CommandContext, row: OccurrenceRow): Promise<void> {
  await context.db.delete(taskOccurrences)
    .where(and(eq(taskOccurrences.id, row.id), eq(taskOccurrences.userId, context.actor.userId)));
}

/** The client's civil date is at most one day away from the UTC date of the action. */
export function assertActionDate(context: CommandContext, actionLocalDate: string): void {
  civilDateSchema.parse(actionLocalDate);
  const utcDay = Date.parse(`${context.recordedAt.slice(0, 10)}T00:00:00Z`);
  const localDay = Date.parse(`${actionLocalDate}T00:00:00Z`);
  if (Math.abs(localDay - utcDay) > 86_400_000) throw new CommandRejection('VALIDATION_FAILED');
}
