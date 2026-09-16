import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../../src/app.js';
import { RuleBasedProvider } from '../../src/modules/assistant/index.js';
import { AuthService, type AuthConfig, type TokenResponse } from '../../src/modules/auth/index.js';
import { ScriptedTranscriptionProvider, TranscriptionError } from '../../src/modules/voice/index.js';
import { NOW, TOMORROW, turnRequest } from '../assistant/helpers.js';
import { createTestDatabase } from '../db/helpers.js';

const URL = '/api/v1/assistant/transcriptions';
const mono = await readFile(new globalThis.URL('../fixtures/audio/tone-3s-mono.m4a', import.meta.url));
const SPOKEN = 'Demain rappelle-moi d’appeler le garage vers 17h.';

/** A multipart body exactly as URLSession would send it (field order preserved). */
async function multipart(parts: Array<[string, string | { data: Buffer; name?: string; type?: string }]>) {
  const form = new FormData();
  for (const [name, value] of parts) {
    if (typeof value === 'string') form.append(name, value);
    else form.append(name, new Blob([new Uint8Array(value.data)], { type: value.type ?? 'audio/mp4' }), value.name ?? 'message.m4a');
  }
  const request = new Request('http://planner.test/', { method: 'POST', body: form });
  return { payload: Buffer.from(await request.arrayBuffer()), contentType: request.headers.get('content-type')! };
}

describe('voice HTTP routes', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let built: Awaited<ReturnType<typeof buildApp>>;
  let disabled: Awaited<ReturnType<typeof buildApp>>;
  let tokens: TokenResponse;
  let otherTokens: TokenResponse;
  let audioDir: string;
  let provider: ScriptedTranscriptionProvider;

  beforeAll(async () => {
    db = await createTestDatabase();
    audioDir = await mkdtemp(join(tmpdir(), 'planner-voice-routes-'));
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048, publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    const config: AuthConfig = {
      issuer: 'http://planner.test', apiAudience: 'planner-api', syncAudience: 'planner-sync', keyId: 'test-key',
      privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey, refreshDerivationKey: randomBytes(32).toString('hex'),
      now: () => NOW,
    };
    provider = new ScriptedTranscriptionProvider([
      (async () => ({ text: SPOKEN, languages: ['fr'], seconds: 3 })),
      new TranscriptionError('TRANSCRIPTION_UNAVAILABLE'),
      (async () => ({ text: 'Troisième.', languages: ['fr'], seconds: 3 })),
    ]);
    built = await buildApp({
      pool: db.pool, auth: config,
      assistant: { provider: new RuleBasedProvider(), clock: () => NOW },
      voice: { provider, audioDir },
    });
    disabled = await buildApp({ pool: db.pool, auth: config, voice: { provider: null, audioDir } });
    const auth = new AuthService(db.pool, config);
    const pair = async (userId?: string) => {
      const secret = await auth.createPairingSecret({ name: 'iPhone', ...(userId ? { userId } : {}) });
      const paired = await built.app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', payload: {
        pairingSecret: secret.pairingSecret, device: { name: 'iPhone', platform: 'ios', osVersion: '26.0', appVersion: '0.1.0' },
      } });
      return paired.json<TokenResponse>();
    };
    tokens = await pair();
    const stranger = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    otherTokens = await pair(stranger);
  });
  afterAll(async () => {
    await built?.voice.shutdown();
    await built?.app.close();
    await disabled?.app.close();
    await db?.close();
    await rm(audioDir, { recursive: true, force: true });
  });

  const headers = (token = tokens.accessToken, extra: Record<string, string> = {}) => ({ authorization: `Bearer ${token}`, 'x-client-version': '0.1.0 (build 3)', ...extra });
  const upload = async (parts: Parameters<typeof multipart>[0], options: { token?: string; app?: typeof built; extra?: Record<string, string> } = {}) => {
    const body = await multipart(parts);
    return (options.app ?? built).app.inject({
      method: 'POST', url: URL, payload: body.payload,
      headers: { ...headers(options.token, options.extra), 'content-type': body.contentType },
    });
  };
  const voice = (id: string, data: Buffer = mono, durationMs = '3000') => [['transcriptionId', id], ['durationMs', durationMs], ['audio', { data }]] as Parameters<typeof multipart>[0];
  const leftovers = async () => (await readdir(audioDir)).filter((name) => !name.startsWith('.'));

  it('transcribes an upload, then the text drives an assistant turn as a voice message', async () => {
    const id = randomUUID();
    const response = await upload(voice(id));
    expect(response.statusCode, response.body).toBe(200);
    expect(response.headers['cache-control']).toBe('no-store');
    expect(response.json()).toMatchObject({ transcriptionId: id, status: 'completed', text: SPOKEN, languages: ['fr'], audioDeleted: true });
    expect(await leftovers()).toEqual([]);
    const read = await built.app.inject({ method: 'GET', url: `${URL}/${id}`, headers: headers() });
    expect(read.json()).toEqual(response.json());

    const request = turnRequest(SPOKEN);
    const turn = await built.app.inject({ method: 'POST', url: '/api/v1/assistant/turns', headers: headers(), payload: {
      ...request, message: { ...request.message, transcriptionId: id },
    } });
    expect(turn.statusCode, turn.body).toBe(200);
    expect(turn.json()).toMatchObject({ status: 'completed', riskClass: 'R1' });
    expect(turn.json().messages[0]).toMatchObject({ role: 'user', kind: 'voice', text: SPOKEN });
    const created = turn.json().results[0].aggregateId;
    expect((await db.pool.query('SELECT title, scheduled_date::text AS date FROM tasks WHERE id = $1', [created])).rows[0]).toEqual({ title: 'Appeler le garage', date: TOMORROW });
    // A device of another user cannot read it.
    const foreign = await built.app.inject({ method: 'GET', url: `${URL}/${id}`, headers: headers(otherTokens.accessToken) });
    expect(foreign.statusCode).toBe(404);
    expect(foreign.body).not.toContain('garage');
  });

  it('reports a provider failure, accepts a retry of the same file, and lets the client abandon', async () => {
    const id = randomUUID();
    const failed = await upload(voice(id));
    expect(failed.statusCode).toBe(200);
    expect(failed.json()).toMatchObject({ status: 'failed', errorCode: 'TRANSCRIPTION_UNAVAILABLE', text: null });
    const retried = await upload(voice(id));
    expect(retried.json()).toMatchObject({ status: 'completed', text: 'Troisième.' });
    const reused = await upload(voice(id, Buffer.concat([mono, Buffer.from([0, 0, 0, 8]), Buffer.from('free', 'latin1')])));
    expect(reused.statusCode).toBe(409);
    expect(reused.json().error.code).toBe('IDEMPOTENCY_KEY_REUSED');
    const abandoned = await built.app.inject({ method: 'DELETE', url: `${URL}/${id}`, headers: headers() });
    expect(abandoned.statusCode).toBe(200);
    expect(abandoned.json()).toMatchObject({ status: 'completed', audioDeleted: true });
    expect(await leftovers()).toEqual([]);
  });

  it('authenticates and checks the client version before reading any audio', async () => {
    const body = await multipart(voice(randomUUID()));
    const anonymous = await built.app.inject({ method: 'POST', url: URL, payload: body.payload, headers: { 'content-type': body.contentType } });
    expect(anonymous.statusCode).toBe(401);
    const forged = await upload(voice(randomUUID()), { token: 'not-a-token' });
    expect(forged.statusCode).toBe(401);
    const old = await upload(voice(randomUUID()), { extra: { 'x-client-version': '0.0.9' } });
    expect(old.statusCode).toBe(426);
    expect(old.json().error).toMatchObject({ code: 'CLIENT_TOO_OLD', minimumVersion: '0.1.0' });
    const off = await upload(voice(randomUUID()), { app: disabled });
    expect(off.statusCode).toBe(503);
    expect(off.json().error.code).toBe('TRANSCRIPTION_UNAVAILABLE');
    expect((await disabled.app.inject({ method: 'GET', url: `${URL}/${randomUUID()}`, headers: headers() })).statusCode).toBe(503);
    expect(await leftovers()).toEqual([]);
    expect(provider.requests.length).toBeLessThanOrEqual(3);
  });

  it('rejects malformed requests and files without leaving anything behind', async () => {
    const before = provider.requests.length;
    const expectations: Array<[Parameters<typeof multipart>[0], number, string]> = [
      [[['transcriptionId', randomUUID()], ['audio', { data: mono }]], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', 'not-a-uuid'], ['durationMs', '3000'], ['audio', { data: mono }]], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', randomUUID()], ['durationMs', '3 s'], ['audio', { data: mono }]], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', randomUUID()], ['durationMs', '999'], ['audio', { data: mono }]], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', randomUUID()], ['durationMs', '120001'], ['audio', { data: mono }]], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', randomUUID()], ['durationMs', '3000'], ['userId', randomUUID()], ['audio', { data: mono }]], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', randomUUID()], ['durationMs', '3000']], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', randomUUID()], ['durationMs', '3000'], ['file', { data: mono }]], 400, 'INVALID_REQUEST'],
      [[['transcriptionId', randomUUID()], ['durationMs', '3000'], ['audio', { data: mono }], ['audio', { data: mono }]], 400, 'INVALID_REQUEST'],
      // The declared name and MIME type are ignored: only the content counts.
      [[['transcriptionId', randomUUID()], ['durationMs', '3000'], ['audio', { data: Buffer.from('#!/bin/sh\necho hi\n'), name: 'voice.m4a', type: 'audio/mp4' }]], 422, 'AUDIO_INVALID'],
      [[['transcriptionId', randomUUID()], ['durationMs', '9000'], ['audio', { data: mono }]], 422, 'AUDIO_DURATION_MISMATCH'],
    ];
    for (const [parts, status, code] of expectations) {
      const response = await upload(parts);
      expect(response.statusCode, `${JSON.stringify(parts.map(([name]) => name))} ${response.body}`).toBe(status);
      expect(response.json().error.code).toBe(code);
    }
    const json = await built.app.inject({ method: 'POST', url: URL, headers: headers(), payload: { transcriptionId: randomUUID(), durationMs: 3000 } });
    expect(json.statusCode).toBe(400);
    expect(json.json().error.code).toBe('INVALID_REQUEST');
    const badId = await built.app.inject({ method: 'GET', url: `${URL}/not-a-uuid`, headers: headers() });
    expect(badId.statusCode).toBe(400);
    expect((await built.app.inject({ method: 'DELETE', url: `${URL}/${randomUUID()}`, headers: headers() })).statusCode).toBe(404);
    expect(provider.requests.length).toBe(before);
    expect(await leftovers()).toEqual([]);
  });

  it('refuses audio over 10 MB with 413 and removes the partial file', async () => {
    const huge = Buffer.concat([mono, Buffer.alloc(10 * 1024 * 1024)]);
    const response = await upload(voice(randomUUID(), huge));
    expect(response.statusCode).toBe(413);
    expect(response.json().error.code).toBe('AUDIO_TOO_LARGE');
    expect(await leftovers()).toEqual([]);
  });

  it('documents the routes and keeps provider names out of the public readiness check', async () => {
    expect(built.openApi.paths[URL]).toHaveProperty('post');
    expect(built.openApi.paths[`${URL}/:id`]).toHaveProperty('get');
    expect(built.openApi.paths[`${URL}/:id`]).toHaveProperty('delete');
    const ready = await built.app.inject('/api/v1/health/ready');
    expect(ready.json()).toMatchObject({ assistant: 'configured', transcription: 'configured' });
    expect(ready.body).not.toMatch(/scripted|rules|openai|deepseek/i);
    expect((await disabled.app.inject('/api/v1/health/ready')).json()).toMatchObject({ assistant: 'disabled', transcription: 'disabled' });
  });
});
