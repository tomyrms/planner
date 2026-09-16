import Fastify, { LogController, type FastifySchema, type RouteOptions } from 'fastify';
import type { Pool } from 'pg';
import { AssistantService, registerAssistantRoutes, type AssistantLimits, type ReasoningProvider } from './modules/assistant/index.js';
import { registerAuthRoutes, type AuthConfig } from './modules/auth/index.js';
import { registerExportRoutes } from './modules/export/index.js';
import { registerSyncRoutes } from './modules/sync/index.js';
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
    assistant: { type: 'string' },
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
  const assistantName = options.assistant?.provider ? `${options.assistant.provider.name}:${options.assistant.provider.model}` : 'disabled';
  registerAssistantRoutes(app, {
    service: assistant, auth,
    minimumClientVersion: options.sync?.minimumClientVersion ?? DEFAULT_MINIMUM_CLIENT_VERSION,
  });
  registerExportRoutes(app, {
    pool: options.pool, auth,
    ...(options.exportIntervalMs === undefined ? {} : { intervalMs: options.exportIntervalMs }),
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
      return { status: 'ready', scope: 'backend-sync', database: 'ready', sync: result.rows[0]!.sync_provisioned ? 'provisioned' : 'not_provisioned', assistant: assistantName };
    } catch {
      return reply.code(503).send({ status: 'not_ready', scope: 'backend-sync', database: 'unavailable', sync: 'unknown', assistant: assistantName });
    }
  });
  await app.ready();
  return {
    app,
    assistant,
    openApi: {
      openapi: '3.1.0',
      info: { title: 'Planner backend — étape 3', version: '0.3.0', description: 'Auth, santé, upload des commandes de synchronisation, export et assistant. La réplication vers l’iPhone passe par PowerSync, hors de cette API.' },
      paths,
      components: { securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' } } },
    },
  };
}
