import { createHash } from 'node:crypto';
import { and, eq } from 'drizzle-orm';
import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import type pg from 'pg';
import { commandReceipts } from '../../infrastructure/db/schema.js';
import {
  commandAggregate, isCommandType, payloadSchemasV1, preconditionForbidden, preconditionRequired,
  type CommandType, type Precondition, type RawCommand,
} from './commands.js';
import { canonicalJson } from './canonical.js';
import { handlers } from './handlers/index.js';
import {
  CommandRejection, rejectionMessages,
  type CommandActor, type CommandContext, type CommandResult, type RejectionCode, type StoredOutcome,
} from './types.js';

export * from './types.js';
export { canonicalJson } from './canonical.js';

const RETRYABLE = new Set(['40P01', '40001']);
const MAX_ATTEMPTS = 3;
const CLOCK_SKEW_MS = 5 * 60 * 1000;

export function commandHash(command: RawCommand): string {
  const { clientCommandId: _id, ...content } = command;
  return createHash('sha256').update(canonicalJson(content)).digest('hex');
}

function reject(code: RejectionCode, currentRevision?: number): StoredOutcome {
  return { outcome: 'rejected', code, message: rejectionMessages[code], ...(currentRevision === undefined ? {} : { currentRevision }) };
}

/** Validation that needs no database: type/version, payload, precondition policy. */
function prevalidate(command: RawCommand): { type: CommandType; payload: unknown; precondition: Precondition } | StoredOutcome {
  if (command.payloadVersion !== 1 || !isCommandType(command.type)) return reject('PAYLOAD_VERSION_UNSUPPORTED');
  const type = command.type;
  if (commandAggregate[type] !== command.aggregate.type) return reject('VALIDATION_FAILED');
  const parsed = payloadSchemasV1[type].safeParse(command.payload ?? {});
  if (!parsed.success) return reject('VALIDATION_FAILED');
  const precondition = command.precondition ?? { kind: 'none' as const };
  if (preconditionRequired.has(type) && precondition.kind === 'none') return reject('VALIDATION_FAILED');
  if (preconditionForbidden.has(type) && precondition.kind !== 'none') return reject('VALIDATION_FAILED');
  return { type, payload: parsed.data, precondition };
}

async function withRetry<T>(work: () => Promise<T>): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await work();
    } catch (error) {
      const code = (error as { code?: unknown }).code;
      if (attempt < MAX_ATTEMPTS && typeof code === 'string' && RETRYABLE.has(code)) continue;
      throw error;
    }
  }
}

async function inTransaction<T>(pool: pg.Pool, work: (client: pg.PoolClient, db: NodePgDatabase) => Promise<{ value: T; commit: boolean }>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { value, commit } = await work(client, drizzle(client));
    await client.query(commit ? 'COMMIT' : 'ROLLBACK');
    return value;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

/**
 * Applies one command inside an open transaction: command lock, receipt, precondition, effect, receipt row.
 * A rejection leaves no effect (savepoint) but stores its receipt. Lock order for every writer:
 * command key, then lists, then tasks, then their rows.
 */
export async function applyCommandInTransaction(client: pg.PoolClient, db: NodePgDatabase, actor: CommandActor, command: RawCommand, now: Date): Promise<CommandResult> {
  const hash = commandHash(command);
  const clientCommandId = command.clientCommandId.toLowerCase();
  await client.query("SELECT pg_advisory_xact_lock(hashtextextended('planner:command:' || $1::uuid::text, 0))", [clientCommandId]);
  const [existing] = await db.select().from(commandReceipts).where(eq(commandReceipts.clientCommandId, clientCommandId));
  if (existing) {
    if (existing.userId !== actor.userId || existing.payloadHash !== hash) {
      return { clientCommandId: command.clientCommandId, ...reject('IDEMPOTENCY_KEY_REUSED') };
    }
    return { clientCommandId: command.clientCommandId, outcome: 'duplicate', original: { outcome: existing.outcome, ...existing.result } as StoredOutcome };
  }

  const store = async (outcome: StoredOutcome, commandType: string): Promise<CommandResult> => {
    const { outcome: receiptOutcome, ...result } = outcome;
    await db.insert(commandReceipts).values({
      clientCommandId, userId: actor.userId, deviceId: actor.deviceId,
      origin: actor.origin, commandType, payloadHash: hash, outcome: receiptOutcome, result,
    });
    return { clientCommandId: command.clientCommandId, ...outcome };
  };

  const checked = prevalidate(command);
  if ('outcome' in checked) return store(checked, command.type);

  const aggregateId = command.aggregate.id.toLowerCase();
  const recordedAtMs = Math.min(Date.parse(command.clientRecordedAt), now.getTime() + CLOCK_SKEW_MS);
  const context: CommandContext = {
    client, db, actor, commandId: clientCommandId, type: checked.type, aggregateId,
    payload: checked.payload, precondition: checked.precondition,
    recordedAt: new Date(recordedAtMs).toISOString(), now, observedRevision: undefined,
    checkPrecondition: (currentRevision) => checkPrecondition(db, actor.userId, aggregateId, checked.precondition, currentRevision),
  };
  await client.query('SAVEPOINT command_effect');
  try {
    const result = await handlers[checked.type](context);
    await client.query('RELEASE SAVEPOINT command_effect');
    return await store({ ...result, outcome: 'applied', revision: result.revision, aggregateId }, checked.type);
  } catch (error) {
    if (!(error instanceof CommandRejection)) throw error;
    await client.query('ROLLBACK TO SAVEPOINT command_effect');
    await client.query('RELEASE SAVEPOINT command_effect');
    return store(reject(error.code, error.currentRevision ?? context.observedRevision), checked.type);
  }
}

/** One command = one PostgreSQL transaction holding its effect and its receipt (ADR-015). */
export async function executeCommand(pool: pg.Pool, actor: CommandActor, command: RawCommand, clock: () => Date = () => new Date()): Promise<CommandResult> {
  return withRetry(() => inTransaction(pool, async (client, db) => ({
    value: await applyCommandInTransaction(client, db, actor, command, clock()),
    commit: true,
  })));
}

export interface PlanStep {
  command: RawCommand;
  result: CommandResult;
}

export interface PlanHooks<T> {
  /** Runs before each command, inside the transaction (e.g. a snapshot of the aggregate). */
  before?: (client: pg.PoolClient, command: RawCommand, index: number) => Promise<unknown>;
  /** Runs after each applied or duplicate command. */
  after?: (client: pg.PoolClient, step: PlanStep, index: number, before: unknown) => Promise<void>;
  /** Runs once every command applied, still inside the transaction (journal, messages…). */
  finish?: (client: pg.PoolClient, steps: PlanStep[]) => Promise<T>;
}

export type PlanRejection = { clientCommandId: string } & Extract<StoredOutcome, { outcome: 'rejected' }>;

export type PlanOutcome<T> =
  | { status: 'applied'; steps: PlanStep[]; value: T }
  | { status: 'rejected'; index: number; steps: PlanStep[]; rejection: PlanRejection };

/**
 * An assistant plan is all-or-nothing (04_AI_Orchestration.md §5): every command in one transaction.
 * The first rejection rolls everything back, receipts included, so a later retry is evaluated afresh.
 * With dryRun the transaction is always rolled back: validation and previews use the real handlers.
 */
export async function executePlan<T = undefined>(pool: pg.Pool, actor: CommandActor, commands: readonly RawCommand[], options: { clock?: () => Date; dryRun?: boolean; hooks?: PlanHooks<T> } = {}): Promise<PlanOutcome<T>> {
  const clock = options.clock ?? (() => new Date());
  return withRetry(() => inTransaction<PlanOutcome<T>>(pool, async (client, db) => {
    const now = clock();
    const steps: PlanStep[] = [];
    for (const [index, command] of commands.entries()) {
      const before = await options.hooks?.before?.(client, command, index);
      const result = await applyCommandInTransaction(client, db, actor, command, now);
      steps.push({ command, result });
      const rejection: PlanRejection | null = result.outcome === 'rejected'
        ? result
        : result.outcome === 'duplicate' && result.original.outcome === 'rejected'
          ? { clientCommandId: result.clientCommandId, ...result.original }
          : null;
      if (rejection) return { value: { status: 'rejected' as const, index, steps, rejection }, commit: false };
      await options.hooks?.after?.(client, { command, result }, index, before);
    }
    const value = (options.hooks?.finish ? await options.hooks.finish(client, steps) : undefined) as T;
    return { value: { status: 'applied' as const, steps, value }, commit: !options.dryRun };
  }));
}

async function checkPrecondition(db: NodePgDatabase, userId: string, aggregateId: string, precondition: Precondition, currentRevision: number): Promise<void> {
  if (precondition.kind === 'none') return;
  if (precondition.kind === 'revision') {
    if (precondition.revision !== currentRevision) throw new CommandRejection('REVISION_MISMATCH', currentRevision);
    return;
  }
  const [cited] = await db.select({ outcome: commandReceipts.outcome, result: commandReceipts.result })
    .from(commandReceipts)
    .where(and(eq(commandReceipts.clientCommandId, precondition.clientCommandId.toLowerCase()), eq(commandReceipts.userId, userId)));
  if (!cited || cited.outcome !== 'applied') throw new CommandRejection('DEPENDENCY_REJECTED', currentRevision);
  if (cited.result.aggregateId !== aggregateId || cited.result.revision !== currentRevision) {
    throw new CommandRejection('REVISION_MISMATCH', currentRevision);
  }
}
