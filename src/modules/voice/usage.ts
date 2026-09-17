import type pg from 'pg';

/** Reserved and dispatched milliseconds in one exact UTC month, including uncertain legacy usage.
 * A reservation being moved to the dispatch month is excluded before checking its replacement. */
export async function monthlyVoiceMilliseconds(client: pg.Pool | pg.PoolClient, userId: string, at: Date,
  excluding?: { transcriptionId: string; attempt: number }): Promise<number> {
  const result = await client.query<{ total: string }>(`SELECT COALESCE(sum(duration_ms::bigint), 0)::bigint AS total
    FROM transcription_attempts
    WHERE user_id = $1 AND state <> 'released'
      AND budget_at >= date_trunc('month', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      AND budget_at < (date_trunc('month', $2::timestamptz AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC'
      AND ($3::uuid IS NULL OR NOT (transcription_id = $3 AND attempt = $4))`,
  [userId, at, excluding?.transcriptionId ?? null, excluding?.attempt ?? null]);
  return Number(result.rows[0]!.total);
}
