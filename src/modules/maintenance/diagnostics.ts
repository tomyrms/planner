import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { AuthError, type AuthService } from '../auth/index.js';

export interface DescribedProvider {
  readonly name: string;
  readonly model: string;
}

export interface DiagnosticsRouteOptions {
  pool: pg.Pool;
  auth: AuthService;
  minimumClientVersion: string;
  assistant: { provider: DescribedProvider | null; monthlyTokenBudget: number };
  transcription: { provider: DescribedProvider | null; monthlyMinutes: number };
  clock?: () => Date;
}

const MAINTENANCE_KINDS = ['backup', 'backup_verify', 'restore', 'purge', 'audio_cleanup'] as const;
const camel = { backup: 'backup', backup_verify: 'backupVerify', restore: 'restore', purge: 'purge', audio_cleanup: 'audioCleanup' } as const;

const nullableString = { type: ['string', 'null'] };
const runBody = {
  type: 'object', required: ['lastSucceededAt', 'lastFailedAt'], additionalProperties: false,
  properties: { lastSucceededAt: nullableString, lastFailedAt: nullableString },
};
const providerBody = (usage: Record<string, unknown>) => ({
  type: 'object', additionalProperties: false,
  required: ['status', 'provider', 'model', ...Object.keys(usage)],
  properties: { status: { enum: ['configured', 'disabled'], type: 'string' }, provider: nullableString, model: nullableString, ...usage },
});
const diagnosticsBody = {
  type: 'object', additionalProperties: false,
  required: ['generatedAt', 'serverGeneration', 'minimumClientVersion', 'sync', 'replicationLagBytes', 'assistant', 'transcription', 'maintenance'],
  properties: {
    generatedAt: { type: 'string' },
    serverGeneration: { type: 'string' },
    minimumClientVersion: { type: 'string' },
    sync: { enum: ['provisioned', 'not_provisioned'], type: 'string' },
    replicationLagBytes: { type: ['integer', 'null'] },
    assistant: providerBody({ monthTokens: { type: 'integer' }, monthTokenBudget: { type: 'integer' } }),
    transcription: providerBody({ monthMinutes: { type: 'number' }, monthMinuteBudget: { type: 'integer' } }),
    maintenance: {
      type: 'object', additionalProperties: false, required: Object.values(camel),
      properties: Object.fromEntries(Object.values(camel).map((key) => [key, runBody])),
    },
  },
};
const errorBody = {
  type: 'object', required: ['error'], additionalProperties: false,
  properties: { error: { type: 'object', required: ['code', 'message', 'requestId'], additionalProperties: false, properties: {
    code: { type: 'string' }, message: { type: 'string' }, requestId: { type: 'string' },
  } } },
};

/**
 * Operating state for Réglages > Diagnostic (07_DeepResearch/39_Observability_Logging_Diagnostics.md):
 * identifiers, dates and counters only, never user content. Like the export, it stays available to an
 * outdated app.
 */
export function registerDiagnosticsRoutes(app: FastifyInstance, options: DiagnosticsRouteOptions): void {
  const now = options.clock ?? (() => new Date());
  app.get('/api/v1/diagnostics', { schema: { response: { 200: diagnosticsBody, 401: errorBody, 429: errorBody } } }, async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    let identity;
    try {
      identity = await options.auth.authenticate(request.headers.authorization);
    } catch (error) {
      if (!(error instanceof AuthError)) throw error;
      const status = error.statusCode === 429 ? 429 : 401;
      return reply.code(status).send({ error: { code: error.code, message: error.message, requestId: request.id } });
    }
    return readDiagnostics(options, identity.userId, now());
  });
}

export async function readDiagnostics(options: DiagnosticsRouteOptions, userId: string, at: Date) {
  const { pool } = options;
  const meta = await pool.query<{ generation: string; provisioned: boolean }>(
    "SELECT generation, EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') AS provisioned FROM server_meta LIMIT 1");
  const runs = await pool.query<{ kind: typeof MAINTENANCE_KINDS[number]; outcome: 'succeeded' | 'failed'; finished_at: Date }>(
    `SELECT kind, outcome, max(finished_at) AS finished_at FROM maintenance_runs
      WHERE kind = ANY($1) GROUP BY kind, outcome`, [MAINTENANCE_KINDS]);
  const month = `date_trunc('month', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`;
  const tokens = await pool.query<{ total: string }>(
    `SELECT COALESCE(sum(input_tokens + output_tokens), 0)::bigint AS total FROM assistant_turns WHERE user_id = $1 AND created_at >= ${month}`,
    [userId, at]);
  const audio = await pool.query<{ total: string }>(
    `SELECT COALESCE(sum(duration_ms::bigint * attempts), 0)::bigint AS total FROM transcriptions WHERE user_id = $1 AND created_at >= ${month}`,
    [userId, at]);
  const maintenance = Object.fromEntries(MAINTENANCE_KINDS.map((kind) => {
    const find = (outcome: 'succeeded' | 'failed') => {
      const row = runs.rows.find((run) => run.kind === kind && run.outcome === outcome);
      return row ? new Date(row.finished_at).toISOString() : null;
    };
    return [camel[kind], { lastSucceededAt: find('succeeded'), lastFailedAt: find('failed') }];
  }));
  return {
    generatedAt: at.toISOString(),
    serverGeneration: meta.rows[0]!.generation,
    minimumClientVersion: options.minimumClientVersion,
    sync: meta.rows[0]!.provisioned ? 'provisioned' as const : 'not_provisioned' as const,
    replicationLagBytes: await replicationLag(pool),
    assistant: {
      ...describe(options.assistant.provider),
      monthTokens: Number(tokens.rows[0]!.total),
      monthTokenBudget: options.assistant.monthlyTokenBudget,
    },
    transcription: {
      ...describe(options.transcription.provider),
      monthMinutes: Math.round(Number(audio.rows[0]!.total) / 600) / 100,
      monthMinuteBudget: options.transcription.monthlyMinutes,
    },
    maintenance,
  };
}

function describe(provider: DescribedProvider | null) {
  return provider
    ? { status: 'configured' as const, provider: provider.name, model: provider.model }
    : { status: 'disabled' as const, provider: null, model: null };
}

/** WAL the PowerSync slot has not confirmed yet; unknown when the slot or the right to read it is missing. */
async function replicationLag(pool: pg.Pool): Promise<number | null> {
  try {
    const result = await pool.query<{ lag: string | null }>(
      `SELECT max(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn))::bigint AS lag
         FROM pg_replication_slots WHERE slot_name LIKE 'powersync%'`);
    const lag = result.rows[0]?.lag;
    return lag === null || lag === undefined ? null : Number(lag);
  } catch {
    return null;
  }
}
