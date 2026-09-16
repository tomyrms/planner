import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../../src/app.js';
import { AuthService, type AuthConfig, type TokenResponse } from '../../src/modules/auth/index.js';
import { clientVersionAccepted } from '../../src/modules/sync/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { command } from './helpers.js';

const URL = '/api/v1/sync/mutations';

describe('POST /api/v1/sync/mutations', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let built: Awaited<ReturnType<typeof buildApp>>;
  let auth: AuthService;
  let tokens: TokenResponse;
  let generation: string;

  beforeAll(async () => {
    db = await createTestDatabase();
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048, publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    const config: AuthConfig = {
      issuer: 'http://planner.test', apiAudience: 'planner-api', syncAudience: 'planner-sync', keyId: 'test-key',
      privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey, refreshDerivationKey: randomBytes(32).toString('hex'),
    };
    built = await buildApp({ pool: db.pool, auth: config, sync: { minimumClientVersion: '0.2.0' } });
    auth = new AuthService(db.pool, config);
    tokens = await pair();
    generation = tokens.serverGeneration;
  });
  afterAll(async () => { await built?.app.close(); await db?.close(); });

  async function pair(userId?: string): Promise<TokenResponse> {
    const secret = await auth.createPairingSecret({ name: 'iPhone', ...(userId ? { userId } : {}) });
    const response = await built.app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', payload: {
      pairingSecret: secret.pairingSecret, device: { name: 'iPhone', platform: 'ios', osVersion: '26.0', appVersion: '0.2.0' },
    } });
    expect(response.statusCode).toBe(201);
    return response.json<TokenResponse>();
  }
  const headers = (token = tokens.accessToken, version = '0.2.0 (build 7)') => ({ authorization: `Bearer ${token}`, 'x-client-version': version });
  const send = (payload: unknown, requestHeaders: Record<string, string> = headers()) =>
    built.app.inject({ method: 'POST', url: URL, headers: requestHeaders, payload: payload as Record<string, unknown> });
  const receipts = async () => (await db.pool.query<{ n: number }>('SELECT count(*)::int AS n FROM command_receipts')).rows[0]!.n;

  it('authenticates before reading the envelope and never leaks the body', async () => {
    const secret = 'private-note-content';
    for (const requestHeaders of [{ 'x-client-version': '0.2.0' }, headers('not-a-token'), headers(tokens.refreshToken)]) {
      const response = await send({ notes: secret }, requestHeaders);
      expect(response.statusCode).toBe(401);
      expect(response.headers['cache-control']).toBe('no-store');
      expect(response.json()).toMatchObject({ error: { code: 'INVALID_TOKEN' } });
      expect(response.body).not.toContain(secret);
    }
  });

  it('asks an outdated or unidentified app to update before any command runs', async () => {
    const before = await receipts();
    const envelope = { envelopeVersion: 1, serverGeneration: generation, commands: [command('task.create', randomUUID(), { title: 'x' })] };
    for (const version of ['0.1.9 (build 3)', 'dev', '']) {
      const response = await send(envelope, headers(tokens.accessToken, version));
      expect(response.statusCode).toBe(426);
      expect(response.json()).toMatchObject({ error: { code: 'CLIENT_TOO_OLD', minimumVersion: '0.2.0' } });
    }
    expect(await receipts()).toBe(before);
  });

  it('refuses malformed envelopes as a protocol error', async () => {
    const valid = command('task.create', randomUUID(), { title: 'x' });
    const cases = [
      {},
      { envelopeVersion: 2, serverGeneration: generation, commands: [valid] },
      { envelopeVersion: 1, serverGeneration: generation, commands: [] },
      { envelopeVersion: 1, serverGeneration: generation, commands: Array.from({ length: 101 }, () => valid) },
      { envelopeVersion: 1, serverGeneration: generation, commands: [{ ...valid, userId: randomUUID() }] },
      { envelopeVersion: 1, serverGeneration: generation, commands: [{ ...valid, clientRecordedAt: '2026-09-16T10:00:00' }] },
      { envelopeVersion: 1, serverGeneration: generation, deviceId: randomUUID(), commands: [valid] },
    ];
    const before = await receipts();
    for (const payload of cases) {
      const response = await send(payload);
      expect(response.statusCode, JSON.stringify(payload).slice(0, 80)).toBe(400);
      expect(response.json()).toMatchObject({ error: { code: 'INVALID_ENVELOPE' } });
    }
    expect(await receipts()).toBe(before);
  });

  it('stops everything when the client saw another server generation', async () => {
    const before = await receipts();
    const response = await send({ envelopeVersion: 1, serverGeneration: randomUUID(), commands: [command('task.create', randomUUID(), { title: 'x' })] });
    expect(response.statusCode).toBe(409);
    expect(response.json()).toMatchObject({ error: { code: 'SERVER_GENERATION_CHANGED', serverGeneration: generation } });
    expect(await receipts()).toBe(before);
  });

  it('applies commands in order and answers with final results', async () => {
    const taskId = randomUUID();
    const create = command('task.create', taskId, { title: 'Acheter du pain' });
    const rejected = command('task.patch', randomUUID(), { set: { title: 'x' } });
    const patch = command('task.patch', taskId, { set: { notes: 'Complet' } }, { precondition: { kind: 'afterCommand', clientCommandId: create.clientCommandId } });
    const response = await send({ envelopeVersion: 1, serverGeneration: generation.toUpperCase(), commands: [create, rejected, patch, create] });
    expect(response.statusCode).toBe(200);
    expect(response.headers['cache-control']).toBe('no-store');
    expect(response.json()).toEqual({
      serverGeneration: generation,
      results: [
        { clientCommandId: create.clientCommandId, outcome: 'applied', revision: 1, aggregateId: taskId },
        { clientCommandId: rejected.clientCommandId, outcome: 'rejected', code: 'ENTITY_NOT_FOUND', message: 'The target does not exist.' },
        { clientCommandId: patch.clientCommandId, outcome: 'applied', revision: 2, aggregateId: taskId },
        { clientCommandId: create.clientCommandId, outcome: 'duplicate', original: { outcome: 'applied', revision: 1, aggregateId: taskId } },
      ],
    });
    const stored = await db.pool.query('SELECT device_id, origin FROM command_receipts WHERE client_command_id = $1', [create.clientCommandId]);
    expect(stored.rows[0]).toEqual({ device_id: tokens.deviceId, origin: 'manual' });
  });

  it('isolates users and stops a revoked device', async () => {
    const otherUser = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    const second = await pair(otherUser);
    const taskId = randomUUID();
    expect((await send({ envelopeVersion: 1, serverGeneration: generation, commands: [command('task.create', taskId, { title: 'Privé' })] })).statusCode).toBe(200);
    const foreign = await send({ envelopeVersion: 1, serverGeneration: generation, commands: [command('task.patch', taskId, { set: { title: 'volé' } })] }, headers(second.accessToken));
    expect(foreign.json().results[0]).toMatchObject({ outcome: 'rejected', code: 'ENTITY_NOT_FOUND' });
    expect((await db.pool.query('SELECT title FROM tasks WHERE id = $1', [taskId])).rows[0].title).toBe('Privé');
    await auth.revokeDevice(second.deviceId);
    const revoked = await send({ envelopeVersion: 1, serverGeneration: generation, commands: [command('task.create', randomUUID(), { title: 'x' })] }, headers(second.accessToken));
    expect(revoked.statusCode).toBe(401);
  });

  it('rejects an oversized body with 413', async () => {
    const response = await send({ envelopeVersion: 1, serverGeneration: generation, commands: [command('task.create', randomUUID(), { title: 'x', notes: 'a'.repeat(1_100_000) })] });
    expect(response.statusCode).toBe(413);
    expect(response.json()).toMatchObject({ error: { code: 'PAYLOAD_TOO_LARGE' } });
  });

  it('documents the route with bearer authentication', () => {
    expect(built.openApi.paths[URL]?.post).toMatchObject({ security: [{ bearerAuth: [] }] });
  });
});

describe('client version header', () => {
  it('compares semantic versions and ignores the build number', () => {
    expect(clientVersionAccepted('0.1.0 (build 12)', '0.1.0')).toBe(true);
    expect(clientVersionAccepted('0.10.0', '0.9.3')).toBe(true);
    expect(clientVersionAccepted('1.0.0', '0.9.9')).toBe(true);
    expect(clientVersionAccepted('0.0.9', '0.1.0')).toBe(false);
    expect(clientVersionAccepted(['0.2.0', '0.0.1'], '0.2.0')).toBe(true);
    for (const value of [undefined, '', '0.1', 'v0.1.0', '0.1.0-beta', '0.1.0 (build x)']) {
      expect(clientVersionAccepted(value, '0.1.0')).toBe(false);
    }
    expect(() => clientVersionAccepted('0.1.0', 'latest')).toThrow();
  });
});
