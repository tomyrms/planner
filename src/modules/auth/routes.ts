import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { Pool } from 'pg';
import { AuthError, AuthService, type AuthConfig } from './service.js';
import { authRouteSchemas, authSchemas } from './schemas.js';

export function registerAuthRoutes(app: FastifyInstance, options: { pool: Pool; config: AuthConfig }): AuthService {
  const service = new AuthService(options.pool, options.config);
  app.addHook('onReady', () => service.ready());
  const handle = (work: (request: FastifyRequest, reply: FastifyReply) => Promise<unknown>) => async (request: FastifyRequest, reply: FastifyReply) => {
    reply.header('Cache-Control', 'no-store');
    try { return await work(request, reply); }
    catch (error) {
      if (!(error instanceof AuthError)) throw error;
      if (error.retryAfter) reply.header('Retry-After', error.retryAfter);
      return reply.code(error.statusCode).send({ error: { code: error.code, message: error.message, requestId: request.id } });
    }
  };
  app.post('/api/v1/auth/pair/complete', { schema: authRouteSchemas.pair }, handle(async (request, reply) => {
    const parsed = authSchemas.pair.safeParse(request.body);
    if (!parsed.success) throw new AuthError('INVALID_ENVELOPE', 400);
    const result = await service.pair(parsed.data, request.ip);
    return reply.code(201).send(result);
  }));
  app.post('/api/v1/auth/refresh', { schema: authRouteSchemas.refresh }, handle(async (request) => {
    const parsed = authSchemas.refresh.safeParse(request.body);
    if (!parsed.success) throw new AuthError('INVALID_ENVELOPE', 400);
    return service.refresh(parsed.data.refreshToken);
  }));
  app.get('/api/v1/auth/sync-token', { schema: authRouteSchemas.sync }, handle(async (request) => service.syncToken(await service.authenticate(request.headers.authorization))));
  app.post('/api/v1/auth/logout', { schema: authRouteSchemas.logout }, handle(async (request) => {
    const identity = await service.authenticate(request.headers.authorization);
    await service.revokeDevice(identity.deviceId, identity.userId);
    return { revoked: true };
  }));
  app.get('/.well-known/jwks.json', async (_request, reply) => {
    reply.header('Cache-Control', 'public, max-age=300');
    return service.jwks();
  });
  return service;
}
