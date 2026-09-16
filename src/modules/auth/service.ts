import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { exportJWK, importPKCS8, importSPKI, jwtVerify, SignJWT } from 'jose';
import type { Pool, PoolClient } from 'pg';
import type { PairInput, TokenResponse } from './schemas.js';

const ACCESS_SECONDS = 15 * 60;
const REFRESH_MS = 60 * 24 * 60 * 60 * 1000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface AuthConfig {
  issuer: string;
  apiAudience: string;
  syncAudience: string;
  privateKeyPem: string;
  publicKeyPem: string;
  keyId: string;
  /** Independent 256-bit key, hex encoded. Never derive this from a JWT key. */
  refreshDerivationKey: string;
  /** Public PowerSync URL handed to the iPhone with each sync token (never compiled into the app). */
  syncEndpoint?: string;
  now?: () => Date;
}

export interface AuthIdentity { userId: string; deviceId: string; sessionId: string }
interface SessionRow { id: string; user_id: string; device_id: string; revoked_at: Date | null; device_revoked_at: Date | null }
interface RefreshRow {
  id: string; session_id: string; token_hash: string; issued_at: Date; expires_at: Date;
  rotated_at: Date | null; replacement_id: string | null; retry_used_at: Date | null;
}

export class AuthError extends Error {
  constructor(public readonly code: string, public readonly statusCode = 401, public readonly retryAfter?: number) {
    super(code === 'RATE_LIMITED' ? 'Trop de tentatives. Réessayez plus tard.' : statusCode === 400 ? 'Requête invalide.' : 'Authentification refusée.');
  }
}

const hash = (value: string) => createHash('sha256').update(value).digest('hex');
function matches(value: string, expected: string): boolean {
  return timingSafeEqual(Buffer.from(hash(value), 'hex'), Buffer.from(expected, 'hex'));
}
function selector(token: string): string | undefined {
  const [id, secret, extra] = token.split('.');
  return id && UUID.test(id) && secret && /^[A-Za-z0-9_-]{43}$/.test(secret) && extra === undefined ? id : undefined;
}

/** Authentication writes use DB transactions and a per-family session lock. */
export class AuthService {
  private privateKeyPromise: ReturnType<typeof importPKCS8> | undefined;
  private publicKeyPromise: ReturnType<typeof importSPKI> | undefined;
  private readonly derivationKey: Buffer;

  constructor(private readonly pool: Pool, private readonly config: AuthConfig) {
    if (!/^[0-9a-f]{64}$/i.test(config.refreshDerivationKey)) throw new Error('AUTH_REFRESH_DERIVATION_KEY must contain 32 random bytes in hex.');
    if (config.apiAudience === config.syncAudience) throw new Error('API and sync audiences must differ.');
    this.derivationKey = Buffer.from(config.refreshDerivationKey, 'hex');
  }

  private privateKey() { return this.privateKeyPromise ??= importPKCS8(this.config.privateKeyPem, 'RS256'); }
  private publicKey() { return this.publicKeyPromise ??= importSPKI(this.config.publicKeyPem, 'RS256'); }

  /** Fail startup before accepting requests if the configured key pair is invalid. */
  async ready(): Promise<void> {
    const proof = await new SignJWT({ purpose: 'configuration-check' })
      .setProtectedHeader({ alg: 'RS256' }).sign(await this.privateKey());
    await jwtVerify(proof, await this.publicKey(), { algorithms: ['RS256'] });
  }

  private now(): Date { return this.config.now?.() ?? new Date(); }
  private refreshValue(id: string): string {
    return `${id}.${createHmac('sha256', this.derivationKey).update(`planner-refresh:v1:${id}`).digest('base64url')}`;
  }
  private async transaction<T>(run: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const result = await run(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally { client.release(); }
  }

  /** Console capability only. Deliberately has no HTTP route. */
  async createPairingSecret(input: { name: string; userId?: string }): Promise<{ pairingSecret: string; expiresAt: string }> {
    const name = input.name.trim();
    if (name.length < 1 || name.length > 100 || (input.userId !== undefined && !UUID.test(input.userId))) throw new Error('Invalid console pairing parameters.');
    return this.transaction(async (client) => {
      // Also prevents two initial console commands from creating two personal users.
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended(current_schema() || ':planner-console-pair', 0))");
      let userId = input.userId;
      if (userId) {
        if (!(await client.query('SELECT id FROM users WHERE id = $1', [userId])).rowCount) throw new Error('Unknown user.');
      } else {
        const users = await client.query<{ id: string }>('SELECT id FROM users ORDER BY created_at LIMIT 2');
        if (users.rows.length > 1) throw new Error('More than one user exists. Pass --user explicitly.');
        userId = users.rows[0]?.id ?? (await client.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
      }
      const id = randomUUID();
      const pairingSecret = `${id}.${randomBytes(32).toString('base64url')}`;
      const now = this.now();
      const expiresAt = new Date(now.getTime() + 10 * 60 * 1000);
      await client.query('INSERT INTO auth_pairing_secrets (id,user_id,console_name,secret_hash,created_at,expires_at) VALUES ($1,$2,$3,$4,$5,$6)', [id, userId, name, hash(pairingSecret), now, expiresAt]);
      return { pairingSecret, expiresAt: expiresAt.toISOString() };
    });
  }

  async pair(input: PairInput, remoteIp: string): Promise<TokenResponse> {
    const result = await this.transaction(async (client): Promise<TokenResponse | AuthError> => {
      const now = this.now();
      // Keyed IP digest avoids retaining plaintext IP addresses. Expired entries are pruned.
      const ipHash = createHmac('sha256', this.derivationKey).update(`planner-pair-ip:v1:${remoteIp}`).digest('hex');
      await client.query("DELETE FROM auth_pair_rate_limits WHERE window_started_at < $1::timestamptz - interval '1 day'", [now]);
      const rate = await client.query<{ attempts: number; window_started_at: Date }>(`
        INSERT INTO auth_pair_rate_limits (ip_hash,window_started_at,attempts) VALUES ($1,$2,1)
        ON CONFLICT (ip_hash) DO UPDATE SET
          attempts = CASE WHEN auth_pair_rate_limits.window_started_at <= $2::timestamptz - interval '1 hour' THEN 1 ELSE auth_pair_rate_limits.attempts + 1 END,
          window_started_at = CASE WHEN auth_pair_rate_limits.window_started_at <= $2::timestamptz - interval '1 hour' THEN $2 ELSE auth_pair_rate_limits.window_started_at END
        RETURNING attempts,window_started_at`, [ipHash, now]);
      const bucket = rate.rows[0]!;
      if (bucket.attempts > 10) return new AuthError('RATE_LIMITED', 429, Math.max(1, Math.ceil((bucket.window_started_at.getTime() + 3_600_000 - now.getTime()) / 1000)));
      const id = selector(input.pairingSecret);
      if (!id) return new AuthError('INVALID_PAIRING_SECRET');
      const pairs = await client.query<{ user_id: string; secret_hash: string; expires_at: Date; consumed_at: Date | null; failed_attempts: number }>('SELECT * FROM auth_pairing_secrets WHERE id = $1 FOR UPDATE', [id]);
      const pair = pairs.rows[0];
      if (!pair || pair.consumed_at || pair.failed_attempts >= 5 || pair.expires_at <= now) return new AuthError('INVALID_PAIRING_SECRET');
      if (!matches(input.pairingSecret, pair.secret_hash)) {
        await client.query('UPDATE auth_pairing_secrets SET failed_attempts = failed_attempts + 1 WHERE id = $1', [id]);
        return new AuthError('INVALID_PAIRING_SECRET');
      }
      await client.query('UPDATE auth_pairing_secrets SET consumed_at = $2 WHERE id = $1', [id, now]);
      const deviceId = randomUUID();
      const sessionId = randomUUID();
      await client.query('INSERT INTO devices (id,user_id,name,platform,os_version,app_version,created_at) VALUES ($1,$2,$3,$4,$5,$6,$7)', [deviceId, pair.user_id, input.device.name, input.device.platform, input.device.osVersion, input.device.appVersion, now]);
      await client.query('INSERT INTO auth_sessions (id,user_id,device_id,created_at) VALUES ($1,$2,$3,$4)', [sessionId, pair.user_id, deviceId, now]);
      const refresh = await this.insertRefresh(client, sessionId, now);
      return this.tokenResponse(client, { userId: pair.user_id, deviceId, sessionId }, refresh);
    });
    // Business refusals commit attempts/rate limits; throwing inside the transaction would erase them.
    if (result instanceof AuthError) throw result;
    return result;
  }

  private async insertRefresh(client: PoolClient, sessionId: string, now: Date): Promise<RefreshRow> {
    const id = randomUUID();
    // Second precision makes re-created JWTs byte-identical after a lost response.
    const issuedAt = new Date(Math.floor(now.getTime() / 1000) * 1000);
    const result = await client.query<RefreshRow>('INSERT INTO auth_refresh_tokens (id,session_id,token_hash,issued_at,expires_at) VALUES ($1,$2,$3,$4,$5) RETURNING *', [id, sessionId, hash(this.refreshValue(id)), issuedAt, new Date(now.getTime() + REFRESH_MS)]);
    return result.rows[0]!;
  }

  async refresh(refreshToken: string): Promise<TokenResponse> {
    const id = selector(refreshToken);
    if (!id) throw new AuthError('INVALID_TOKEN');
    const result = await this.transaction(async (client): Promise<TokenResponse | AuthError> => {
      const now = this.now();
      const lookup = await client.query<{ session_id: string }>('SELECT session_id FROM auth_refresh_tokens WHERE id = $1', [id]);
      const sessionId = lookup.rows[0]?.session_id;
      if (!sessionId) return new AuthError('INVALID_TOKEN');
      // Lock the family first, then its token: parent and descendant refreshes serialize.
      const sessions = await client.query<SessionRow>('SELECT s.*, d.revoked_at AS device_revoked_at FROM auth_sessions s JOIN devices d ON d.id = s.device_id AND d.user_id = s.user_id WHERE s.id = $1 FOR UPDATE OF s', [sessionId]);
      const session = sessions.rows[0];
      const tokens = await client.query<RefreshRow>('SELECT * FROM auth_refresh_tokens WHERE id = $1 FOR UPDATE', [id]);
      const token = tokens.rows[0];
      if (!session || !token || !matches(refreshToken, token.token_hash) || session.revoked_at || session.device_revoked_at) return new AuthError('INVALID_TOKEN');
      const identity = { userId: session.user_id, deviceId: session.device_id, sessionId };
      if (token.rotated_at) {
        const replacement = token.replacement_id ? (await client.query<RefreshRow>('SELECT * FROM auth_refresh_tokens WHERE id = $1', [token.replacement_id])).rows[0] : undefined;
        const rotationAge = now.getTime() - token.rotated_at.getTime();
        if (!token.retry_used_at && rotationAge >= 0 && rotationAge < 60_000 && replacement && !replacement.rotated_at && replacement.expires_at > now) {
          await client.query('UPDATE auth_refresh_tokens SET retry_used_at = $2 WHERE id = $1', [id, now]);
          return this.tokenResponse(client, identity, replacement);
        }
        await client.query('UPDATE auth_sessions SET revoked_at = $2 WHERE id = $1', [sessionId, now]);
        return new AuthError('TOKEN_REUSED');
      }
      if (token.expires_at <= now) return new AuthError('INVALID_TOKEN');
      const replacement = await this.insertRefresh(client, sessionId, now);
      await client.query('UPDATE auth_refresh_tokens SET rotated_at = $2, replacement_id = $3 WHERE id = $1', [id, now, replacement.id]);
      return this.tokenResponse(client, identity, replacement);
    });
    if (result instanceof AuthError) throw result;
    return result;
  }

  private async sign(identity: AuthIdentity, id: string, issuedAt: Date, audience: string, tokenUse: 'access' | 'sync'): Promise<string> {
    const iat = Math.floor(issuedAt.getTime() / 1000);
    return new SignJWT({ device_id: identity.deviceId, session_id: identity.sessionId, token_use: tokenUse })
      .setProtectedHeader({ alg: 'RS256', kid: this.config.keyId, typ: 'JWT' })
      .setIssuer(this.config.issuer).setAudience(audience).setSubject(identity.userId)
      .setJti(id).setIssuedAt(iat).setExpirationTime(iat + ACCESS_SECONDS).sign(await this.privateKey());
  }

  private async tokenResponse(client: PoolClient, identity: AuthIdentity, refresh: RefreshRow): Promise<TokenResponse> {
    const generation = await client.query<{ generation: string }>('SELECT generation FROM server_meta WHERE singleton = true');
    if (!generation.rows[0]) throw new Error('Server generation is missing. Apply migrations first.');
    return {
      deviceId: identity.deviceId,
      accessToken: await this.sign(identity, refresh.id, refresh.issued_at, this.config.apiAudience, 'access'),
      accessTokenExpiresAt: new Date(refresh.issued_at.getTime() + ACCESS_SECONDS * 1000).toISOString(),
      refreshToken: this.refreshValue(refresh.id),
      serverGeneration: generation.rows[0].generation,
    };
  }

  async authenticate(authorization: string | undefined): Promise<AuthIdentity> {
    if (!authorization?.startsWith('Bearer ')) throw new AuthError('INVALID_TOKEN');
    let identity: AuthIdentity;
    try {
      const { payload, protectedHeader } = await jwtVerify(authorization.slice(7), await this.publicKey(), {
        algorithms: ['RS256'], issuer: this.config.issuer, audience: this.config.apiAudience,
        currentDate: this.now(), requiredClaims: ['sub', 'iat', 'exp', 'device_id', 'session_id', 'token_use'],
      });
      if (protectedHeader.kid !== this.config.keyId || payload.token_use !== 'access' || typeof payload.sub !== 'string' || typeof payload.device_id !== 'string' || typeof payload.session_id !== 'string' || !UUID.test(payload.sub) || !UUID.test(payload.device_id) || !UUID.test(payload.session_id)) throw new Error('Invalid claims');
      if (typeof payload.iat !== 'number' || typeof payload.exp !== 'number' || payload.exp - payload.iat > ACCESS_SECONDS || payload.iat > Math.floor(this.now().getTime() / 1000)) throw new Error('Invalid lifetime');
      identity = { userId: payload.sub, deviceId: payload.device_id, sessionId: payload.session_id };
    } catch { throw new AuthError('INVALID_TOKEN'); }
    const active = await this.pool.query(`SELECT s.id FROM auth_sessions s JOIN devices d ON d.id = s.device_id AND d.user_id = s.user_id
      WHERE s.id = $1 AND s.user_id = $2 AND s.device_id = $3 AND s.revoked_at IS NULL AND d.revoked_at IS NULL`, [identity.sessionId, identity.userId, identity.deviceId]);
    if (!active.rowCount) throw new AuthError('INVALID_TOKEN');
    return identity;
  }

  async syncToken(identity: AuthIdentity): Promise<{ token: string; expiresAt: string; endpoint: string | null }> {
    const now = new Date(Math.floor(this.now().getTime() / 1000) * 1000);
    return {
      token: await this.sign(identity, randomUUID(), now, this.config.syncAudience, 'sync'),
      expiresAt: new Date(now.getTime() + ACCESS_SECONDS * 1000).toISOString(),
      endpoint: this.config.syncEndpoint ?? null,
    };
  }

  async revokeDevice(deviceId: string, userId?: string): Promise<boolean> {
    if (!UUID.test(deviceId)) throw new Error('Invalid device identifier.');
    const result = await this.pool.query('UPDATE devices SET revoked_at = COALESCE(revoked_at, $2) WHERE id = $1 AND ($3::uuid IS NULL OR user_id = $3) RETURNING id', [deviceId, this.now(), userId ?? null]);
    return !!result.rowCount;
  }

  async listDevices(): Promise<Array<{ id: string; user_id: string; name: string; created_at: Date; revoked_at: Date | null }>> {
    return (await this.pool.query<{ id: string; user_id: string; name: string; created_at: Date; revoked_at: Date | null }>('SELECT id,user_id,name,created_at,revoked_at FROM devices ORDER BY created_at')).rows;
  }

  async jwks() {
    const jwk = await exportJWK(await this.publicKey());
    return { keys: [{ ...jwk, kid: this.config.keyId, alg: 'RS256', use: 'sig' }] };
  }
}
