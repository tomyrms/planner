import { Temporal } from '@js-temporal/polyfill';
import { v5 as uuidv5, validate as validUuid } from 'uuid';
import { z } from 'zod';
import { afterCompletionRecurrenceSchema, fixedRecurrenceSchema, type AfterCompletionRecurrence, type FixedRecurrence } from './rules.js';
import { civilDateSchema, localDateAt } from './values.js';

/** Frozen project namespace; persist unchanged in the Swift client and every migration. */
export const OCCURRENCE_NAMESPACE = '6fcb5ad1-40ec-5ca9-bfab-62083e61c443';
export const MAX_OCCURRENCE_WINDOW_DAYS = 60;
export const occurrenceKeySchema = z.string().refine((key) => {
  const pieces = key.split('~');
  if (pieces.length > 2 || !civilDateSchema.safeParse(pieces[0]).success) return false;
  return pieces.length === 1 || (/^(0|[1-9]\d*)$/.test(pieces[1]!) && Number.isSafeInteger(Number(pieces[1])));
}, 'Expected YYYY-MM-DD or YYYY-MM-DD~cycle');

export function occurrenceDate(occurrenceKey: string): string {
  occurrenceKeySchema.parse(occurrenceKey);
  return occurrenceKey.split('~')[0]!;
}

export function afterCompletionKey(date: string, cycle: number): string {
  civilDateSchema.parse(date);
  if (!Number.isSafeInteger(cycle) || cycle < 0) throw new RangeError('Expected a non-negative safe cycle ordinal');
  return `${date}~${cycle}`;
}

export function nextAfterCompletionKey(currentKey: string, nextDate: string): string {
  occurrenceKeySchema.parse(currentKey);
  const cycle = currentKey.split('~')[1];
  if (cycle === undefined) throw new RangeError('After-completion occurrence requires a cycle ordinal');
  return afterCompletionKey(nextDate, Number(cycle) + 1);
}

export function occurrenceId(taskId: string, occurrenceKey: string): string {
  if (!validUuid(taskId)) throw new RangeError('Invalid task UUID');
  occurrenceKeySchema.parse(occurrenceKey);
  return uuidv5(`${taskId.toLowerCase()}:${occurrenceKey}`, OCCURRENCE_NAMESPACE);
}

export function nextAfterCompletionDate(rule: AfterCompletionRecurrence, referenceInstant: string, deviceTimeZone: string): string {
  return nextAfterCompletionFromLocalDate(rule, localDateAt(referenceInstant, deviceTimeZone));
}

/** Sync commands carry the civil date of the action as seen on the device. */
export function nextAfterCompletionFromLocalDate(rule: AfterCompletionRecurrence, completedLocalDate: string): string {
  const parsed = afterCompletionRecurrenceSchema.parse(rule);
  const day = Temporal.PlainDate.from(civilDateSchema.parse(completedLocalDate));
  const duration = parsed.unit === 'day' ? { days: parsed.interval } : parsed.unit === 'week' ? { weeks: parsed.interval } : { months: parsed.interval };
  return civilDateSchema.parse(day.add(duration, { overflow: 'constrain' }).toString());
}

export function nextAfterCompletion(input: { rule: AfterCompletionRecurrence; referenceInstant: string; deviceTimeZone: string }): string {
  return nextAfterCompletionDate(input.rule, input.referenceInstant, input.deviceTimeZone);
}

const weekdays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'] as const;
const daysBetween = (from: Temporal.PlainDate, to: Temporal.PlainDate): number => from.until(to, { largestUnit: 'day' }).days;
const gcd = (a: number, b: number): number => b === 0 ? a : gcd(b, a % b);
const leap = (year: number): boolean => year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
function monthLength(year: number, month: number): number {
  if (month === 2) return leap(year) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

/** Rank without materializing historical dates. Monthly calendars repeat after 400 years. */
function rawCountThrough(anchor: Temporal.PlainDate, rule: FixedRecurrence, through: Temporal.PlainDate): number {
  if (Temporal.PlainDate.compare(through, anchor) < 0) return 0;
  if (rule.freq === 'daily') return Math.floor(daysBetween(anchor, through) / rule.interval) + 1;
  if (rule.freq === 'weekly') {
    const weekStart = anchor.subtract({ days: anchor.dayOfWeek - 1 });
    let count = 0;
    for (const weekday of rule.byWeekday) {
      let first = weekStart.add({ days: weekdays.indexOf(weekday) });
      if (Temporal.PlainDate.compare(first, anchor) < 0) first = first.add({ weeks: rule.interval });
      const days = daysBetween(first, through);
      if (days >= 0) count += Math.floor(days / (7 * rule.interval)) + 1;
    }
    return count;
  }
  const monthDelta = (through.year - anchor.year) * 12 + through.month - anchor.month;
  const lastIndex = Math.floor(monthDelta / rule.interval);
  const candidateDay = (index: number): number | null => {
    const monthIndex = anchor.year * 12 + anchor.month - 1 + index * rule.interval;
    const year = Math.floor(monthIndex / 12);
    const month = monthIndex % 12 + 1;
    const length = monthLength(year, month);
    return 'byMonthDay' in rule ? rule.byMonthDay <= length ? rule.byMonthDay : null : length;
  };
  const period = 4800 / gcd(4800, rule.interval);
  const n = lastIndex + 1;
  let validPerPeriod = 0;
  let remainderCount = 0;
  const remainder = n % period;
  // For short histories only visit the months that actually exist.
  for (let index = 0; index < Math.min(n, period); index++) {
    if (candidateDay(index) !== null) {
      validPerPeriod++;
      if (index < remainder) remainderCount++;
    }
  }
  let count = n < period ? validPerPeriod : Math.floor(n / period) * validPerPeriod + remainderCount;
  const initialDay = candidateDay(0);
  if (initialDay !== null && initialDay < anchor.day) count--;
  const lastDay = candidateDay(lastIndex);
  if (lastDay !== null && lastIndex * rule.interval === monthDelta && lastDay > through.day) count--;
  return Math.max(0, count);
}

function countThrough(anchor: Temporal.PlainDate, rule: FixedRecurrence, through: Temporal.PlainDate): number {
  const end = rule.until !== undefined && rule.until < through.toString() ? Temporal.PlainDate.from(rule.until) : through;
  return Math.min(rawCountThrough(anchor, rule, end), rule.count ?? Number.MAX_SAFE_INTEGER);
}

function isOccurrence(anchor: Temporal.PlainDate, rule: FixedRecurrence, date: Temporal.PlainDate): boolean {
  return countThrough(anchor, rule, date) > countThrough(anchor, rule, date.subtract({ days: 1 }));
}

/** True when the civil date is produced by the fixed series (anchor, count and until included). */
export function isFixedOccurrence(input: { anchor: string; rule: FixedRecurrence; date: string }): boolean {
  return isOccurrence(
    Temporal.PlainDate.from(civilDateSchema.parse(input.anchor)),
    fixedRecurrenceSchema.parse(input.rule),
    Temporal.PlainDate.from(civilDateSchema.parse(input.date)),
  );
}

export interface FixedWindowInput { taskId: string; anchor: string; rule: FixedRecurrence; from: string; through: string }
export interface FixedOccurrence { id: string; occurrenceKey: string }

export function fixedOccurrences(input: FixedWindowInput): FixedOccurrence[] {
  const anchor = Temporal.PlainDate.from(civilDateSchema.parse(input.anchor));
  const rule = fixedRecurrenceSchema.parse(input.rule);
  let date = Temporal.PlainDate.from(civilDateSchema.parse(input.from));
  const through = Temporal.PlainDate.from(civilDateSchema.parse(input.through));
  const days = daysBetween(date, through) + 1;
  if (days < 1 || days > MAX_OCCURRENCE_WINDOW_DAYS) throw new RangeError('Occurrence window must contain 1 to 60 civil days');
  // Validates the ID even when this window contains no occurrences.
  occurrenceId(input.taskId, input.anchor);
  const occurrences: FixedOccurrence[] = [];
  for (let index = 0; index < days; index++) {
    if (isOccurrence(anchor, rule, date)) {
      const occurrenceKey = date.toString();
      occurrences.push({ id: occurrenceId(input.taskId, occurrenceKey), occurrenceKey });
    }
    if (index < days - 1) date = date.add({ days: 1 });
  }
  return occurrences;
}

export interface MaterializedOccurrence {
  occurrenceKey: string;
  status: 'open' | 'completed' | 'skipped';
  overrideDate?: string | null;
}

function keyAtRank(anchor: Temporal.PlainDate, rule: FixedRecurrence, through: Temporal.PlainDate, rank: number): string {
  let low = 0;
  let high = daysBetween(anchor, through);
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (countThrough(anchor, rule, anchor.add({ days: middle })) >= rank) high = middle;
    else low = middle + 1;
  }
  return anchor.add({ days: low }).toString();
}

/** One summary row for days strictly before beforeDate. No historical occurrence array.
 * ignoredBefore (series-level "ignore previous") drops every origin date before it.
 */
export function countMissedFixed(input: { anchor: string; rule: FixedRecurrence; beforeDate: string; materialized?: readonly MaterializedOccurrence[]; ignoredBefore?: string | null }): { count: number; latestOccurrenceKey: string | null } {
  const anchor = Temporal.PlainDate.from(civilDateSchema.parse(input.anchor));
  const rule = fixedRecurrenceSchema.parse(input.rule);
  const cutoff = Temporal.PlainDate.from(civilDateSchema.parse(input.beforeDate));
  const through = cutoff.subtract({ days: 1 });
  const ignoredBefore = input.ignoredBefore == null ? null : civilDateSchema.parse(input.ignoredBefore);
  const upper = countThrough(anchor, rule, through);
  const lower = ignoredBefore === null ? 0 : countThrough(anchor, rule, Temporal.PlainDate.from(ignoredBefore).subtract({ days: 1 }));
  const total = Math.max(0, upper - lower);
  const excluded = new Set<string>();
  const extras: string[] = [];
  const seen = new Set<string>();
  for (const row of input.materialized ?? []) {
    civilDateSchema.parse(row.occurrenceKey);
    if (seen.has(row.occurrenceKey)) throw new RangeError('Duplicate materialized occurrence key');
    seen.add(row.occurrenceKey);
    if (ignoredBefore !== null && row.occurrenceKey < ignoredBefore) continue;
    const effectiveDate = row.overrideDate == null ? row.occurrenceKey : civilDateSchema.parse(row.overrideDate);
    const inBase = row.occurrenceKey < input.beforeDate && isOccurrence(anchor, rule, Temporal.PlainDate.from(row.occurrenceKey));
    const missed = row.status === 'open' && effectiveDate < input.beforeDate;
    if (inBase && !missed) excluded.add(row.occurrenceKey);
    if (!inBase && missed) extras.push(row.occurrenceKey);
  }
  let rank = upper;
  let latest: string | null = null;
  while (rank > lower) {
    const key = keyAtRank(anchor, rule, through, rank);
    if (!excluded.has(key)) { latest = key; break; }
    rank--;
  }
  for (const key of extras) if (latest === null || key > latest) latest = key;
  return { count: total - excluded.size + extras.length, latestOccurrenceKey: latest };
}

export interface AfterCompletionState {
  occurrenceKey: string;
  status: 'open' | 'completed' | 'skipped';
  completedAt: string | null;
  successorOccurrenceKey: string | null;
}

/** Pure preview; the server must lock and persist state + successor in one transaction. */
export function closeAfterCompletion(input: { state: AfterCompletionState; rule: AfterCompletionRecurrence; referenceInstant: string; deviceTimeZone: string; action: 'complete' | 'skip' }): { outcome: 'applied' | 'duplicate'; state: AfterCompletionState } {
  occurrenceKeySchema.parse(input.state.occurrenceKey);
  if (input.state.status !== 'open') return { outcome: 'duplicate', state: { ...input.state } };
  const successorOccurrenceKey = nextAfterCompletionKey(input.state.occurrenceKey, nextAfterCompletionDate(input.rule, input.referenceInstant, input.deviceTimeZone));
  return { outcome: 'applied', state: { ...input.state, status: input.action === 'complete' ? 'completed' : 'skipped', completedAt: input.action === 'complete' ? Temporal.Instant.from(input.referenceInstant).toString() : null, successorOccurrenceKey } };
}

export function reopenAfterCompletion(state: AfterCompletionState, successorMaterialized: boolean): { outcome: 'applied' | 'duplicate' | 'rejected'; code?: 'SUCCESSOR_ALREADY_CHANGED'; state: AfterCompletionState } {
  if (state.status === 'open') return { outcome: 'duplicate', state: { ...state } };
  if (successorMaterialized) return { outcome: 'rejected', code: 'SUCCESSOR_ALREADY_CHANGED', state: { ...state } };
  return { outcome: 'applied', state: { ...state, status: 'open', completedAt: null, successorOccurrenceKey: null } };
}
