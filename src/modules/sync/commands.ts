import { z } from 'zod';
import {
  civilDateSchema, durationMinutesSchema, occurrenceKeySchema, recurrenceSchema,
  reminderRuleSchema, timeValueSchema,
} from '../time/index.js';

/** Transport-level shape. A violation here is a protocol error (HTTP 400), not a business rejection. */
export const preconditionSchema = z.discriminatedUnion('kind', [
  z.strictObject({ kind: z.literal('none') }),
  z.strictObject({ kind: z.literal('revision'), revision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER) }),
  z.strictObject({ kind: z.literal('afterCommand'), clientCommandId: z.uuid() }),
]);
export type Precondition = z.infer<typeof preconditionSchema>;

export const rawCommandSchema = z.strictObject({
  clientCommandId: z.uuid(),
  type: z.string().min(1).max(64),
  payloadVersion: z.number().int().min(1).max(1000),
  aggregate: z.strictObject({ type: z.enum(['task', 'project', 'tag', 'settings']), id: z.uuid() }),
  precondition: preconditionSchema.optional(),
  clientRecordedAt: z.iso.datetime({ offset: true }),
  payload: z.record(z.string(), z.unknown()).optional(),
});
export type RawCommand = z.infer<typeof rawCommandSchema>;

export const MAX_COMMANDS_PER_ENVELOPE = 100;
export const envelopeSchema = z.strictObject({
  envelopeVersion: z.literal(1),
  serverGeneration: z.uuid(),
  commands: z.array(rawCommandSchema).min(1).max(MAX_COMMANDS_PER_ENVELOPE),
});
export type Envelope = z.infer<typeof envelopeSchema>;

const title = z.string().trim().min(1).max(500);
const notes = z.string().max(10_000);
const priority = z.enum(['none', 'low', 'medium', 'high']);
const reminderInput = z.strictObject({
  id: z.uuid(),
  rule: reminderRuleSchema,
  occurrenceKey: occurrenceKeySchema.nullable().optional(),
});
const nonEmpty = (value: Record<string, unknown>) => Object.keys(value).length > 0;
const projectName = z.string().trim().min(1).max(200);
const colorKey = z.string().min(1).max(64);
const sortOrder = z.number().finite();
const subtaskInput = z.strictObject({ id: z.uuid(), title, isCompleted: z.boolean().optional(), sortOrder: sortOrder.optional() });
const tagName = z.string().trim().min(1).max(50);

/** Payload schemas for payloadVersion 1. A missing type/version pair is rejected explicitly. */
export const payloadSchemasV1 = {
  'task.create': z.strictObject({
    title,
    notes: notes.nullable().optional(),
    priority: priority.optional(),
    projectId: z.uuid().nullable().optional(),
    schedule: timeValueSchema.nullable().optional(),
    deadline: timeValueSchema.nullable().optional(),
    durationMinutes: durationMinutesSchema.optional(),
    recurrence: recurrenceSchema.nullable().optional(),
    reminders: z.array(reminderInput).max(10).optional(),
    subtasks: z.array(subtaskInput).max(50).optional(),
    tagIds: z.array(z.uuid()).max(10).optional(),
  }),
  'task.patch': z.strictObject({
    set: z.strictObject({
      title: title.optional(),
      notes: notes.nullable().optional(),
      priority: priority.optional(),
      projectId: z.uuid().nullable().optional(),
      schedule: timeValueSchema.nullable().optional(),
      deadline: timeValueSchema.nullable().optional(),
      durationMinutes: durationMinutesSchema.optional(),
    }).refine(nonEmpty, 'Empty patch'),
  }),
  'task.complete': z.strictObject({}),
  'task.reopen': z.strictObject({}),
  'task.delete': z.strictObject({}),
  'task.restore': z.strictObject({}),
  'task.subtask.add': z.strictObject({ subtask: subtaskInput }),
  'task.subtask.patch': z.strictObject({ subtaskId: z.uuid(), set: z.strictObject({
    title: title.optional(), isCompleted: z.boolean().optional(), sortOrder: sortOrder.optional(),
  }).refine(nonEmpty, 'Empty patch') }),
  'task.subtask.remove': z.strictObject({ subtaskId: z.uuid() }),
  'task.tag.add': z.strictObject({ tagId: z.uuid() }),
  'task.tag.remove': z.strictObject({ tagId: z.uuid() }),
  'occurrence.complete': z.strictObject({ occurrenceKey: occurrenceKeySchema, actionLocalDate: civilDateSchema }),
  'occurrence.skip': z.strictObject({ occurrenceKey: occurrenceKeySchema, actionLocalDate: civilDateSchema }),
  'occurrence.reopen': z.strictObject({ occurrenceKey: occurrenceKeySchema }),
  'occurrence.reschedule': z.strictObject({ occurrenceKey: occurrenceKeySchema, schedule: timeValueSchema.nullable() }),
  'occurrence.skip_missed_before': z.strictObject({ occurrenceKey: occurrenceKeySchema }),
  'series.update': z.strictObject({
    recurrence: recurrenceSchema.optional(),
    set: z.strictObject({
      title: title.optional(),
      notes: notes.nullable().optional(),
      priority: priority.optional(),
      projectId: z.uuid().nullable().optional(),
      durationMinutes: durationMinutesSchema.optional(),
      schedule: timeValueSchema.optional(),
    }).refine(nonEmpty, 'Empty series patch').optional(),
  }).refine((value) => value.recurrence !== undefined || value.set !== undefined, 'Empty series update'),
  'series.end': z.strictObject({}),
  'reminder.set': reminderInput,
  'reminder.remove': z.strictObject({ id: z.uuid() }),
  'project.create': z.strictObject({ name: projectName, colorKey: colorKey.nullable().optional(), sortOrder: sortOrder.nullable().optional() }),
  'project.patch': z.strictObject({
    set: z.strictObject({ name: projectName.optional(), colorKey: colorKey.nullable().optional(), sortOrder: sortOrder.nullable().optional() }).refine(nonEmpty, 'Empty patch'),
  }),
  'project.archive': z.strictObject({}),
  'project.unarchive': z.strictObject({}),
  'project.delete': z.strictObject({ taskPolicy: z.enum(['move_tasks_to_inbox', 'trash_tasks_with_project']) }),
  'project.restore': z.strictObject({}),
  'tag.create': z.strictObject({ name: tagName }),
  'tag.patch': z.strictObject({ set: z.strictObject({ name: tagName }) }),
  'tag.delete': z.strictObject({}),
  'tag.restore': z.strictObject({}),
  'settings.patch': z.strictObject({ set: z.strictObject({ autoTags: z.boolean() }) }),
} as const;

export type CommandType = keyof typeof payloadSchemasV1;
export type PayloadOf<T extends CommandType> = z.infer<(typeof payloadSchemasV1)[T]>;

export const commandAggregate: Record<CommandType, RawCommand['aggregate']['type']> = {
  'task.create': 'task', 'task.patch': 'task', 'task.complete': 'task', 'task.reopen': 'task',
  'task.delete': 'task', 'task.restore': 'task',
  'task.subtask.add': 'task', 'task.subtask.patch': 'task', 'task.subtask.remove': 'task',
  'task.tag.add': 'task', 'task.tag.remove': 'task',
  'occurrence.complete': 'task', 'occurrence.skip': 'task', 'occurrence.reopen': 'task',
  'occurrence.reschedule': 'task', 'occurrence.skip_missed_before': 'task',
  'series.update': 'task', 'series.end': 'task', 'reminder.set': 'task', 'reminder.remove': 'task',
  'project.create': 'project', 'project.patch': 'project', 'project.archive': 'project',
  'project.unarchive': 'project', 'project.delete': 'project', 'project.restore': 'project',
  'tag.create': 'tag', 'tag.patch': 'tag', 'tag.delete': 'tag', 'tag.restore': 'tag', 'settings.patch': 'settings',
};

/** Commands whose risk requires the client to prove what it last saw. */
export const preconditionRequired = new Set<CommandType>(['series.update', 'series.end', 'project.delete']);
/** Creation cannot depend on an earlier state. */
export const preconditionForbidden = new Set<CommandType>(['task.create', 'project.create', 'tag.create']);

export function isCommandType(type: string): type is CommandType {
  return Object.hasOwn(payloadSchemasV1, type);
}
