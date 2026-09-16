import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { createWriteStream } from 'node:fs';
import { rm } from 'node:fs/promises';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { AssistantError } from '../assistant/index.js';
import { AuthError, type AuthIdentity, type AuthService } from '../auth/index.js';
import { clientVersionAccepted } from '../sync/index.js';
import type { VoiceService } from './service.js';

export const MAX_AUDIO_BYTES = 10 * 1024 * 1024;

const errorBody = {
  type: 'object', required: ['error'], additionalProperties: false,
  properties: { error: { type: 'object', required: ['code', 'message', 'requestId'], additionalProperties: true, properties: {
    code: { type: 'string' }, message: { type: 'string' }, requestId: { type: 'string' },
  } } },
};
const snapshotBody = {
  type: 'object', additionalProperties: false, required: ['transcriptionId', 'status'],
  properties: {
    transcriptionId: { type: 'string' },
    status: { enum: ['received', 'transcribing', 'completed', 'failed', 'abandoned'], type: 'string' },
    text: { type: ['string', 'null'] },
    languages: { type: 'array', items: { type: 'string' } },
    errorCode: { type: ['string', 'null'] },
    durationMs: { type: 'integer' },
    createdAt: { type: 'string' },
    completedAt: { type: ['string', 'null'] },
    audioDeleted: { type: 'boolean' },
  },
};
const errors = { 400: errorBody, 401: errorBody, 404: errorBody, 409: errorBody, 413: errorBody, 422: errorBody, 426: errorBody, 429: errorBody, 503: errorBody };
const idParams = { type: 'object', required: ['id'], properties: { id: { type: 'string', format: 'uuid' } } };
const fieldsSchema = z.strictObject({
  transcriptionId: z.uuid(),
  durationMs: z.string().regex(/^\d{1,6}$/).transform(Number).pipe(z.number().int().min(1000).max(120_000)),
});

function send(request: FastifyRequest, reply: FastifyReply, status: number, code: string, message: string, extra: Record<string, unknown> = {}): FastifyReply {
  return reply.code(status).header('Cache-Control', 'no-store').send({ error: { ...extra, code, message, requestId: request.id } });
}

/** Voice routes (02_API_Contract.md §4.7). Authentication happens before the audio is read. */
export function registerVoiceRoutes(app: FastifyInstance, options: { service: VoiceService; auth: AuthService; minimumClientVersion: string }): void {
  const identities = new WeakMap<FastifyRequest, AuthIdentity>();
  const onRequest = async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      identities.set(request, await options.auth.authenticate(request.headers.authorization));
    } catch (error) {
      if (!(error instanceof AuthError)) throw error;
      return send(request, reply, error.statusCode, error.code, error.message);
    }
    if (!clientVersionAccepted(request.headers['x-client-version'], options.minimumClientVersion)) {
      return send(request, reply, 426, 'CLIENT_TOO_OLD', 'Update the app to send voice messages.', { minimumVersion: options.minimumClientVersion });
    }
    if (!options.service.enabled) return send(request, reply, 503, 'TRANSCRIPTION_UNAVAILABLE', 'Voice transcription is not configured.');
  };
  const who = (request: FastifyRequest) => {
    const found = identities.get(request);
    if (!found) throw new Error('Unauthenticated voice request reached a handler');
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

  app.post('/api/v1/assistant/transcriptions', {
    onRequest,
    schema: { consumes: ['multipart/form-data'], response: { 200: snapshotBody, ...errors } },
  }, handle(async (request, reply) => {
    if (!request.isMultipart()) return send(request, reply, 400, 'INVALID_REQUEST', 'Expected multipart/form-data.');
    const fields: Record<string, string> = {};
    let upload: { path: string; byteSize: number; sha256: string } | null = null;
    let tooLarge = false;
    try {
      for await (const part of request.parts({ limits: { fileSize: MAX_AUDIO_BYTES, files: 1, fields: 4, fieldSize: 100, parts: 5 } })) {
        if (part.type === 'file') {
          // A part past the limits makes the plugin destroy the file stream before it is read, and
          // pipeline() never settles on a destroyed stream: skip it, the next step reports the limit.
          if (part.file.destroyed) continue;
          if (part.fieldname !== 'audio' || upload !== null) {
            part.file.resume();
            return send(request, reply, 400, 'INVALID_REQUEST', 'Expected one "audio" file.');
          }
          // The name and MIME type sent by the client are ignored; the content is inspected later.
          const path = options.service.temporaryPath();
          const hash = createHash('sha256');
          let byteSize = 0;
          upload = { path, byteSize: 0, sha256: '' };
          const out = createWriteStream(path, { flags: 'wx', mode: 0o600 });
          try {
            await pipeline(part.file, new Transform({
              transform(chunk: Buffer, _encoding, callback) {
                hash.update(chunk);
                byteSize += chunk.length;
                callback(null, chunk);
              },
            }), out);
          } finally {
            // Windows keeps an open file listed after its deletion: close it before any removal.
            if (!out.closed) await once(out, 'close').catch(() => undefined);
          }
          if (part.file.truncated) tooLarge = true;
          upload = { path, byteSize, sha256: hash.digest('hex') };
        } else {
          if (typeof part.value !== 'string') return send(request, reply, 400, 'INVALID_REQUEST', 'Invalid field.');
          fields[part.fieldname] = part.value;
        }
      }
    } catch (error) {
      if (upload) await rm(upload.path, { force: true });
      const code = (error as { code?: string }).code;
      if (code === 'FST_REQ_FILE_TOO_LARGE') return send(request, reply, 413, 'AUDIO_TOO_LARGE', 'Audio larger than 10 MB.');
      if (typeof code === 'string' && (code.startsWith('FST_') || code === 'ERR_STREAM_PREMATURE_CLOSE')) {
        return send(request, reply, 400, 'INVALID_REQUEST', 'Invalid multipart request.');
      }
      throw error;
    }
    const parsed = fieldsSchema.safeParse(fields);
    if (!upload || tooLarge || !parsed.success) {
      if (upload) await rm(upload.path, { force: true });
      if (tooLarge) return send(request, reply, 413, 'AUDIO_TOO_LARGE', 'Audio larger than 10 MB.');
      return send(request, reply, 400, 'INVALID_REQUEST', 'Expected transcriptionId, durationMs and audio.');
    }
    return options.service.receive(who(request), { ...parsed.data, ...upload });
  }));

  app.get('/api/v1/assistant/transcriptions/:id', { onRequest, attachValidation: true, schema: { params: idParams, response: { 200: snapshotBody, ...errors } } },
    handle(async (request) => options.service.snapshot(who(request).userId, (request.params as { id: string }).id)));

  app.delete('/api/v1/assistant/transcriptions/:id', { onRequest, attachValidation: true, schema: { params: idParams, response: { 200: snapshotBody, ...errors } } },
    handle(async (request) => options.service.abandon(who(request), (request.params as { id: string }).id)));
}
