import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { rotateGeneration } from '../../src/infrastructure/db/recovery.js';
import { createTestDatabase } from './helpers.js';

describe('restore generation', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let userId: string;

  beforeAll(async () => {
    db = await createTestDatabase();
    userId = (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id;
  });
  afterAll(async () => { await db?.close(); });

  async function device(revokedAt: Date | null = null): Promise<string> {
    const id = randomUUID();
    await db.pool.query("INSERT INTO devices (id, user_id, name, platform, os_version, app_version, created_at, revoked_at) VALUES ($1, $2, 'iPhone', 'ios', '26.0', '0.1.0', now(), $3)", [id, userId, revokedAt]);
    await db.pool.query('INSERT INTO auth_sessions (id, user_id, device_id, created_at) VALUES ($1, $2, $3, now())', [randomUUID(), userId, id]);
    return id;
  }
  const generation = async () => (await db.pool.query<{ generation: string }>('SELECT generation FROM server_meta')).rows[0]!.generation;

  it('creates a new generation and revokes every active device and session', async () => {
    const earlier = new Date('2026-09-01T00:00:00Z');
    const active = [await device(), await device()];
    const alreadyRevoked = await device(earlier);
    const before = await generation();
    const now = new Date('2026-09-16T12:00:00Z');
    const result = await rotateGeneration(db.pool, { revokeDevices: true, now });
    expect(result.generation).not.toBe(before);
    expect(await generation()).toBe(result.generation);
    expect(result.revokedDevices).toBe(2);
    const devices = await db.pool.query<{ id: string; revoked_at: Date }>('SELECT id, revoked_at FROM devices ORDER BY id');
    for (const row of devices.rows) {
      expect(row.revoked_at).toEqual(row.id === alreadyRevoked ? earlier : now);
    }
    expect(active.every((id) => devices.rows.some((row) => row.id === id))).toBe(true);
    expect((await db.pool.query('SELECT count(*)::int AS n FROM auth_sessions WHERE revoked_at IS NULL')).rows[0].n).toBe(0);
  });

  it('can keep devices when the operator knows the registry is current', async () => {
    const kept = await device();
    const before = await generation();
    const result = await rotateGeneration(db.pool, { revokeDevices: false });
    expect(result).toEqual({ generation: expect.not.stringMatching(before), revokedDevices: 0 });
    expect((await db.pool.query('SELECT revoked_at FROM devices WHERE id = $1', [kept])).rows[0].revoked_at).toBeNull();
  });
});
