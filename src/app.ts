import { tmpdir } from 'node:os';
import { join } from 'node:path';
import fastifyMultipart from '@fastify/multipart';
import Fastify, { LogController, type FastifySchema, type RouteOptions } from 'fastify';
import type { Pool } from 'pg';
import { AssistantService, DEFAULT_LIMITS, registerAssistantRoutes, type AssistantLimits, type ReasoningProvider } from './modules/assistant/index.js';
import { registerAuthRoutes, type AuthConfig } from './modules/auth/index.js';
import { registerExportRoutes } from './modules/export/index.js';
import { registerDiagnosticsRoutes } from './modules/maintenance/index.js';
import { registerSyncRoutes } from './modules/sync/index.js';
import { DEFAULT_VOICE_LIMITS, MAX_AUDIO_BYTES, registerVoiceRoutes, VoiceService, type TranscriptionProvider, type VoiceLimits } from './modules/voice/index.js';
import { registerErrorHandler } from './errors.js';

export const DEFAULT_MINIMUM_CLIENT_VERSION = '0.1.0';
const PUBLIC_ROUTES = new Set(['/api/v1/health/live', '/api/v1/health/ready', '/api/v1/auth/pair/complete', '/api/v1/auth/refresh', '/.well-known/jwks.json', '/openapi.json']);

type JsonObject = Record<string, unknown>;
const liveSchema: FastifySchema = {
  response: { 200: { type: 'object', required: ['status'], properties: { status: { const: 'alive', type: 'string' } }, additionalProperties: false } },
};
const readyBody = {
  type: 'object', required: ['status', 'scope', 'database', 'sync'], additionalProperties: false,
  properties: {
    assistant: { enum: ['configured', 'disabled'], type: 'string' },
    transcription: { enum: ['configured', 'disabled'], type: 'string' },
    status: { enum: ['ready', 'not_ready'], type: 'string' },
    scope: { const: 'backend-sync', type: 'string' },
    database: { enum: ['ready', 'unavailable'], type: 'string' },
    sync: { enum: ['provisioned', 'not_provisioned', 'unknown'], type: 'string' },
  },
};

export interface BuildAppOptions {
  pool: Pool;
  auth: AuthConfig;
  logger?: boolean;
  sync?: { minimumClientVersion?: string; clock?: () => Date };
  exportIntervalMs?: number;
  /** Without a provider the assistant routes answer 503 ASSISTANT_UNAVAILABLE. */
  assistant?: { provider: ReasoningProvider | null; limits?: Partial<AssistantLimits>; clock?: () => Date };
  /** Without a provider the transcription routes answer 503 TRANSCRIPTION_UNAVAILABLE. */
  voice?: { provider: TranscriptionProvider | null; audioDir?: string; limits?: Partial<VoiceLimits>; clock?: () => Date };
}

export async function buildApp(options: BuildAppOptions) {
  const app = Fastify({
    bodyLimit: 1_048_576,
    trustProxy: false,
    ajv: { customOptions: { removeAdditional: false, coerceTypes: false, useDefaults: false } },
    logger: options.logger ?? false,
    logController: new LogController({ disableRequestLogging: true }),
  });
  const paths: Record<string, JsonObject> = {};
  app.addHook('onRoute', (route: RouteOptions) => {
    for (const method of Array.isArray(route.method) ? route.method : [route.method]) {
      if (method === 'HEAD') continue;
      const schema = route.schema;
      const responseSchemas = schema?.response ?? { 200: {} };
      const responses = Object.fromEntries(Object.entries(responseSchemas).map(([status, body]) => [status, {
        description: Number(status) < 400 ? 'Success' : 'Error',
        content: { 'application/json': { schema: body } },
      }]));
      paths[route.url] ??= {};
      paths[route.url]![method.toLowerCase()] = {
        responses,
        ...(schema?.body ? { requestBody: { required: true, content: { 'application/json': { schema: schema.body } } } } : {}),
        ...(PUBLIC_ROUTES.has(route.url) ? {} : { security: [{ bearerAuth: [] }] }),
      };
    }
  });
  registerErrorHandler(app);
  // Only the transcription route reads multipart bodies; its per-request limits are stricter still.
  await app.register(fastifyMultipart, { limits: { fileSize: MAX_AUDIO_BYTES, files: 1, fields: 4, fieldSize: 100, parts: 5 } });
  app.addHook('onResponse', async (request, reply) => {
    request.log.info({ requestId: request.id, method: request.method, route: request.routeOptions.url ?? 'unmatched', status: reply.statusCode, durationMs: reply.elapsedTime }, 'Request completed');
  });
  const auth = registerAuthRoutes(app, { pool: options.pool, config: options.auth });
  await auth.ready();
  registerSyncRoutes(app, {
    pool: options.pool, auth,
    minimumClientVersion: options.sync?.minimumClientVersion ?? DEFAULT_MINIMUM_CLIENT_VERSION,
    ...(options.sync?.clock ? { clock: options.sync.clock } : {}),
  });
  const assistant = new AssistantService(options.pool, options.assistant?.provider ?? null, {
    ...(options.assistant?.limits ? { limits: options.assistant.limits } : {}),
    ...(options.assistant?.clock ? { clock: options.assistant.clock } : {}),
    // Technical events only: identifiers, statuses, counts. Never prompts, arguments or notes.
    log: (event) => app.log.info(event, 'assistant'),
  });
  // The readiness check is public: it says whether a provider is set, never which one (names go to /diagnostics).
  const assistantState = options.assistant?.provider ? 'configured' : 'disabled';
  registerAssistantRoutes(app, {
    service: assistant, auth,
    minimumClientVersion: options.sync?.minimumClientVersion ?? DEFAULT_MINIMUM_CLIENT_VERSION,
  });
  const voice = new VoiceService(options.pool, options.voice?.provider ?? null, options.voice?.audioDir ?? join(tmpdir(), 'planner-audio'), {
    ...(options.voice?.limits ? { limits: options.voice.limits } : {}),
    ...(options.voice?.clock ? { clock: options.voice.clock } : {}),
    log: (event) => app.log.info(event, 'voice'),
  });
  await voice.prepareDirectory();
  const transcriptionState = options.voice?.provider ? 'configured' : 'disabled';
  registerVoiceRoutes(app, {
    service: voice, auth,
    minimumClientVersion: options.sync?.minimumClientVersion ?? DEFAULT_MINIMUM_CLIENT_VERSION,
  });
  registerExportRoutes(app, {
    pool: options.pool, auth,
    ...(options.exportIntervalMs === undefined ? {} : { intervalMs: options.exportIntervalMs }),
    ...(options.sync?.clock ? { clock: options.sync.clock } : {}),
  });
  registerDiagnosticsRoutes(app, {
    pool: options.pool, auth,
    minimumClientVersion: options.sync?.minimumClientVersion ?? DEFAULT_MINIMUM_CLIENT_VERSION,
    assistant: {
      provider: options.assistant?.provider ?? null,
      monthlyTokenBudget: options.assistant?.limits?.monthlyTokenBudget ?? DEFAULT_LIMITS.monthlyTokenBudget,
    },
    transcription: {
      provider: options.voice?.provider ?? null,
      monthlyMinutes: options.voice?.limits?.monthlyMinutes ?? DEFAULT_VOICE_LIMITS.monthlyMinutes,
    },
    ...(options.sync?.clock ? { clock: options.sync.clock } : {}),
  });
  app.get('/api/v1/health/live', { schema: liveSchema }, async () => ({ status: 'alive' }));
  app.get('/api/v1/health/ready', { schema: { response: { 200: readyBody, 503: readyBody } } }, async (_request, reply) => {
    reply.header('Cache-Control', 'no-store');
    try {
      // The API serves uploads on its own; "sync" only reports whether PowerSync can replicate (publication present).
      const result = await options.pool.query<{ generation: string; sync_provisioned: boolean }>(
        "SELECT generation, EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') AS sync_provisioned FROM server_meta LIMIT 1");
      if (result.rowCount !== 1) throw new Error('Missing generation');
      return { status: 'ready', scope: 'backend-sync', database: 'ready', sync: result.rows[0]!.sync_provisioned ? 'provisioned' : 'not_provisioned', assistant: assistantState, transcription: transcriptionState };
    } catch {
      return reply.code(503).send({ status: 'not_ready', scope: 'backend-sync', database: 'unavailable', sync: 'unknown', assistant: assistantState, transcription: transcriptionState });
    }
  });
  await app.ready();
  return {
    app,
    assistant,
    voice,
    openApi: {
      openapi: '3.1.0',
      info: { title: 'Planner backend', version: '0.4.0', description: 'Auth, santé, upload des commandes de synchronisation, export, diagnostics, assistant et messages vocaux. La réplication vers l’iPhone passe par PowerSync, hors de cette API.' },
      paths,
      components: { securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' } } },
    },
  };
}
