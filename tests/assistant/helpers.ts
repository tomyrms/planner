import { randomUUID } from 'node:crypto';
import type pg from 'pg';
import { AssistantService, ScriptedProvider, type AssistantLimits, type Identity, type ReasoningProvider, type ScriptStep } from '../../src/modules/assistant/index.js';
import { executeCommand, type RawCommand } from '../../src/modules/sync/index.js';

export const ZONE = 'Europe/Zurich';
/** Wednesday 16 September 2026, 18:42 in Zurich. */
export const REFERENCE_INSTANT = '2026-09-16T18:42:00+02:00';
export const TODAY = '2026-09-16';
export const TOMORROW = '2026-09-17';
export const NOW = new Date('2026-09-16T16:45:00Z');

export function turnRequest(text: string, overrides: Record<string, unknown> = {}) {
  return {
    turnId: randomUUID(),
    conversationId: randomUUID(),
    message: { id: randomUUID(), text, transcriptionId: null, revisesMessageId: null },
    referenceInstant: REFERENCE_INSTANT,
    timeZone: ZONE,
    unsyncedAggregateIds: [] as string[],
    calendarContext: null,
    ...overrides,
  };
}

export function assistantFor(pool: pg.Pool, provider: ReasoningProvider | readonly ScriptStep[], options: { clock?: () => Date; limits?: Partial<AssistantLimits> } = {}) {
  const resolved = Array.isArray(provider) ? new ScriptedProvider(provider) : provider as ReasoningProvider;
  const service = new AssistantService(pool, resolved, { clock: options.clock ?? (() => NOW), ...(options.limits ? { limits: options.limits } : {}) });
  return { service, provider: resolved };
}

export async function ask(service: AssistantService, identity: Identity, text: string, overrides: Record<string, unknown> = {}) {
  const request = turnRequest(text, overrides);
  await service.submitTurn(identity, request);
  const snapshot = await service.run(identity, request.turnId) as Record<string, any>;
  return { request, snapshot };
}

export async function seedTask(pool: pg.Pool, userId: string, payload: Record<string, unknown>, id = randomUUID()): Promise<string> {
  const command: RawCommand = {
    clientCommandId: randomUUID(), type: 'task.create', payloadVersion: 1,
    aggregate: { type: 'task', id }, clientRecordedAt: '2026-09-16T08:00:00Z', payload,
  };
  const result = await executeCommand(pool, { userId, deviceId: null, origin: 'manual' }, command, () => NOW);
  if (result.outcome !== 'applied') throw new Error(`seed failed: ${JSON.stringify(result)}`);
  return id;
}

export async function manual(pool: pg.Pool, userId: string, type: string, id: string, payload?: Record<string, unknown>) {
  return executeCommand(pool, { userId, deviceId: null, origin: 'manual' }, {
    clientCommandId: randomUUID(), type, payloadVersion: 1,
    aggregate: { type: type.startsWith('project.') ? 'project' : 'task', id }, clientRecordedAt: '2026-09-16T16:44:00Z',
    ...(payload ? { payload } : {}),
  }, () => NOW);
}

export async function task(pool: pg.Pool, id: string) {
  const { rows: [row] } = await pool.query(`SELECT title, notes, status, priority, scheduled_date::text AS scheduled_date,
    scheduled_time::text AS scheduled_time, scheduled_time_zone, deleted_at, revision::int AS revision FROM tasks WHERE id = $1`, [id]);
  return row as Record<string, any> | undefined;
}

export async function count(pool: pg.Pool, sql: string, params: unknown[] = []): Promise<number> {
  return (await pool.query<{ n: number }>(`SELECT count(*)::int AS n FROM (${sql}) AS counted`, params)).rows[0]!.n;
}
