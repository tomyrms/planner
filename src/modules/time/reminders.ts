import { Temporal } from '@js-temporal/polyfill';
import { validate as validUuid } from 'uuid';
import { z } from 'zod';
import { civilDateSchema, localTimeSchema, resolveTimeValue, timeValueSchema, timeZoneSchema, type TimeValue } from './values.js';
import { occurrenceKeySchema } from './recurrence.js';

const offset = z.number().int().min(0).max(10080);
const absoluteTimeSchema = z.object({ date: civilDateSchema, time: localTimeSchema, timeZone: timeZoneSchema }).strict();
export const reminderRuleSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('before_start'), offsetMinutes: offset }).strict(),
  z.object({ kind: z.literal('before_deadline'), offsetMinutes: offset }).strict(),
  z.object({ kind: z.literal('on_scheduled_day_at'), localTime: localTimeSchema }).strict(),
  z.object({ kind: z.literal('on_deadline_day_at'), localTime: localTimeSchema }).strict(),
  z.object({ kind: z.literal('absolute'), absolute: absoluteTimeSchema }).strict(),
]);
export type ReminderRule = z.infer<typeof reminderRuleSchema>;
export type ReminderTrigger = { state: 'active'; triggerAt: string } | { state: 'inactive_base_missing'; triggerAt: null };

export function notificationId(reminderId: string, occurrenceKey: string | null = null): string {
  if (!validUuid(reminderId)) throw new RangeError('Invalid reminder UUID');
  if (occurrenceKey !== null) occurrenceKeySchema.parse(occurrenceKey);
  return `r:${reminderId.toLowerCase()}:${occurrenceKey ?? 'once'}`;
}

/** Caller supplies the effective occurrence schedule (including its durable override). */
export function resolveReminderTrigger(input: { reminder: ReminderRule; schedule: TimeValue | null; deadline: TimeValue | null; deviceTimeZone: string; isRecurring?: boolean; occurrenceKey?: string | null }): ReminderTrigger {
  const reminder = reminderRuleSchema.parse(input.reminder);
  timeZoneSchema.parse(input.deviceTimeZone);
  if (input.occurrenceKey != null) occurrenceKeySchema.parse(input.occurrenceKey);
  if (reminder.kind === 'absolute') {
    if (input.isRecurring === true && input.occurrenceKey == null) throw new RangeError('ABSOLUTE_REMINDER_REQUIRES_OCCURRENCE');
    const resolved = resolveTimeValue(reminder.absolute);
    if (resolved.kind !== 'timed') throw new Error('Absolute reminder requires a time');
    return { state: 'active', triggerAt: resolved.instant };
  }
  const base = reminder.kind === 'before_start' || reminder.kind === 'on_scheduled_day_at' ? input.schedule : input.deadline;
  if (base === null) return { state: 'inactive_base_missing', triggerAt: null };
  const normalized = timeValueSchema.parse(base);
  if (reminder.kind === 'before_start' || reminder.kind === 'before_deadline') {
    if (normalized.time === null) return { state: 'inactive_base_missing', triggerAt: null };
    const resolved = resolveTimeValue(normalized);
    if (resolved.kind !== 'timed') throw new Error('Timed base expected');
    return { state: 'active', triggerAt: Temporal.Instant.from(resolved.instant).subtract({ minutes: reminder.offsetMinutes }).toString() };
  }
  if (normalized.time !== null) return { state: 'inactive_base_missing', triggerAt: null };
  const resolved = resolveTimeValue({ date: normalized.date, time: reminder.localTime, timeZone: input.deviceTimeZone });
  if (resolved.kind !== 'timed') throw new Error('Timed reminder expected');
  return { state: 'active', triggerAt: resolved.instant };
}

export const REMINDER_WINDOW_DAYS = 14;
export const MAX_PENDING_REMINDERS = 50;
export interface ReminderCandidate {
  reminderId: string;
  occurrenceKey: string | null;
  trigger: ReminderTrigger;
  /** false for a deleted reminder or a completed/skipped/deleted task or occurrence. */
  eligible: boolean;
}
export interface ScheduledRequest { notificationId: string; triggerAt: string }
export interface SchedulingReceipt extends ScheduledRequest { acceptedAt: string }
export type ReminderProgrammingState = 'needs_scheduling' | 'scheduled' | 'pending_window' | 'pending_capacity' | 'notifications_disabled' | 'inactive_base_missing' | 'removed' | 'missed' | 'display_unknown';

/** Pure desired-state plan. Only actual system pending requests prove scheduling. */
export function planReminderReconciliation(input: {
  referenceInstant: string;
  deviceTimeZone: string;
  notificationsAuthorized: boolean;
  candidates: readonly ReminderCandidate[];
  systemPending?: readonly ScheduledRequest[];
  schedulingReceipts?: readonly SchedulingReceipt[];
}): { desired: ScheduledRequest[]; addOrReplace: ScheduledRequest[]; remove: string[]; states: Record<string, ReminderProgrammingState> } {
  timeZoneSchema.parse(input.deviceTimeZone);
  const now = Temporal.Instant.from(input.referenceInstant);
  const horizon = now.toZonedDateTimeISO(input.deviceTimeZone).add({ days: REMINDER_WINDOW_DAYS }).toInstant();
  const pending = new Map((input.systemPending ?? []).map((request) => [request.notificationId, Temporal.Instant.from(request.triggerAt).toString()]));
  const receipts = input.schedulingReceipts ?? [];
  const states: Record<string, ReminderProgrammingState> = Object.create(null) as Record<string, ReminderProgrammingState>;
  const eligible: ScheduledRequest[] = [];
  for (const candidate of input.candidates) {
    const id = notificationId(candidate.reminderId, candidate.occurrenceKey);
    if (Object.hasOwn(states, id)) throw new RangeError('Duplicate notification candidate');
    if (!candidate.eligible) { states[id] = 'removed'; continue; }
    if (candidate.trigger.state === 'inactive_base_missing') { states[id] = 'inactive_base_missing'; continue; }
    const trigger = Temporal.Instant.from(candidate.trigger.triggerAt);
    if (Temporal.Instant.compare(trigger, now) <= 0) {
      const wasScheduled = receipts.some((receipt) => receipt.notificationId === id && Temporal.Instant.compare(receipt.triggerAt, trigger) === 0 && Temporal.Instant.compare(receipt.acceptedAt, trigger) < 0);
      states[id] = wasScheduled ? 'display_unknown' : 'missed';
      continue;
    }
    if (!input.notificationsAuthorized) { states[id] = 'notifications_disabled'; continue; }
    if (Temporal.Instant.compare(trigger, horizon) > 0) { states[id] = 'pending_window'; continue; }
    states[id] = 'pending_capacity';
    eligible.push({ notificationId: id, triggerAt: trigger.toString() });
  }
  eligible.sort((a, b) => Temporal.Instant.compare(a.triggerAt, b.triggerAt) || a.notificationId.localeCompare(b.notificationId, 'en'));
  const desired = eligible.slice(0, MAX_PENDING_REMINDERS);
  const desiredIds = new Set(desired.map((request) => request.notificationId));
  const addOrReplace: ScheduledRequest[] = [];
  for (const request of desired) {
    const accepted = pending.get(request.notificationId) === request.triggerAt;
    states[request.notificationId] = accepted ? 'scheduled' : 'needs_scheduling';
    if (!accepted) addOrReplace.push(request);
  }
  const remove = [...pending.keys()].filter((id) => id.startsWith('r:') && !desiredIds.has(id)).sort();
  return { desired, addOrReplace, remove, states };
}
