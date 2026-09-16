import { createHash } from 'node:crypto';
import { Temporal } from '@js-temporal/polyfill';
import { and, eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import type pg from 'pg';
import { z } from 'zod';
import { commandReceipts, taskOccurrences, tasks } from '../../infrastructure/db/schema.js';
import { afterCompletionKey, afterCompletionRecurrenceSchema, closeAfterCompletion, occurrenceId, occurrenceKeySchema, timeZoneSchema } from '../time/index.js';

const commandSchema = z.object({
  userId: z.uuid(), commandId: z.uuid(), taskId: z.uuid(),
  deviceId: z.uuid().optional(), origin: z.enum(['manual','assistant','undo']).default('manual'),
  occurrenceKey: occurrenceKeySchema.refine((key) => key.includes('~'), 'After-completion keys include a cycle ordinal'),
  action: z.enum(['complete','skip','reopen']),
  referenceInstant: z.string().refine((value) => { try { Temporal.Instant.from(value); return true; } catch { return false; } }),
  deviceTimeZone: timeZoneSchema,
  expectedRevision: z.string().regex(/^[1-9][0-9]*$/).optional(),
}).strict();

export type AfterCompletionCommand = z.input<typeof commandSchema>;
export interface DomainReceipt {
  outcome: 'applied' | 'rejected' | 'duplicate';
  receiptOutcome: 'applied' | 'rejected';
  result: Record<string, unknown>;
}

/** Internal domain operation, not a sync endpoint. userId comes from trusted auth.
 * Lock order: command key, then aggregate; all callers modifying this aggregate
 * must acquire the task lock. A virtual successor is stored once on its parent.
 */
export async function mutateAfterCompletion(pool: pg.Pool, input: AfterCompletionCommand): Promise<DomainReceipt> {
  const command = commandSchema.parse(input);
  const payloadHash = createHash('sha256').update(JSON.stringify({
    userId: command.userId, taskId: command.taskId, occurrenceKey: command.occurrenceKey,
    action: command.action, referenceInstant: Temporal.Instant.from(command.referenceInstant).toString(),
    deviceTimeZone: command.deviceTimeZone, expectedRevision: command.expectedRevision ?? null,
    deviceId: command.deviceId ?? null, origin: command.origin,
  })).digest('hex');
  const client = await pool.connect();
  const db = drizzle(client);
  try {
    await client.query('BEGIN');
    await client.query("SELECT pg_advisory_xact_lock(hashtextextended('planner:command:' || $1, 0))", [command.commandId]);
    const [existingReceipt] = await db.select().from(commandReceipts).where(eq(commandReceipts.clientCommandId, command.commandId));
    if (existingReceipt) {
      await client.query('COMMIT');
      return existingReceipt.userId === command.userId && existingReceipt.payloadHash === payloadHash
        ? { outcome: 'duplicate', receiptOutcome: existingReceipt.outcome, result: existingReceipt.result }
        : { outcome: 'rejected', receiptOutcome: 'rejected', result: { code: 'IDEMPOTENCY_KEY_REUSED' } };
    }
    const finish = async (outcome: DomainReceipt['outcome'], result: Record<string, unknown>): Promise<DomainReceipt> => {
      const receiptOutcome = outcome === 'rejected' ? 'rejected' : 'applied';
      await db.insert(commandReceipts).values({
        clientCommandId: command.commandId, userId: command.userId, deviceId: command.deviceId ?? null,
        origin: command.origin, commandType: `occurrence.${command.action}`, payloadHash, outcome: receiptOutcome, result,
      });
      await client.query('COMMIT');
      return { outcome, receiptOutcome, result };
    };
    const [task] = await db.select().from(tasks)
      .where(and(eq(tasks.id, command.taskId), eq(tasks.userId, command.userId))).for('update');
    if (!task) return await finish('rejected', { code: 'ENTITY_NOT_FOUND' });
    if (task.deletedAt !== null) return await finish('rejected', { code: 'TASK_DELETED' });
    if (task.status !== 'active') return await finish('rejected', { code: 'SERIES_COMPLETED' });
    const rule = afterCompletionRecurrenceSchema.safeParse(task.recurrence);
    if (!rule.success || task.scheduledDate === null) return await finish('rejected', { code: 'NOT_AFTER_COMPLETION_SERIES' });
    const occurrences = await db.select().from(taskOccurrences)
      .where(and(eq(taskOccurrences.taskId, task.id), eq(taskOccurrences.userId, command.userId)));
    const byKey = new Map(occurrences.map((row) => [row.occurrenceKey, row]));
    const existing = byKey.get(command.occurrenceKey);
    const resultFor = (status: string, successorOccurrenceKey: string | null, revision: bigint): Record<string, unknown> => ({
      taskId: task.id, occurrenceId: occurrenceId(task.id, command.occurrenceKey),
      occurrenceKey: command.occurrenceKey, status, successorOccurrenceKey, revision: revision.toString(),
    });
    // A second complete/skip wins no race and produces no new revision.
    if (command.action !== 'reopen' && existing && existing.status !== 'open') {
      return await finish('duplicate', resultFor(existing.status, existing.successorOccurrenceKey, task.revision));
    }
    if (command.expectedRevision !== undefined && command.expectedRevision !== task.revision.toString()) {
      return await finish('rejected', { code: 'REVISION_MISMATCH', currentRevision: task.revision.toString() });
    }
    let current = afterCompletionKey(task.scheduledDate, 0);
    const visited = new Set<string>();
    while (byKey.get(current)?.status !== undefined && byKey.get(current)?.status !== 'open') {
      if (visited.has(current)) throw new Error('Invalid occurrence chain cycle');
      visited.add(current);
      const next = byKey.get(current)!.successorOccurrenceKey;
      if (next === null) throw new Error('Closed after-completion occurrence is missing its successor');
      current = next;
    }
    if (command.action === 'reopen') {
      if (!existing || existing.status === 'open') {
        if (current !== command.occurrenceKey) return await finish('rejected', { code: 'OCCURRENCE_NOT_CURRENT' });
        return await finish('duplicate', resultFor('open', null, task.revision));
      }
      if (existing.successorOccurrenceKey && byKey.has(existing.successorOccurrenceKey)) {
        return await finish('rejected', { code: 'SUCCESSOR_ALREADY_CHANGED' });
      }
    } else if (current !== command.occurrenceKey) {
      return await finish('rejected', { code: 'OCCURRENCE_NOT_CURRENT' });
    }
    const state = command.action === 'reopen'
      ? { status: 'open' as const, completedAt: null, successorOccurrenceKey: null }
      : closeAfterCompletion({
        state: { occurrenceKey: command.occurrenceKey, status: 'open', completedAt: null, successorOccurrenceKey: null },
        rule: rule.data, referenceInstant: command.referenceInstant, deviceTimeZone: command.deviceTimeZone, action: command.action,
      }).state;
    const now = new Date().toISOString();
    if (existing) {
      await db.update(taskOccurrences).set({ status: state.status, completedAt: state.completedAt, successorOccurrenceKey: state.successorOccurrenceKey, updatedAt: now })
        .where(and(eq(taskOccurrences.id, existing.id), eq(taskOccurrences.userId, command.userId)));
    } else {
      await db.insert(taskOccurrences).values({ id: occurrenceId(task.id, command.occurrenceKey), userId: command.userId, taskId: task.id,
        occurrenceKey: command.occurrenceKey, status: state.status, completedAt: state.completedAt, successorOccurrenceKey: state.successorOccurrenceKey });
    }
    const revision = task.revision + 1n;
    await db.update(tasks).set({ revision, updatedAt: now }).where(and(eq(tasks.id, task.id), eq(tasks.userId, command.userId)));
    return await finish('applied', resultFor(state.status, state.successorOccurrenceKey, revision));
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
