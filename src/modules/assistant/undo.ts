import type { ReminderRule, TimeValue } from '../time/index.js';
import type { Changes } from './snapshot.js';

export interface ActionRow {
  id: string;
  planIndex: number;
  aggregateType: 'task' | 'project';
  aggregateId: string;
  commandType: string;
  changes: Changes;
  resultingRevision: number;
}

export interface CompensationDraft {
  action: ActionRow;
  type: string;
  aggregate: { type: 'task' | 'project'; id: string };
  payload?: Record<string, unknown>;
}

const PATCHABLE = ['title', 'notes', 'priority', 'projectId', 'schedule', 'deadline', 'durationMinutes'] as const;
const SERIES_TEMPLATE = ['title', 'notes', 'priority', 'projectId', 'durationMinutes', 'schedule'] as const;

type ReminderState = { rule: ReminderRule; occurrenceKey: string | null } | null;
type OccurrenceState = { status: 'open' | 'completed' | 'skipped'; override: TimeValue | null } | null;

function pick(changes: Changes, fields: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(fields.filter((field) => field in changes).map((field) => [field, changes[field]!.before]));
}

/**
 * Minimal compensating commands for one applied action (04_AI_Orchestration.md §7).
 * Returns null when the action changed nothing or cannot be reverted by a domain command.
 */
export function compensationFor(action: ActionRow, localDate: string): CompensationDraft[] | null {
  const task = { type: 'task' as const, id: action.aggregateId };
  const draft = (type: string, payload?: Record<string, unknown>): CompensationDraft =>
    ({ action, type, aggregate: action.aggregateType === 'project' ? { type: 'project', id: action.aggregateId } : task, ...(payload ? { payload } : {}) });
  const changes = action.changes;
  if (Object.keys(changes).length === 0) return null;
  const occurrences = Object.entries(changes).filter(([field]) => field.startsWith('occurrence:'))
    .map(([field, change]) => ({ key: field.slice('occurrence:'.length), before: change.before as OccurrenceState, after: change.after as OccurrenceState }));
  switch (action.commandType) {
    case 'task.create': return [draft('task.delete')];
    case 'project.create': return [draft('project.delete', { taskPolicy: 'move_tasks_to_inbox' })];
    case 'task.patch': {
      const set = pick(changes, PATCHABLE);
      return Object.keys(set).length > 0 ? [draft('task.patch', { set })] : null;
    }
    case 'task.tag.add':
    case 'task.tag.remove': {
      const items = Object.entries(changes).filter(([field]) => field.startsWith('tag:'));
      return items.length ? items.map(([field, change]) => draft(change.before === null ? 'task.tag.remove' : 'task.tag.add', { tagId: field.slice('tag:'.length) })) : null;
    }
    case 'task.subtask.add':
    case 'task.subtask.patch':
    case 'task.subtask.remove': {
      const items = Object.entries(changes).filter(([field]) => field.startsWith('subtask:'));
      return items.length ? items.map(([field, change]) => {
        const subtaskId = field.slice('subtask:'.length);
        if (change.before === null) return draft('task.subtask.remove', { subtaskId });
        const before = change.before as { id: string; title: string; isCompleted: boolean; sortOrder: number };
        if (change.after === null) return draft('task.subtask.add', { subtask: before });
        const after = change.after as typeof before;
        const set = Object.fromEntries((['title', 'isCompleted', 'sortOrder'] as const).filter((key) => before[key] !== after[key]).map((key) => [key, before[key]]));
        return draft('task.subtask.patch', { subtaskId, set });
      }) : null;
    }
    case 'task.complete': return [draft('task.reopen')];
    case 'task.reopen': return [draft('task.complete')];
    case 'task.delete': return [draft('task.restore')];
    case 'task.restore': return [draft('task.delete')];
    case 'series.end': return [draft('task.reopen')];
    case 'series.update': {
      const payload: Record<string, unknown> = {};
      if ('recurrence' in changes) payload.recurrence = changes.recurrence!.before;
      const set = pick(changes, SERIES_TEMPLATE);
      if (Object.keys(set).length > 0) payload.set = set;
      return Object.keys(payload).length > 0 ? [draft('series.update', payload)] : null;
    }
    case 'occurrence.complete':
    case 'occurrence.skip': {
      const closed = occurrences.find((item) => item.after?.status !== 'open' && item.before?.status !== item.after?.status);
      return closed ? [draft('occurrence.reopen', { occurrenceKey: closed.key })] : null;
    }
    case 'occurrence.reopen': {
      const reopened = occurrences.find((item) => item.before && item.before.status !== 'open');
      if (!reopened) return null;
      const type = reopened.before!.status === 'completed' ? 'occurrence.complete' : 'occurrence.skip';
      return [draft(type, { occurrenceKey: reopened.key, actionLocalDate: localDate })];
    }
    case 'occurrence.reschedule': {
      const moved = occurrences[0];
      return moved ? [draft('occurrence.reschedule', { occurrenceKey: moved.key, schedule: moved.before?.override ?? null })] : null;
    }
    case 'reminder.set':
    case 'reminder.remove': {
      const drafts = Object.entries(changes).filter(([field]) => field.startsWith('reminder:')).map(([field, change]) => {
        const id = field.slice('reminder:'.length);
        const before = change.before as ReminderState;
        return before === null
          ? draft('reminder.remove', { id })
          : draft('reminder.set', { id, rule: before.rule, ...(before.occurrenceKey ? { occurrenceKey: before.occurrenceKey } : {}) });
      });
      return drafts.length > 0 ? drafts : null;
    }
    default:
      return null;
  }
}
