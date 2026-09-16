import { describe, expect, it } from 'vitest';
import {
  afterCompletionKey, civilDateSchema, countMissedFixed, durationMinutesSchema, fixedOccurrences,
  nextAfterCompletionKey, occurrenceDate, occurrenceId, occurrenceKeySchema, recurrenceSchema,
  timeValueSchema, type FixedRecurrence,
} from '../../src/modules/time/index.js';

const taskId = '11111111-1111-4111-8111-111111111111';

describe('temporal input contracts', () => {
  it.each(['2026-02-29', '2026-04-31', '0000-01-01', '26-09-17', '2026-9-17', '2026-09-17T00:00:00Z'])('rejects invalid civil date %s', (date) => {
    expect(civilDateSchema.safeParse(date).success).toBe(false);
  });
  it('accepts leap dates and normalizes omitted date-only fields', () => {
    expect(timeValueSchema.parse({ date: '2028-02-29' })).toEqual({ date: '2028-02-29', time: null, timeZone: null });
  });
  it.each([
    { date: '2026-09-17', time: '17:00' },
    { date: '2026-09-17', time: null, timeZone: 'Europe/Zurich' },
    { date: '2026-09-17', time: '17:00:01', timeZone: 'Europe/Zurich' },
    { date: '2026-09-17', time: '24:00', timeZone: 'Europe/Zurich' },
    { date: '2026-09-17', time: '17:00', timeZone: '+02:00' },
    { date: '2026-09-17', time: '17:00', timeZone: 'Europe/Imaginary' },
    { date: '2026-09-17', dueAt: '2026-09-17T23:59:59Z' },
  ])('rejects incoherent time value %j', (value) => expect(timeValueSchema.safeParse(value).success).toBe(false));
  it.each([0, -1, 1.5, 1441])('rejects invalid duration %s', (duration) => expect(durationMinutesSchema.safeParse(duration).success).toBe(false));
  it('allows unknown duration without turning it into zero', () => {
    expect(durationMinutesSchema.parse(null)).toBeNull();
    expect(durationMinutesSchema.parse(1440)).toBe(1440);
  });
  it.each([
    { v: 1, mode: 'fixed', freq: 'daily', interval: 0 },
    { v: 1, mode: 'fixed', freq: 'daily', interval: 366 },
    { v: 1, mode: 'fixed', freq: 'daily', interval: 1, count: 0 },
    { v: 1, mode: 'fixed', freq: 'daily', interval: 1, count: 1, until: '2026-09-17' },
    { v: 1, mode: 'fixed', freq: 'weekly', interval: 1, byWeekday: ['MO', 'MO'] },
    { v: 1, mode: 'fixed', freq: 'weekly', interval: 1, byWeekday: [] },
    { v: 1, mode: 'fixed', freq: 'monthly', interval: 1, byMonthDay: 31, lastDayOfMonth: true },
    { v: 1, mode: 'after_completion', unit: 'year', interval: 1 },
  ])('rejects malformed recurrence %j', (rule) => expect(recurrenceSchema.safeParse(rule).success).toBe(false));
});

describe('bounded recurrence and durable identity', () => {
  const daily: FixedRecurrence = { v: 1, mode: 'fixed', freq: 'daily', interval: 1 };
  it('refuses a historical array or reversed display window', () => {
    expect(() => fixedOccurrences({ taskId, anchor: '2026-01-01', rule: daily, from: '2026-01-01', through: '2026-07-01' })).toThrow(/1 to 60/);
    expect(() => fixedOccurrences({ taskId, anchor: '2026-01-01', rule: daily, from: '2026-07-01', through: '2026-01-01' })).toThrow(/1 to 60/);
  });
  it('summarizes twenty years of daily misses without generating occurrences', () => {
    expect(countMissedFixed({ anchor: '2000-01-01', rule: daily, beforeDate: '2020-01-01' })).toEqual({ count: 7305, latestOccurrenceKey: '2019-12-31' });
  });
  it('counts Gregorian cycles including a non-leap century', () => {
    expect(countMissedFixed({ anchor: '2000-02-29', rule: { v: 1, mode: 'fixed', freq: 'monthly', interval: 12, byMonthDay: 29 }, beforeDate: '2400-02-29' })).toEqual({ count: 97, latestOccurrenceKey: '2396-02-29' });
  });
  it('weekly count bounds count actual selected weekdays', () => {
    expect(fixedOccurrences({ taskId, anchor: '2026-09-16', rule: { v: 1, mode: 'fixed', freq: 'weekly', interval: 1, byWeekday: ['FR', 'MO'], count: 3 }, from: '2026-09-16', through: '2026-10-01' }).map((row) => row.occurrenceKey)).toEqual(['2026-09-18', '2026-09-21', '2026-09-25']);
  });
  it('counts a future origin moved into the missed interval exactly once', () => {
    expect(countMissedFixed({ anchor: '2026-09-17', rule: daily, beforeDate: '2026-09-19', materialized: [{ occurrenceKey: '2026-09-20', status: 'open', overrideDate: '2026-09-18' }] })).toEqual({ count: 3, latestOccurrenceKey: '2026-09-20' });
  });
  it('keeps a moved occurrence identity and distinguishes after-completion cycles', () => {
    expect(occurrenceId(taskId.toUpperCase(), '2026-09-17')).toBe('9cd7f856-8c30-5059-ab6a-6a80545780d1');
    expect(occurrenceId(taskId, '2026-09-17~0')).not.toBe(occurrenceId(taskId, '2026-09-17~1'));
    expect(occurrenceDate('2026-09-17~1')).toBe('2026-09-17');
    expect(afterCompletionKey('2026-09-17', 0)).toBe('2026-09-17~0');
    expect(nextAfterCompletionKey('2026-09-17~0', '2026-09-16')).toBe('2026-09-16~1');
  });
  it.each(['2026-09-17~-1', '2026-09-17~01', '2026-09-17~1~2', '2026-02-30~0', '2026-09-17~9007199254740992'])('rejects invalid occurrence key %s', (key) => expect(occurrenceKeySchema.safeParse(key).success).toBe(false));
});
