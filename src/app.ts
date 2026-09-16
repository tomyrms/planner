import Fastify, { LogController, type FastifySchema, type RouteOptions } from 'fastify';
import type { Pool } from 'pg';
import { registerAuthRoutes, type AuthConfig } from './modules/auth/index.js';
import { registerErrorHandler } from './errors.js';

type JsonObject = Record<string, unknown>;
const liveSchema: FastifySchema = {
  response: { 200: { type: 'object', required: ['status'], properties: { status: { const: 'alive', type: 'string' } }, additionalProperties: false } },
};
const readyBody = {
  type: 'object', required: ['status', 'scope', 'database', 'sync'], additionalProperties: false,
  properties: {
    status: { enum: ['ready', 'not_ready'], type: 'string' },
    scope: { const: 'backend-foundation', type: 'string' },
    database: { enum: ['ready', 'unavailable'], type: 'string' },
    sync: { const: 'not_installed', type: 'string' },
  },
};

export async function buildApp(options: { pool: Pool; auth: AuthConfig; logger?: boolean }) {
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
        ...(['/api/v1/auth/sync-token', '/api/v1/auth/logout'].includes(route.url) ? { security: [{ bearerAuth: [] }] } : {}),
      };
    }
  });
  registerErrorHandler(app);
  app.addHook('onResponse', async (request, reply) => {
    request.log.info({ requestId: request.id, method: request.method, route: request.routeOptions.url ?? 'unmatched', status: reply.statusCode, durationMs: reply.elapsedTime }, 'Request completed');
  });
  const auth = registerAuthRoutes(app, { pool: options.pool, config: options.auth });
  await auth.ready();
  app.get('/api/v1/health/live', { schema: liveSchema }, async () => ({ status: 'alive' }));
  app.get('/api/v1/health/ready', { schema: { response: { 200: readyBody, 503: readyBody } } }, async (_request, reply) => {
    reply.header('Cache-Control', 'no-store');
    try {
      const result = await options.pool.query('SELECT generation FROM server_meta LIMIT 1');
      if (result.rowCount !== 1) throw new Error('Missing generation');
      return { status: 'ready', scope: 'backend-foundation', database: 'ready', sync: 'not_installed' };
    } catch {
      return reply.code(503).send({ status: 'not_ready', scope: 'backend-foundation', database: 'unavailable', sync: 'not_installed' });
    }
  });
  await app.ready();
  return {
    app,
    openApi: {
      openapi: '3.1.0',
      info: { title: 'Planner backend — étape 1', version: '0.1.0', description: 'Auth et santé du backend. La synchronisation PowerSync est hors de cette étape.' },
      paths,
      components: { securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' } } },
    },
  };
}
