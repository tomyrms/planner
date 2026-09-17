import { createHash, randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readdir, readFile, rm, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { reply, type AssistantError, type Identity } from '../../src/modules/assistant/index.js';
import { buildExport } from '../../src/modules/export/index.js';
import {
  ScriptedTranscriptionProvider, TranscriptionError, VoiceService,
  type TranscriptionProvider, type TranscriptionRequest, type TranscriptionResult, type VoiceLimits,
} from '../../src/modules/voice/index.js';
import { assistantFor, manual, turnRequest } from '../assistant/helpers.js';
import { createTestDatabase } from '../db/helpers.js';
import { monthlyVoiceMilliseconds } from '../../src/modules/voice/usage.js';

const mono = await readFile(new URL('../fixtures/audio/tone-3s-mono.m4a', import.meta.url));
const stereo = await readFile(new URL('../fixtures/audio/tone-3s-stereo.m4a', import.meta.url));
/** Same recording plus an empty "free" box: still valid, different fingerprint. */
const variant = Buffer.concat([mono, Buffer.from([0, 0, 0, 8]), Buffer.from('free', 'latin1')]);
const sha = (data: Buffer) => createHash('sha256').update(data).digest('hex');
const said = (text: string, languages = ['fr']): TranscriptionResult => ({ text, languages, seconds: 3 });
const failure = (promise: Promise<unknown>) => promise.then(() => null, (error: unknown) => error as AssistantError);
const sleep = (ms: number) => new Promise((resolve) => { setTimeout(resolve, ms); });

/** A provider call that only ends when it is cancelled, like a slow network request. */
const hang = (request: TranscriptionRequest) => new Promise<TranscriptionResult>((_resolve, reject) => {
  const stop = () => reject(new TranscriptionError('TRANSCRIPTION_TIMEOUT'));
  if (request.signal.aborted) stop();
  request.signal.addEventListener('abort', stop);
});

describe('voice transcription service', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  const created: Array<{ service: VoiceService; dir: string }> = [];

  beforeAll(async () => { db = await createTestDatabase(); });
  afterEach(async () => {
    for (const { service, dir } of created.splice(0)) {
      await service.shutdown();
      await rm(dir, { recursive: true, force: true });
    }
  });
  afterAll(async () => { await db?.close(); });

  const freshUser = async (): Promise<Identity> =>
    ({ userId: (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id, deviceId: null });

  async function voiceFor(provider: TranscriptionProvider | null, options: { limits?: Partial<VoiceLimits>; clock?: () => Date; directory?: string } = {}) {
    const dir = options.directory ?? await mkdtemp(join(tmpdir(), 'planner-voice-test-'));
    const service = new VoiceService(db.pool, provider, dir, { clock: options.clock ?? (() => new Date()), ...(options.limits ? { limits: options.limits } : {}) });
    await service.prepareDirectory();
    created.push({ service, dir });
    return { service, dir, files: () => readdir(dir) };
  }

  async function send(service: VoiceService, identity: Identity, options: { id?: string; bytes?: Buffer; durationMs?: number } = {}) {
    const bytes = options.bytes ?? mono;
    const path = service.temporaryPath();
    await writeFile(path, bytes);
    const id = options.id ?? randomUUID();
    const snapshot = await service.receive(identity, { transcriptionId: id, durationMs: options.durationMs ?? 3000, path, byteSize: bytes.length, sha256: sha(bytes) });
    return { id, snapshot: snapshot as Record<string, any> };
  }

  const row = async (id: string) => (await db.pool.query(`SELECT status, text, error_code, attempts, audio_deleted_at, byte_size, audio_sha256, provider, model
    FROM transcriptions WHERE id = $1`, [id])).rows[0] as Record<string, any> | undefined;

  async function eventually(check: () => Promise<boolean>): Promise<void> {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (await check()) return;
      await sleep(20);
    }
    throw new Error('condition not reached');
  }

  it('transcribes with language and project hints, keeps only the text and deletes the audio', async () => {
    const me = await freshUser();
    await manual(db.pool, me.userId, 'project.create', randomUUID(), { name: 'Drivey' });
    await manual(db.pool, me.userId, 'project.create', randomUUID(), { name: 'C#' });
    const provider = new ScriptedTranscriptionProvider([async (request) => {
      // The file exists only while the provider reads it.
      expect(existsSync(request.audioPath)).toBe(true);
      return said('Demain, avancer sur Drivey.', ['fr', 'pt']);
    }]);
    const { service, files } = await voiceFor(provider);
    expect(service.enabled).toBe(true);
    const { id, snapshot } = await send(service, me);
    expect(snapshot).toMatchObject({
      transcriptionId: id, status: 'completed', text: 'Demain, avancer sur Drivey.', languages: ['fr', 'pt'],
      errorCode: null, durationMs: 3000, audioDeleted: true,
    });
    expect(snapshot.completedAt).toEqual(expect.any(String));
    expect(provider.requests).toHaveLength(1);
    expect(provider.requests[0]).toMatchObject({ languages: ['fr', 'pt', 'en'], keywords: ['C#', 'Drivey'] });
    expect(provider.requests[0]!.audioPath.endsWith(`${id}.m4a`)).toBe(true);
    expect(await files()).toEqual([]);
    expect(await row(id)).toMatchObject({ attempts: 1, byte_size: mono.length, audio_sha256: sha(mono), provider: 'scripted', model: 'scripted-v1' });
    expect(await service.snapshot(me.userId, id.toUpperCase())).toEqual(snapshot);
  });

  it('is idempotent per identifier and file, and isolates users', async () => {
    const me = await freshUser();
    const other = await freshUser();
    const provider = new ScriptedTranscriptionProvider([said('Acheter du pain.')]);
    const { service, files } = await voiceFor(provider);
    const first = await send(service, me);
    // A lost response: the same file again returns the same text without a second billed call.
    const again = await send(service, me, { id: first.id });
    expect(again.snapshot).toEqual(first.snapshot);
    expect(provider.requests).toHaveLength(1);
    expect(await files()).toEqual([]);
    expect(await failure(send(service, me, { id: first.id, bytes: variant }))).toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED', statusCode: 409 });
    expect(await failure(send(service, me, { id: first.id, durationMs: 3500 }))).toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED', statusCode: 409 });
    expect(await failure(send(service, other, { id: first.id }))).toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED', statusCode: 409 });
    expect(await files()).toEqual([]);
    // Another user can neither read nor abandon it.
    expect(await failure(service.snapshot(other.userId, first.id))).toMatchObject({ code: 'TRANSCRIPTION_NOT_FOUND', statusCode: 404 });
    expect(await failure(service.abandon(other, first.id))).toMatchObject({ code: 'TRANSCRIPTION_NOT_FOUND', statusCode: 404 });
    expect(await failure(service.snapshot(me.userId, randomUUID()))).toMatchObject({ code: 'TRANSCRIPTION_NOT_FOUND' });
    expect((await row(first.id))!.text).toBe('Acheter du pain.');
  });

  it('rejects an invalid recording before storing or sending anything', async () => {
    const me = await freshUser();
    const provider = new ScriptedTranscriptionProvider([said('x')]);
    const { service, files } = await voiceFor(provider);
    const cases: Array<[Buffer, number, string]> = [
      [Buffer.from('not an audio file'), 3000, 'AUDIO_INVALID'],
      [mono.subarray(0, 5000), 3000, 'AUDIO_INVALID'],
      [stereo, 3000, 'AUDIO_NOT_MONO'],
      [mono, 6000, 'AUDIO_DURATION_MISMATCH'],
    ];
    for (const [bytes, durationMs, code] of cases) {
      const id = randomUUID();
      expect(await failure(send(service, me, { id, bytes, durationMs }))).toMatchObject({ code, statusCode: 422 });
      expect(await row(id)).toBeUndefined();
    }
    expect(provider.requests).toHaveLength(0);
    expect(await files()).toEqual([]);
  });

  it('retries a failed transcription at most three times, then asks the user to write instead', async () => {
    const me = await freshUser();
    const provider = new ScriptedTranscriptionProvider([
      new TranscriptionError('TRANSCRIPTION_UNAVAILABLE'), new TranscriptionError('TRANSCRIPTION_TIMEOUT'),
      new TranscriptionError('TRANSCRIPTION_REJECTED'), said('Jamais atteint.'),
    ]);
    const { service, files } = await voiceFor(provider);
    const first = await send(service, me);
    expect(first.snapshot).toMatchObject({ status: 'failed', errorCode: 'TRANSCRIPTION_UNAVAILABLE', text: null, audioDeleted: true });
    expect(await files()).toEqual([]);
    expect((await send(service, me, { id: first.id })).snapshot).toMatchObject({ status: 'failed', errorCode: 'TRANSCRIPTION_TIMEOUT' });
    expect((await send(service, me, { id: first.id })).snapshot).toMatchObject({ status: 'failed', errorCode: 'TRANSCRIPTION_REJECTED' });
    expect(await failure(send(service, me, { id: first.id }))).toMatchObject({ code: 'TRANSCRIPTION_FAILED', statusCode: 422 });
    expect(provider.requests).toHaveLength(3);
    expect(await row(first.id)).toMatchObject({ attempts: 3, status: 'failed' });
    expect(await files()).toEqual([]);

    const recovering = await voiceFor(new ScriptedTranscriptionProvider([new TranscriptionError('TRANSCRIPTION_UNAVAILABLE'), said('Deuxième essai.')]));
    const retried = await send(recovering.service, me);
    expect(retried.snapshot.status).toBe('failed');
    expect((await send(recovering.service, me, { id: retried.id })).snapshot).toMatchObject({ status: 'completed', text: 'Deuxième essai.', errorCode: null });
    expect(await row(retried.id)).toMatchObject({ attempts: 2 });
  });

  it('never turns silence or an unexpected error into a message', async () => {
    const me = await freshUser();
    const { service, files } = await voiceFor(new ScriptedTranscriptionProvider([
      said('   \n '),
      async () => { throw new Error('private transcript in a stack trace'); },
    ]));
    expect((await send(service, me)).snapshot).toMatchObject({ status: 'failed', errorCode: 'EMPTY_TRANSCRIPT', text: null });
    const crashed = await send(service, me);
    expect(crashed.snapshot).toMatchObject({ status: 'failed', errorCode: 'INTERNAL_ERROR', text: null });
    expect(JSON.stringify(crashed.snapshot)).not.toContain('private');
    expect(await files()).toEqual([]);
  });

  it('answers "transcribing" for a slow call, finishes it in the background and joins duplicates', async () => {
    const me = await freshUser();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const provider = new ScriptedTranscriptionProvider([async () => { await gate; return said('Plus tard.'); }]);
    const { service, files } = await voiceFor(provider, { limits: { inlineWaitMs: 30 } });
    const pending = await send(service, me);
    expect(pending.snapshot).toMatchObject({ status: 'transcribing', text: null, audioDeleted: false });
    expect(await files()).toEqual([`${pending.id}.m4a`]);
    // The client retries while the call is still running: no second call, the temporary copy is dropped.
    expect((await send(service, me, { id: pending.id })).snapshot.status).toBe('transcribing');
    expect(provider.requests).toHaveLength(1);
    expect(await files()).toEqual([`${pending.id}.m4a`]);
    release();
    // The durable transcript commits before file removal and its separate deletion receipt.
    // Wait for both observable outcomes; completed alone deliberately does not promise cleanup.
    await eventually(async () => {
      const snapshot = await service.snapshot(me.userId, pending.id);
      return snapshot.status === 'completed' && snapshot.audioDeleted === true;
    });
    expect(await service.snapshot(me.userId, pending.id)).toMatchObject({ text: 'Plus tard.', audioDeleted: true });
    expect(await files()).toEqual([]);
  });

  it('lets the user abandon a running transcription; a finished text stays usable', async () => {
    const me = await freshUser();
    const provider = new ScriptedTranscriptionProvider([hang]);
    const { service, files } = await voiceFor(provider, { limits: { inlineWaitMs: 30 } });
    const pending = await send(service, me);
    expect(pending.snapshot.status).toBe('transcribing');
    const abandoned = await service.abandon(me, pending.id);
    expect(abandoned).toMatchObject({ status: 'abandoned', text: null, errorCode: null, audioDeleted: true });
    expect(provider.requests[0]!.signal.aborted).toBe(true);
    expect(await files()).toEqual([]);
    expect(await failure(send(service, me, { id: pending.id }))).toMatchObject({ code: 'TRANSCRIPTION_ABANDONED', statusCode: 422 });
    expect(await files()).toEqual([]);

    const done = await voiceFor(new ScriptedTranscriptionProvider([said('Déjà transcrit.')]));
    const finished = await send(done.service, me);
    expect(await done.service.abandon(me, finished.id)).toMatchObject({ status: 'completed', text: 'Déjà transcrit.' });
  });

  it('joins concurrent uploads of the same recording, including on a second service instance', async () => {
    const me = await freshUser();
    const provider = new ScriptedTranscriptionProvider([hang]);
    const { service, dir, files } = await voiceFor(provider, { limits: { inlineWaitMs: 10 } });
    const otherProvider = new ScriptedTranscriptionProvider([said('Ne doit pas être appelé.')]);
    const peer = await voiceFor(otherProvider, { directory: dir, limits: { inlineWaitMs: 10 } });
    const id = randomUUID();
    const copies = await Promise.all(Array.from({ length: 6 }, () => send(service, me, { id })));
    expect(copies.every((copy) => ['received', 'transcribing'].includes(copy.snapshot.status))).toBe(true);
    expect((await send(peer.service, me, { id })).snapshot.status).toBe('transcribing');
    expect(provider.requests).toHaveLength(1);
    expect(otherProvider.requests).toHaveLength(0);
    expect(await row(id)).toMatchObject({ attempts: 1, status: 'transcribing' });
    expect(await files()).toEqual([`${id}.m4a`]);
    await service.abandon(me, id);
  });

  it('reserves hourly and monthly allowances atomically for simultaneous recordings', async () => {
    for (const limits of [{ perHour: 1 }, { monthlyMinutes: 0.05 }]) {
      const me = await freshUser();
      const provider = new ScriptedTranscriptionProvider([hang]);
      const { service } = await voiceFor(provider, { limits: { ...limits, inlineWaitMs: 10 } });
      const results = await Promise.allSettled(Array.from({ length: 5 }, () => send(service, me)));
      expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
      const failures = results.filter((result) => result.status === 'rejected');
      expect(failures).toHaveLength(4);
      for (const result of failures) {
        expect(result.reason).toMatchObject({ code: 'perHour' in limits ? 'RATE_LIMITED' : 'TRANSCRIPTION_BUDGET_EXCEEDED', statusCode: 429 });
      }
      await eventually(async () => provider.requests.length === 1);
      expect(provider.requests).toHaveLength(1);
      expect((await db.pool.query('SELECT count(*)::int AS n FROM transcription_attempts WHERE user_id = $1', [me.userId])).rows[0].n).toBe(1);
    }
  });

  it('preserves a completed transcript when deleting the audio fails and retries cleanup later', async () => {
    const me = await freshUser();
    const provider = new ScriptedTranscriptionProvider([async (request) => {
      // A filesystem failure after the provider has read the file must not strand the status in transcribing.
      await rm(request.audioPath);
      await mkdir(request.audioPath);
      return said('Résultat déjà reçu.');
    }]);
    const { service, dir, files } = await voiceFor(provider);
    const result = await send(service, me);
    expect(result.snapshot).toMatchObject({ status: 'completed', text: 'Résultat déjà reçu.', audioDeleted: false });
    expect(await row(result.id)).toMatchObject({ status: 'completed', attempts: 1, audio_deleted_at: null });
    // Restore a normal file once the filesystem is available again; hourly cleanup removes it.
    await rm(join(dir, `${result.id}.m4a`), { recursive: true });
    await writeFile(join(dir, `${result.id}.m4a`), mono);
    await service.cleanup();
    expect(await files()).toEqual([]);
    expect(await service.snapshot(me.userId, result.id)).toMatchObject({ status: 'completed', text: 'Résultat déjà reçu.', audioDeleted: true });
    expect(provider.requests).toHaveLength(1);
  });

  it('keeps the audio if persisting a result fails, so an interrupted attempt can be retried', async () => {
    const me = await freshUser();
    const id = randomUUID();
    const provider = new ScriptedTranscriptionProvider([said('À conserver.')]);
    const { service, files } = await voiceFor(provider);
    // A constraint in this disposable schema simulates the result write failing, without disrupting other DB calls.
    await db.pool.query(`ALTER TABLE transcriptions ADD CONSTRAINT test_result_unavailable CHECK (id <> '${id}'::uuid OR status <> 'completed')`);
    try {
      expect((await send(service, me, { id })).snapshot).toMatchObject({ status: 'transcribing', text: null, audioDeleted: false });
      expect(await files()).toEqual([`${id}.m4a`]);
    } finally {
      await db.pool.query('ALTER TABLE transcriptions DROP CONSTRAINT test_result_unavailable');
    }
    await db.pool.query("UPDATE transcriptions SET updated_at = now() - interval '11 minutes' WHERE id = $1", [id]);
    expect((await send(service, me, { id })).snapshot).toMatchObject({ status: 'completed', text: 'À conserver.', audioDeleted: true });
    expect(await files()).toEqual([]);
    expect(provider.requests).toHaveLength(2);
  });

  it('does not let a delayed result overwrite a later attempt', async () => {
    const me = await freshUser();
    let now = new Date();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const provider = new ScriptedTranscriptionProvider([async () => { await gate; return said('Ancien résultat.'); }]);
    const { service, dir } = await voiceFor(provider, { clock: () => now, limits: { inlineWaitMs: 10 } });
    const peer = await voiceFor(new ScriptedTranscriptionProvider([said('Résultat repris.')]), { directory: dir, clock: () => now });
    try {
      const pending = await send(service, me);
      now = new Date(now.getTime() + 11 * 60_000);
      expect((await send(peer.service, me, { id: pending.id })).snapshot).toMatchObject({ status: 'completed', text: 'Résultat repris.' });
      release();
      await service.shutdown();
      expect(await row(pending.id)).toMatchObject({ status: 'completed', text: 'Résultat repris.', attempts: 2 });
    } finally {
      release();
    }
  });

  it('limits voice messages per hour and bills every attempt against the monthly minutes', async () => {
    let now = new Date('2026-09-30T20:00:00Z');
    const clock = () => now;
    const me = await freshUser();
    const hourly = await voiceFor(new ScriptedTranscriptionProvider([said('Un.')]), { clock, limits: { perHour: 2 } });
    await send(hourly.service, me);
    now = new Date('2026-09-30T20:10:00Z');
    await send(hourly.service, me);
    const limited = await failure(send(hourly.service, me));
    expect(limited).toMatchObject({ code: 'RATE_LIMITED', statusCode: 429 });
    expect(limited!.details.retryAfterSeconds).toBe(3000);
    expect(await hourly.files()).toEqual([]);
    now = new Date('2026-09-30T21:00:01Z');
    expect((await send(hourly.service, me)).snapshot.status).toBe('completed');

    // 7.2 seconds a month: two failed attempts of one 3-second message already use 6 s, so a new one does not fit.
    const tight = { perHour: 100, monthlyMinutes: 0.12 };
    const other = await freshUser();
    const budget = await voiceFor(new ScriptedTranscriptionProvider([new TranscriptionError('TRANSCRIPTION_UNAVAILABLE')]), { clock, limits: tight });
    const failed = await send(budget.service, other);
    expect(failed.snapshot.status).toBe('failed');
    expect((await send(budget.service, other, { id: failed.id })).snapshot.status).toBe('failed');
    expect(await row(failed.id)).toMatchObject({ attempts: 2 });
    expect(await failure(send(budget.service, other))).toMatchObject({ code: 'TRANSCRIPTION_BUDGET_EXCEEDED', statusCode: 429 });
    expect(await failure(send(budget.service, other, { id: failed.id }))).toMatchObject({ code: 'TRANSCRIPTION_BUDGET_EXCEEDED' });
    expect(await budget.files()).toEqual([]);
    // A new month (UTC) starts a new budget.
    now = new Date('2026-10-01T00:00:01Z');
    expect((await send(budget.service, other, { id: failed.id })).snapshot).toMatchObject({ status: 'failed', errorCode: 'TRANSCRIPTION_UNAVAILABLE' });
    expect(await monthlyVoiceMilliseconds(db.pool, other.userId, new Date('2026-09-01T00:00:00Z'))).toBe(6000);
    expect(await monthlyVoiceMilliseconds(db.pool, other.userId, now)).toBe(3000);
    // The retry belongs to October even though the recording was first created in September.
    expect((await send(budget.service, other)).snapshot.status).toBe('failed');
    expect(await monthlyVoiceMilliseconds(db.pool, other.userId, now)).toBe(6000);
    expect(await failure(send(budget.service, other))).toMatchObject({ code: 'TRANSCRIPTION_BUDGET_EXCEEDED' });
  });

  it.each([false, true])('rechecks the actual dispatch month before HTTP (destination budget full: %s)', async (full) => {
    const me = await freshUser();
    const september = new Date('2026-09-30T23:59:59Z');
    let now = september;
    let preparing = false;
    let sent = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const provider: TranscriptionProvider = {
      name: 'scripted', model: 'preparation-gate',
      async transcribe(request) {
        preparing = true;
        await gate;
        await request.beforeSend();
        sent++;
        return said('Envoyé dans le nouveau mois.');
      },
    };
    const { service } = await voiceFor(provider, { clock: () => now, limits: { monthlyMinutes: 0.05, inlineWaitMs: 10 } });
    try {
      const pending = await send(service, me);
      await eventually(async () => preparing);
      expect(await monthlyVoiceMilliseconds(db.pool, me.userId, september)).toBe(3000);
      expect(sent).toBe(0);
      now = new Date('2026-10-01T00:00:00Z');
      if (full) {
        const peer = await voiceFor(new ScriptedTranscriptionProvider([said('Budget déjà utilisé.')]), { clock: () => now, limits: { monthlyMinutes: 0.05 } });
        expect((await send(peer.service, me)).snapshot.status).toBe('completed');
      }
      release();
      await eventually(async () => (await row(pending.id))?.status === (full ? 'failed' : 'completed'));
      expect(sent).toBe(full ? 0 : 1);
      expect(await monthlyVoiceMilliseconds(db.pool, me.userId, september)).toBe(0);
      expect(await monthlyVoiceMilliseconds(db.pool, me.userId, now)).toBe(3000);
      const attempt = (await db.pool.query('SELECT state, reserved_at, budget_at, dispatched_at FROM transcription_attempts WHERE transcription_id = $1', [pending.id])).rows[0];
      expect(attempt).toEqual({ state: full ? 'released' : 'dispatched', reserved_at: september, budget_at: full ? september : now, dispatched_at: full ? null : now });
      if (full) expect(await row(pending.id)).toMatchObject({ attempts: 1, error_code: 'TRANSCRIPTION_BUDGET_EXCEEDED' });
    } finally { release(); }
  });

  it('releases a local failure before HTTP but counts an uncertain failure after dispatch', async () => {
    const me = await freshUser();
    let prepared = 0;
    let sent = 0;
    const provider: TranscriptionProvider = {
      name: 'scripted', model: 'local-failure',
      async transcribe(request) {
        if (++prepared === 1) throw new Error('local preparation failed');
        await request.beforeSend();
        sent++;
        throw new TranscriptionError('TRANSCRIPTION_UNAVAILABLE');
      },
    };
    const now = new Date('2026-10-01T00:00:00Z');
    const { service } = await voiceFor(provider, { clock: () => now, limits: { monthlyMinutes: 0.05 } });
    const first = await send(service, me);
    expect(first.snapshot).toMatchObject({ status: 'failed', errorCode: 'INTERNAL_ERROR' });
    expect(await monthlyVoiceMilliseconds(db.pool, me.userId, now)).toBe(0);
    expect((await send(service, me, { id: first.id })).snapshot).toMatchObject({ status: 'failed', errorCode: 'TRANSCRIPTION_UNAVAILABLE' });
    expect(sent).toBe(1);
    expect(await monthlyVoiceMilliseconds(db.pool, me.userId, now)).toBe(3000);
    await service.abandon(me, first.id);
    await service.cleanup();
    expect(await monthlyVoiceMilliseconds(db.pool, me.userId, now)).toBe(3000);
    expect(await failure(send(service, me))).toMatchObject({ code: 'TRANSCRIPTION_BUDGET_EXCEEDED' });
    expect((await db.pool.query('SELECT attempt, state FROM transcription_attempts WHERE transcription_id = $1 ORDER BY attempt', [first.id])).rows)
      .toEqual([{ attempt: 1, state: 'released' }, { attempt: 2, state: 'dispatched' }]);
  });

  it('releases interrupted reservations during polling, retry and cleanup without refunding dispatched attempts', async () => {
    const me = await freshUser();
    const now = new Date('2026-09-17T10:00:00Z');
    const old = new Date(now.getTime() - 11 * 60_000);
    const ids = Array.from({ length: 5 }, () => randomUUID());
    for (const [index, id] of ids.entries()) {
      await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, attempts, created_at, updated_at)
        VALUES ($1, $2, $3, 3000, $4, $5, 1, $6, $6)`, [id, me.userId, index === 3 ? 'failed' : 'transcribing', mono.length, sha(mono), old]);
      await db.pool.query(`INSERT INTO transcription_attempts (transcription_id, attempt, user_id, duration_ms, state, reserved_at, budget_at, dispatched_at)
        VALUES ($1, 1, $2, 3000, $3, $4, $4, $5)`, [id, me.userId, index === 4 ? 'dispatched' : 'reserved', old, index === 4 ? old : null]);
    }
    const { service } = await voiceFor(new ScriptedTranscriptionProvider([said('Reprise.')]), { clock: () => now });
    expect(await monthlyVoiceMilliseconds(db.pool, me.userId, now)).toBe(15000);
    expect(await service.snapshot(me.userId, ids[0]!)).toMatchObject({ status: 'failed', errorCode: 'INTERRUPTED' });
    expect((await send(service, me, { id: ids[1]! })).snapshot.status).toBe('completed');
    await service.cleanup();
    const attempts = (await db.pool.query('SELECT transcription_id, attempt, state FROM transcription_attempts WHERE user_id = $1', [me.userId])).rows;
    for (const id of ids.slice(0, 4)) expect(attempts).toContainEqual({ transcription_id: id, attempt: 1, state: 'released' });
    expect(attempts).toContainEqual({ transcription_id: ids[1], attempt: 2, state: 'dispatched' });
    expect(attempts).toContainEqual({ transcription_id: ids[4], attempt: 1, state: 'dispatched' });
    expect(await monthlyVoiceMilliseconds(db.pool, me.userId, now)).toBe(6000);
  });

  it('resumes a transcription cut by a restart and marks silent jobs as interrupted', async () => {
    const me = await freshUser();
    const now = new Date();
    const orphan = randomUUID();
    const stale = randomUUID();
    const fresh = randomUUID();
    for (const [id, updated] of [[orphan, new Date(now.getTime() - 11 * 60_000)], [stale, new Date(now.getTime() - 11 * 60_000)], [fresh, now]] as const) {
      await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, attempts, provider, model, created_at, updated_at)
        VALUES ($1, $2, 'transcribing', 3000, $3, $4, 1, 'scripted', 'scripted-v1', $5, $5)`, [id, me.userId, mono.length, sha(mono), updated]);
    }
    const { service } = await voiceFor(new ScriptedTranscriptionProvider([said('Repris après redémarrage.')]), { clock: () => now });
    // Once the interruption deadline passes, uploading the same file retries the job.
    expect((await send(service, me, { id: orphan })).snapshot).toMatchObject({ status: 'completed', text: 'Repris après redémarrage.' });
    expect(await row(orphan)).toMatchObject({ attempts: 2 });
    const counts = await service.cleanup();
    expect(counts.interrupted).toBeGreaterThanOrEqual(1);
    expect(await row(stale)).toMatchObject({ status: 'failed', error_code: 'INTERRUPTED' });
    expect((await row(stale))!.audio_deleted_at).not.toBeNull();
    expect(await row(fresh)).toMatchObject({ status: 'transcribing' });
  });

  it('applies the attempt limit to interrupted jobs as well as recorded failures', async () => {
    const me = await freshUser();
    const id = randomUUID();
    await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, attempts, created_at, updated_at)
      VALUES ($1, $2, 'transcribing', 3000, $3, $4, 3, now() - interval '11 minutes', now() - interval '11 minutes')`, [id, me.userId, mono.length, sha(mono)]);
    const provider = new ScriptedTranscriptionProvider([said('Jamais appelé.')]);
    const { service, files } = await voiceFor(provider);
    expect(await failure(send(service, me, { id }))).toMatchObject({ code: 'TRANSCRIPTION_FAILED', statusCode: 422 });
    expect(provider.requests).toHaveLength(0);
    expect(await files()).toEqual([]);
  });

  it('lets polling discover an interrupted job without waiting for hourly cleanup', async () => {
    const me = await freshUser();
    const id = randomUUID();
    let now = new Date();
    await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, attempts, created_at, updated_at)
      VALUES ($1, $2, 'transcribing', 3000, $3, $4, 1, $5, $5)`, [id, me.userId, mono.length, sha(mono), now]);
    const provider = new ScriptedTranscriptionProvider([said('Repris.')]);
    const { service, dir, files } = await voiceFor(provider, { clock: () => now });
    await writeFile(join(dir, `${id}.m4a`), mono);
    expect(await service.snapshot(me.userId, id)).toMatchObject({ status: 'transcribing', audioDeleted: false });
    now = new Date(now.getTime() + 11 * 60_000);
    expect(await service.snapshot(me.userId, id)).toMatchObject({ status: 'failed', errorCode: 'INTERRUPTED', audioDeleted: true });
    expect(await files()).toEqual([]);
    expect(provider.requests).toHaveLength(0);
    expect((await send(service, me, { id })).snapshot).toMatchObject({ status: 'completed', text: 'Repris.' });
    expect(await row(id)).toMatchObject({ attempts: 2 });
  });

  it('cleans old and orphaned audio, erases texts never used, and leaves foreign files alone', async () => {
    const me = await freshUser();
    const now = new Date();
    const { service, dir, files } = await voiceFor(new ScriptedTranscriptionProvider([said('Jamais envoyé.'), said('Récent.')]), { clock: () => now });
    const unused = await send(service, me);
    const recent = await send(service, me);
    await db.pool.query('UPDATE transcriptions SET updated_at = $2 WHERE id = $1', [unused.id, new Date(now.getTime() - 25 * 3600_000)]);
    const old = randomUUID();
    await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256, error_code, created_at, updated_at)
      VALUES ($1, $2, 'failed', 3000, 1, $3, 'TRANSCRIPTION_UNAVAILABLE', $4, $4)`, [old, me.userId, sha(mono), now]);
    const aged = new Date(now.getTime() - 25 * 3600_000);
    const eleven = new Date(now.getTime() - 11 * 60_000);
    const write = async (name: string, at: Date | null) => {
      await writeFile(join(dir, name), 'x');
      if (at) await utimes(join(dir, name), at, at);
    };
    await write(`${old}.m4a`, aged);
    await write(`${randomUUID()}.m4a`, null);
    await write(`upload-${randomUUID()}.part`, eleven);
    const uploading = `upload-${randomUUID()}.part`;
    await write(uploading, null);
    await write('notes.txt', aged);
    await write('not-a-uuid.m4a', aged);

    const counts = await service.cleanup();
    expect(counts.files).toBe(3);
    expect(counts.erased).toBeGreaterThanOrEqual(1);
    expect((await files()).sort()).toEqual(['not-a-uuid.m4a', 'notes.txt', uploading].sort());
    expect((await row(old))!.audio_deleted_at).not.toBeNull();
    expect(await row(unused.id)).toMatchObject({ status: 'erased', text: null, attempts: 1 });
    expect(await failure(service.snapshot(me.userId, unused.id))).toMatchObject({ code: 'TRANSCRIPTION_NOT_FOUND' });
    expect(await failure(send(service, me, { id: unused.id }))).toMatchObject({ code: 'TRANSCRIPTION_ERASED', statusCode: 422 });
    expect(await row(recent.id)).toMatchObject({ status: 'completed', text: 'Récent.' });
    const { rows: [run] } = await db.pool.query("SELECT outcome, details FROM maintenance_runs WHERE kind = 'audio_cleanup' ORDER BY id DESC LIMIT 1");
    expect(run).toEqual({ outcome: 'succeeded', details: counts });
    expect(JSON.stringify(run)).not.toContain('Jamais');
  });

  it('is unavailable without a provider and removes the upload', async () => {
    const me = await freshUser();
    const { service, files } = await voiceFor(null);
    expect(service.enabled).toBe(false);
    expect(await failure(send(service, me))).toMatchObject({ code: 'TRANSCRIPTION_UNAVAILABLE', statusCode: 503 });
    expect(await files()).toEqual([]);
  });

  it('turns a finished transcription into a voice message; deleting the history erases the text but not the billed minutes', async () => {
    const me = await freshUser();
    const other = await freshUser();
    const spoken = 'Demain rappelle-moi d’appeler le garage vers 17h.';
    const { service: voice } = await voiceFor(new ScriptedTranscriptionProvider([said(spoken), said('Autre compte.')]), { limits: { monthlyMinutes: 0.08 } });
    const { id } = await send(voice, me);
    const foreign = (await send(voice, other)).id;
    const waiting = randomUUID();
    await db.pool.query(`INSERT INTO transcriptions (id, user_id, status, duration_ms, byte_size, audio_sha256) VALUES ($1, $2, 'received', 3000, 1, $3)`, [waiting, me.userId, sha(mono)]);

    const { service } = assistantFor(db.pool, [reply('Noté.'), reply('Noté.')]);
    const voiceTurn = (transcriptionId: string, text: string) => {
      const request = turnRequest(text);
      return { ...request, message: { ...request.message, transcriptionId } };
    };
    expect(await failure(service.submitTurn(me, voiceTurn(foreign, 'x')))).toMatchObject({ code: 'TRANSCRIPTION_UNKNOWN', statusCode: 422 });
    expect(await failure(service.submitTurn(me, voiceTurn(waiting, 'x')))).toMatchObject({ code: 'TRANSCRIPTION_NOT_READY', statusCode: 422 });

    // The user corrected "17h" before sending: the original transcript is kept next to the sent text.
    const corrected = voiceTurn(id.toUpperCase(), 'Demain rappelle-moi d’appeler le garage vers 18h.');
    await service.submitTurn(me, corrected);
    await service.run(me, corrected.turnId);
    const { rows: [message] } = await db.pool.query('SELECT kind, text, original_transcript, transcription_id FROM messages WHERE id = $1', [corrected.message.id]);
    expect(message).toEqual({ kind: 'voice', text: corrected.message.text, original_transcript: spoken, transcription_id: id });
    const unchanged = voiceTurn(id, spoken);
    await service.submitTurn(me, { ...unchanged, conversationId: corrected.conversationId });
    await service.run(me, unchanged.turnId);
    expect((await db.pool.query('SELECT kind, original_transcript FROM messages WHERE id = $1', [unchanged.message.id])).rows[0]).toEqual({ kind: 'voice', original_transcript: null });

    const archive = await buildExport(db.pool, me.userId);
    expect(archive.conversations).toHaveLength(1);
    expect(archive.conversations[0]!.messages.filter((item) => item.role === 'user')).toEqual([
      expect.objectContaining({ kind: 'voice', text: corrected.message.text, originalTranscript: spoken, transcriptionId: id }),
      expect.objectContaining({ kind: 'voice', text: spoken, originalTranscript: null, transcriptionId: id }),
    ]);
    expect(JSON.stringify(archive)).not.toContain('audio');

    // Still used by the second message: deleting the first one keeps the text.
    await service.deleteMessage(me, corrected.message.id);
    expect(await row(id)).toMatchObject({ status: 'completed', text: spoken });
    await service.deleteConversation(me, corrected.conversationId);
    expect(await row(id)).toMatchObject({ status: 'erased', text: null, attempts: 1 });
    expect(await failure(service.submitTurn(me, voiceTurn(id, spoken)))).toMatchObject({ code: 'TRANSCRIPTION_UNKNOWN' });
    // Deleting history never refunds minutes: 3 s used + 3 s more exceeds the 4.8-minute test budget.
    expect(await failure(send(voice, me))).toMatchObject({ code: 'TRANSCRIPTION_BUDGET_EXCEEDED' });
  });
});
