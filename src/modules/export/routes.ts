import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { AuthError, type AuthService } from '../auth/index.js';
import { buildExport } from './archive.js';

export interface ExportRouteOptions {
  pool: pg.Pool;
  auth: AuthService;
  /** Minimum delay between two exports of the same device. */
  intervalMs?: number;
  clock?: () => Date;
}

const errorBody = {
  type: 'object', required: ['error'], additionalProperties: false,
  properties: { error: { type: 'object', required: ['code', 'message', 'requestId'], additionalProperties: false, properties: {
    code: { type: 'string' }, message: { type: 'string' }, requestId: { type: 'string' },
  } } },
};
const archiveBody = {
  type: 'object', additionalProperties: true,
  required: ['exportVersion', 'exportedAt', 'serverGeneration', 'projects', 'tasks', 'taskOccurrences', 'reminders', 'conversations'],
  properties: { exportVersion: { const: 1, type: 'integer' }, exportedAt: { type: 'string' }, serverGeneration: { type: 'string' } },
};

/** Export stays available to an outdated app: it is the recovery path (02_API_Contract.md §5). */
export function registerExportRoutes(app: FastifyInstance, options: ExportRouteOptions): void {
  const lastExport = new Map<string, number>();
  const interval = options.intervalMs ?? 60_000;
  const now = options.clock ?? (() => new Date());
  app.get('/api/v1/export', { schema: { response: { 200: archiveBody, 401: errorBody, 429: errorBody } } }, async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    const fail = (status: 401 | 429, code: string, message: string) =>
      reply.code(status).send({ error: { code, message, requestId: request.id } });
    let identity;
    try {
      identity = await options.auth.authenticate(request.headers.authorization);
    } catch (error) {
      if (!(error instanceof AuthError)) throw error;
      return fail(error.statusCode === 429 ? 429 : 401, error.code, error.message);
    }
    const at = now();
    const previous = lastExport.get(identity.deviceId);
    if (previous !== undefined && at.getTime() - previous < interval) {
      reply.header('Retry-After', Math.ceil((previous + interval - at.getTime()) / 1000));
      return fail(429, 'RATE_LIMITED', 'Export already requested recently.');
    }
    lastExport.set(identity.deviceId, at.getTime());
    const archive = await buildExport(options.pool, identity.userId, at);
    reply.header('Content-Disposition', `attachment; filename="planner-export-${archive.exportedAt.slice(0, 10)}.json"`);
    return archive;
  });
}
