import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { AuthError, type AuthIdentity, type AuthService } from '../auth/index.js';
import { envelopeSchema } from './commands.js';
import { ServerGenerationChanged, applyEnvelope } from './service.js';

export interface SyncRouteOptions {
  pool: pg.Pool;
  auth: AuthService;
  /** Oldest app version allowed to upload (X-Client-Version, 426 below it). */
  minimumClientVersion: string;
  clock?: () => Date;
}

const VERSION = /^(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?: \(build \d{1,9}\))?$/;

export function clientVersionAccepted(header: string | string[] | undefined, minimum: string): boolean {
  const value = Array.isArray(header) ? header[0] : header;
  const client = value === undefined ? null : VERSION.exec(value.trim());
  const floor = VERSION.exec(minimum);
  if (floor === null) throw new Error('Invalid minimum client version');
  if (client === null) return false;
  for (let index = 1; index <= 3; index++) {
    const difference = Number(client[index]) - Number(floor[index]);
    if (difference !== 0) return difference > 0;
  }
  return true;
}

const errorBody = {
  type: 'object', required: ['error'], additionalProperties: false,
  properties: {
    error: {
      type: 'object', required: ['code', 'message', 'requestId'], additionalProperties: false,
      properties: {
        code: { type: 'string' }, message: { type: 'string' }, requestId: { type: 'string' },
        serverGeneration: { type: 'string' }, minimumVersion: { type: 'string' },
      },
    },
  },
};
const resultBody = { type: 'object', required: ['clientCommandId', 'outcome'], additionalProperties: true, properties: {
  clientCommandId: { type: 'string' }, outcome: { enum: ['applied', 'rejected', 'duplicate'], type: 'string' },
} };
export const syncRouteSchema = {
  body: z.toJSONSchema(envelopeSchema, { target: 'draft-7' }),
  response: {
    200: { type: 'object', required: ['serverGeneration', 'results'], additionalProperties: false, properties: {
      serverGeneration: { type: 'string' }, results: { type: 'array', items: resultBody },
    } },
    400: errorBody, 401: errorBody, 409: errorBody, 413: errorBody, 426: errorBody,
  },
};

function fail(request: FastifyRequest, reply: FastifyReply, status: number, code: string, message: string, extra: Record<string, string> = {}): FastifyReply {
  return reply.code(status).header('Cache-Control', 'no-store').send({ error: { code, message, requestId: request.id, ...extra } });
}

export function registerSyncRoutes(app: FastifyInstance, options: SyncRouteOptions): void {
  const identities = new WeakMap<FastifyRequest, AuthIdentity>();
  app.post('/api/v1/sync/mutations', {
    schema: syncRouteSchema,
    // The envelope is checked by Zod after authentication, with one protocol error code.
    attachValidation: true,
    // Authentication and version run before the body is even read.
    onRequest: async (request, reply) => {
      try {
        identities.set(request, await options.auth.authenticate(request.headers.authorization));
      } catch (error) {
        if (!(error instanceof AuthError)) throw error;
        return fail(request, reply, error.statusCode, error.code, error.message);
      }
      if (!clientVersionAccepted(request.headers['x-client-version'], options.minimumClientVersion)) {
        return fail(request, reply, 426, 'CLIENT_TOO_OLD', 'Update the app to keep syncing.', { minimumVersion: options.minimumClientVersion });
      }
    },
  }, async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    const identity = identities.get(request);
    if (identity === undefined) throw new Error('Unauthenticated sync request reached the handler');
    const parsed = envelopeSchema.safeParse(request.body);
    if (request.validationError !== undefined || !parsed.success) return fail(request, reply, 400, 'INVALID_ENVELOPE', 'Invalid request.');
    try {
      return await applyEnvelope(options.pool, { userId: identity.userId, deviceId: identity.deviceId, origin: 'manual' }, parsed.data, options.clock);
    } catch (error) {
      if (!(error instanceof ServerGenerationChanged)) throw error;
      return fail(request, reply, 409, 'SERVER_GENERATION_CHANGED', 'The server was restored. Sync is paused.', { serverGeneration: error.serverGeneration });
    }
  });
}
