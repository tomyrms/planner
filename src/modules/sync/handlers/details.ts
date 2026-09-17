import { and, eq, inArray, isNull } from 'drizzle-orm';
import { tags, taskTags } from '../../../infrastructure/db/schema.js';
import { MAX_SUBTASKS, MAX_TASK_TAGS, normalizeSubtask, orderedSubtasks, taskTagId } from '../../domain/details.js';
import { CommandRejection, type CommandContext, type Handler } from '../types.js';
import { assertLive, lockTask, noop, payloadOf, revisionOf, saveTask } from './shared.js';

/** Tag rows are locked in UUID order, before the task; deletion cannot race an attachment. */
export async function requireTags(context: CommandContext, ids: readonly string[], allowDeleted = false): Promise<string[]> {
  const wanted = [...new Set(ids.map((id) => id.toLowerCase()))].sort();
  if (wanted.length !== ids.length) throw new CommandRejection('VALIDATION_FAILED');
  if (wanted.length === 0) return [];
  const rows = await context.db.select().from(tags)
    .where(and(eq(tags.userId, context.actor.userId), inArray(tags.id, wanted))).orderBy(tags.id).for('share');
  if (rows.length !== wanted.length) throw new CommandRejection('FORBIDDEN_REFERENCE');
  if (!allowDeleted && rows.some((row) => row.deletedAt !== null)) throw new CommandRejection('TAG_DELETED');
  return wanted;
}

export async function insertInitialTaskTags(context: CommandContext, tagIds: readonly string[]): Promise<void> {
  if (tagIds.length === 0) return;
  await context.db.insert(taskTags).values(tagIds.map((tagId) => ({
    id: taskTagId(context.aggregateId, tagId), userId: context.actor.userId, taskId: context.aggregateId, tagId,
  })));
}

async function checklistTask(context: CommandContext) {
  const { task } = await lockTask(context);
  assertLive(task);
  if (task.recurrence !== null) throw new CommandRejection('SUBTASKS_ON_RECURRING_TASK');
  await context.checkPrecondition(revisionOf(task));
  return task;
}

export const subtaskAdd: Handler = async (context) => {
  const { subtask: input } = payloadOf(context, 'task.subtask.add');
  const task = await checklistTask(context);
  if (task.subtasks.some((item) => item.id === input.id.toLowerCase())) throw new CommandRejection('SUBTASK_ALREADY_EXISTS');
  if (task.subtasks.length >= MAX_SUBTASKS) throw new CommandRejection('SUBTASK_LIMIT_REACHED');
  const fallbackOrder = task.subtasks.length === 0 ? 0 : Math.max(...task.subtasks.map((item) => item.sortOrder)) + 1;
  const subtask = normalizeSubtask(input, fallbackOrder);
  const revision = await saveTask(context, task, { subtasks: orderedSubtasks([...task.subtasks, subtask]) });
  return { revision, subtaskId: subtask.id };
};

export const subtaskPatch: Handler = async (context) => {
  const { subtaskId, set } = payloadOf(context, 'task.subtask.patch');
  if (set.sortOrder !== undefined && context.precondition.kind === 'none') throw new CommandRejection('VALIDATION_FAILED');
  const task = await checklistTask(context);
  const existing = task.subtasks.find((item) => item.id === subtaskId.toLowerCase());
  if (!existing) throw new CommandRejection('SUBTASK_NOT_FOUND');
  const changed = { ...existing, title: set.title ?? existing.title,
    isCompleted: set.isCompleted ?? existing.isCompleted, sortOrder: set.sortOrder ?? existing.sortOrder };
  if (existing.title === changed.title && existing.isCompleted === changed.isCompleted && existing.sortOrder === changed.sortOrder) return noop(task);
  return { revision: await saveTask(context, task, {
    subtasks: orderedSubtasks(task.subtasks.map((item) => item.id === existing.id ? changed : item)),
  }), subtaskId: existing.id };
};

export const subtaskRemove: Handler = async (context) => {
  const { subtaskId } = payloadOf(context, 'task.subtask.remove');
  const task = await checklistTask(context);
  const subtasks = task.subtasks.filter((item) => item.id !== subtaskId.toLowerCase());
  if (subtasks.length === task.subtasks.length) return noop(task);
  return { revision: await saveTask(context, task, { subtasks }), subtaskId: subtaskId.toLowerCase() };
};

const changeTaskTag = (add: boolean): Handler => async (context) => {
  const { tagId: input } = payloadOf(context, add ? 'task.tag.add' : 'task.tag.remove');
  const [tagId] = await requireTags(context, [input], !add);
  const { task } = await lockTask(context);
  assertLive(task);
  await context.checkPrecondition(revisionOf(task));
  const id = taskTagId(task.id, tagId!);
  const [existing] = await context.db.select().from(taskTags)
    .where(and(eq(taskTags.userId, context.actor.userId), eq(taskTags.taskId, task.id), eq(taskTags.tagId, tagId!)));
  const attached = existing !== undefined && existing.deletedAt === null;
  if (attached === add) return noop(task);
  if (add) {
    const active = await context.db.select({ id: taskTags.id }).from(taskTags).innerJoin(tags, eq(tags.id, taskTags.tagId))
      .where(and(eq(taskTags.userId, context.actor.userId), eq(taskTags.taskId, task.id), isNull(taskTags.deletedAt), isNull(tags.deletedAt)));
    if (active.length >= MAX_TASK_TAGS) throw new CommandRejection('TASK_TAG_LIMIT_REACHED');
  }
  const now = context.now.toISOString();
  if (existing) {
    await context.db.update(taskTags).set({ deletedAt: add ? null : now, updatedAt: now }).where(eq(taskTags.id, existing.id));
  } else {
    await context.db.insert(taskTags).values({ id, userId: context.actor.userId, taskId: task.id, tagId: tagId! });
  }
  return { revision: await saveTask(context, task, {}), taskTagId: id, tagId };
};

export const taskTagAdd = changeTaskTag(true);
export const taskTagRemove = changeTaskTag(false);
