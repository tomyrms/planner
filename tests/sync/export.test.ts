import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../../src/app.js';
import { AuthService, type AuthConfig, type TokenResponse } from '../../src/modules/auth/index.js';
import { executeCommand, type CommandActor } from '../../src/modules/sync/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { command } from './helpers.js';

describe('GET /api/v1/export', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let built: Awaited<ReturnType<typeof buildApp>>;
  let auth: AuthService;
  let tokens: TokenResponse;
  let now = new Date('2026-09-16T10:00:00Z');

  beforeAll(async () => {
    db = await createTestDatabase();
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048, publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    const config: AuthConfig = {
      issuer: 'http://planner.test', apiAudience: 'planner-api', syncAudience: 'planner-sync', keyId: 'test-key',
      privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey, refreshDerivationKey: randomBytes(32).toString('hex'),
    };
    built = await buildApp({ pool: db.pool, auth: config, sync: { clock: () => now } });
    auth = new AuthService(db.pool, config);
    tokens = await pair();
  });
  afterAll(async () => { await built?.app.close(); await db?.close(); });

  async function pair(userId?: string): Promise<TokenResponse> {
    const secret = await auth.createPairingSecret({ name: 'iPhone', ...(userId ? { userId } : {}) });
    const response = await built.app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', payload: {
      pairingSecret: secret.pairingSecret, device: { name: 'iPhone', platform: 'ios', osVersion: '26.0', appVersion: '0.1.0' },
    } });
    return response.json<TokenResponse>();
  }
  const ownerOf = async (deviceId: string) => (await db.pool.query<{ user_id: string }>('SELECT user_id FROM devices WHERE id = $1', [deviceId])).rows[0]!.user_id;
  const download = (token = tokens.accessToken) => built.app.inject({ method: 'GET', url: '/api/v1/export', headers: { authorization: `Bearer ${token}` } });

  it('exports the user data in the contract shape, from one snapshot, never another user data', async () => {
    const actor: CommandActor = { userId: await ownerOf(tokens.deviceId), deviceId: tokens.deviceId, origin: 'manual' };
    const listId = randomUUID();
    const taskId = randomUUID();
    const seriesId = randomUUID();
    const reminderId = randomUUID();
    const run = async (input: ReturnType<typeof command>, as = actor) => {
      const result = await executeCommand(db.pool, as, input, () => now);
      expect(result.outcome).toBe('applied');
    };
    await run(command('project.create', listId, { name: 'Maison' }));
    await run(command('task.create', taskId, {
      title: 'Réparer la fuite', notes: 'Joint 12 mm', projectId: listId, priority: 'high',
      schedule: { date: '2026-09-18', time: '17:00', timeZone: 'Europe/Zurich' }, deadline: { date: '2026-09-20', time: null, timeZone: null },
      reminders: [{ id: reminderId, rule: { kind: 'before_start', offsetMinutes: 30 } }],
    }));
    await run(command('task.create', seriesId, { title: 'Arroser', recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 1 }, schedule: { date: '2026-09-01', time: null, timeZone: null } }));
    await run(command('occurrence.reschedule', seriesId, { occurrenceKey: '2026-09-17', schedule: { date: '2026-09-18', time: '07:15', timeZone: 'Europe/Zurich' } }));
    const otherUser = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
    await run(command('task.create', randomUUID(), { title: 'Secret d’un autre' }), { userId: otherUser, deviceId: null, origin: 'manual' });

    const response = await download();
    expect(response.statusCode).toBe(200);
    expect(response.headers['cache-control']).toBe('no-store');
    expect(response.headers['content-disposition']).toBe('attachment; filename="planner-export-2026-09-16.json"');
    expect(response.body).not.toContain('Secret d’un autre');
    const archive = response.json();
    const generation = (await db.pool.query('SELECT generation FROM server_meta')).rows[0].generation;
    expect(archive).toMatchObject({ exportVersion: 1, exportedAt: '2026-09-16T10:00:00.000Z', serverGeneration: generation, conversations: [] });
    expect(archive.projects).toEqual([expect.objectContaining({ id: listId, name: 'Maison', archivedAt: null, deletedAt: null, revision: 1 })]);
    expect(archive.tasks).toHaveLength(2);
    expect(archive.tasks.find((task: { id: string }) => task.id === taskId)).toEqual(expect.objectContaining({
      projectId: listId, title: 'Réparer la fuite', notes: 'Joint 12 mm', priority: 'high', status: 'active',
      schedule: { date: '2026-09-18', time: '17:00', timeZone: 'Europe/Zurich' },
      deadline: { date: '2026-09-20', time: null, timeZone: null }, recurrence: null, revision: 1,
    }));
    expect(archive.tasks.find((task: { id: string }) => task.id === seriesId)).toMatchObject({ recurrence: { mode: 'fixed', freq: 'daily' }, revision: 2 });
    expect(archive.taskOccurrences).toEqual([expect.objectContaining({
      taskId: seriesId, occurrenceKey: '2026-09-17', status: 'open', override: { date: '2026-09-18', time: '07:15', timeZone: 'Europe/Zurich' },
    })]);
    expect(archive.reminders).toEqual([expect.objectContaining({
      id: reminderId, taskId, kind: 'before_start', offsetMinutes: 30, localTime: null, absolute: null, state: 'active', deletedAt: null,
    })]);
    expect(JSON.stringify(archive)).not.toMatch(/user_id|userId|search_text|payload_hash/);
  });

  it('limits exports per device and requires authentication', async () => {
    now = new Date('2026-09-16T10:00:30Z');
    const limited = await download();
    expect(limited.statusCode).toBe(429);
    expect(limited.headers['retry-after']).toBe('30');
    expect(limited.json()).toMatchObject({ error: { code: 'RATE_LIMITED' } });
    now = new Date('2026-09-16T10:01:00Z');
    expect((await download()).statusCode).toBe(200);
    const unauthenticated = await built.app.inject({ method: 'GET', url: '/api/v1/export' });
    expect(unauthenticated.statusCode).toBe(401);
    expect(built.openApi.paths['/api/v1/export']?.get).toMatchObject({ security: [{ bearerAuth: [] }] });
  });
});
