import { z } from 'zod';
import { civilDateSchema, durationMinutesSchema, occurrenceKeySchema, recurrenceSchema, timeValueSchema } from '../time/index.js';

export const MAX_IMPORT_BYTES = 20 * 1024 * 1024;
export const MAX_IMPORT_COMMANDS = 500;
const uuid = z.uuid().transform((value) => value.toLowerCase());
// PowerSync exports PostgreSQL timestamptz with a space separator; server exports use T.
const timestamp = z.string().transform((value) => value.replace(/^(\d{4}-\d{2}-\d{2}) /, '$1T')).pipe(z.iso.datetime({ offset: true }));
const maybeTimestamp = timestamp.nullable().optional();
const metadata = {
  revision: z.number().int().min(0).optional(), createdAt: maybeTimestamp, updatedAt: maybeTimestamp,
  deletedAt: maybeTimestamp, deletedByCommandId: uuid.nullable().optional(),
};
export const sourceProjectSchema = z.strictObject({
  id: uuid, name: z.string().trim().min(1).max(200), colorKey: z.string().min(1).max(64).nullable().optional(),
  sortOrder: z.number().finite().nullable().optional(), archivedAt: maybeTimestamp, ...metadata,
});
export const sourceTagSchema = z.strictObject({ id: uuid, name: z.string().trim().min(1).max(50), ...metadata });
export const sourceSubtaskSchema = z.strictObject({
  id: uuid, title: z.string().trim().min(1).max(500), isCompleted: z.boolean(), sortOrder: z.number().finite(),
});
export const sourceTaskSchema = z.strictObject({
  id: uuid, title: z.string().trim().min(1).max(500), notes: z.string().max(10_000).nullable(),
  projectId: uuid.nullable(), priority: z.enum(['none', 'low', 'medium', 'high']), status: z.enum(['active', 'completed']),
  completedAt: timestamp.nullable(), schedule: timeValueSchema.nullable(), deadline: timeValueSchema.nullable(),
  durationMinutes: durationMinutesSchema, recurrence: recurrenceSchema.nullable(),
  missedIgnoredBefore: civilDateSchema.nullable().optional(), subtasks: z.array(sourceSubtaskSchema).max(50).optional(),
  ...metadata,
}).refine((value) => (value.status === 'completed') === (value.completedAt !== null), 'Inconsistent completion');
export const sourceTaskTagSchema = z.strictObject({
  id: uuid, taskId: uuid, tagId: uuid, deletedAt: maybeTimestamp, createdAt: maybeTimestamp, updatedAt: maybeTimestamp,
});
export const sourceReminderSchema = z.strictObject({
  id: uuid, taskId: uuid, occurrenceKey: occurrenceKeySchema.nullable(),
  kind: z.enum(['before_start', 'on_scheduled_day_at', 'before_deadline', 'on_deadline_day_at', 'absolute']),
  offsetMinutes: z.number().int().nullable(), localTime: z.string().nullable(), absolute: timeValueSchema.nullable(),
  state: z.enum(['active', 'inactive_base_missing']), deletedAt: maybeTimestamp,
  createdAt: maybeTimestamp, updatedAt: maybeTimestamp,
}).refine((value) => {
  if (value.kind === 'before_start' || value.kind === 'before_deadline') {
    return value.offsetMinutes !== null && value.localTime === null && value.absolute === null;
  }
  if (value.kind === 'on_scheduled_day_at' || value.kind === 'on_deadline_day_at') {
    return value.offsetMinutes === null && value.localTime !== null && value.absolute === null;
  }
  return value.offsetMinutes === null && value.localTime === null && value.absolute?.time != null;
}, 'Inconsistent reminder fields');

// Excluded categories are opaque JSON. They are counted and never copied into a plan or interpreted.
const opaqueRows = z.array(z.unknown()).max(100_000);
export const sourceExportSchema = z.strictObject({
  exportVersion: z.literal(1), taskDetailsVersion: z.literal(1).optional(),
  localExportVersion: z.literal(1).optional(), exportSource: z.literal('iphone').optional(),
  exportedAt: timestamp, serverGeneration: uuid.nullable().optional(),
  projects: opaqueRows, tasks: opaqueRows, tags: opaqueRows.optional(), taskTags: opaqueRows.optional(),
  reminders: opaqueRows, taskOccurrences: opaqueRows, conversations: opaqueRows,
  assistantSettings: z.unknown().optional(), localState: z.unknown().optional(),
  unlinkedMessages: opaqueRows.optional(), pendingCommands: opaqueRows.optional(), syncRejections: opaqueRows.optional(),
  drafts: z.unknown().optional(),
}).refine((value) => (value.localExportVersion === 1) === (value.exportSource === 'iphone'), 'Incomplete local export identity');

export const selectionSchema = z.strictObject({
  taskIds: z.array(uuid).max(500), projectIds: z.array(uuid).max(500), tagIds: z.array(uuid).max(200),
  tagNames: z.record(z.uuid(), z.string().trim().min(1).max(50))
    .refine((values) => new Set(Object.keys(values).map((key) => key.toLowerCase())).size === Object.keys(values).length)
    .transform((values) => Object.fromEntries(Object.entries(values).map(([key, value]) => [key.toLowerCase(), value]))).optional(),
  restartSeries: z.record(z.uuid(), timeValueSchema)
    .refine((values) => new Set(Object.keys(values).map((key) => key.toLowerCase())).size === Object.keys(values).length)
    .transform((values) => Object.fromEntries(Object.entries(values).map(([key, value]) => [key.toLowerCase(), value]))).optional(),
});
export type ImportSelection = z.infer<typeof selectionSchema>;
export type SourceExport = z.infer<typeof sourceExportSchema>;

/** Errors are fixed codes and optional identifiers, never Zod values, SQL details or imported content. */
export class ImportError extends Error {
  constructor(readonly importCode: string, readonly sourceId?: string) {
    super(`${importCode}${sourceId ? ` (${sourceId})` : ''}`);
  }
}

export function checked<T>(schema: z.ZodType<T>, value: unknown, code: string, sourceId?: string): T {
  const result = schema.safeParse(value);
  if (!result.success) throw new ImportError(code, sourceId);
  return result.data;
}

/** Repeated source IDs make selection ambiguous even if their fields happen to match. */
export function sourceRows(rows: readonly unknown[]): Map<string, unknown> {
  const result = new Map<string, unknown>();
  for (const row of rows) {
    const key = checked(z.object({ id: uuid }), row, 'IMPORT_INVALID_SOURCE_ID').id;
    if (result.has(key)) throw new ImportError('IMPORT_DUPLICATE_SOURCE_ID', key);
    result.set(key, row);
  }
  return result;
}
