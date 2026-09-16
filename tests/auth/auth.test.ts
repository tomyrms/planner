import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import Fastify, { type FastifyInstance } from 'fastify';
import { decodeJwt, jwtVerify, importSPKI, importPKCS8, SignJWT } from 'jose';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { AuthService, registerAuthRoutes, type AuthConfig, type TokenResponse } from '../../src/modules/auth/index.js';
import { registerErrorHandler } from '../../src/errors.js';
import { createTestDatabase } from '../db/helpers.js';

describe('PostgreSQL authentication lifecycle', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let app: FastifyInstance;
  let service: AuthService;
  let config: AuthConfig;
  let now = new Date('2026-09-15T12:00:00.000Z');
  let ipCounter = 0;
  const device = { name: 'Test iPhone', platform: 'ios', osVersion: '26.0', appVersion: '0.1.0' };
  const ip = () => `198.51.100.${++ipCounter}`;
  const bearer = (tokens: TokenResponse) => ({ authorization: `Bearer ${tokens.accessToken}` });

  beforeAll(async () => {
    db = await createTestDatabase();
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048, publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    config = {
      issuer: 'http://planner.test', apiAudience: 'planner-api', syncAudience: 'planner-sync', keyId: 'test-key',
      privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey,
      refreshDerivationKey: randomBytes(32).toString('hex'), now: () => now,
    };
    app = Fastify({ logger: false, ajv: { customOptions: { removeAdditional: false, coerceTypes: false } } });
    registerErrorHandler(app);
    service = registerAuthRoutes(app, { pool: db.pool, config });
    await app.ready();
  });
  beforeEach(() => { now = new Date('2026-09-15T12:00:00.000Z'); });
  afterAll(async () => { await app?.close(); await db?.close(); });

  async function pair(): Promise<TokenResponse> {
    const secret = await service.createPairingSecret({ name: 'iPhone' });
    const result = await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: secret.pairingSecret, device } });
    expect(result.statusCode).toBe(201);
    return result.json<TokenResponse>();
  }
  const refresh = (token: string) => app.inject({ method: 'POST', url: '/api/v1/auth/refresh', payload: { refreshToken: token } });

  it('has no HTTP capability to create an enrollment secret', async () => {
    for (const url of ['/api/v1/auth/pair', '/api/v1/auth/pair/create', '/api/v1/admin/pair']) {
      expect((await app.inject({ method: 'POST', url, payload: {} })).statusCode).toBe(404);
    }
  });

  it('pairs once, stores only hashes, and sends no-store token responses', async () => {
    const secret = await service.createPairingSecret({ name: 'iPhone' });
    const request = { method: 'POST' as const, url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: secret.pairingSecret, device } };
    const response = await app.inject(request);
    expect(response.statusCode).toBe(201);
    expect(response.headers['cache-control']).toBe('no-store');
    expect((await app.inject(request)).statusCode).toBe(401);
    const tokens = response.json<TokenResponse>();
    const pairs = await db.pool.query('SELECT * FROM auth_pairing_secrets WHERE id=$1', [secret.pairingSecret.split('.')[0]]);
    const stored = await db.pool.query('SELECT * FROM auth_refresh_tokens WHERE id=$1', [tokens.refreshToken.split('.')[0]]);
    expect(pairs.rows[0].secret_hash).toMatch(/^[a-f0-9]{64}$/);
    expect(stored.rows[0].token_hash).toMatch(/^[a-f0-9]{64}$/);
    expect(JSON.stringify([...pairs.rows, ...stored.rows])).not.toContain(secret.pairingSecret);
    expect(JSON.stringify(stored.rows)).not.toContain(tokens.refreshToken);
    expect(await service.authenticate(`Bearer ${tokens.accessToken}`)).toMatchObject({ deviceId: tokens.deviceId });
    expect(tokens.serverGeneration).toBe((await db.pool.query('SELECT generation FROM server_meta')).rows[0].generation);
  });

  it('allows only one winner when a pairing secret is submitted concurrently', async () => {
    const secret = await service.createPairingSecret({ name: 'iPhone' });
    const responses = await Promise.all(Array.from({ length: 4 }, () => app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: secret.pairingSecret, device } })));
    expect(responses.map(r => r.statusCode).sort()).toEqual([201, 401, 401, 401]);
  });

  it('rejects pairing at ten minutes and locks it after five incorrect proofs', async () => {
    const expired = await service.createPairingSecret({ name: 'iPhone' });
    now = new Date(now.getTime() + 600_000);
    expect((await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: expired.pairingSecret, device } })).statusCode).toBe(401);
    const locked = await service.createPairingSecret({ name: 'iPhone' });
    const wrong = `${locked.pairingSecret.split('.')[0]}.${randomBytes(32).toString('base64url')}`;
    for (let n = 0; n < 5; n++) expect((await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: wrong, device } })).statusCode).toBe(401);
    expect((await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: locked.pairingSecret, device } })).statusCode).toBe(401);
    expect((await db.pool.query('SELECT failed_attempts FROM auth_pairing_secrets WHERE id=$1', [locked.pairingSecret.split('.')[0]])).rows[0].failed_attempts).toBe(5);
  });

  it('persists IP rate limiting across unknown secrets and returns Retry-After', async () => {
    const address = ip();
    for (let n = 0; n < 10; n++) expect((await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: address, payload: { pairingSecret: 'unknown', device } })).statusCode).toBe(401);
    const limited = await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: address, payload: { pairingSecret: 'unknown', device } });
    expect(limited.statusCode).toBe(429);
    expect(Number(limited.headers['retry-after'])).toBe(3600);
    expect(JSON.stringify((await db.pool.query('SELECT * FROM auth_pair_rate_limits')).rows)).not.toContain(address);
    now = new Date(now.getTime() + 3_600_000);
    expect((await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: address, payload: { pairingSecret: 'unknown', device } })).statusCode).toBe(401);
  });

  it('returns byte-identical tokens on one lost-response retry then revokes the family', async () => {
    const original = await pair();
    const rotated = await refresh(original.refreshToken);
    expect(rotated.statusCode).toBe(200);
    const replacement = rotated.json<TokenResponse>();
    now = new Date(now.getTime() + 30_000);
    const retry = await refresh(original.refreshToken);
    expect(retry.statusCode).toBe(200);
    expect(retry.json()).toEqual(replacement);
    const replay = await refresh(original.refreshToken);
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error.code).toBe('TOKEN_REUSED');
    expect((await refresh(replacement.refreshToken)).statusCode).toBe(401);
    expect((await app.inject({ method: 'GET', url: '/api/v1/auth/sync-token', headers: bearer(replacement) })).statusCode).toBe(401);
  });

  it('serializes simultaneous refreshes into one replacement without a branch', async () => {
    const original = await pair();
    const responses = await Promise.all([refresh(original.refreshToken), refresh(original.refreshToken)]);
    expect(responses.map(r => r.statusCode)).toEqual([200, 200]);
    expect(responses[0]!.json()).toEqual(responses[1]!.json());
    const sessionId = decodeJwt(original.accessToken).session_id;
    expect((await db.pool.query('SELECT id FROM auth_refresh_tokens WHERE session_id=$1', [sessionId])).rowCount).toBe(2);
  });

  it('revokes a family on old refresh reuse after the sixty second window', async () => {
    const original = await pair();
    const replacement = (await refresh(original.refreshToken)).json<TokenResponse>();
    now = new Date(now.getTime() + 60_001);
    expect((await refresh(original.refreshToken)).json().error.code).toBe('TOKEN_REUSED');
    expect((await refresh(replacement.refreshToken)).statusCode).toBe(401);
  });

  it('does not revoke a family when an attacker knows only the public token selector', async () => {
    const original = await pair();
    const forged = `${original.refreshToken.split('.')[0]}.${randomBytes(32).toString('base64url')}`;
    expect((await refresh(forged)).statusCode).toBe(401);
    expect((await refresh(original.refreshToken)).statusCode).toBe(200);
  });

  it('extends refresh validity sixty days from rotation and rejects expired refreshes', async () => {
    const original = await pair();
    now = new Date(now.getTime() + 59 * 86_400_000);
    const rotated = await refresh(original.refreshToken);
    expect(rotated.statusCode).toBe(200);
    const row = (await db.pool.query('SELECT expires_at FROM auth_refresh_tokens WHERE id=$1', [rotated.json<TokenResponse>().refreshToken.split('.')[0]])).rows[0];
    expect(row.expires_at.toISOString()).toBe(new Date(now.getTime() + 60 * 86_400_000).toISOString());
    now = new Date(now.getTime() + 60 * 86_400_000);
    expect((await refresh(rotated.json<TokenResponse>().refreshToken)).statusCode).toBe(401);
  });

  it('separates token audiences, publishes public keys only, and checks fifteen minute expiry', async () => {
    const original = await pair();
    const result = await app.inject({ method: 'GET', url: '/api/v1/auth/sync-token', headers: bearer(original) });
    expect(result.statusCode).toBe(200);
    const sync = result.json<{ token: string; expiresAt: string }>();
    const verified = await jwtVerify(sync.token, await importSPKI(config.publicKeyPem, 'RS256'), { issuer: config.issuer, audience: config.syncAudience, currentDate: now });
    expect(verified.payload.sub).toBe(decodeJwt(original.accessToken).sub);
    expect(verified.payload.exp! - verified.payload.iat!).toBe(900);
    expect((await app.inject({ method: 'GET', url: '/api/v1/auth/sync-token', headers: { authorization: `Bearer ${sync.token}` } })).statusCode).toBe(401);
    const jwks = (await app.inject({ method: 'GET', url: '/.well-known/jwks.json' })).json();
    expect(jwks.keys[0]).toMatchObject({ kid: config.keyId, alg: 'RS256', kty: 'RSA' });
    expect(jwks.keys[0].d).toBeUndefined();
    now = new Date(now.getTime() + 900_000);
    expect((await app.inject({ method: 'GET', url: '/api/v1/auth/sync-token', headers: bearer(original) })).statusCode).toBe(401);
  });

  it('rejects a valid signature whose user does not own its session', async () => {
    const original = await pair();
    const payload = decodeJwt(original.accessToken);
    const forged = await new SignJWT({ ...payload, sub: randomUUID() }).setProtectedHeader({ alg: 'RS256', kid: config.keyId, typ: 'JWT' }).sign(await importPKCS8(config.privateKeyPem, 'RS256'));
    expect((await app.inject({ method: 'GET', url: '/api/v1/auth/sync-token', headers: { authorization: `Bearer ${forged}` } })).statusCode).toBe(401);
  });

  it('revokes API and refresh immediately when logging out or revoking from console', async () => {
    const original = await pair();
    expect((await app.inject({ method: 'POST', url: '/api/v1/auth/logout', headers: bearer(original) })).statusCode).toBe(200);
    expect((await refresh(original.refreshToken)).statusCode).toBe(401);
    expect((await app.inject({ method: 'GET', url: '/api/v1/auth/sync-token', headers: bearer(original) })).statusCode).toBe(401);
    const second = await pair();
    expect(await service.revokeDevice(second.deviceId)).toBe(true);
    expect((await refresh(second.refreshToken)).statusCode).toBe(401);
  });

  it('forbids user/device ownership fields from the client', async () => {
    const secret = await service.createPairingSecret({ name: 'iPhone' });
    const result = await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: secret.pairingSecret, device, user_id: randomUUID() } });
    expect(result.statusCode).toBe(400);
    const blankName = await app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', remoteAddress: ip(), payload: { pairingSecret: secret.pairingSecret, device: { ...device, name: ' ' } } });
    expect(blankName.statusCode).toBe(400);
  });
});
