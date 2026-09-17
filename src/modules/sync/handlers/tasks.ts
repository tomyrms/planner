import { reminderColumns } from '../../domain/derive.js';
import { reminders, tasks } from '../../../infrastructure/db/schema.js';
import { CommandRejection, type Handler } from '../types.js';
import { normalizeSubtask, orderedSubtasks } from '../../domain/details.js';
import { insertInitialTaskTags, requireTags } from './details.js';
import {
  assertLive, assertNewAggregate, checkReminder, deadlineColumns, lockLists, lockTask, noop, payloadOf,
  refreshReminderStates, requireLiveList, revisionOf, saveTask, sameTime, scheduleColumns, searchTextFor,
  taskDeadline, taskSchedule, templateChanges, type TaskRow, type TaskShape,
} from './shared.js';

const SERIES_PATCHABLE = new Set(['title', 'notes', 'priority', 'projectId']);

export const taskCreate: Handler = async (context) => {
  const payload = payloadOf(context, 'task.create');
  await assertNewAggregate(context, 'task');
  const lists = await lockLists(context, [payload.projectId]);
  const list = payload.projectId == null ? null : requireLiveList(lists, payload.projectId);
  const schedule = payload.schedule ?? null;
  const deadline = payload.deadline ?? null;
  const recurrence = payload.recurrence ?? null;
  const subtasks = orderedSubtasks((payload.subtasks ?? []).map(normalizeSubtask));
  if (new Set(subtasks.map((item) => item.id)).size !== subtasks.length) throw new CommandRejection('VALIDATION_FAILED');
  if (recurrence !== null && subtasks.length > 0) throw new CommandRejection('SUBTASKS_ON_RECURRING_TASK');
  const tagIds = await requireTags(context, payload.tagIds ?? []);
  if (recurrence !== null) {
    if (schedule === null) throw new CommandRejection('VALIDATION_FAILED');
    if (deadline !== null) throw new CommandRejection('RECURRING_TASK_DEADLINE_UNSUPPORTED');
  }
  const columns = { ...scheduleColumns(schedule, recurrence !== null), ...deadlineColumns(deadline) };
  const shape: TaskShape = {
    id: context.aggregateId, recurrence,
    scheduledDate: columns.scheduledDate ?? null, scheduledTime: columns.scheduledTime ?? null, scheduledTimeZone: columns.scheduledTimeZone ?? null,
    deadlineDate: columns.deadlineDate ?? null, deadlineTime: columns.deadlineTime ?? null, deadlineTimeZone: columns.deadlineTimeZone ?? null,
  };
  const reminderInputs = payload.reminders ?? [];
  if (new Set(reminderInputs.map((reminder) => reminder.id.toLowerCase())).size !== reminderInputs.length) {
    throw new CommandRejection('VALIDATION_FAILED');
  }
  for (const reminder of reminderInputs) checkReminder(shape, { rule: reminder.rule, occurrenceKey: reminder.occurrenceKey ?? null }, new Map());

  const notes = payload.notes ?? null;
  const inserted = await context.db.insert(tasks).values({
    ...columns, id: context.aggregateId, userId: context.actor.userId, projectId: list?.id ?? null,
    title: payload.title, notes, priority: payload.priority ?? 'none', recurrence, subtasks,
    durationMinutes: payload.durationMinutes ?? null,
    searchText: searchTextFor({ title: payload.title, notes }, list),
  }).onConflictDoNothing().returning({ id: tasks.id });
  if (inserted.length === 0) throw new CommandRejection('ENTITY_ALREADY_EXISTS');
  await insertInitialTaskTags(context, tagIds);
  if (reminderInputs.length > 0) {
    const created = await context.db.insert(reminders).values(reminderInputs.map((reminder) => ({
      ...reminderColumns(reminder.rule), id: reminder.id.toLowerCase(), userId: context.actor.userId,
      taskId: context.aggregateId, occurrenceKey: reminder.occurrenceKey ?? null,
    }))).onConflictDoNothing().returning({ id: reminders.id });
    if (created.length !== reminderInputs.length) throw new CommandRejection('ENTITY_ALREADY_EXISTS');
  }
  return { revision: 1 };
};

export const taskPatch: Handler = async (context) => {
  const { set } = payloadOf(context, 'task.patch');
  const { task, lists } = await lockTask(context, { lists: true, extraLists: [set.projectId] });
  assertLive(task);
  if (task.recurrence !== null && Object.keys(set).some((field) => !SERIES_PATCHABLE.has(field))) {
    throw new CommandRejection('SERIES_COMMAND_REQUIRED');
  }
  await context.checkPrecondition(revisionOf(task));
  const changes = templateChanges(task, set, lists);
  if (set.schedule !== undefined && !sameTime(set.schedule, taskSchedule(task))) Object.assign(changes, scheduleColumns(set.schedule, false));
  if (set.deadline !== undefined && !sameTime(set.deadline, taskDeadline(task))) Object.assign(changes, deadlineColumns(set.deadline));
  if (Object.keys(changes).length === 0) return noop(task);
  await refreshReminderStates(context, { ...task, ...changes } as TaskRow, new Map());
  return { revision: await saveTask(context, task, changes) };
};

export const taskComplete: Handler = async (context) => {
  const { task } = await lockTask(context);
  assertLive(task);
  if (task.recurrence !== null) throw new CommandRejection('SERIES_COMMAND_REQUIRED');
  await context.checkPrecondition(revisionOf(task));
  if (task.status === 'completed') return noop(task);
  return { revision: await saveTask(context, task, { status: 'completed', completedAt: context.recordedAt }) };
};

/** Also reactivates an ended series (series.end). */
export const taskReopen: Handler = async (context) => {
  const { task } = await lockTask(context);
  assertLive(task);
  await context.checkPrecondition(revisionOf(task));
  if (task.status === 'active') return noop(task);
  return { revision: await saveTask(context, task, { status: 'active', completedAt: null }) };
};

export const taskDelete: Handler = async (context) => {
  const { task } = await lockTask(context);
  await context.checkPrecondition(revisionOf(task));
  if (task.deletedAt !== null) return noop(task);
  return { revision: await saveTask(context, task, { deletedAt: context.now.toISOString(), deletedByCommandId: context.commandId }) };
};

export const taskRestore: Handler = async (context) => {
  const { task, lists } = await lockTask(context, { lists: true });
  await context.checkPrecondition(revisionOf(task));
  if (task.deletedAt === null) return noop(task);
  if (task.projectId !== null) requireLiveList(lists, task.projectId);
  return { revision: await saveTask(context, task, { deletedAt: null, deletedByCommandId: null }) };
};
