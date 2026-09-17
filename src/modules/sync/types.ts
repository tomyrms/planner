import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type pg from 'pg';
import type { CommandType, Precondition } from './commands.js';

export type Origin = 'manual' | 'assistant' | 'undo';
export interface CommandActor { userId: string; deviceId: string | null; origin: Origin }

export type RejectionCode =
  | 'VALIDATION_FAILED' | 'ENTITY_NOT_FOUND' | 'ENTITY_PURGED' | 'ENTITY_ALREADY_EXISTS' | 'TASK_DELETED'
  | 'PROJECT_DELETED' | 'REVISION_MISMATCH' | 'DEPENDENCY_REJECTED' | 'REMINDER_BASE_MISSING'
  | 'RECURRING_TASK_DEADLINE_UNSUPPORTED' | 'OCCURRENCE_NOT_IN_SERIES' | 'OCCURRENCE_NOT_CURRENT'
  | 'SUCCESSOR_ALREADY_CHANGED' | 'SERIES_COMMAND_REQUIRED' | 'NOT_A_SERIES' | 'SERIES_ENDED'
  | 'IDEMPOTENCY_KEY_REUSED' | 'FORBIDDEN_REFERENCE' | 'PAYLOAD_VERSION_UNSUPPORTED'
  | 'SUBTASKS_ON_RECURRING_TASK' | 'SUBTASK_NOT_FOUND' | 'SUBTASK_ALREADY_EXISTS' | 'SUBTASK_LIMIT_REACHED'
  | 'TAG_DELETED' | 'TAG_NAME_TAKEN' | 'TAG_LIMIT_REACHED' | 'TASK_TAG_LIMIT_REACHED';

export const rejectionMessages: Record<RejectionCode, string> = {
  VALIDATION_FAILED: 'The command payload is not valid.',
  ENTITY_NOT_FOUND: 'The target does not exist.',
  ENTITY_PURGED: 'The target was permanently removed.',
  ENTITY_ALREADY_EXISTS: 'An entity with this identifier already exists.',
  TASK_DELETED: 'The task is in the trash.',
  PROJECT_DELETED: 'The list is in the trash.',
  REVISION_MISMATCH: 'The target changed since it was read.',
  DEPENDENCY_REJECTED: 'A previous command this one depends on was not applied.',
  REMINDER_BASE_MISSING: 'The reminder needs a date or time that the task does not have.',
  RECURRING_TASK_DEADLINE_UNSUPPORTED: 'Repeating tasks cannot have a deadline yet.',
  OCCURRENCE_NOT_IN_SERIES: 'This occurrence is not part of the series.',
  OCCURRENCE_NOT_CURRENT: 'Only the open, current occurrence can be changed.',
  SUCCESSOR_ALREADY_CHANGED: 'The next occurrence has already changed.',
  SERIES_COMMAND_REQUIRED: 'Use an occurrence or series command for a repeating task.',
  NOT_A_SERIES: 'The task does not repeat.',
  SERIES_ENDED: 'The series has ended.',
  IDEMPOTENCY_KEY_REUSED: 'This command identifier was already used for different content.',
  FORBIDDEN_REFERENCE: 'A referenced entity is not available.',
  PAYLOAD_VERSION_UNSUPPORTED: 'This command type or version is not supported.',
  SUBTASKS_ON_RECURRING_TASK: 'Repeating tasks cannot have subtasks yet.',
  SUBTASK_NOT_FOUND: 'This subtask does not exist.',
  SUBTASK_ALREADY_EXISTS: 'A subtask with this identifier already exists.',
  SUBTASK_LIMIT_REACHED: 'A task can have at most 50 subtasks.',
  TAG_DELETED: 'The tag was deleted.',
  TAG_NAME_TAKEN: 'An active tag already uses this name.',
  TAG_LIMIT_REACHED: 'The tag catalog can have at most 200 active tags.',
  TASK_TAG_LIMIT_REACHED: 'A task can have at most 10 tags.',
};

/** Thrown by handlers; the executor rolls back the handler's writes and stores the rejection. */
export class CommandRejection extends Error {
  constructor(public readonly code: RejectionCode, public readonly currentRevision?: number) {
    super(rejectionMessages[code]);
  }
}

/** What a receipt stores and what a duplicate replays. */
export type StoredOutcome =
  | ({ outcome: 'applied'; revision: number; aggregateId: string } & Record<string, unknown>)
  | { outcome: 'rejected'; code: RejectionCode; message: string; currentRevision?: number };

export type CommandResult =
  | ({ clientCommandId: string } & StoredOutcome)
  | { clientCommandId: string; outcome: 'duplicate'; original: StoredOutcome };

export interface CommandContext {
  client: pg.PoolClient;
  db: NodePgDatabase;
  actor: CommandActor;
  commandId: string;
  type: CommandType;
  /** Lowercase UUID of the aggregate named by the command. */
  aggregateId: string;
  /** Payload already parsed by the schema of `type`. */
  payload: unknown;
  precondition: Precondition;
  /** Client action time, never later than the server clock + 5 minutes. */
  recordedAt: string;
  now: Date;
  /** Revision of the locked aggregate, attached to any rejection (02_API_Contract.md §3.1). */
  observedRevision: number | undefined;
  /** Throws REVISION_MISMATCH / DEPENDENCY_REJECTED when the precondition does not hold. */
  checkPrecondition(currentRevision: number): Promise<void>;
}

/** `noop: true` marks an accepted command that changed nothing (revision unchanged). */
export interface HandlerResult { revision: number; [key: string]: unknown }
export type Handler = (context: CommandContext) => Promise<HandlerResult>;
