import { z } from 'zod';
import { civilDateSchema } from './values.js';

export const weekdaySchema = z.enum(['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU']);
const fixedBase = { v: z.literal(1), mode: z.literal('fixed'), interval: z.number().int().min(1).max(365), until: civilDateSchema.optional(), count: z.number().int().positive().max(3_652_059).optional() };
const endIsExclusive = (rule: { until?: string | undefined; count?: number | undefined }) => !(rule.until !== undefined && rule.count !== undefined);
export const fixedRecurrenceSchema = z.union([
  z.object({ ...fixedBase, freq: z.literal('daily') }).strict(),
  z.object({ ...fixedBase, freq: z.literal('weekly'), byWeekday: z.array(weekdaySchema).min(1).max(7).refine((days) => new Set(days).size === days.length, 'Duplicate weekday') }).strict(),
  z.object({ ...fixedBase, freq: z.literal('monthly'), byMonthDay: z.number().int().min(1).max(31) }).strict(),
  z.object({ ...fixedBase, freq: z.literal('monthly'), lastDayOfMonth: z.literal(true) }).strict(),
]).refine(endIsExclusive, 'Use either until or count, never both');
export const afterCompletionRecurrenceSchema = z.object({ v: z.literal(1), mode: z.literal('after_completion'), unit: z.enum(['day', 'week', 'month']), interval: z.number().int().min(1).max(365) }).strict();
export const recurrenceSchema = z.union([fixedRecurrenceSchema, afterCompletionRecurrenceSchema]);
export type FixedRecurrence = z.infer<typeof fixedRecurrenceSchema>;
export type AfterCompletionRecurrence = z.infer<typeof afterCompletionRecurrenceSchema>;
export type Recurrence = z.infer<typeof recurrenceSchema>;
export type RecurrenceRule = Recurrence;
