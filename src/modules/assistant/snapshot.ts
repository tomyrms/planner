import type pg from 'pg';
import { reminderRuleFromColumns, toTimeValue } from '../domain/derive.js';
import { canonicalJson } from '../sync/index.js';

/** User-visible state of an aggregate, flattened so that a diff reads as {field: {before, after}}. */
export type Snapshot = { title: string; revision: number; fields: Record<string, unknown> } | null;
export type Changes = Record<string, { before: unknown; after: unknown }>;

export async function snapshotAggregate(client: pg.PoolClient, userId: string, type: 'task' | 'project', id: string): Promise<Snapshot> {
  if (type === 'project') {
    const { rows: [row] } = await client.query(`SELECT name, color_key, sort_order, archived_at IS NOT NULL AS archived,
        deleted_at IS NOT NULL AS deleted, revision::int AS revision
      FROM projects WHERE id = $1 AND user_id = $2`, [id, userId]);
    if (!row) return null;
    return { title: row.name, revision: row.revision, fields: { name: row.name, colorKey: row.color_key, sortOrder: row.sort_order, archived: row.archived, deleted: row.deleted } };
  }
  const { rows: [row] } = await client.query(`SELECT t.title, t.notes, t.priority, t.project_id, p.name AS list_name, t.status,
      t.scheduled_date::text AS scheduled_date, t.scheduled_time::text AS scheduled_time, t.scheduled_time_zone,
      t.deadline_date::text AS deadline_date, t.deadline_time::text AS deadline_time, t.deadline_time_zone,
      t.duration_minutes, t.recurrence, t.missed_ignored_before::text AS missed_ignored_before,
      t.deleted_at IS NOT NULL AS deleted, t.revision::int AS revision
    FROM tasks t LEFT JOIN projects p ON p.id = t.project_id WHERE t.id = $1 AND t.user_id = $2`, [id, userId]);
  if (!row) return null;
  const fields: Record<string, unknown> = {
    title: row.title,
    notes: row.notes,
    priority: row.priority,
    projectId: row.project_id,
    listName: row.list_name,
    status: row.status,
    schedule: toTimeValue({ date: row.scheduled_date, time: row.scheduled_time, zone: row.scheduled_time_zone }),
    deadline: toTimeValue({ date: row.deadline_date, time: row.deadline_time, zone: row.deadline_time_zone }),
    durationMinutes: row.duration_minutes,
    recurrence: row.recurrence,
    missedIgnoredBefore: row.missed_ignored_before,
    deleted: row.deleted,
  };
  const reminders = await client.query(`SELECT id, occurrence_key, kind, offset_minutes, local_time::text AS local_time,
      absolute_date::text AS absolute_date, absolute_time::text AS absolute_time, absolute_time_zone, state
    FROM reminders WHERE task_id = $1 AND user_id = $2 AND deleted_at IS NULL`, [id, userId]);
  for (const reminder of reminders.rows) {
    fields[`reminder:${reminder.id}`] = {
      rule: reminderRuleFromColumns({
        kind: reminder.kind, offsetMinutes: reminder.offset_minutes, localTime: reminder.local_time,
        absoluteDate: reminder.absolute_date, absoluteTime: reminder.absolute_time, absoluteTimeZone: reminder.absolute_time_zone,
      }),
      occurrenceKey: reminder.occurrence_key,
      state: reminder.state,
    };
  }
  const occurrences = await client.query(`SELECT occurrence_key, status, override_date::text AS override_date,
      override_time::text AS override_time, override_time_zone, successor_occurrence_key
    FROM task_occurrences WHERE task_id = $1 AND user_id = $2`, [id, userId]);
  for (const occurrence of occurrences.rows) {
    fields[`occurrence:${occurrence.occurrence_key}`] = {
      status: occurrence.status,
      override: toTimeValue({ date: occurrence.override_date, time: occurrence.override_time, zone: occurrence.override_time_zone }),
      successorOccurrenceKey: occurrence.successor_occurrence_key,
    };
  }
  return { title: row.title, revision: row.revision, fields };
}

/** Only fields whose value changed; absent keys (a new reminder, a removed occurrence) read as null. */
export function diffSnapshots(before: Snapshot, after: Snapshot): Changes {
  const left = before?.fields ?? {};
  const right = after?.fields ?? {};
  const changes: Changes = {};
  for (const key of new Set([...Object.keys(left), ...Object.keys(right)])) {
    const previous = left[key] ?? null;
    const next = right[key] ?? null;
    if (canonicalJson(previous) !== canonicalJson(next)) changes[key] = { before: previous, after: next };
  }
  return changes;
}
