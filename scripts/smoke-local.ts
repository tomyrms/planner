// Local end-to-end check against a running API (npm run smoke:local).
// Uses the trusted console capability, then the public HTTP routes. Prints no secret or token.
import { loadConfig } from '../src/config.js';
import { createPool } from '../src/infrastructure/db/pool.js';
import { AuthService } from '../src/modules/auth/index.js';

const baseUrl = process.env.SMOKE_BASE_URL ?? 'http://127.0.0.1:4317';
const config = loadConfig();
const pool = createPool(config.databaseUrl);
const steps: string[] = [];

async function call(method: string, path: string, init: { body?: unknown; token?: string } = {}): Promise<{ status: number; json: any }> {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      ...(init.body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(init.token ? { authorization: `Bearer ${init.token}` } : {}),
    },
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  const text = await response.text();
  return { status: response.status, json: text ? JSON.parse(text) : null };
}

function expectStatus(label: string, actual: number, expected: number): void {
  if (actual !== expected) throw new Error(`${label}: HTTP ${actual}, attendu ${expected}`);
  steps.push(`${label} → ${actual}`);
}

try {
  const live = await call('GET', '/api/v1/health/live');
  expectStatus('health/live', live.status, 200);
  const ready = await call('GET', '/api/v1/health/ready');
  expectStatus('health/ready', ready.status, 200);
  if (ready.json.sync !== 'not_installed') throw new Error('Portée de readiness inattendue');

  const service = new AuthService(pool, config.auth);
  const { pairingSecret } = await service.createPairingSecret({ name: 'Smoke test local' });
  const device = { name: 'Smoke test local', platform: 'ios', osVersion: '26.0', appVersion: '0.1.0-smoke' };
  const paired = await call('POST', '/api/v1/auth/pair/complete', { body: { pairingSecret, device } });
  expectStatus('pair/complete', paired.status, 201);
  expectStatus('pair/complete rejoué', (await call('POST', '/api/v1/auth/pair/complete', { body: { pairingSecret, device } })).status, 401);

  const rotated = await call('POST', '/api/v1/auth/refresh', { body: { refreshToken: paired.json.refreshToken } });
  expectStatus('auth/refresh', rotated.status, 200);
  const sync = await call('GET', '/api/v1/auth/sync-token', { token: rotated.json.accessToken });
  expectStatus('auth/sync-token', sync.status, 200);
  const jwks = await call('GET', '/.well-known/jwks.json');
  expectStatus('jwks', jwks.status, 200);
  if (jwks.json.keys.some((key: Record<string, unknown>) => 'd' in key)) throw new Error('Clé privée exposée dans le JWKS');

  expectStatus('auth/logout', (await call('POST', '/api/v1/auth/logout', { token: rotated.json.accessToken })).status, 200);
  expectStatus('refresh après logout', (await call('POST', '/api/v1/auth/refresh', { body: { refreshToken: rotated.json.refreshToken } })).status, 401);
  expectStatus('sync-token après logout', (await call('GET', '/api/v1/auth/sync-token', { token: rotated.json.accessToken })).status, 401);
  expectStatus('route CRUD absente', (await call('POST', '/api/v1/tasks', { body: {} })).status, 404);

  process.stdout.write(`Smoke local réussi (${baseUrl}) :\n${steps.map((step) => `  ✓ ${step}`).join('\n')}\n`);
} catch (error) {
  process.stderr.write(`Smoke local en échec : ${error instanceof Error ? error.message : 'erreur inconnue'}\n`);
  process.exitCode = 1;
} finally {
  await pool.end();
}
