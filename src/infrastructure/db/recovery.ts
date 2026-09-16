import type pg from 'pg';

/**
 * After a restore (04_Backend/05_Homelab_Deployment.md, case B): a new server generation makes every
 * client suspend its uploads (409 SERVER_GENERATION_CHANGED). By default every device is revoked too,
 * because the restored registry may predate a revocation; the iPhone is then paired again.
 */
export async function rotateGeneration(pool: pg.Pool, options: { revokeDevices: boolean; now?: Date }): Promise<{ generation: string; revokedDevices: number }> {
  const now = options.now ?? new Date();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const rotated = await client.query<{ generation: string }>('UPDATE server_meta SET generation = gen_random_uuid() RETURNING generation');
    if (rotated.rowCount !== 1) throw new Error('server_meta must hold exactly one generation');
    let revokedDevices = 0;
    if (options.revokeDevices) {
      const devices = await client.query('UPDATE devices SET revoked_at = $1 WHERE revoked_at IS NULL', [now]);
      await client.query('UPDATE auth_sessions SET revoked_at = $1 WHERE revoked_at IS NULL', [now]);
      revokedDevices = devices.rowCount ?? 0;
    }
    await client.query('COMMIT');
    return { generation: rotated.rows[0]!.generation, revokedDevices };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
