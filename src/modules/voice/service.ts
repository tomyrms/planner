import { randomUUID } from 'node:crypto';
import { chmod, mkdir, readdir, readFile, rename, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import type pg from 'pg';
import { AssistantError, type Identity } from '../assistant/index.js';
import { AudioRejected, inspectM4a } from './m4a.js';
import { TranscriptionError, type TranscriptionProvider } from './provider.js';

export const DEFAULT_VOICE_LIMITS = {
  /** 04_Backend/06_Security_Privacy.md: 30 transcriptions per hour. */
  perHour: 30,
  /** Monthly cap of transcribed minutes (04_Backend/07_Cost_Model.md). */
  monthlyMinutes: 600,
  /** Longer transcriptions answer "transcribing" and finish in the background. */
  inlineWaitMs: 1_000,
  providerTimeoutMs: 60_000,
  audioTtlMs: 24 * 60 * 60_000,
  /** A transcription left "received" or "transcribing" this long without a running job was interrupted. */
  staleMs: 10 * 60_000,
  maxAttempts: 3,
  maxKeywords: 50,
};
export type VoiceLimits = typeof DEFAULT_VOICE_LIMITS;

export const LANGUAGE_HINTS = ['fr', 'pt', 'en'] as const;
const OPEN_STATUSES = ['received', 'transcribing'];

export interface UploadedAudio {
  transcriptionId: string;
  durationMs: number;
  /** Temporary file written by the route; this service moves or deletes it. */
  path: string;
  byteSize: number;
  sha256: string;
}

interface Job { promise: Promise<void>; abort: AbortController }

async function transaction<T>(pool: pg.Pool, work: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const value = await work(client);
    await client.query('COMMIT');
    return value;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

const sleep = (ms: number) => new Promise<void>((resolve) => { setTimeout(resolve, ms).unref(); });

async function lockTranscription(client: pg.PoolClient, id: string): Promise<void> {
  await client.query("SELECT pg_advisory_xact_lock(hashtextextended('planner:transcription:' || $1::uuid::text, 0))", [id]);
}

/** Voice messages (03_iOS/04_Audio_Transcription.md): the text is kept, the audio never is. */
export class VoiceService {
  private readonly jobs = new Map<string, Job>();
  private readonly limits: VoiceLimits;
  private readonly clock: () => Date;
  private readonly log: (event: Record<string, unknown>) => void;

  constructor(
    private readonly pool: pg.Pool,
    private readonly provider: TranscriptionProvider | null,
    readonly audioDir: string,
    options: { clock?: () => Date; limits?: Partial<VoiceLimits>; log?: (event: Record<string, unknown>) => void } = {},
  ) {
    this.limits = { ...DEFAULT_VOICE_LIMITS, ...options.limits };
    this.clock = options.clock ?? (() => new Date());
    this.log = options.log ?? (() => undefined);
  }

  get enabled(): boolean { return this.provider !== null; }

  async prepareDirectory(): Promise<void> {
    await mkdir(this.audioDir, { recursive: true, mode: 0o700 });
  }

  temporaryPath(): string {
    return join(this.audioDir, `upload-${randomUUID()}.part`);
  }

  private audioPath(id: string): string {
    return join(this.audioDir, `${id}.m4a`);
  }

  async snapshot(userId: string, transcriptionId: string): Promise<Record<string, unknown>> {
    const id = transcriptionId.toLowerCase();
    const select = `SELECT id, status, text, languages, error_code, duration_ms, created_at, completed_at, audio_deleted_at, updated_at
      FROM transcriptions WHERE id = $1 AND user_id = $2`;
    let { rows: [row] } = await this.pool.query(select, [id, userId]);
    const now = this.clock();
    if (row && OPEN_STATUSES.includes(row.status) && !this.jobs.has(id) && now.getTime() - new Date(row.updated_at).getTime() >= this.limits.staleMs) {
      // Polling after a server restart must eventually expose a retryable failure, even before hourly cleanup runs.
      const attempt = await transaction(this.pool, async (client) => {
        await lockTranscription(client, id);
        const { rows: [interrupted] } = await client.query(`UPDATE transcriptions SET status = 'failed', error_code = 'INTERRUPTED', updated_at = $3
          WHERE id = $1 AND user_id = $2 AND status = ANY($4) AND updated_at <= $3::timestamptz - make_interval(secs => $5)
          RETURNING attempts`, [id, userId, now, OPEN_STATUSES, this.limits.staleMs / 1000]);
        return interrupted?.attempts as number | undefined;
      });
      if (attempt !== undefined) await this.deleteAudio(id, attempt).catch((error) => {
        this.log({ event: 'transcription_audio_cleanup_error', transcriptionId: id, code: (error as { code?: string }).code ?? 'INTERNAL_ERROR' });
      });
      ({ rows: [row] } = await this.pool.query(select, [id, userId]));
    }
    if (!row || row.status === 'erased') throw new AssistantError('TRANSCRIPTION_NOT_FOUND', 404, 'Unknown transcription.');
    return {
      transcriptionId: row.id,
      status: row.status,
      text: row.text,
      languages: row.languages,
      errorCode: row.error_code,
      durationMs: row.duration_ms,
      createdAt: new Date(row.created_at).toISOString(),
      completedAt: row.completed_at ? new Date(row.completed_at).toISOString() : null,
      audioDeleted: row.audio_deleted_at !== null,
    };
  }

  /** Idempotent by transcriptionId + SHA-256; a completed text is returned without a second provider call. */
  async receive(identity: Identity, upload: UploadedAudio): Promise<Record<string, unknown>> {
    const id = upload.transcriptionId.toLowerCase();
    let keepTemporary = false;
    try {
      if (!this.provider) throw new AssistantError('TRANSCRIPTION_UNAVAILABLE', 503, 'Voice transcription is not configured.');
      try {
        inspectM4a(await readFile(upload.path), upload.durationMs);
      } catch (error) {
        if (error instanceof AudioRejected) throw new AssistantError(error.code, 422, error.message);
        throw error;
      }
      const now = this.clock();
      const decision = await transaction(this.pool, async (client) => {
        // Reserve the budget before releasing this lock: simultaneous uploads must see one another's attempts.
        await client.query("SELECT pg_advisory_xact_lock(hashtextextended('planner:voice-budget:' || $1::uuid::text, 0))", [identity.userId]);
        await lockTranscription(client, id);
        const { rows: [existing] } = await client.query('SELECT user_id, audio_sha256, duration_ms, status, attempts, updated_at FROM transcriptions WHERE id = $1', [id]);
        if (existing) {
          if (existing.user_id !== identity.userId || existing.audio_sha256 !== upload.sha256 || existing.duration_ms !== upload.durationMs) {
            throw new AssistantError('IDEMPOTENCY_KEY_REUSED', 409, 'This transcription identifier was already used for another file.');
          }
          if (existing.status === 'abandoned') throw new AssistantError('TRANSCRIPTION_ABANDONED', 422, 'This voice message was abandoned.');
          if (existing.status === 'erased') throw new AssistantError('TRANSCRIPTION_ERASED', 422, 'This voice message was deleted.');
          if (existing.status === 'completed' || this.jobs.has(id)) return null;
          // Another instance may own this job. Its absence from our in-memory map is not proof of a restart.
          if (OPEN_STATUSES.includes(existing.status) && now.getTime() - new Date(existing.updated_at).getTime() < this.limits.staleMs) return null;
          if (existing.attempts >= this.limits.maxAttempts) {
            throw new AssistantError('TRANSCRIPTION_FAILED', 422, 'Transcription failed; write the message instead.');
          }
          await this.checkBudget(client, identity.userId, upload.durationMs, now);
          await client.query(`UPDATE transcriptions SET status = 'received', attempts = attempts + 1, error_code = NULL, audio_deleted_at = NULL, updated_at = $2
            WHERE id = $1`, [id, now]);
        } else {
          const scope = identity.deviceId ? 'device_id = $2' : 'user_id = $2';
          const hour = await client.query(`SELECT count(*)::int AS n, min(created_at) AS oldest FROM transcriptions
            WHERE created_at > $1::timestamptz - interval '1 hour' AND ${scope}`, [now, identity.deviceId ?? identity.userId]);
          if (hour.rows[0].n >= this.limits.perHour) {
            const retryAfterSeconds = Math.max(1, Math.ceil((new Date(hour.rows[0].oldest).getTime() + 3_600_000 - now.getTime()) / 1000));
            throw new AssistantError('RATE_LIMITED', 429, 'Too many voice messages this hour.', { retryAfterSeconds });
          }
          await this.checkBudget(client, identity.userId, upload.durationMs, now);
          await client.query(`INSERT INTO transcriptions (id, user_id, device_id, duration_ms, byte_size, audio_sha256, provider, model, attempts, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 1, $9, $9)`,
          [id, identity.userId, identity.deviceId, upload.durationMs, upload.byteSize, upload.sha256, this.provider!.name, this.provider!.model, now]);
        }
        // Keep the identifier locked until its file is in place. A duplicate must never replace an active recording.
        await rename(upload.path, this.audioPath(id));
        keepTemporary = true;
        await chmod(this.audioPath(id), 0o600).catch(() => undefined);
        return Number(existing?.attempts ?? 0) + 1;
      });
      if (decision !== null) this.start(identity.userId, id, decision);
      const job = this.jobs.get(id);
      if (job) await Promise.race([job.promise, sleep(this.limits.inlineWaitMs)]);
      return await this.snapshot(identity.userId, id);
    } finally {
      if (!keepTemporary) await rm(upload.path, { force: true });
    }
  }

  /** Every call to the provider is billed, retries included (04_Backend/07_Cost_Model.md). */
  private async checkBudget(client: pg.PoolClient, userId: string, durationMs: number, now: Date): Promise<void> {
    const month = await client.query(`SELECT COALESCE(sum(duration_ms::bigint * attempts), 0)::bigint AS total FROM transcriptions
      WHERE user_id = $1 AND created_at >= date_trunc('month', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`, [userId, now]);
    if (Number(month.rows[0].total) + durationMs > this.limits.monthlyMinutes * 60_000) {
      throw new AssistantError('TRANSCRIPTION_BUDGET_EXCEEDED', 429, 'The monthly transcription budget is used up.');
    }
  }

  private start(userId: string, id: string, attempt: number): void {
    const abort = new AbortController();
    const promise = this.run(userId, id, attempt, abort.signal)
      .catch((error) => this.log({ event: 'transcription_error', transcriptionId: id, code: (error as { code?: string }).code ?? 'INTERNAL_ERROR' }))
      .finally(() => this.jobs.delete(id));
    this.jobs.set(id, { promise, abort });
  }

  private async keywords(userId: string): Promise<string[]> {
    const { rows } = await this.pool.query<{ name: string }>(`SELECT DISTINCT name FROM projects
      WHERE user_id = $1 AND deleted_at IS NULL AND length(name) <= 50 ORDER BY name LIMIT $2`, [userId, this.limits.maxKeywords]);
    return rows.map((row) => row.name);
  }

  private async run(userId: string, id: string, attempt: number, signal: AbortSignal): Promise<void> {
    const started = Date.now();
    const claimed = await this.pool.query(`UPDATE transcriptions SET status = 'transcribing', updated_at = $2
      WHERE id = $1 AND status = 'received' AND attempts = $3 AND attempts <= $4 RETURNING id`, [id, this.clock(), attempt, this.limits.maxAttempts]);
    if (!claimed.rowCount) return;
    let outcome: { status: 'completed' | 'failed'; text?: string; languages?: string[]; code?: string } = { status: 'failed', code: 'INTERNAL_ERROR' };
    try {
      const result = await this.provider!.transcribe({
        audioPath: this.audioPath(id), languages: LANGUAGE_HINTS, keywords: await this.keywords(userId),
        signal: AbortSignal.any([signal, AbortSignal.timeout(this.limits.providerTimeoutMs)]),
      });
      const text = result.text.trim().slice(0, 8000);
      // Silence or an empty transcript never becomes a message (03_iOS/04_Audio_Transcription.md).
      outcome = text.length === 0 ? { status: 'failed', code: 'EMPTY_TRANSCRIPT' } : { status: 'completed', text, languages: result.languages };
    } catch (error) {
      outcome = { status: 'failed', code: error instanceof TranscriptionError ? error.code : 'INTERNAL_ERROR' };
    }
    // Persist the result before deleting its source. A disk cleanup error must not lose a completed transcript.
    await transaction(this.pool, async (client) => {
      await lockTranscription(client, id);
      const now = this.clock();
      // An abandon or a later attempt wins; a delayed result cannot overwrite either.
      await client.query(`UPDATE transcriptions SET
          status = CASE WHEN status = 'transcribing' THEN $2 ELSE status END,
          text = CASE WHEN status = 'transcribing' THEN $3 ELSE text END,
          languages = CASE WHEN status = 'transcribing' THEN $4::text[] ELSE languages END,
          error_code = CASE WHEN status = 'transcribing' THEN $5 ELSE error_code END,
          completed_at = CASE WHEN status = 'transcribing' AND $2 = 'completed' THEN $6::timestamptz ELSE completed_at END,
          updated_at = CASE WHEN status = 'transcribing' THEN $6 ELSE updated_at END
        WHERE id = $1 AND attempts = $7`,
      [id, outcome.status, outcome.text ?? null, outcome.languages ?? [], outcome.code ?? null, now, attempt]);
    });
    await this.deleteAudio(id, attempt).catch((error) => {
      this.log({ event: 'transcription_audio_cleanup_error', transcriptionId: id, code: (error as { code?: string }).code ?? 'INTERNAL_ERROR' });
    });
    this.log({ event: 'transcription', transcriptionId: id, status: outcome.status, code: outcome.code ?? null, durationMs: Date.now() - started });
  }

  private async deleteAudio(id: string, attempt: number): Promise<void> {
    await transaction(this.pool, async (client) => {
      await lockTranscription(client, id);
      const { rows: [row] } = await client.query('SELECT attempts, status FROM transcriptions WHERE id = $1', [id]);
      if (!row || row.attempts !== attempt || OPEN_STATUSES.includes(row.status)) return;
      await rm(this.audioPath(id), { force: true });
      await client.query('UPDATE transcriptions SET audio_deleted_at = COALESCE(audio_deleted_at, $2) WHERE id = $1', [id, this.clock()]);
    });
  }

  /** DELETE: the server audio is removed at once; a text already transcribed stays usable. */
  async abandon(identity: Identity, transcriptionId: string): Promise<Record<string, unknown>> {
    const id = transcriptionId.toLowerCase();
    const attempt = await transaction(this.pool, async (client) => {
      await lockTranscription(client, id);
      const { rows: [row] } = await client.query('SELECT status, attempts FROM transcriptions WHERE id = $1 AND user_id = $2', [id, identity.userId]);
      if (!row || row.status === 'erased') throw new AssistantError('TRANSCRIPTION_NOT_FOUND', 404, 'Unknown transcription.');
      await client.query(`UPDATE transcriptions SET status = CASE WHEN status = 'completed' THEN status ELSE 'abandoned' END,
        updated_at = CASE WHEN status = 'completed' THEN updated_at ELSE $2 END WHERE id = $1`, [id, this.clock()]);
      return row.attempts as number;
    });
    const job = this.jobs.get(id);
    job?.abort.abort();
    await this.deleteAudio(id, attempt);
    await job?.promise;
    return this.snapshot(identity.userId, id);
  }

  /** Hourly and at startup: audio older than 24 h, orphans, interrupted jobs and texts never used (ADR-021, ADR-030). */
  async cleanup(): Promise<{ files: number; interrupted: number; erased: number }> {
    const now = this.clock();
    const interrupted = await this.pool.query(`UPDATE transcriptions SET status = 'failed', error_code = 'INTERRUPTED', updated_at = $1
      WHERE status = ANY($2) AND updated_at < $1::timestamptz - make_interval(secs => $3) AND NOT (id = ANY($4::uuid[])) RETURNING id`,
    [now, OPEN_STATUSES, this.limits.staleMs / 1000, [...this.jobs.keys()]]);
    const erased = await this.pool.query(`UPDATE transcriptions t SET status = 'erased', text = NULL, languages = '{}', completed_at = NULL, error_code = NULL
      WHERE t.status IN ('completed','failed','abandoned') AND t.updated_at < $1::timestamptz - make_interval(secs => $2)
        AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.transcription_id = t.id)`, [now, this.limits.audioTtlMs / 1000]);
    let files = 0;
    let names: string[] = [];
    try { names = await readdir(this.audioDir); } catch { names = []; }
    for (const name of names) {
      const path = join(this.audioDir, name);
      const info = await stat(path).catch(() => null);
      if (!info?.isFile()) continue;
      const id = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.m4a$/.exec(name)?.[1];
      const partial = /^upload-[0-9a-f-]{36}\.part$/.test(name);
      // Never touch a file this service did not write, even in a misconfigured shared directory.
      if (id === undefined && !partial) continue;
      const age = now.getTime() - info.mtimeMs;
      if (id !== undefined) {
        const removed = await transaction(this.pool, async (client) => {
          await lockTranscription(client, id);
          const { rows: [row] } = await client.query('SELECT status FROM transcriptions WHERE id = $1', [id]);
          // Recheck under the lock: a retry may have replaced the file since readdir().
          if (this.jobs.has(id) || (row && OPEN_STATUSES.includes(row.status))) return false;
          await rm(path, { force: true });
          await client.query('UPDATE transcriptions SET audio_deleted_at = COALESCE(audio_deleted_at, $2) WHERE id = $1', [id, now]);
          return true;
        });
        if (removed) files++;
      } else if (age > this.limits.staleMs) {
        await rm(path, { force: true });
        files++;
      }
    }
    // Retry failed deletions and record the absence of files lost during an interrupted startup.
    const { rows: pendingDeletion } = await this.pool.query<{ id: string; attempts: number }>(
      'SELECT id, attempts FROM transcriptions WHERE NOT (status = ANY($1)) AND audio_deleted_at IS NULL', [OPEN_STATUSES]);
    for (const row of pendingDeletion) await this.deleteAudio(row.id, row.attempts);
    const counts = { files, interrupted: interrupted.rowCount ?? 0, erased: erased.rowCount ?? 0 };
    if (counts.files + counts.interrupted + counts.erased > 0) {
      await this.pool.query("INSERT INTO maintenance_runs (kind, outcome, details, finished_at) VALUES ('audio_cleanup', 'succeeded', $1, $2)",
        [counts, now]);
    }
    return counts;
  }

  async shutdown(): Promise<void> {
    for (const job of this.jobs.values()) job.abort.abort();
    await Promise.allSettled([...this.jobs.values()].map((job) => job.promise));
  }
}
