import { Temporal } from '@js-temporal/polyfill';
import { z } from 'zod';

/** ISO Gregorian civil dates, deliberately distinct from an instant. */
export const civilDateSchema = z.string().regex(/^(?!0000)\d{4}-\d{2}-\d{2}$/).refine((date) => {
  try { return Temporal.PlainDate.from(date).toString() === date; } catch { return false; }
}, 'Invalid Gregorian civil date');
export const localTimeSchema = z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/, 'Expected HH:mm');
export const timeZoneSchema = z.string().min(1).max(100).refine((zone) => {
  if (/^[+\-]/.test(zone)) return false;
  try { new Intl.DateTimeFormat('en', { timeZone: zone }); return true; } catch { return false; }
}, 'Expected an IANA time zone identifier');
export const timeValueSchema = z.union([
  z.object({ date: civilDateSchema, time: z.null().default(null), timeZone: z.null().default(null) }).strict(),
  z.object({ date: civilDateSchema, time: localTimeSchema, timeZone: timeZoneSchema }).strict(),
]);
export const durationMinutesSchema = z.number().int().min(1).max(1440).nullable();
export type TimeValue = z.input<typeof timeValueSchema>;
export type TimedValue = Extract<TimeValue, { time: string }>;
export type ResolvedTimeValue =
  | { kind: 'date'; date: string }
  | { kind: 'timed'; date: string; time: string; timeZone: string; instant: string; effectiveDate: string; effectiveTime: string; adjustment: 'exact' | 'gap_forward' | 'fold_first' };

/** A DST gap advances to its first valid minute, not by the size of the gap. */
export function resolveTimeValue(value: TimeValue): ResolvedTimeValue;
export function resolveTimeValue(value: null): null;
export function resolveTimeValue(value: TimeValue | null): ResolvedTimeValue | null;
export function resolveTimeValue(value: TimeValue | null): ResolvedTimeValue | null {
  if (value === null) return null;
  const parsed = timeValueSchema.parse(value);
  if (parsed.time === null) return { kind: 'date', date: parsed.date };
  const requested = Temporal.PlainDateTime.from(`${parsed.date}T${parsed.time}`);
  let effective = requested;
  let earlier = effective.toZonedDateTime(parsed.timeZone, { disambiguation: 'earlier' });
  let later = effective.toZonedDateTime(parsed.timeZone, { disambiguation: 'later' });
  let gap = false;
  // Covers even whole-day IANA transitions (e.g. Samoa). Bounded to two days.
  for (let minutes = 0; !earlier.toPlainDateTime().equals(effective); minutes++) {
    if (minutes >= 2880) throw new RangeError('Time-zone gap exceeds two days');
    gap = true;
    effective = effective.add({ minutes: 1 });
    earlier = effective.toZonedDateTime(parsed.timeZone, { disambiguation: 'earlier' });
    later = effective.toZonedDateTime(parsed.timeZone, { disambiguation: 'later' });
  }
  return {
    kind: 'timed', ...parsed, instant: earlier.toInstant().toString(),
    effectiveDate: effective.toPlainDate().toString(),
    effectiveTime: effective.toPlainTime().toString({ smallestUnit: 'minute' }),
    adjustment: gap ? 'gap_forward' : earlier.epochNanoseconds !== later.epochNanoseconds ? 'fold_first' : 'exact',
  };
}

export function projectTimeValue(value: TimeValue, displayTimeZone: string): { date: string; time: string | null; timeZone: string | null } {
  timeZoneSchema.parse(displayTimeZone);
  const resolved = resolveTimeValue(value);
  if (resolved.kind === 'date') return { date: resolved.date, time: null, timeZone: null };
  const projected = Temporal.Instant.from(resolved.instant).toZonedDateTimeISO(displayTimeZone);
  return { date: projected.toPlainDate().toString(), time: projected.toPlainTime().toString({ smallestUnit: 'minute' }), timeZone: displayTimeZone };
}

export function localDateAt(referenceInstant: string, timeZone: string): string {
  timeZoneSchema.parse(timeZone);
  return civilDateSchema.parse(Temporal.Instant.from(referenceInstant).toZonedDateTimeISO(timeZone).toPlainDate().toString());
}

/** Relative AI dates use the captured turn instant, never a processing clock. */
export function relativeDate(referenceInstant: string, timeZone: string, days: number): string {
  if (!Number.isSafeInteger(days)) throw new RangeError('Expected an integer day offset');
  return civilDateSchema.parse(Temporal.PlainDate.from(localDateAt(referenceInstant, timeZone)).add({ days }).toString());
}

export function isOverdue(value: TimeValue | null, referenceInstant: string, deviceTimeZone: string): boolean {
  if (value === null) return false;
  const resolved = resolveTimeValue(value);
  return resolved.kind === 'date'
    ? localDateAt(referenceInstant, deviceTimeZone) > resolved.date
    : Temporal.Instant.compare(referenceInstant, resolved.instant) > 0;
}
