import Fastify, { LogController, type FastifySchema, type RouteOptions } from 'fastify';
import type { Pool } from 'pg';
import { registerAuthRoutes, type AuthConfig } from './modules/auth/index.js';
import { registerExportRoutes } from './modules/export/index.js';
import { registerSyncRoutes } from './modules/sync/index.js';
import { registerErrorHandler } from './errors.js';

export const DEFAULT_MINIMUM_CLIENT_VERSION = '0.1.0';
const BEARER_ROUTES = new Set(['/api/v1/auth/sync-token', '/api/v1/auth/logout', '/api/v1/sync/mutations', '/api/v1/export']);

type JsonObject = Record<string, unknown>;
const liveSchema: FastifySchema = {
  response: { 200: { type: 'object', required: ['status'], properties: { status: { const: 'alive', type: 'string' } }, additionalProperties: false } },
};
const readyBody = {
  type: 'object', required: ['status', 'scope', 'database', 'sync'], additionalProperties: false,
  properties: {
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
        ...(BEARER_ROUTES.has(route.url) ? { security: [{ bearerAuth: [] }] } : {}),
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
      return { status: 'ready', scope: 'backend-sync', database: 'ready', sync: result.rows[0]!.sync_provisioned ? 'provisioned' : 'not_provisioned' };
    } catch {
      return reply.code(503).send({ status: 'not_ready', scope: 'backend-sync', database: 'unavailable', sync: 'unknown' });
    }
  });
  await app.ready();
  return {
    app,
    openApi: {
      openapi: '3.1.0',
      info: { title: 'Planner backend — étape 2', version: '0.2.0', description: 'Auth, santé, upload des commandes de synchronisation et export. La réplication vers l’iPhone passe par PowerSync, hors de cette API.' },
      paths,
      components: { securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' } } },
    },
  };
}
