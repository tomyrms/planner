import { resolveTimeValue, type ReminderRule, type TimeValue } from '../time/index.js';

export interface StoredTimeColumns { date: string | null; time: string | null; zone: string | null }

/** PostgreSQL returns TIME as HH:MM:SS; the contract uses HH:mm. */
export function toTimeValue(columns: StoredTimeColumns): TimeValue | null {
  if (columns.date === null) return null;
  if (columns.time === null) return { date: columns.date, time: null, timeZone: null };
  return { date: columns.date, time: columns.time.slice(0, 5), timeZone: columns.zone! };
}

/** Columns plus the derived instant used for indexing (null for date-only values). */
export function fromTimeValue(value: TimeValue | null | undefined): StoredTimeColumns & { instant: string | null } {
  if (value == null) return { date: null, time: null, zone: null, instant: null };
  const resolved = resolveTimeValue(value);
  if (resolved.kind === 'date') return { date: resolved.date, time: null, zone: null, instant: null };
  return { date: resolved.date, time: resolved.time, zone: resolved.timeZone, instant: resolved.instant };
}

/** Whether a reminder has the base its kind requires (03_Data_Model.md §3, reminders). */
export function reminderHasBase(rule: ReminderRule, schedule: TimeValue | null, deadline: TimeValue | null): boolean {
  switch (rule.kind) {
    case 'absolute': return true;
    case 'before_start': return schedule !== null && schedule.time != null;
    case 'on_scheduled_day_at': return schedule !== null && schedule.time == null;
    case 'before_deadline': return deadline !== null && deadline.time != null;
    case 'on_deadline_day_at': return deadline !== null && deadline.time == null;
  }
}

export interface ReminderColumns {
  kind: ReminderRule['kind'];
  offsetMinutes: number | null;
  localTime: string | null;
  absoluteDate: string | null;
  absoluteTime: string | null;
  absoluteTimeZone: string | null;
}

export function reminderColumns(rule: ReminderRule): ReminderColumns {
  const empty = { offsetMinutes: null, localTime: null, absoluteDate: null, absoluteTime: null, absoluteTimeZone: null };
  switch (rule.kind) {
    case 'before_start':
    case 'before_deadline':
      return { ...empty, kind: rule.kind, offsetMinutes: rule.offsetMinutes };
    case 'on_scheduled_day_at':
    case 'on_deadline_day_at':
      return { ...empty, kind: rule.kind, localTime: rule.localTime };
    case 'absolute':
      return { ...empty, kind: rule.kind, absoluteDate: rule.absolute.date, absoluteTime: rule.absolute.time, absoluteTimeZone: rule.absolute.timeZone };
  }
}

export function reminderRuleFromColumns(row: ReminderColumns): ReminderRule {
  switch (row.kind) {
    case 'before_start':
    case 'before_deadline':
      return { kind: row.kind, offsetMinutes: row.offsetMinutes! };
    case 'on_scheduled_day_at':
    case 'on_deadline_day_at':
      return { kind: row.kind, localTime: row.localTime!.slice(0, 5) };
    case 'absolute':
      return { kind: 'absolute', absolute: { date: row.absoluteDate!, time: row.absoluteTime!.slice(0, 5), timeZone: row.absoluteTimeZone! } };
  }
}
