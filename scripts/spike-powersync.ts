// PowerSync spike on the server side (ADR-004, criteria 2, 3, 5, 6, 7 and 8), run with npm run spike:powersync.
// Needs the local stack: docker compose --profile app up -d --wait, then npm run db:provision-sync.
// A temporary device is paired and revoked at the end; "[spike]" tasks are left in the trash.
// Prints no token, password or task content beyond the spike's own titles.
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  PowerSyncDatabase, Schema, Table, UpdateType, column,
  type AbstractPowerSyncDatabase, type PowerSyncBackendConnector, type Transaction,
} from '@powersync/node';
import { loadConfig } from '../src/config.js';
import { createPool } from '../src/infrastructure/db/pool.js';
import { AuthService } from '../src/modules/auth/index.js';
import { executeCommand, type RawCommand } from '../src/modules/sync/index.js';

const API_URL = process.env.SMOKE_BASE_URL ?? 'http://127.0.0.1:4317';
const POWERSYNC_URL = process.env.POWERSYNC_URL ?? 'http://127.0.0.1:4318';
const config = loadConfig();
if (!config.databaseAdminUrl) throw new Error('DATABASE_ADMIN_URL is required (generation change scenario).');
const CLIENT_VERSION = `${config.minimumClientVersion} (build 1)`;

// Client schema: the synced columns of powersync/sync-config.yaml, plus the local queue tables.
const { text, integer, real } = column;
const schema = new Schema({
  projects: new Table({ name: text, color_key: text, sort_order: real, archived_at: text, deleted_at: text, revision: integer, created_at: text, updated_at: text }),
  tasks: new Table({
    project_id: text, title: text, notes: text, priority: text, status: text, completed_at: text,
    scheduled_date: text, scheduled_time: text, scheduled_time_zone: text, scheduled_start_at: text, duration_minutes: integer,
    deadline_date: text, deadline_time: text, deadline_time_zone: text, deadline_at: text,
    recurrence: text, missed_ignored_before: text, search_text: text, deleted_at: text, revision: integer, created_at: text, updated_at: text,
  }),
  task_occurrences: new Table({
    task_id: text, occurrence_key: text, status: text, completed_at: text,
    override_date: text, override_time: text, override_time_zone: text, successor_occurrence_key: text, created_at: text, updated_at: text,
  }),
  reminders: new Table({
    task_id: text, occurrence_key: text, kind: text, offset_minutes: integer, local_time: text,
    absolute_date: text, absolute_time: text, absolute_time_zone: text, state: text, created_at: text, updated_at: text,
  }),
  server_meta: new Table({ generation: text }),
  // Candidate queue representation (criterion 9): one insert-only row per command, id = clientCommandId.
  outbox: new Table({
    type: text, payload_version: integer, aggregate_type: text, aggregate_id: text,
    precondition: text, client_recorded_at: text, payload: text,
  }, { insertOnly: true }),
  sync_rejections: new Table({ command_type: text, aggregate_id: text, code: text, message: text, rejected_at: text }, { localOnly: true }),
  local_meta: new Table({ value: text }, { localOnly: true }),
});

type Check = { criterion: string; name: string; ok: boolean; detail: string };
const checks: Check[] = [];
function check(criterion: string, name: string, ok: boolean, detail = ''): void {
  checks.push({ criterion, name, ok, detail });
  process.stdout.write(`${ok ? '  ✓' : '  ✗'} [${criterion}] ${name}${detail ? ` — ${detail}` : ''}\n`);
}

async function waitFor<T>(label: string, probe: () => Promise<T | null | undefined | false>, timeoutMs = 30_000): Promise<T> {
  const started = Date.now();
  for (;;) {
    const value = await probe();
    if (value) return value;
    if (Date.now() - started > timeoutMs) throw new Error(`Timeout: ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
}

async function call(method: string, path: string, init: { body?: unknown; token?: string } = {}): Promise<{ status: number; json: any }> {
  const response = await fetch(`${API_URL}${path}`, {
    method,
    headers: {
      'x-client-version': CLIENT_VERSION,
      ...(init.body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(init.token ? { authorization: `Bearer ${init.token}` } : {}),
    },
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  const text = await response.text();
  return { status: response.status, json: text ? JSON.parse(text) : null };
}

class SyncSuspended extends Error {}

/** Translates insert-only outbox rows into the upload envelope; CRUD of synced tables is only the optimistic projection. */
class SpikeConnector implements PowerSyncBackendConnector {
  posts = 0;
  completedTransactions = 0;
  loseNextResponse = false;
  suspendedGeneration: string | null = null;
  constructor(private readonly accessToken: () => string) {}

  async fetchCredentials() {
    const response = await call('GET', '/api/v1/auth/sync-token', { token: this.accessToken() });
    if (response.status !== 200) throw new Error(`sync-token HTTP ${response.status}`);
    return { endpoint: POWERSYNC_URL, token: response.json.token as string };
  }

  async uploadData(database: AbstractPowerSyncDatabase): Promise<void> {
    if (this.suspendedGeneration !== null) throw new SyncSuspended('Sync suspended after a server generation change');
    const transaction = await database.getNextCrudTransaction();
    if (!transaction) return;
    const commands: RawCommand[] = transaction.crud
      .filter((entry) => entry.table === 'outbox' && entry.op === UpdateType.PUT)
      .map((entry) => {
        const data = entry.opData ?? {};
        return {
          clientCommandId: entry.id,
          type: data.type,
          payloadVersion: data.payload_version,
          aggregate: { type: data.aggregate_type, id: data.aggregate_id },
          ...(data.precondition ? { precondition: JSON.parse(data.precondition) } : {}),
          clientRecordedAt: data.client_recorded_at,
          ...(data.payload ? { payload: JSON.parse(data.payload) } : {}),
        } as RawCommand;
      });
    if (commands.length > 0) {
      const seen = await database.get<{ value: string }>("SELECT value FROM local_meta WHERE id = 'server_generation'");
      this.posts++;
      const response = await call('POST', '/api/v1/sync/mutations', {
        token: this.accessToken(),
        body: { envelopeVersion: 1, serverGeneration: seen.value, commands },
      });
      if (this.loseNextResponse) {
        this.loseNextResponse = false;
        throw new Error('Simulated lost response after the server committed');
      }
      if (response.status === 409) {
        // Keep the queue: no complete(), no purge (03_iOS/02_Local_Data_Sync.md, restoration).
        this.suspendedGeneration = response.json.error.serverGeneration;
        throw new SyncSuspended('Server generation changed');
      }
      if (response.status !== 200) throw new Error(`Upload HTTP ${response.status}`);
      const rejected = (response.json.results as Array<Record<string, any>>).filter((result) => result.outcome === 'rejected');
      if (rejected.length > 0) {
        await database.writeTransaction(async (tx: Transaction) => {
          for (const result of rejected) {
            const command = commands.find((candidate) => candidate.clientCommandId === result.clientCommandId)!;
            await tx.execute(
              'INSERT INTO sync_rejections (id, command_type, aggregate_id, code, message, rejected_at) VALUES (?, ?, ?, ?, ?, ?)',
              [command.clientCommandId, command.type, command.aggregate.id, result.code, result.message, new Date().toISOString()],
            );
          }
        });
      }
    }
    // Acknowledged is not applied: rejections stay visible in sync_rejections.
    await transaction.complete();
    this.completedTransactions++;
  }
}

function newCommand(type: string, aggregateId: string, payload: Record<string, unknown>, extra: Partial<RawCommand> = {}): RawCommand {
  return {
    clientCommandId: randomUUID(), type, payloadVersion: 1,
    aggregate: { type: type.startsWith('project.') ? 'project' : 'task', id: aggregateId },
    clientRecordedAt: new Date().toISOString(), payload, ...extra,
  };
}

async function enqueue(db: AbstractPowerSyncDatabase, command: RawCommand, optimistic?: (tx: Transaction) => Promise<unknown>): Promise<void> {
  // One local transaction: optimistic projection + queued command (03_iOS/02_Local_Data_Sync.md).
  await db.writeTransaction(async (tx) => {
    if (optimistic) await optimistic(tx);
    await tx.execute(
      'INSERT INTO outbox (id, type, payload_version, aggregate_type, aggregate_id, precondition, client_recorded_at, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [command.clientCommandId, command.type, command.payloadVersion, command.aggregate.type, command.aggregate.id,
        command.precondition ? JSON.stringify(command.precondition) : null, command.clientRecordedAt,
        command.payload ? JSON.stringify(command.payload) : null],
    );
  });
}

const apiPool = createPool(config.databaseUrl);
const adminPool = createPool(config.databaseAdminUrl);
const auth = new AuthService(apiPool, config.auth);
const directory = mkdtempSync(join(tmpdir(), 'planner-spike-'));
let db: AbstractPowerSyncDatabase | undefined;
let deviceId: string | undefined;
let originalGeneration: string | undefined;
const started = Date.now();

try {
  const { pairingSecret } = await auth.createPairingSecret({ name: 'Spike PowerSync' });
  const paired = await call('POST', '/api/v1/auth/pair/complete', {
    body: { pairingSecret, device: { name: 'Spike PowerSync', platform: 'ios', osVersion: '26.0', appVersion: config.minimumClientVersion } },
  });
  if (paired.status !== 201) throw new Error(`pair HTTP ${paired.status}`);
  deviceId = paired.json.deviceId as string;
  originalGeneration = paired.json.serverGeneration as string;
  const accessToken = paired.json.accessToken as string;
  const { rows: [owner] } = await apiPool.query<{ user_id: string }>('SELECT user_id FROM devices WHERE id = $1', [deviceId]);
  const userId = owner!.user_id;
  const assistant = { userId, deviceId: null, origin: 'assistant' as const };

  const connector = new SpikeConnector(() => accessToken);
  db = new PowerSyncDatabase({ schema, database: { dbFilename: 'spike.sqlite', dbLocation: directory } });
  await db.init();
  await db.execute("INSERT INTO local_meta (id, value) VALUES ('server_generation', ?)", [originalGeneration]);
  const localDb = db;
  const pending = async () => (await localDb.getNextCrudTransaction()) !== null;
  const localTask = (id: string) => localDb.getOptional<{ title: string; revision: number; deleted_at: string | null }>(
    'SELECT title, revision, deleted_at FROM tasks WHERE id = ?', [id]);
  const serverTask = async (id: string) => (await apiPool.query<{ title: string; revision: string }>('SELECT title, revision FROM tasks WHERE id = $1', [id])).rows[0];
  const receipts = async (commandId: string) => (await apiPool.query<{ n: number }>('SELECT count(*)::int AS n FROM command_receipts WHERE client_command_id = $1', [commandId])).rows[0]!.n;
  const created: string[] = [];

  console.log('Spike PowerSync — connexion…');
  await db.connect(connector, { retryDelayMs: 300, crudUploadThrottleMs: 50 });
  const firstSyncStarted = Date.now();
  await db.waitForFirstSync({ signal: AbortSignal.timeout(30_000) });
  const generationRow = await db.getOptional<{ generation: string }>('SELECT generation FROM server_meta');
  check('base', 'premier sync et génération répliquée', generationRow?.generation === originalGeneration, `${Date.now() - firstSyncStarted} ms`);

  // Criterion 5: a server mutation (the AI path) reaches the client and is never uploaded again.
  const serverTaskId = randomUUID();
  created.push(serverTaskId);
  const postsBefore = connector.posts;
  await executeCommand(apiPool, assistant, newCommand('task.create', serverTaskId, { title: '[spike] créée par le serveur' }));
  const replicationStarted = Date.now();
  await waitFor('server task replicated', () => localTask(serverTaskId));
  const replicationMs = Date.now() - replicationStarted;
  await executeCommand(apiPool, assistant, newCommand('task.patch', serverTaskId, { set: { title: '[spike] modifiée par le serveur' } }));
  const patched = await waitFor('server patch replicated', async () => {
    const row = await localTask(serverTaskId);
    return row?.title === '[spike] modifiée par le serveur' ? row : null;
  });
  check('5', 'mutation serveur répliquée sans ré-upload', patched.revision === 2 && connector.posts === postsBefore && !(await pending()),
    `création visible en ${replicationMs} ms, révision ${patched.revision}, envois ${connector.posts - postsBefore}`);

  // Local flow: optimistic projection, upload, server state replaces the projection.
  const localTaskId = randomUUID();
  created.push(localTaskId);
  const create = newCommand('task.create', localTaskId, { title: '[spike] créée hors ligne' });
  await enqueue(db, create, (tx) => tx.execute('INSERT INTO tasks (id, title, status, priority, revision) VALUES (?, ?, ?, ?, 0)', [localTaskId, '[spike] créée hors ligne', 'active', 'none']));
  const optimistic = await localTask(localTaskId);
  const patch = newCommand('task.patch', localTaskId, { set: { title: '[spike] renommée hors ligne' } }, { precondition: { kind: 'afterCommand', clientCommandId: create.clientCommandId } });
  await enqueue(db, patch, (tx) => tx.execute('UPDATE tasks SET title = ? WHERE id = ?', ['[spike] renommée hors ligne', localTaskId]));
  await waitFor('local commands uploaded', async () => !(await pending()));
  const confirmed = await waitFor('server state replicated', async () => {
    const row = await localTask(localTaskId);
    return row?.revision === 2 ? row : null;
  });
  check('flux', 'projection optimiste puis état serveur (afterCommand chaîné)', optimistic?.revision === 0 && confirmed.title === '[spike] renommée hors ligne',
    `révision locale 0 → ${confirmed.revision}`);

  // Criterion 3: a rejection at the head of the queue does not block the following commands.
  const rejectedCommand = newCommand('task.patch', randomUUID(), { set: { title: 'inconnue' } });
  const afterRejectionId = randomUUID();
  created.push(afterRejectionId);
  await enqueue(db, rejectedCommand);
  await enqueue(db, newCommand('task.create', afterRejectionId, { title: '[spike] après un rejet' }));
  await waitFor('queue drained after rejection', async () => !(await pending()));
  const rejection = await db.getOptional<{ code: string }>('SELECT code FROM sync_rejections WHERE id = ?', [rejectedCommand.clientCommandId]);
  check('3', 'rejet en tête conservé, file non bloquée', rejection?.code === 'ENTITY_NOT_FOUND' && (await serverTask(afterRejectionId)) !== undefined,
    `rejet ${rejection?.code ?? 'absent'}`);

  // Criterion 2: the server committed but the response was lost; the retry yields one effect.
  const lostId = randomUUID();
  created.push(lostId);
  const lost = newCommand('task.create', lostId, { title: '[spike] réponse perdue' });
  const postsBeforeLoss = connector.posts;
  connector.loseNextResponse = true;
  await enqueue(db, lost);
  await waitFor('queue drained after lost response', async () => !(await pending()));
  await waitFor('lost-response task replicated', () => localTask(lostId));
  const lostServer = await serverTask(lostId);
  check('2', 'réponse perdue puis renvoi : un seul effet', connector.posts - postsBeforeLoss === 2 && (await receipts(lost.clientCommandId)) === 1 && lostServer?.revision === '1',
    `${connector.posts - postsBeforeLoss} envois, ${await receipts(lost.clientCommandId)} reçu, révision ${lostServer?.revision}`);

  // Criterion 6: an accumulated command with an unknown payload version is rejected explicitly; an old-shape command is accepted.
  const futureCommand = { ...newCommand('task.patch', lostId, { set: { title: 'v2' } }), payloadVersion: 2 };
  const oldShapeId = randomUUID();
  created.push(oldShapeId);
  await enqueue(db, futureCommand);
  await enqueue(db, newCommand('task.create', oldShapeId, { title: '[spike] ancien format' }));
  await waitFor('queue drained after version mismatch', async () => !(await pending()));
  await waitFor('old-shape task replicated', () => localTask(oldShapeId));
  const versionRejection = await db.getOptional<{ code: string }>('SELECT code FROM sync_rejections WHERE id = ?', [futureCommand.clientCommandId]);
  check('6', 'version de payload inconnue rejetée explicitement, ancien format accepté',
    versionRejection?.code === 'PAYLOAD_VERSION_UNSUPPORTED' && (await serverTask(oldShapeId)) !== undefined, `rejet ${versionRejection?.code ?? 'absent'}`);

  // Criterion 7: a restore changes the generation; the client stops uploading and keeps its queue.
  const restoredGeneration = randomUUID();
  const localIds = async () => new Set((await localDb.getAll<{ id: string }>('SELECT id FROM tasks')).map((row) => row.id));
  const before = await localIds();
  await adminPool.query('UPDATE server_meta SET generation = $1', [restoredGeneration]);
  await waitFor('new generation replicated', () => localDb.getOptional('SELECT 1 FROM server_meta WHERE generation = ?', [restoredGeneration]));
  const heldId = randomUUID();
  created.push(heldId);
  const held = newCommand('task.create', heldId, { title: '[spike] en attente pendant la restauration' });
  await enqueue(db, held, (tx) => tx.execute('INSERT INTO tasks (id, title, status, priority, revision) VALUES (?, ?, ?, ?, 0)', [heldId, held.payload!.title, 'active', 'none']));
  await waitFor('upload suspended', async () => connector.suspendedGeneration);
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  const heldTransaction = await db.getNextCrudTransaction();
  const stillQueued = heldTransaction?.crud.some((entry) => entry.table === 'outbox' && entry.id === held.clientCommandId) ?? false;
  const after = await localIds();
  const kept = [...before].every((id) => after.has(id));
  check('7', 'génération changée : envoi suspendu, file et données locales conservées',
    connector.suspendedGeneration === restoredGeneration && stillQueued && (await serverTask(heldId)) === undefined && kept && after.has(heldId),
    `file ${stillQueued ? 'conservée' : 'perdue'}, ${before.size} tâches locales ${kept ? 'toutes conservées' : 'EN PARTIE PERDUES'} + 1 en attente`);

  // Back to the original generation (local environment only): the held command then goes through.
  await adminPool.query('UPDATE server_meta SET generation = $1', [originalGeneration]);
  originalGeneration = undefined;
  connector.suspendedGeneration = null;
  await waitFor('held command uploaded after recovery', async () => !(await pending()), 30_000);
  check('7', 'reprise : la commande conservée est envoyée une seule fois', (await receipts(held.clientCommandId)) === 1 && (await serverTask(heldId)) !== undefined);

  // Criterion 8: measured operating cost of this installation.
  const { rows: [cost] } = await adminPool.query<{ storage: string; slot_lag: string; slots: number }>(`
    SELECT pg_size_pretty(pg_database_size('planner_powersync')) AS storage,
           COALESCE(pg_size_pretty(max(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn))), '0 bytes') AS slot_lag,
           count(*)::int AS slots
    FROM pg_replication_slots WHERE plugin = 'pgoutput'`);
  const local = await db.get<{ bytes: number }>('SELECT page_count * page_size AS bytes FROM pragma_page_count(), pragma_page_size()');
  check('8', 'coût mesuré', true, `stockage ${cost!.storage}, ${cost!.slots} slot(s), retard ${cost!.slot_lag}, SQLite local ${Math.round(local.bytes / 1024)} Kio`);

  // Leave the spike tasks in the trash, as a user would.
  for (const id of created) await executeCommand(apiPool, { userId, deviceId: null, origin: 'manual' }, newCommand('task.delete', id, {}));
} catch (error) {
  check('spike', 'exécution', false, error instanceof Error ? error.message : 'erreur inconnue');
} finally {
  if (originalGeneration !== undefined) await adminPool.query('UPDATE server_meta SET generation = $1', [originalGeneration]).catch(() => undefined);
  await db?.disconnectAndClear().catch(() => undefined);
  await db?.close().catch(() => undefined);
  if (deviceId) await auth.revokeDevice(deviceId).catch(() => undefined);
  await apiPool.end();
  await adminPool.end();
  rmSync(directory, { recursive: true, force: true });
}

const failed = checks.filter((item) => !item.ok);
console.log(`\nSpike terminé en ${Math.round((Date.now() - started) / 1000)} s : ${checks.length - failed.length}/${checks.length} vérifications réussies.`);
process.exitCode = failed.length > 0 ? 1 : 0;
