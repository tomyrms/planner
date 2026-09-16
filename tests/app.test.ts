import { generateKeyPairSync } from 'node:crypto';
import type { Pool } from 'pg';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';

const keys = generateKeyPairSync('rsa', { modulusLength: 2048, privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } });
const auth = {
  issuer: 'https://planner.test', apiAudience: 'planner-api', syncAudience: 'planner-sync',
  privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey, keyId: 'test', refreshDerivationKey: 'a'.repeat(64),
};
const apps: Awaited<ReturnType<typeof buildApp>>[] = [];
afterEach(async () => { for (const { app } of apps.splice(0)) await app.close(); });

describe('API boundary', () => {
  async function setup(query = vi.fn()) {
    const built = await buildApp({ pool: { query } as unknown as Pool, auth });
    apps.push(built);
    return { ...built, query };
  }
  it('is alive independently of PostgreSQL and reports not-ready without leaking database failures', async () => {
    const { app } = await setup(vi.fn().mockRejectedValue(new Error('private-password private-task')));
    expect((await app.inject('/api/v1/health/live')).statusCode).toBe(200);
    const result = await app.inject('/api/v1/health/ready');
    expect(result.statusCode).toBe(503);
    expect(result.body).not.toContain('private');
    expect(result.json()).toMatchObject({ scope: 'backend-foundation', sync: 'not_installed', database: 'unavailable' });
  });
  it('reports the limited readiness scope honestly after the schema exists', async () => {
    const { app } = await setup(vi.fn().mockResolvedValue({ rowCount: 1, rows: [{ generation: 'g' }] }));
    expect((await app.inject('/api/v1/health/ready')).json()).toMatchObject({ status: 'ready', sync: 'not_installed' });
  });
  it('rejects added ownership fields instead of silently stripping them', async () => {
    const { app, query } = await setup();
    const result = await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', payload: {
      pairingSecret: 'a-secret', userId: 'other-user', device: { name: 'iPhone', platform: 'ios', osVersion: '26', appVersion: '0.1' },
    } });
    expect(result.statusCode).toBe(400);
    expect(result.json().error.code).toBe('INVALID_PAYLOAD');
    expect(result.body).not.toContain('a-secret');
    expect(query).not.toHaveBeenCalled();
  });
  it('does not expose a public pairing initiation route or CRUD API', async () => {
    const { app } = await setup();
    for (const url of ['/api/v1/auth/pair', '/api/v1/tasks', '/api/v1/projects']) {
      expect((await app.inject({ method: 'POST', url })).statusCode).toBe(404);
    }
  });
  it('generates schemas for real routes and marks bearer authentication', async () => {
    const { app, openApi } = await setup();
    for (const [url, methods] of Object.entries(openApi.paths)) {
      for (const method of Object.keys(methods)) {
        expect(app.hasRoute({ method: method.toUpperCase() as 'GET' | 'POST', url })).toBe(true);
      }
    }
    expect(openApi.paths['/api/v1/auth/sync-token']?.get).toMatchObject({ security: [{ bearerAuth: [] }] });
    expect(JSON.stringify(openApi)).not.toContain('PRIVATE KEY');
  });
});
