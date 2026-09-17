import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../../src/app.js';
import type { ReasoningProvider } from '../../src/modules/assistant/index.js';
import { AuthService, type AuthConfig, type TokenResponse } from '../../src/modules/auth/index.js';
import { createTestDatabase } from '../db/helpers.js';

describe('GET /api/v1/diagnostics', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let built: Awaited<ReturnType<typeof buildApp>>;
  let tokens: TokenResponse;
  const now = new Date('2026-09-17T10:00:00Z');

  beforeAll(async () => {
    db = await createTestDatabase();
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048, publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    const config: AuthConfig = {
      issuer: 'http://planner.test', apiAudience: 'planner-api', syncAudience: 'planner-sync', keyId: 'test-key',
      privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey, refreshDerivationKey: randomBytes(32).toString('hex'),
    };
    const provider: ReasoningProvider = { name: 'deepseek', model: 'deepseek-test', respond: async () => { throw new Error('unused'); } };
    built = await buildApp({
      pool: db.pool, auth: config, sync: { clock: () => now, minimumClientVersion: '0.2.0' },
      assistant: { provider, limits: { monthlyTokenBudget: 1000 } },
      voice: { provider: null },
    });
    const auth = new AuthService(db.pool, config);
    const secret = await auth.createPairingSecret({ name: 'iPhone' });
    const response = await built.app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', payload: {
      pairingSecret: secret.pairingSecret, device: { name: 'iPhone', platform: 'ios', osVersion: '26.0', appVersion: '0.1.0' },
    } });
    tokens = response.json<TokenResponse>();
  });
  afterAll(async () => { await built?.app.close(); await db?.close(); });

  const read = (token?: string) => built.app.inject({
    method: 'GET', url: '/api/v1/diagnostics', ...(token ? { headers: { authorization: `Bearer ${token}` } } : {}),
  });

  it('requires a device token', async () => {
    const response = await read();
    expect(response.statusCode).toBe(401);
  });

  it('reports generation, providers, monthly counters and maintenance dates, without content', async () => {
    const user = (await db.pool.query<{ user_id: string }>('SELECT user_id FROM devices WHERE id = $1', [tokens.deviceId])).rows[0]!.user_id;
    await db.pool.query(
      `INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, attempts, created_at)
       VALUES (gen_random_uuid(), $1, 'erased', 90000, 100, $2, 2, $3), (gen_random_uuid(), $1, 'erased', 90000, 100, $2, 4, '2026-08-31T23:00:00Z')`,
      [user, 'b'.repeat(64), now]);
    await db.pool.query(`INSERT INTO transcription_attempts
      (transcription_id, attempt, user_id, duration_ms, state, reserved_at, budget_at, dispatched_at)
      SELECT t.id, n.attempt, t.user_id, t.duration_ms, 'dispatched', t.created_at, t.created_at, t.created_at
      FROM transcriptions t CROSS JOIN LATERAL generate_series(1, t.attempts) AS n(attempt) WHERE t.user_id = $1`, [user]);
    // This recording was created in August, retried in September, then again in October.
    // Diagnostics counts only the September attempt; a released reservation contributes nothing.
    await db.pool.query(`UPDATE transcription_attempts a SET budget_at = $2, dispatched_at = $2
      FROM transcriptions t WHERE a.transcription_id = t.id AND t.user_id = $1 AND t.attempts = 4 AND a.attempt = 2`, [user, now]);
    await db.pool.query(`UPDATE transcription_attempts a SET budget_at = '2026-10-01T00:00:00Z', dispatched_at = '2026-10-01T00:00:00Z'
      FROM transcriptions t WHERE a.transcription_id = t.id AND t.user_id = $1 AND t.attempts = 4 AND a.attempt = 3`, [user]);
    await db.pool.query(`UPDATE transcription_attempts a SET state = 'released', reserved_at = $2, budget_at = $2, dispatched_at = NULL, released_at = $2
      FROM transcriptions t WHERE a.transcription_id = t.id AND t.user_id = $1 AND t.attempts = 4 AND a.attempt = 4`, [user, now]);
    await db.pool.query(
      `INSERT INTO maintenance_runs (kind, outcome, finished_at) VALUES
       ('backup', 'succeeded', '2026-09-16T02:00:00Z'), ('backup', 'succeeded', '2026-09-17T02:00:00Z'),
       ('backup_verify', 'failed', '2026-09-17T02:05:00Z')`);
    const response = await read(tokens.accessToken);
    expect(response.statusCode).toBe(200);
    expect(response.headers['cache-control']).toBe('no-store');
    const generation = (await db.pool.query('SELECT generation FROM server_meta')).rows[0].generation;
    // Publication and replication slot belong to the whole test database: only their shape is checked.
    const body = response.json();
    expect(['provisioned', 'not_provisioned']).toContain(body.sync);
    expect(body.replicationLagBytes === null || Number.isInteger(body.replicationLagBytes)).toBe(true);
    expect({ ...body, sync: '-', replicationLagBytes: '-' }).toEqual({
      generatedAt: '2026-09-17T10:00:00.000Z',
      serverGeneration: generation,
      minimumClientVersion: '0.2.0',
      sync: '-',
      replicationLagBytes: '-',
      assistant: { status: 'configured', provider: 'deepseek', model: 'deepseek-test', monthTokens: 0, monthTokenBudget: 1000 },
      transcription: { status: 'disabled', provider: null, model: null, monthMinutes: 4.5, monthMinuteBudget: 600 },
      maintenance: {
        backup: { lastSucceededAt: '2026-09-17T02:00:00.000Z', lastFailedAt: null },
        backupVerify: { lastSucceededAt: null, lastFailedAt: '2026-09-17T02:05:00.000Z' },
        restore: { lastSucceededAt: null, lastFailedAt: null },
        purge: { lastSucceededAt: null, lastFailedAt: null },
        audioCleanup: { lastSucceededAt: null, lastFailedAt: null },
      },
    });
  });
});
