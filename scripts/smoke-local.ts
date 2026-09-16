// Local end-to-end check against a running API (npm run smoke:local).
// Uses the trusted console capability, then the public HTTP routes. Prints no secret or token.
// Leaves trashed "[smoke]" tasks and assistant conversations in the local database, as a real device would.
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { loadConfig } from '../src/config.js';
import { createPool } from '../src/infrastructure/db/pool.js';
import { AuthService } from '../src/modules/auth/index.js';

const baseUrl = process.env.SMOKE_BASE_URL ?? 'http://127.0.0.1:4317';
const config = loadConfig();
const pool = createPool(config.databaseUrl);
const steps: string[] = [];

async function call(method: string, path: string, init: { body?: unknown; form?: FormData; token?: string; clientVersion?: string } = {}): Promise<{ status: number; json: any }> {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      ...(init.body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(init.token ? { authorization: `Bearer ${init.token}` } : {}),
      ...(init.clientVersion ? { 'x-client-version': init.clientVersion } : {}),
    },
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
    ...(init.form === undefined ? {} : { body: init.form }),
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
  if (ready.json.sync !== 'provisioned') throw new Error('PowerSync non provisionné : lancer npm run db:provision-sync');

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
  // The iPhone learns the sync address here: a stale API image once returned none.
  const expectedEndpoint = config.auth.syncEndpoint ?? null;
  if (sync.json.endpoint !== expectedEndpoint) {
    throw new Error(`Adresse de sync ${sync.json.endpoint ?? 'absente'}, attendu ${expectedEndpoint ?? 'aucune'} : reconstruire l'API (docker compose --profile app up -d --build)`);
  }
  steps.push(`adresse de sync → ${expectedEndpoint ?? 'aucune'}`);
  const jwks = await call('GET', '/.well-known/jwks.json');
  expectStatus('jwks', jwks.status, 200);
  if (jwks.json.keys.some((key: Record<string, unknown>) => 'd' in key)) throw new Error('Clé privée exposée dans le JWKS');

  const token = rotated.json.accessToken as string;
  const clientVersion = `${config.minimumClientVersion} (build 1)`;
  const taskId = randomUUID();
  const createId = randomUUID();
  const recordedAt = new Date().toISOString();
  const envelope = { envelopeVersion: 1, serverGeneration: rotated.json.serverGeneration, commands: [
    { clientCommandId: createId, type: 'task.create', payloadVersion: 1, aggregate: { type: 'task', id: taskId }, clientRecordedAt: recordedAt, payload: { title: '[smoke] tâche de test' } },
    { clientCommandId: randomUUID(), type: 'task.delete', payloadVersion: 1, aggregate: { type: 'task', id: taskId }, clientRecordedAt: recordedAt,
      precondition: { kind: 'afterCommand', clientCommandId: createId } },
  ] };
  const mutations = await call('POST', '/api/v1/sync/mutations', { token, clientVersion, body: envelope });
  expectStatus('sync/mutations', mutations.status, 200);
  const outcomes = mutations.json.results.map((result: { outcome: string; revision?: number }) => `${result.outcome}:${result.revision}`).join(',');
  if (outcomes !== 'applied:1,applied:2') throw new Error(`Résultats de sync inattendus : ${outcomes}`);
  const replay = await call('POST', '/api/v1/sync/mutations', { token, clientVersion, body: envelope });
  expectStatus('sync/mutations rejoué', replay.status, 200);
  if (!replay.json.results.every((result: { outcome: string }) => result.outcome === 'duplicate')) throw new Error('Le rejeu a produit un nouvel effet');
  expectStatus('sync/mutations sans version', (await call('POST', '/api/v1/sync/mutations', { token, body: envelope })).status, 426);
  expectStatus('sync/mutations autre génération', (await call('POST', '/api/v1/sync/mutations', { token, clientVersion, body: { ...envelope, serverGeneration: randomUUID() } })).status, 409);

  // The public readiness check never names providers: the local .env (shared with Compose) says which ones run.
  // Assistant and voice are exercised only with the deterministic stand-ins, never a paid provider.
  const turnWith = async (label: string, text: string, transcriptionId: string | null) => {
    const turn = await call('POST', '/api/v1/assistant/turns', { token, clientVersion, body: {
      turnId: randomUUID(), conversationId: randomUUID(),
      message: { id: randomUUID(), text, transcriptionId, revisesMessageId: null },
      referenceInstant: new Date().toISOString(), timeZone: 'Europe/Zurich', unsyncedAggregateIds: [], calendarContext: null,
    } });
    expectStatus(label, turn.status, 200);
    if (turn.json.status !== 'completed' || turn.json.riskClass !== 'R1' || !turn.json.undo?.actionId) throw new Error(`Tour d'assistant inattendu : ${turn.json.status}/${turn.json.riskClass}`);
    if (turn.json.messages[0].kind !== (transcriptionId ? 'voice' : 'text')) throw new Error('Type de message inattendu');
    const undo = await call('POST', `/api/v1/assistant/actions/${turn.json.undo.actionId}/undo`, { token, clientVersion, body: { undoRequestId: randomUUID() } });
    expectStatus(`${label} undo`, undo.status, 200);
    if (undo.json.outcome !== 'undone') throw new Error('Undo non appliqué');
  };
  if (config.assistant.provider.kind === 'rules') {
    if (ready.json.assistant !== 'configured') throw new Error('Assistant non configuré côté API');
    await turnWith('assistant/turns', 'Demain rappelle-moi de [smoke] vérifier l’assistant vers 17h.', null);
  } else {
    steps.push(`assistant (${config.assistant.provider.kind}) non testé : fournisseur réel ou désactivé`);
  }
  if (config.voice.provider.kind === 'simulated') {
    if (ready.json.transcription !== 'configured') throw new Error('Transcription non configurée côté API');
    const transcriptionId = randomUUID();
    const form = new FormData();
    form.append('transcriptionId', transcriptionId);
    form.append('durationMs', '3000');
    form.append('audio', new Blob([new Uint8Array(await readFile(new URL('../tests/fixtures/audio/tone-3s-mono.m4a', import.meta.url)))], { type: 'audio/mp4' }), 'message.m4a');
    const voice = await call('POST', '/api/v1/assistant/transcriptions', { token, clientVersion, form });
    expectStatus('assistant/transcriptions', voice.status, 200);
    if (voice.json.status !== 'completed' || !voice.json.audioDeleted || !String(voice.json.text).includes('[voix simulée]')) {
      throw new Error(`Transcription inattendue : ${voice.json.status}`);
    }
    expectStatus('assistant/transcriptions sans jeton', (await call('POST', '/api/v1/assistant/transcriptions', { clientVersion, form })).status, 401);
    await turnWith('assistant/turns vocal', voice.json.text, transcriptionId);
  } else {
    steps.push(`voix (${config.voice.provider.kind}) non testée : fournisseur réel ou désactivé`);
  }

  expectStatus('auth/logout', (await call('POST', '/api/v1/auth/logout', { token: rotated.json.accessToken })).status, 200);
  expectStatus('refresh après logout', (await call('POST', '/api/v1/auth/refresh', { body: { refreshToken: rotated.json.refreshToken } })).status, 401);
  expectStatus('sync-token après logout', (await call('GET', '/api/v1/auth/sync-token', { token: rotated.json.accessToken })).status, 401);
  expectStatus('sync/mutations après logout', (await call('POST', '/api/v1/sync/mutations', { token, clientVersion, body: envelope })).status, 401);
  expectStatus('route CRUD absente', (await call('POST', '/api/v1/tasks', { body: {} })).status, 404);

  process.stdout.write(`Smoke local réussi (${baseUrl}) :\n${steps.map((step) => `  ✓ ${step}`).join('\n')}\n`);
} catch (error) {
  process.stderr.write(`Smoke local en échec : ${error instanceof Error ? error.message : 'erreur inconnue'}\n`);
  process.exitCode = 1;
} finally {
  await pool.end();
}
