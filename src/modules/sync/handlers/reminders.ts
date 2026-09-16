import { and, count, eq, isNull } from 'drizzle-orm';
import { reminders } from '../../../infrastructure/db/schema.js';
import { reminderColumns } from '../../domain/derive.js';
import { CommandRejection, type CommandContext, type Handler } from '../types.js';
import {
  MAX_REMINDERS_PER_TASK, assertLive, checkReminder, loadOccurrences, lockTask, noop, payloadOf, retryable, revisionOf, saveTask,
  type TaskRow,
} from './shared.js';

type ReminderRow = typeof reminders.$inferSelect;

/** Reminder ids are global: one that belongs to another task or user is never taken over. */
async function lockReminder(context: CommandContext, task: TaskRow, id: string): Promise<ReminderRow | undefined> {
  const [row] = await context.db.select().from(reminders).where(eq(reminders.id, id.toLowerCase())).for('update');
  if (row !== undefined && (row.userId !== context.actor.userId || row.taskId !== task.id)) throw new CommandRejection('FORBIDDEN_REFERENCE');
  return row;
}

const minutes = (value: string | null): string | null => value?.slice(0, 5) ?? null;

function sameRule(row: ReminderRow, columns: ReturnType<typeof reminderColumns>): boolean {
  return row.kind === columns.kind && row.offsetMinutes === columns.offsetMinutes
    && minutes(row.localTime) === columns.localTime && row.absoluteDate === columns.absoluteDate
    && minutes(row.absoluteTime) === columns.absoluteTime && row.absoluteTimeZone === columns.absoluteTimeZone;
}

export const reminderSet: Handler = async (context) => {
  const payload = payloadOf(context, 'reminder.set');
  const { task } = await lockTask(context);
  assertLive(task);
  await context.checkPrecondition(revisionOf(task));
  const occurrenceKey = payload.occurrenceKey ?? null;
  const rows = task.recurrence === null ? new Map() : await loadOccurrences(context, task.id);
  const existing = await lockReminder(context, task, payload.id);
  checkReminder(task, { rule: payload.rule, occurrenceKey }, rows);
  const columns = reminderColumns(payload.rule);
  const live = existing !== undefined && existing.deletedAt === null;
  if (live && existing.occurrenceKey === occurrenceKey && existing.state === 'active' && sameRule(existing, columns)) return noop(task);
  if (!live) {
    const [active] = await context.db.select({ total: count() }).from(reminders)
      .where(and(eq(reminders.taskId, task.id), eq(reminders.userId, context.actor.userId), isNull(reminders.deletedAt)));
    if ((active?.total ?? 0) >= MAX_REMINDERS_PER_TASK) throw new CommandRejection('VALIDATION_FAILED');
  }
  const values = { ...columns, occurrenceKey, state: 'active' as const, deletedAt: null, updatedAt: context.now.toISOString() };
  if (existing !== undefined) {
    await context.db.update(reminders).set(values).where(and(eq(reminders.id, existing.id), eq(reminders.userId, context.actor.userId)));
  } else {
    const inserted = await context.db.insert(reminders)
      .values({ ...values, id: payload.id.toLowerCase(), userId: context.actor.userId, taskId: task.id })
      .onConflictDoNothing().returning({ id: reminders.id });
    // Another command created this id meanwhile: the retry sees and checks its row.
    if (inserted.length === 0) throw retryable();
  }
  return { revision: await saveTask(context, task, {}), reminderId: payload.id.toLowerCase() };
};

export const reminderRemove: Handler = async (context) => {
  const { id } = payloadOf(context, 'reminder.remove');
  const { task } = await lockTask(context);
  assertLive(task);
  await context.checkPrecondition(revisionOf(task));
  const existing = await lockReminder(context, task, id);
  if (existing === undefined) throw new CommandRejection('ENTITY_NOT_FOUND');
  if (existing.deletedAt !== null) return noop(task, { reminderId: existing.id });
  const now = context.now.toISOString();
  await context.db.update(reminders).set({ deletedAt: now, updatedAt: now })
    .where(and(eq(reminders.id, existing.id), eq(reminders.userId, context.actor.userId)));
  return { revision: await saveTask(context, task, {}), reminderId: existing.id };
};
