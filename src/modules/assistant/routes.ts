import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { AuthError, type AuthIdentity, type AuthService } from '../auth/index.js';
import { clientVersionAccepted } from '../sync/index.js';
import { AssistantError, turnRequestSchema, type AssistantService, type Identity } from './service.js';

export interface AssistantRouteOptions {
  service: AssistantService;
  auth: AuthService;
  minimumClientVersion: string;
}

const errorBody = {
  type: 'object', required: ['error'], additionalProperties: false,
  properties: { error: { type: 'object', required: ['code', 'message', 'requestId'], additionalProperties: true, properties: {
    code: { type: 'string' }, message: { type: 'string' }, requestId: { type: 'string' },
  } } },
};
const anyObject = { type: 'object', additionalProperties: true };
const errors = { 400: errorBody, 401: errorBody, 404: errorBody, 409: errorBody, 422: errorBody, 426: errorBody, 429: errorBody, 503: errorBody };
const idParams = { type: 'object', required: ['id'], properties: { id: { type: 'string', format: 'uuid' } } };
const confirmBody = z.strictObject({ planHash: z.string().regex(/^[0-9a-f]{64}$/) });
const undoBody = z.strictObject({ undoRequestId: z.uuid() });
const json = (schema: z.ZodType) => z.toJSONSchema(schema, { target: 'draft-7' });

function send(request: FastifyRequest, reply: FastifyReply, status: number, code: string, message: string, extra: Record<string, unknown> = {}): FastifyReply {
  return reply.code(status).header('Cache-Control', 'no-store').send({ error: { ...extra, code, message, requestId: request.id } });
}

/** Assistant routes (02_API_Contract.md §4). Each request is authenticated before its body is read. */
export function registerAssistantRoutes(app: FastifyInstance, options: AssistantRouteOptions): void {
  const identities = new WeakMap<FastifyRequest, AuthIdentity>();
  const onRequest = async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      identities.set(request, await options.auth.authenticate(request.headers.authorization));
    } catch (error) {
      if (!(error instanceof AuthError)) throw error;
      return send(request, reply, error.statusCode, error.code, error.message);
    }
    if (!clientVersionAccepted(request.headers['x-client-version'], options.minimumClientVersion)) {
      return send(request, reply, 426, 'CLIENT_TOO_OLD', 'Update the app to use the assistant.', { minimumVersion: options.minimumClientVersion });
    }
    if (!options.service.enabled) return send(request, reply, 503, 'ASSISTANT_UNAVAILABLE', 'The assistant is not configured.');
  };
  const identity = (request: FastifyRequest): Identity => {
    const found = identities.get(request);
    if (!found) throw new Error('Unauthenticated assistant request reached a handler');
    return { userId: found.userId, deviceId: found.deviceId };
  };
  const handle = (work: (request: FastifyRequest, reply: FastifyReply) => Promise<unknown>) => async (request: FastifyRequest, reply: FastifyReply) => {
    reply.header('Cache-Control', 'no-store');
    if (request.validationError) return send(request, reply, 400, 'INVALID_REQUEST', 'Invalid request.');
    try {
      return await work(request, reply);
    } catch (error) {
      if (!(error instanceof AssistantError)) throw error;
      if (typeof error.details.retryAfterSeconds === 'number') reply.header('Retry-After', error.details.retryAfterSeconds);
      return send(request, reply, error.statusCode, error.code, error.message, error.details);
    }
  };
  const idOf = (request: FastifyRequest) => (request.params as { id: string }).id;
  const common = { onRequest, attachValidation: true };

  app.post('/api/v1/assistant/turns', {
    ...common,
    schema: { body: json(turnRequestSchema), response: { 200: anyObject, ...errors } },
  }, handle(async (request, reply) => {
    const who = identity(request);
    const { turnId } = await options.service.submitTurn(who, request.body);
    if (!String(request.headers.accept ?? '').includes('text/event-stream')) return options.service.run(who, turnId);
    // The turn outlives the stream: closing it cancels nothing (02_API_Contract.md §4.1).
    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store', 'x-accel-buffering': 'no' });
    const write = (event: string, data: unknown) => {
      if (!raw.destroyed && !raw.writableEnded) raw.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    };
    try {
      const snapshot = await options.service.run(who, turnId, (event) => write(event.event, event.data));
      write('turn.final', snapshot);
    } catch (error) {
      write('error', { code: error instanceof AssistantError ? error.code : 'INTERNAL_ERROR' });
    } finally {
      if (!raw.writableEnded) raw.end();
    }
    return reply;
  }));

  app.get('/api/v1/assistant/turns/:id', { ...common, schema: { params: idParams, response: { 200: anyObject, ...errors } } },
    handle(async (request) => options.service.snapshot(identity(request).userId, idOf(request))));

  app.post('/api/v1/assistant/turns/:id/cancel', { ...common, schema: { params: idParams, response: { 200: anyObject, ...errors } } },
    handle(async (request) => options.service.cancel(identity(request), idOf(request))));

  app.post('/api/v1/assistant/proposals/:id/confirm', {
    ...common, schema: { params: idParams, body: json(confirmBody), response: { 200: anyObject, ...errors } },
  }, handle(async (request, reply) => {
    const body = confirmBody.safeParse(request.body);
    if (!body.success) return send(request, reply, 400, 'INVALID_REQUEST', 'Invalid request.');
    return options.service.confirm(identity(request), idOf(request), body.data.planHash);
  }));

  app.post('/api/v1/assistant/proposals/:id/reject', { ...common, schema: { params: idParams, response: { 200: anyObject, ...errors } } },
    handle(async (request) => options.service.reject(identity(request), idOf(request))));

  app.post('/api/v1/assistant/actions/:id/undo', {
    ...common, schema: { params: idParams, body: json(undoBody), response: { 200: anyObject, ...errors } },
  }, handle(async (request, reply) => {
    const body = undoBody.safeParse(request.body);
    if (!body.success) return send(request, reply, 400, 'INVALID_REQUEST', 'Invalid request.');
    return options.service.undo(identity(request), idOf(request), body.data.undoRequestId);
  }));

  app.delete('/api/v1/conversations/:id', { ...common, schema: { params: idParams, response: { 204: { type: 'null' }, ...errors } } },
    handle(async (request, reply) => {
      await options.service.deleteConversation(identity(request), idOf(request));
      return reply.code(204).send();
    }));

  app.delete('/api/v1/messages/:id', { ...common, schema: { params: idParams, response: { 204: { type: 'null' }, ...errors } } },
    handle(async (request, reply) => {
      await options.service.deleteMessage(identity(request), idOf(request));
      return reply.code(204).send();
    }));
}
