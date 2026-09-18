import { Temporal } from '@js-temporal/polyfill';
import type pg from 'pg';
import { toTimeValue } from '../../domain/derive.js';
import { normalizeSearchText } from '../../domain/search.js';
import {
  afterCompletionRecurrenceSchema, countMissedFixed, fixedOccurrences, fixedRecurrenceSchema, occurrenceDate,
  projectTimeValue, type RecurrenceRule, type TimeValue,
} from '../../time/index.js';
import { currentCycleKey, type OccurrenceRow } from '../../sync/handlers/shared.js';
import type { ProposedSlot, TurnState } from '../state.js';
import type { ToolArgs } from './catalog.js';

type Row = Record<string, any>;

export class ToolFailure extends Error {
  constructor(public readonly code: string, message: string) { super(message); }
}

const MAX_TASKS_SCANNED = 5000;
const DAY_START = '08:00';
const DAY_END = '22:00';
const DEFAULT_DURATION = 30;

const minutes = (time: string): number => Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5));
const clock = (value: number): string => `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`;
const addDays = (date: string, days: number): string => Temporal.PlainDate.from(date).add({ days }).toString();

export function recurrenceSummary(rule: RecurrenceRule | null): string | null {
  if (rule === null) return null;
  if (rule.mode === 'after_completion') return `${rule.interval} ${rule.unit}(s) après chaque complétion`;
  const every = rule.interval === 1 ? '' : ` (tous les ${rule.interval})`;
  if (rule.freq === 'daily') return `chaque jour${every}`;
  if (rule.freq === 'weekly') return `chaque semaine le ${rule.byWeekday.join(', ')}${every}`;
  return 'byMonthDay' in rule ? `chaque mois le ${rule.byMonthDay}${every}` : `chaque mois le dernier jour${every}`;
}

const TASK_COLUMNS = `t.id, t.title, t.notes, t.status, t.priority, t.project_id, p.name AS list_name,
  t.scheduled_date::text AS scheduled_date, t.scheduled_time::text AS scheduled_time, t.scheduled_time_zone,
  t.deadline_date::text AS deadline_date, t.deadline_time::text AS deadline_time, t.deadline_time_zone,
  t.duration_minutes, t.recurrence, t.subtasks, t.missed_ignored_before::text AS missed_ignored_before,
  t.deleted_at, t.completed_at, t.revision::int AS revision`;

const scheduleOf = (row: Row): TimeValue | null => toTimeValue({ date: row.scheduled_date, time: row.scheduled_time, zone: row.scheduled_time_zone });
const deadlineOf = (row: Row): TimeValue | null => toTimeValue({ date: row.deadline_date, time: row.deadline_time, zone: row.deadline_time_zone });

function taskSummary(row: Row) {
  return {
    taskId: row.id as string,
    title: row.title as string,
    list: (row.list_name as string | null) ?? null,
    status: row.status as string,
    priority: row.priority as string,
    schedule: scheduleOf(row),
    deadline: deadlineOf(row),
    durationMinutes: row.duration_minutes as number | null,
    recurrence: recurrenceSummary(row.recurrence),
    recurring: row.recurrence !== null,
    deleted: row.deleted_at !== null,
    revision: row.revision as number,
  };
}

function observe(state: TurnState, row: Row, selection: 'explicit' | 'ambiguous' | 'filter'): void {
  state.observeTask(row.id, { revision: row.revision, title: row.title, recurring: row.recurrence !== null }, selection);
  if (row.project_id) state.projects.add(row.project_id);
}

const escapeLike = (value: string): string => value.replace(/[\\%_]/g, (character) => `\\${character}`);

export async function searchTasks(pool: pg.Pool, state: TurnState, args: ToolArgs<'search_tasks'>) {
  const tokens = normalizeSearchText(args.query).split(' ').filter(Boolean).slice(0, 8);
  if (tokens.length === 0) return { results: [] };
  const status = args.status === 'all' ? null : args.status;
  const { rows } = await pool.query(`SELECT ${TASK_COLUMNS}
    FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
    WHERE t.user_id = $1 AND t.deleted_at IS NULL AND ($2::text IS NULL OR t.status = $2)
      AND t.search_text LIKE ALL ($3::text[])
    ORDER BY (t.status = 'active') DESC, t.scheduled_date NULLS LAST, t.updated_at DESC, t.id
    LIMIT $4`, [state.turn.userId, status, tokens.map((token) => `%${escapeLike(token)}%`), args.limit]);
  for (const row of rows) observe(state, row, rows.length === 1 ? 'explicit' : 'ambiguous');
  if (rows.length === 1) state.referenced.set(rows[0].id, rows[0].title);
  const results = rows.map(taskSummary);
  for (const task of results) state.currentTaskReads.set(task.taskId, task);
  return { results, truncated: rows.length === args.limit };
}

async function loadOccurrences(pool: pg.Pool, userId: string, taskIds: readonly string[]): Promise<Map<string, Map<string, OccurrenceRow>>> {
  const byTask = new Map<string, Map<string, OccurrenceRow>>();
  if (taskIds.length === 0) return byTask;
  const { rows } = await pool.query(`SELECT id, user_id, task_id, occurrence_key, status, completed_at,
      override_date::text AS override_date, override_time::text AS override_time, override_time_zone, successor_occurrence_key
    FROM task_occurrences WHERE user_id = $1 AND task_id = ANY($2::uuid[])`, [userId, taskIds]);
  for (const row of rows) {
    const occurrence = {
      id: row.id, userId: row.user_id, taskId: row.task_id, occurrenceKey: row.occurrence_key, status: row.status,
      completedAt: row.completed_at, overrideDate: row.override_date, overrideTime: row.override_time,
      overrideTimeZone: row.override_time_zone, successorOccurrenceKey: row.successor_occurrence_key,
      createdAt: '', updatedAt: '',
    } as OccurrenceRow;
    if (!byTask.has(row.task_id)) byTask.set(row.task_id, new Map());
    byTask.get(row.task_id)!.set(row.occurrence_key, occurrence);
  }
  return byTask;
}

export async function getTask(pool: pg.Pool, state: TurnState, args: ToolArgs<'get_task'>) {
  const { rows: [row] } = await pool.query(`SELECT ${TASK_COLUMNS} FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
    WHERE t.id = $1 AND t.user_id = $2`, [args.taskId, state.turn.userId]);
  if (!row) throw new ToolFailure('NOT_FOUND', 'Aucune tâche avec cet identifiant.');
  const known = state.tasks.get(row.id);
  observe(state, row, known?.selection ?? 'filter');
  const subtasks = row.subtasks as Array<{ id: string; title: string; isCompleted: boolean; sortOrder: number }>;
  for (const item of subtasks) state.subtasks.set(item.id, row.id);
  const tags = (await pool.query<{ id: string; name: string }>(`SELECT t.id, t.name FROM task_tags tt
    JOIN tags t ON t.id = tt.tag_id AND t.user_id = tt.user_id
    WHERE tt.task_id = $1 AND tt.user_id = $2 AND tt.deleted_at IS NULL AND t.deleted_at IS NULL
    ORDER BY t.normalized_name, t.id LIMIT 10`, [row.id, state.turn.userId])).rows;
  for (const tag of tags) state.tags.set(tag.id, tag.name);
  const reminders = (await pool.query(`SELECT id, occurrence_key, kind, offset_minutes, local_time::text AS local_time,
      absolute_date::text AS absolute_date, absolute_time::text AS absolute_time, absolute_time_zone, state
    FROM reminders WHERE task_id = $1 AND user_id = $2 AND deleted_at IS NULL ORDER BY created_at, id`, [row.id, state.turn.userId])).rows;
  for (const reminder of reminders) state.reminders.set(reminder.id, row.id);
  const occurrences = (await pool.query(`SELECT occurrence_key, status, override_date::text AS override_date,
      override_time::text AS override_time, override_time_zone, successor_occurrence_key
    FROM task_occurrences WHERE task_id = $1 AND user_id = $2 ORDER BY occurrence_key DESC LIMIT 10`, [row.id, state.turn.userId])).rows;
  let currentOccurrenceKey: string | null = null;
  const after = afterCompletionRecurrenceSchema.safeParse(row.recurrence);
  if (after.success && row.scheduled_date) {
    const all = await loadOccurrences(pool, state.turn.userId, [row.id]);
    currentOccurrenceKey = currentCycleKey(row.scheduled_date, all.get(row.id) ?? new Map());
  }
  const summary = taskSummary(row);
  state.currentTaskReads.set(summary.taskId, summary);
  return {
    ...summary,
    notes: row.notes as string | null,
    subtasks,
    tags: tags.map((tag) => ({ tagId: tag.id, name: tag.name })),
    recurrenceRule: row.recurrence,
    currentOccurrenceKey,
    missedIgnoredBefore: row.missed_ignored_before,
    reminders: reminders.map((reminder) => ({
      reminderId: reminder.id, occurrenceKey: reminder.occurrence_key, kind: reminder.kind,
      offsetMinutes: reminder.offset_minutes, localTime: reminder.local_time?.slice(0, 5) ?? null,
      absolute: reminder.absolute_date === null ? null
        : { date: reminder.absolute_date, time: reminder.absolute_time.slice(0, 5), timeZone: reminder.absolute_time_zone },
      state: reminder.state,
    })),
    recentOccurrences: occurrences.map((occurrence) => ({
      occurrenceKey: occurrence.occurrence_key, status: occurrence.status,
      override: toTimeValue({ date: occurrence.override_date, time: occurrence.override_time, zone: occurrence.override_time_zone }),
      successorOccurrenceKey: occurrence.successor_occurrence_key,
    })),
  };
}

export async function listProjects(pool: pg.Pool, state: TurnState) {
  const { rows } = await pool.query(`SELECT id, name, archived_at IS NOT NULL AS archived FROM projects
    WHERE user_id = $1 AND deleted_at IS NULL ORDER BY sort_order NULLS LAST, name, id`, [state.turn.userId]);
  for (const row of rows) state.projects.add(row.id);
  return { projects: rows.map((row) => ({ projectId: row.id, name: row.name, archived: row.archived })) };
}

export async function listTags(pool: pg.Pool, state: TurnState) {
  const { rows } = await pool.query<{ id: string; name: string; revision: number }>(`SELECT id, name, revision::int AS revision
    FROM tags WHERE user_id = $1 AND deleted_at IS NULL ORDER BY normalized_name, id LIMIT 201`, [state.turn.userId]);
  if (rows.length > 200) throw new ToolFailure('TOO_MANY_TAGS', 'Le catalogue dépasse la limite de 200 tags.');
  state.catalogueTagIds.clear();
  for (const tag of rows) { state.tags.set(tag.id, tag.name); state.catalogueTagIds.add(tag.id); }
  state.tagsCatalogueRead = true;
  return { tags: rows.map((tag) => ({ tagId: tag.id, name: tag.name, revision: tag.revision })) };
}

interface DayItem {
  taskId: string;
  occurrenceKey: string | null;
  title: string;
  time: string | null;
  durationMinutes: number | null;
  list: string | null;
  priority: string;
  hasDeadlineToday: boolean;
  revision: number;
}

interface Snapshot { tasks: Row[]; occurrences: Map<string, Map<string, OccurrenceRow>> }

async function loadSnapshot(pool: pg.Pool, state: TurnState): Promise<Snapshot> {
  const { rows } = await pool.query(`SELECT ${TASK_COLUMNS} FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
    WHERE t.user_id = $1 AND t.deleted_at IS NULL AND t.status = 'active'
    ORDER BY t.id LIMIT ${MAX_TASKS_SCANNED + 1}`, [state.turn.userId]);
  if (rows.length > MAX_TASKS_SCANNED) throw new ToolFailure('TOO_MANY_TASKS', 'Trop de tâches actives pour ce calcul.');
  const recurring = rows.filter((row) => row.recurrence !== null).map((row) => row.id as string);
  return { tasks: rows, occurrences: await loadOccurrences(pool, state.turn.userId, recurring) };
}

function localDateOf(value: TimeValue, zone: string): { date: string; time: string | null } {
  const projected = projectTimeValue(value, zone);
  return { date: projected.date, time: projected.time };
}

function occurrenceValue(row: Row, key: string, occurrence: OccurrenceRow | undefined): TimeValue {
  if (occurrence?.overrideDate) {
    return toTimeValue({ date: occurrence.overrideDate, time: occurrence.overrideTime, zone: occurrence.overrideTimeZone })!;
  }
  return { ...scheduleOf(row)!, date: occurrenceDate(key) };
}

function dayProgram(state: TurnState, snapshot: Snapshot, date: string, includeOverdue: boolean) {
  const zone = state.turn.timeZone;
  const commitments: DayItem[] = [];
  const todo: DayItem[] = [];
  const deadlines: Array<{ taskId: string; title: string; time: string | null; revision: number }> = [];
  const toReschedule: Array<Record<string, unknown>> = [];
  const add = (row: Row, key: string | null, value: TimeValue) => {
    const local = localDateOf(value, zone);
    if (local.date !== date) return;
    const deadline = deadlineOf(row);
    const item: DayItem = {
      taskId: row.id, occurrenceKey: key, title: row.title, time: local.time, durationMinutes: row.duration_minutes,
      list: row.list_name ?? null, priority: row.priority,
      hasDeadlineToday: deadline !== null && localDateOf(deadline, zone).date === date, revision: row.revision,
    };
    (local.time === null ? todo : commitments).push(item);
    observe(state, row, 'filter');
  };

  for (const row of snapshot.tasks) {
    const schedule = scheduleOf(row);
    const deadline = deadlineOf(row);
    if (row.recurrence === null) {
      if (schedule) add(row, null, schedule);
      if (deadline) {
        const local = localDateOf(deadline, zone);
        if (local.date === date) {
          deadlines.push({ taskId: row.id, title: row.title, time: local.time, revision: row.revision });
          observe(state, row, 'filter');
        } else if (includeOverdue && local.date < date) {
          toReschedule.push({ taskId: row.id, title: row.title, reason: 'deadline_passed', deadline, revision: row.revision });
          observe(state, row, 'filter');
        }
      }
      if (includeOverdue && schedule && localDateOf(schedule, zone).date < date) {
        toReschedule.push({ taskId: row.id, title: row.title, reason: 'scheduled_before', schedule, revision: row.revision });
        observe(state, row, 'filter');
      }
      continue;
    }
    const rows = snapshot.occurrences.get(row.id) ?? new Map<string, OccurrenceRow>();
    const fixed = fixedRecurrenceSchema.safeParse(row.recurrence);
    if (fixed.success) {
      // Window of ±1 day: a timed occurrence can change date once projected into the turn's zone.
      for (const { occurrenceKey } of fixedOccurrences({ taskId: row.id, anchor: row.scheduled_date, rule: fixed.data, from: addDays(date, -1), through: addDays(date, 1) })) {
        const occurrence = rows.get(occurrenceKey);
        if (occurrence && occurrence.status !== 'open') continue;
        add(row, occurrenceKey, occurrenceValue(row, occurrenceKey, occurrence));
      }
      for (const occurrence of rows.values()) {
        // Occurrences moved into this date from further away.
        if (occurrence.status !== 'open' || !occurrence.overrideDate || Math.abs(Temporal.PlainDate.from(occurrence.occurrenceKey).until(date).days) <= 1) continue;
        add(row, occurrence.occurrenceKey, occurrenceValue(row, occurrence.occurrenceKey, occurrence));
      }
      if (includeOverdue) {
        const missed = countMissedFixed({
          anchor: row.scheduled_date, rule: fixed.data, beforeDate: date, ignoredBefore: row.missed_ignored_before,
          materialized: [...rows.values()].map((occurrence) => ({ occurrenceKey: occurrence.occurrenceKey, status: occurrence.status, overrideDate: occurrence.overrideDate })),
        });
        if (missed.count > 0) {
          toReschedule.push({ taskId: row.id, title: row.title, reason: 'missed_occurrences', missedCount: missed.count, latestOccurrenceKey: missed.latestOccurrenceKey, revision: row.revision });
          observe(state, row, 'filter');
        }
      }
      continue;
    }
    const key = currentCycleKey(row.scheduled_date, rows);
    const value = occurrenceValue(row, key, rows.get(key));
    add(row, key, value);
    if (includeOverdue && localDateOf(value, zone).date < date) {
      toReschedule.push({ taskId: row.id, title: row.title, reason: 'cycle_overdue', occurrenceKey: key, schedule: value, revision: row.revision });
      observe(state, row, 'filter');
    }
  }
  commitments.sort((left, right) => (left.time ?? '').localeCompare(right.time ?? '') || left.title.localeCompare(right.title));
  todo.sort((left, right) => left.title.localeCompare(right.title));
  return { date, commitments, todo, deadlines, toReschedule: includeOverdue ? toReschedule : undefined, calendar: calendarFor(state, date) };
}

function calendarFor(state: TurnState, date: string) {
  const calendar = state.turn.calendar;
  if (calendar === null) return { coverage: 'not_shared' as const, events: [] };
  if (date < calendar.from || date > calendar.to) return { coverage: 'outside_range' as const, events: [] };
  const zone = state.turn.timeZone;
  const events = calendar.events.flatMap((event) => {
    const start = Temporal.Instant.from(event.start).toZonedDateTimeISO(zone);
    const end = Temporal.Instant.from(event.end).toZonedDateTimeISO(zone);
    const startDate = start.toPlainDate().toString();
    const endDate = end.toPlainDate().toString();
    if (event.allDay ? !(startDate <= date && date < (endDate > startDate ? endDate : addDays(startDate, 1))) : !(startDate <= date && date <= endDate)) return [];
    return [{
      title: event.title, calendar: event.calendarName, allDay: event.allDay,
      start: event.allDay ? null : startDate === date ? start.toPlainTime().toString({ smallestUnit: 'minute' }) : '00:00',
      end: event.allDay ? null : endDate === date ? end.toPlainTime().toString({ smallestUnit: 'minute' }) : '23:59',
    }];
  });
  return { coverage: 'included' as const, capturedAt: calendar.capturedAt, calendars: calendar.calendars, events };
}

export async function listDay(pool: pg.Pool, state: TurnState, args: ToolArgs<'list_day'>) {
  const snapshot = await loadSnapshot(pool, state);
  return dayProgram(state, snapshot, args.date, args.date === state.turn.localDate);
}

export async function listUpcoming(pool: pg.Pool, state: TurnState, args: ToolArgs<'list_upcoming'>) {
  const span = Temporal.PlainDate.from(args.fromDate).until(args.toDate).days;
  if (span < 0 || span > 13) throw new ToolFailure('INVALID_RANGE', 'La période doit couvrir 1 à 14 dates, fromDate ≤ toDate.');
  const snapshot = await loadSnapshot(pool, state);
  const days = [];
  for (let offset = 0; offset <= span; offset++) {
    const date = addDays(args.fromDate, offset);
    days.push(dayProgram(state, snapshot, date, date === state.turn.localDate));
  }
  return { days };
}

export async function findFreeSlots(pool: pg.Pool, state: TurnState, args: ToolArgs<'find_free_slots'>) {
  const snapshot = await loadSnapshot(pool, state);
  const program = dayProgram(state, snapshot, args.date, false);
  const busy: Array<[number, number]> = [];
  for (const item of program.commitments) {
    const start = minutes(item.time!);
    busy.push([start, Math.min(24 * 60, start + (item.durationMinutes ?? DEFAULT_DURATION))]);
  }
  for (const event of program.calendar.events) {
    busy.push(event.allDay ? [0, 0] : [minutes(event.start!), minutes(event.end!)]);
  }
  for (const interval of args.extraBusy ?? []) busy.push([minutes(interval.start), minutes(interval.end)]);
  let windowStart = Math.max(minutes(DAY_START), args.notBefore ? minutes(args.notBefore) : 0);
  const windowEnd = Math.min(minutes(DAY_END), args.notAfter ? minutes(args.notAfter) : 24 * 60);
  if (args.date === state.turn.localDate) windowStart = Math.max(windowStart, Math.ceil((minutes(state.turn.localTime) + 1) / 15) * 15);
  if (args.date < state.turn.localDate) throw new ToolFailure('DATE_IN_PAST', 'Cette date est passée.');

  const intervals = busy.filter(([start, end]) => end > start).sort((left, right) => left[0] - right[0]);
  const gaps: Array<[number, number]> = [];
  let cursor = windowStart;
  for (const [start, end] of intervals) {
    if (start > cursor) gaps.push([cursor, Math.min(start, windowEnd)]);
    cursor = Math.max(cursor, end);
    if (cursor >= windowEnd) break;
  }
  if (cursor < windowEnd) gaps.push([cursor, windowEnd]);
  const slots: ProposedSlot[] = [];
  const push = (start: number) => {
    if (slots.length < 3) slots.push({ date: args.date, start: clock(start), end: clock(start + args.durationMinutes) });
  };
  const aligned = (value: number) => Math.ceil(value / 15) * 15;
  for (const [start, end] of gaps) if (aligned(start) + args.durationMinutes <= end) push(aligned(start));
  // Fewer than three gaps: offer later starts in the widest one.
  const widest = [...gaps].sort((left, right) => (right[1] - right[0]) - (left[1] - left[0]))[0];
  for (let start = widest ? aligned(widest[0]) + 60 : Infinity; widest && slots.length < 3 && start + args.durationMinutes <= widest[1]; start += 60) {
    if (!slots.some((slot) => slot.start === clock(start))) push(start);
  }
  slots.sort((left, right) => left.start.localeCompare(right.start));
  state.proposedSlots.push(...slots);
  const assumptions = [
    `Journée utile ${clock(windowStart)}–${clock(windowEnd)} (${state.turn.timeZone}).`,
    `Tâches sans durée comptées ${DEFAULT_DURATION} min.`,
    program.calendar.coverage === 'included' ? 'Calendrier partagé pris en compte.'
      : program.calendar.coverage === 'not_shared' ? 'Calendrier non partagé : événements non pris en compte.'
        : 'Date hors de la période du calendrier partagé.',
    ...(args.extraBusy?.length ? ['Contraintes du message prises en compte.'] : []),
  ];
  return { date: args.date, durationMinutes: args.durationMinutes, slots, assumptions, coverage: program.calendar.coverage };
}
