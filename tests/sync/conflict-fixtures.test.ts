import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { executeCommand, type CommandActor, type RawCommand } from '../../src/modules/sync/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { RECORDED_AT, taskRow } from './helpers.js';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
interface FixtureCommand { type: string; aggregate: string; payloadVersion?: number; precondition?: Json; payload?: Json }
interface Step {
  id?: string;
  as?: 'other';
  command?: FixtureCommand;
  replay?: string;
  payload?: Json;
  expect: { [key: string]: Json };
  state?: Record<string, { [key: string]: Json }>;
}
interface Fixture { version: number; cases: Array<{ id: string; description: string; steps: Step[] }> }

const fixture = JSON.parse(readFileSync(new URL('../../fixtures/sync/conflicts-v1.json', import.meta.url), 'utf8')) as Fixture;
const SYMBOL = /^(task|project|reminder|cmd):[a-z0-9_-]+$/;

describe(`sync conflict fixtures v${fixture.version}`, () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let actor: CommandActor;
  let other: CommandActor;
  const clock = () => new Date('2026-09-16T08:30:00Z');

  beforeAll(async () => {
    db = await createTestDatabase();
    const insertUser = async () => (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    actor = { userId: await insertUser(), deviceId: null, origin: 'manual' };
    other = { userId: await insertUser(), deviceId: null, origin: 'manual' };
  });
  afterAll(async () => { await db?.close(); });

  it('lists unique case identifiers', () => {
    const ids = fixture.cases.map((item) => item.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids.length).toBeGreaterThanOrEqual(12);
  });

  for (const scenario of fixture.cases) {
    it(`${scenario.id}: ${scenario.description}`, async () => {
      const symbols = new Map<string, string>();
      const resolve = (value: Json): Json => {
        if (typeof value === 'string' && SYMBOL.test(value)) {
          if (!symbols.has(value)) symbols.set(value, randomUUID());
          return symbols.get(value)!;
        }
        if (Array.isArray(value)) return value.map(resolve);
        if (value !== null && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, resolve(item)]));
        return value;
      };
      const sent = new Map<string, RawCommand>();
      for (const [index, step] of scenario.steps.entries()) {
        let input: RawCommand;
        if (step.replay !== undefined) {
          const original = sent.get(step.replay);
          if (!original) throw new Error(`Unknown replay ${step.replay}`);
          input = step.payload === undefined ? original : { ...original, payload: resolve(step.payload) as Record<string, unknown> };
        } else {
          const { type, aggregate, payloadVersion, precondition, payload } = step.command!;
          input = {
            clientCommandId: step.id === undefined ? randomUUID() : resolve(`cmd:${step.id}`) as string,
            type,
            payloadVersion: payloadVersion ?? 1,
            aggregate: { type: aggregate.startsWith('project:') ? 'project' : 'task', id: resolve(aggregate) as string },
            clientRecordedAt: RECORDED_AT,
            ...(precondition === undefined ? {} : { precondition: resolve(precondition) as RawCommand['precondition'] }),
            ...(payload === undefined ? {} : { payload: resolve(payload) as Record<string, unknown> }),
          };
          if (step.id !== undefined) sent.set(step.id, input);
        }
        const result = await executeCommand(db.pool, step.as === 'other' ? other : actor, input, clock);
        expect(result, `${scenario.id} step ${index + 1}`).toMatchObject(resolve(step.expect) as object);
        for (const [symbol, columns] of Object.entries(step.state ?? {})) {
          expect(await taskRow(db.pool, resolve(symbol) as string), `${scenario.id} step ${index + 1} ${symbol}`).toMatchObject(columns);
        }
      }
    });
  }
});
