import { and, eq, inArray, isNotNull, isNull } from 'drizzle-orm';
import { reminders, taskOccurrences } from '../../../infrastructure/db/schema.js';
import { fromTimeValue } from '../../domain/derive.js';
import {
  nextAfterCompletionFromLocalDate, nextAfterCompletionKey, occurrenceDate, occurrenceId,
} from '../../time/index.js';
import { canonicalJson } from '../canonical.js';
import { CommandRejection, type CommandContext, type Handler, type HandlerResult } from '../types.js';
import {
  assertActionDate, assertInSeries, assertLive, currentCycleKey, loadOccurrences, lockTask, noop, overrideOf,
  payloadOf, refreshReminderStates, removeOccurrence, revisionOf, sameTime, saveTask, scheduleColumns, seriesOf,
  taskSchedule, templateChanges, writeOccurrence,
  type OccurrenceRow, type Occurrences, type Series, type TaskChanges, type TaskRow,
} from './shared.js';

function belongsToSeries(task: TaskRow, series: Series, key: string, rows: Occurrences): boolean {
  try {
    assertInSeries(task, series, key, rows);
    return true;
  } catch (error) {
    if (error instanceof CommandRejection) return false;
    throw error;
  }
}

/** A reminder attached to an occurrence the series no longer produces is removed with it. */
async function dropOrphanReminders(context: CommandContext, task: TaskRow, series: Series, rows: Occurrences): Promise<void> {
  const attached = await context.db.select({ id: reminders.id, occurrenceKey: reminders.occurrenceKey }).from(reminders)
    .where(and(eq(reminders.taskId, task.id), eq(reminders.userId, context.actor.userId), isNotNull(reminders.occurrenceKey), isNull(reminders.deletedAt)))
    .orderBy(reminders.id).for('update');
  const orphaned = attached.filter((reminder) => !belongsToSeries(task, series, reminder.occurrenceKey!, rows)).map((reminder) => reminder.id);
  if (orphaned.length === 0) return;
  const now = context.now.toISOString();
  await context.db.update(reminders).set({ deletedAt: now, updatedAt: now })
    .where(and(eq(reminders.userId, context.actor.userId), inArray(reminders.id, orphaned)));
}

/** Occurrence commands need a live, running series; the precondition is checked before any rule. */
async function lockRunningSeries(context: CommandContext): Promise<{ task: TaskRow; series: Series; rows: Occurrences }> {
  const { task } = await lockTask(context);
  assertLive(task);
  const series = seriesOf(task);
  if (task.status === 'completed') throw new CommandRejection('SERIES_ENDED');
  await context.checkPrecondition(revisionOf(task));
  return { task, series, rows: await loadOccurrences(context, task.id) };
}

function occurrenceResult(task: TaskRow, key: string, row: OccurrenceRow | undefined, revision: number, unchanged = false): HandlerResult {
  return {
    revision,
    occurrenceKey: key,
    occurrenceId: occurrenceId(task.id, key),
    status: row?.status ?? 'open',
    successorOccurrenceKey: row?.successorOccurrenceKey ?? null,
    ...(unchanged ? { noop: true } : {}),
  };
}

/** Closing twice never produces a second successor: a closed occurrence is left as it is (§4.5). */
const closeOccurrence = (status: 'completed' | 'skipped'): Handler => async (context) => {
  const { occurrenceKey: key, actionLocalDate } = payloadOf(context, 'occurrence.complete');
  assertActionDate(context, actionLocalDate);
  const { task, series, rows } = await lockRunningSeries(context);
  assertInSeries(task, series, key, rows);
  const existing = rows.get(key);
  if (existing !== undefined && existing.status !== 'open') return occurrenceResult(task, key, existing, revisionOf(task), true);
  let successorOccurrenceKey: string | null = null;
  if (series.mode === 'after_completion') {
    if (key !== currentCycleKey(task.scheduledDate!, rows)) throw new CommandRejection('OCCURRENCE_NOT_CURRENT');
    successorOccurrenceKey = nextAfterCompletionKey(key, nextAfterCompletionFromLocalDate(series.rule, actionLocalDate));
  }
  const row = await writeOccurrence(context, task, key, existing, {
    status, completedAt: status === 'completed' ? context.recordedAt : null, successorOccurrenceKey,
  });
  return occurrenceResult(task, key, row, await saveTask(context, task, {}));
};

export const occurrenceComplete = closeOccurrence('completed');
export const occurrenceSkip = closeOccurrence('skipped');

export const occurrenceReopen: Handler = async (context) => {
  const { occurrenceKey: key } = payloadOf(context, 'occurrence.reopen');
  const { task, series, rows } = await lockRunningSeries(context);
  assertInSeries(task, series, key, rows);
  const existing = rows.get(key);
  if (existing === undefined || existing.status === 'open') return occurrenceResult(task, key, existing, revisionOf(task), true);
  const successor = existing.successorOccurrenceKey;
  if (successor !== null) {
    const [attached] = await context.db.select({ id: reminders.id }).from(reminders)
      .where(and(eq(reminders.taskId, task.id), eq(reminders.userId, context.actor.userId), eq(reminders.occurrenceKey, successor), isNull(reminders.deletedAt)))
      .limit(1);
    // A successor that was closed, moved or given its own reminder is no longer a pure derivation.
    if (rows.has(successor) || attached !== undefined) throw new CommandRejection('SUCCESSOR_ALREADY_CHANGED');
  }
  if (overrideOf(existing) === null) {
    await removeOccurrence(context, existing);
    return occurrenceResult(task, key, undefined, await saveTask(context, task, {}));
  }
  const row = await writeOccurrence(context, task, key, existing, { status: 'open', completedAt: null, successorOccurrenceKey: null });
  return occurrenceResult(task, key, row, await saveTask(context, task, {}));
};

/** Moves one open occurrence; its key and identity never change. `schedule: null` removes the move. */
export const occurrenceReschedule: Handler = async (context) => {
  const { occurrenceKey: key, schedule } = payloadOf(context, 'occurrence.reschedule');
  const { task, series, rows } = await lockRunningSeries(context);
  assertInSeries(task, series, key, rows);
  const existing = rows.get(key);
  if (existing !== undefined && existing.status !== 'open') throw new CommandRejection('OCCURRENCE_NOT_CURRENT');
  if (series.mode === 'after_completion' && key !== currentCycleKey(task.scheduledDate!, rows)) throw new CommandRejection('OCCURRENCE_NOT_CURRENT');
  if (sameTime(overrideOf(existing), schedule)) return occurrenceResult(task, key, existing, revisionOf(task), true);
  let row: OccurrenceRow | undefined;
  if (schedule === null) {
    await removeOccurrence(context, existing!);
    rows.delete(key);
  } else {
    const moved = fromTimeValue(schedule);
    row = await writeOccurrence(context, task, key, existing, {
      status: 'open', overrideDate: moved.date, overrideTime: moved.time, overrideTimeZone: moved.zone,
    });
    rows.set(key, row);
  }
  await refreshReminderStates(context, task, rows);
  return occurrenceResult(task, key, row, await saveTask(context, task, {}));
};

/** "Ignorer les précédentes": missed occurrences strictly before this one leave the grouped row. */
export const occurrenceSkipMissedBefore: Handler = async (context) => {
  const { occurrenceKey: key } = payloadOf(context, 'occurrence.skip_missed_before');
  const { task, series, rows } = await lockRunningSeries(context);
  if (series.mode !== 'fixed') throw new CommandRejection('OCCURRENCE_NOT_IN_SERIES');
  assertInSeries(task, series, key, rows);
  const cutoff = occurrenceDate(key);
  if (task.missedIgnoredBefore !== null && task.missedIgnoredBefore >= cutoff) {
    return noop(task, { missedIgnoredBefore: task.missedIgnoredBefore });
  }
  return { revision: await saveTask(context, task, { missedIgnoredBefore: cutoff }), missedIgnoredBefore: cutoff };
};

/** Whole-series edit (§4.4). Closed rows stay as history; open rows the new rule no longer produces go. */
export const seriesUpdate: Handler = async (context) => {
  const payload = payloadOf(context, 'series.update');
  const set = payload.set ?? {};
  const { task, lists } = await lockTask(context, { lists: true, extraLists: [set.projectId] });
  assertLive(task);
  const series = seriesOf(task);
  await context.checkPrecondition(revisionOf(task));
  const rows = await loadOccurrences(context, task.id);
  const changes: TaskChanges = templateChanges(task, set, lists);
  if (payload.recurrence !== undefined) {
    if (payload.recurrence.mode !== series.mode) throw new CommandRejection('VALIDATION_FAILED');
    if (canonicalJson(payload.recurrence) !== canonicalJson(task.recurrence)) changes.recurrence = payload.recurrence;
  }
  if (set.schedule !== undefined && !sameTime(set.schedule, taskSchedule(task))) {
    // After-completion keys are derived from the anchor date once a cycle exists.
    if (series.mode === 'after_completion' && rows.size > 0 && set.schedule.date !== task.scheduledDate) {
      throw new CommandRejection('VALIDATION_FAILED');
    }
    Object.assign(changes, scheduleColumns(set.schedule, true));
  }
  if (Object.keys(changes).length === 0) return noop(task);

  const updated: TaskRow = { ...task, ...changes } as TaskRow;
  const removedOccurrenceKeys: string[] = [];
  if (changes.recurrence !== undefined || changes.scheduledDate !== undefined) {
    const next = seriesOf(updated);
    if (next.mode === 'fixed') {
      for (const row of rows.values()) {
        if (row.status === 'open' && !belongsToSeries(updated, next, row.occurrenceKey, rows)) removedOccurrenceKeys.push(row.occurrenceKey);
      }
      removedOccurrenceKeys.sort();
      if (removedOccurrenceKeys.length > 0) {
        await context.db.delete(taskOccurrences).where(and(
          eq(taskOccurrences.taskId, task.id), eq(taskOccurrences.userId, context.actor.userId),
          inArray(taskOccurrences.occurrenceKey, removedOccurrenceKeys),
        ));
        for (const key of removedOccurrenceKeys) rows.delete(key);
      }
    }
    await dropOrphanReminders(context, updated, next, rows);
  }
  await refreshReminderStates(context, updated, rows);
  const revision = await saveTask(context, task, changes);
  return removedOccurrenceKeys.length > 0 ? { revision, removedOccurrenceKeys } : { revision };
};

export const seriesEnd: Handler = async (context) => {
  const { task } = await lockTask(context);
  assertLive(task);
  seriesOf(task);
  await context.checkPrecondition(revisionOf(task));
  if (task.status === 'completed') return noop(task);
  return { revision: await saveTask(context, task, { status: 'completed', completedAt: context.recordedAt }) };
};
