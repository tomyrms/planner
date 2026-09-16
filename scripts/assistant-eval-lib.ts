// Shared runner for fixtures/assistant/eval-v1.json: the deterministic test (scripted model)
// and the live evaluation (npm run eval:assistant) check the same provider-independent expectations.
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Temporal } from '@js-temporal/polyfill';
import type pg from 'pg';
import {
  AssistantService, ProviderError, ScriptedProvider, callTools, reply, toolCall,
  type ProviderRequest, type ProviderResponse, type ReasoningProvider, type ScriptStep,
} from '../src/modules/assistant/index.js';
import { executeCommand } from '../src/modules/sync/index.js';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export interface EvalExpectation {
  tools: string[];
  live?: 'tools' | 'skip';
  status?: string;
  statusIn?: string[];
  riskClass?: string | null;
  riskClassIn?: Array<string | null>;
  created?: Array<Record<string, Json>>;
  unchanged?: string[];
  changed?: Record<string, Record<string, Json>>;
  occurrences?: Array<{ task: string; occurrence_key: string; status: string }>;
  proposalTargets?: string[];
  replyIncludes?: string[];
  forbidden?: string[];
}

export interface EvalCase {
  id: string;
  category: string;
  message: string;
  setup?: Array<{ name: string; payload: Record<string, Json> }>;
  expect: EvalExpectation;
  script: Array<{ call: Array<{ name: string; arguments: Json }> } | { reply: string } | { error: string }>;
}

export interface EvalSet { version: number; promptVersion: string; referenceInstant: string; timeZone: string; cases: EvalCase[] }

export interface CaseReport {
  id: string;
  category: string;
  passed: boolean;
  skipped: boolean;
  failures: string[];
  toolsCalled: string[];
  status: string;
  riskClass: string | null;
  durationMs: number;
  tokens: number;
}

export function loadEvalSet(path = new URL('../fixtures/assistant/eval-v1.json', import.meta.url)): EvalSet {
  return JSON.parse(readFileSync(path, 'utf8')) as EvalSet;
}

function resolver(set: EvalSet, tasks: Map<string, string>) {
  const today = Temporal.Instant.from(new Date(set.referenceInstant).toISOString()).toZonedDateTimeISO(set.timeZone).toPlainDate();
  const resolve = (value: Json): Json => {
    if (typeof value === 'string') {
      if (value === '$today') return today.toString();
      if (value === '$tomorrow') return today.add({ days: 1 }).toString();
      if (value.startsWith('$task:')) {
        const id = tasks.get(value.slice('$task:'.length));
        if (!id) throw new Error(`Unknown task symbol ${value}`);
        return id;
      }
      return value;
    }
    if (Array.isArray(value)) return value.map(resolve);
    if (value !== null && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, resolve(item)]));
    return value;
  };
  return resolve;
}

export function scriptFor(evalCase: EvalCase, resolve: (value: Json) => Json): ScriptStep[] {
  return evalCase.script.map((step) => {
    if ('call' in step) return callTools(...step.call.map((call) => toolCall(call.name, resolve(call.arguments))));
    if ('reply' in step) return reply(step.reply);
    return new ProviderError(step.error as ProviderError['code']);
  });
}

/** Records which tools the provider asked for, whatever the provider. */
class Recording implements ReasoningProvider {
  readonly tools: string[] = [];
  tokens = 0;
  constructor(private readonly inner: ReasoningProvider) {}
  get name() { return this.inner.name; }
  get model() { return this.inner.model; }
  async respond(request: ProviderRequest): Promise<ProviderResponse> {
    const response = await this.inner.respond(request);
    this.tools.push(...response.toolCalls.map((call) => call.name));
    this.tokens += response.usage.inputTokens + response.usage.outputTokens;
    return response;
  }
}

const matches = (actual: Record<string, unknown>, expected: Record<string, Json>) =>
  Object.entries(expected).every(([key, value]) => JSON.stringify(actual[key] ?? null) === JSON.stringify(value));

export async function runCase(pool: pg.Pool, set: EvalSet, evalCase: EvalCase, options: { live?: ReasoningProvider } = {}): Promise<CaseReport> {
  const started = Date.now();
  const skipped = options.live !== undefined && evalCase.expect.live === 'skip';
  const base = { id: evalCase.id, category: evalCase.category, skipped, toolsCalled: [] as string[], status: 'skipped', riskClass: null, durationMs: 0, tokens: 0 };
  if (skipped) return { ...base, passed: true, failures: [] };

  const userId = (await pool.query<{ id: string }>("INSERT INTO users (default_time_zone) VALUES ($1) RETURNING id", [set.timeZone])).rows[0]!.id;
  const tasks = new Map<string, string>();
  const resolve = resolver(set, tasks);
  for (const item of evalCase.setup ?? []) tasks.set(item.name, randomUUID());
  for (const item of evalCase.setup ?? []) {
    const result = await executeCommand(pool, { userId, deviceId: null, origin: 'manual' }, {
      clientCommandId: randomUUID(), type: 'task.create', payloadVersion: 1, aggregate: { type: 'task', id: tasks.get(item.name)! },
      clientRecordedAt: '2026-09-16T08:00:00Z', payload: resolve(item.payload) as Record<string, unknown>,
    });
    if (result.outcome !== 'applied') throw new Error(`${evalCase.id}: setup ${item.name} failed`);
  }
  const provider = new Recording(options.live ?? new ScriptedProvider(scriptFor(evalCase, resolve)));
  const now = new Date(new Date(set.referenceInstant).getTime() + 3 * 60_000);
  const service = new AssistantService(pool, provider, { clock: () => now });
  const turnId = randomUUID();
  const identity = { userId, deviceId: null };
  await service.submitTurn(identity, {
    turnId, conversationId: randomUUID(),
    message: { id: randomUUID(), text: evalCase.message, transcriptionId: null, revisesMessageId: null },
    referenceInstant: set.referenceInstant, timeZone: set.timeZone, unsyncedAggregateIds: [], calendarContext: null,
  });
  const snapshot = await service.run(identity, turnId) as Record<string, any>;
  const failures: string[] = [];
  const expect = evalCase.expect;
  const toolsOnly = options.live !== undefined && expect.live === 'tools';

  // Tool choice is the model's job: only checked against a real provider (the script fixes it otherwise).
  if (options.live) for (const tool of expect.tools) if (!provider.tools.includes(tool)) failures.push(`tool ${tool} not called`);
  if (!toolsOnly) {
    if (expect.status !== undefined && snapshot.status !== expect.status) failures.push(`status ${snapshot.status} ≠ ${expect.status}`);
    if (expect.statusIn && !expect.statusIn.includes(snapshot.status)) failures.push(`status ${snapshot.status} ∉ ${expect.statusIn.join('|')}`);
    if (expect.riskClass !== undefined && snapshot.riskClass !== expect.riskClass) failures.push(`risk ${snapshot.riskClass} ≠ ${expect.riskClass}`);
    if (expect.riskClassIn && !expect.riskClassIn.includes(snapshot.riskClass)) failures.push(`risk ${snapshot.riskClass} ∉ ${expect.riskClassIn.join('|')}`);
    if (expect.created) {
      const { rows } = await pool.query(`SELECT t.title, t.scheduled_date::text AS scheduled_date, t.scheduled_time::text AS scheduled_time,
          t.deadline_date::text AS deadline_date, t.duration_minutes,
          (SELECT count(*)::int FROM reminders r WHERE r.task_id = t.id AND r.deleted_at IS NULL) AS reminders
        FROM tasks t WHERE t.user_id = $1 AND NOT (t.id = ANY($2::uuid[]))`, [userId, [...tasks.values()]]);
      if (rows.length !== expect.created.length) failures.push(`${rows.length} tasks created, expected ${expect.created.length}`);
      for (const wanted of expect.created) {
        if (!rows.some((row) => matches(row, resolve(wanted) as Record<string, Json>))) {
          // Fixture data only: showing what was created (same fields) makes a live mismatch diagnosable.
          const seen = rows.map((row) => Object.fromEntries(Object.keys(wanted).map((key) => [key, row[key] ?? null])));
          failures.push(`no created task matches ${JSON.stringify(wanted)} — created ${JSON.stringify(seen)}`);
        }
      }
    }
    for (const name of expect.unchanged ?? []) {
      const { rows: [row] } = await pool.query('SELECT revision::int AS revision, deleted_at FROM tasks WHERE id = $1', [tasks.get(name)]);
      if (row?.revision !== 1 || row.deleted_at !== null) failures.push(`${name} changed without confirmation`);
    }
    for (const [name, columns] of Object.entries(expect.changed ?? {})) {
      const { rows: [row] } = await pool.query('SELECT status, title, priority, scheduled_date::text AS scheduled_date FROM tasks WHERE id = $1', [tasks.get(name)]);
      if (!row || !matches(row, resolve(columns) as Record<string, Json>)) failures.push(`${name} does not match ${JSON.stringify(columns)}`);
    }
    for (const occurrence of expect.occurrences ?? []) {
      const { rows } = await pool.query('SELECT status FROM task_occurrences WHERE task_id = $1 AND occurrence_key = $2', [tasks.get(occurrence.task), resolve(occurrence.occurrence_key)]);
      if (rows[0]?.status !== occurrence.status) failures.push(`occurrence ${occurrence.occurrence_key} of ${occurrence.task} is ${rows[0]?.status ?? 'absent'}`);
    }
    if (expect.proposalTargets) {
      const targets = new Set((snapshot.proposal?.preview?.items ?? []).map((item: { aggregateId: string }) => item.aggregateId));
      const wanted = new Set(expect.proposalTargets.map((name) => tasks.get(name)));
      if (targets.size !== wanted.size || ![...wanted].every((id) => targets.has(id))) failures.push('proposal targets differ');
    }
  }
  const assistantTexts = (snapshot.messages as Array<{ role: string; text: string }>).filter((message) => message.role === 'assistant').map((message) => message.text);
  for (const phrase of expect.replyIncludes ?? []) {
    if (!toolsOnly && !assistantTexts.some((text) => text.includes(resolve(phrase) as string))) failures.push(`reply lacks « ${phrase} »`);
  }
  for (const phrase of expect.forbidden ?? []) {
    if (assistantTexts.some((text) => text.toLowerCase().includes(phrase.toLowerCase()))) failures.push(`reply contains forbidden « ${phrase} »`);
  }
  return {
    ...base, passed: failures.length === 0, failures, toolsCalled: provider.tools,
    status: snapshot.status, riskClass: snapshot.riskClass, durationMs: Date.now() - started, tokens: provider.tokens,
  };
}
