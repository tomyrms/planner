import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../../src/app.js';
import { RuleBasedProvider } from '../../src/modules/assistant/index.js';
import { AuthService, type AuthConfig, type TokenResponse } from '../../src/modules/auth/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { NOW, TODAY, TOMORROW, ZONE, seedTask, task, turnRequest } from './helpers.js';

const URL = '/api/v1/assistant/turns';

describe('assistant HTTP routes and the five reference requests', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let built: Awaited<ReturnType<typeof buildApp>>;
  let disabled: Awaited<ReturnType<typeof buildApp>>;
  let auth: AuthService;
  let tokens: TokenResponse;
  let userId: string;

  beforeAll(async () => {
    db = await createTestDatabase();
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048, publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    const config: AuthConfig = {
      issuer: 'http://planner.test', apiAudience: 'planner-api', syncAudience: 'planner-sync', keyId: 'test-key',
      privateKeyPem: keys.privateKey, publicKeyPem: keys.publicKey, refreshDerivationKey: randomBytes(32).toString('hex'),
      now: () => NOW,
    };
    built = await buildApp({ pool: db.pool, auth: config, assistant: { provider: new RuleBasedProvider(), clock: () => NOW } });
    disabled = await buildApp({ pool: db.pool, auth: config });
    auth = new AuthService(db.pool, config);
    const secret = await auth.createPairingSecret({ name: 'iPhone' });
    const paired = await built.app.inject({ method: 'POST', url: '/api/v1/auth/pair/complete', payload: {
      pairingSecret: secret.pairingSecret, device: { name: 'iPhone', platform: 'ios', osVersion: '26.0', appVersion: '0.1.0' },
    } });
    tokens = paired.json<TokenResponse>();
    userId = (await db.pool.query('SELECT user_id FROM devices WHERE id = $1', [tokens.deviceId])).rows[0].user_id;
  });
  afterAll(async () => { await built?.app.close(); await disabled?.app.close(); await db?.close(); });

  const headers = (extra: Record<string, string> = {}) => ({ authorization: `Bearer ${tokens.accessToken}`, 'x-client-version': '0.1.0 (build 3)', ...extra });
  const post = (url: string, payload: unknown, extra: Record<string, string> = {}) =>
    built.app.inject({ method: 'POST', url, headers: headers(extra), payload: payload as Record<string, unknown> });
  const say = async (text: string, overrides: Record<string, unknown> = {}) => {
    const request = turnRequest(text, overrides);
    const response = await post(URL, request);
    expect(response.statusCode, response.body).toBe(200);
    return { request, snapshot: response.json() };
  };

  it('1 — « Demain rappelle-moi d’appeler le garage vers 17h » creates the task and its reminder', async () => {
    const { snapshot } = await say('Demain rappelle-moi d’appeler le garage vers 17h.');
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R1' });
    expect(snapshot.messages[1].text).toBe('Ajouté : Appeler le garage — demain 17:00\nRappel : à l’heure prévue');
    const id = snapshot.results[0].aggregateId;
    expect(await task(db.pool, id)).toMatchObject({ scheduled_date: TOMORROW, scheduled_time: '17:00:00', scheduled_time_zone: ZONE });
    expect((await db.pool.query('SELECT device_id FROM command_receipts WHERE client_command_id = $1', [snapshot.results[0].clientCommandId])).rows[0].device_id).toBe(tokens.deviceId);
    const reread = await built.app.inject({ method: 'GET', url: `${URL}/${snapshot.turnId}`, headers: headers() });
    expect(reread.json()).toEqual(snapshot);
    expect((await post(`${URL}/${snapshot.turnId}/cancel`, {})).json()).toEqual(snapshot);
  });

  it('3 — « Qu’est-ce qu’il me reste aujourd’hui ? » reads the day without effect', async () => {
    await seedTask(db.pool, userId, { title: 'Courses', schedule: { date: TODAY, time: '10:00', timeZone: ZONE } });
    await seedTask(db.pool, userId, { title: 'Arroser', schedule: { date: TODAY, time: null, timeZone: null } });
    await seedTask(db.pool, userId, { title: 'Facture en retard', schedule: { date: '2026-09-14', time: null, timeZone: null } });
    const { snapshot } = await say('Qu’est-ce qu’il me reste aujourd’hui ?');
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0', results: [] });
    expect(snapshot.messages[1].text).toBe('Il te reste : 10:00 Courses ; Arroser. À replanifier : Facture en retard.');
  });

  it('2 — « Décale les tâches non urgentes de ce soir à demain » proposes, then applies on confirmation, with a grouped Undo', async () => {
    const tidy = await seedTask(db.pool, userId, { title: 'Ranger le salon', schedule: { date: TODAY, time: '19:00', timeZone: ZONE } });
    const laundry = await seedTask(db.pool, userId, { title: 'Lessive', schedule: { date: TODAY, time: '21:30', timeZone: ZONE } });
    const urgent = await seedTask(db.pool, userId, { title: 'Appeler maman', priority: 'high', schedule: { date: TODAY, time: '20:00', timeZone: ZONE } });
    const due = await seedTask(db.pool, userId, { title: 'Envoyer le rapport', schedule: { date: TODAY, time: '22:00', timeZone: ZONE }, deadline: { date: TODAY, time: null, timeZone: null } });

    // Streamed: status, proposal and text events, then the final snapshot.
    const request = turnRequest('Décale les tâches non urgentes de ce soir à demain.');
    const stream = await post(URL, request, { accept: 'text/event-stream' });
    expect(stream.statusCode).toBe(200);
    expect(stream.headers['content-type']).toContain('text/event-stream');
    const events = stream.body.trim().split('\n\n').map((block) => {
      const [eventLine, dataLine] = block.split('\n');
      return { event: eventLine!.slice('event: '.length), data: JSON.parse(dataLine!.slice('data: '.length)) };
    });
    expect(events.map((event) => event.event)).toEqual(['turn.status', 'proposal', 'assistant.text', 'turn.final']);
    const proposal = events[1]!.data;
    expect(proposal.items.map((item: any) => item.text)).toEqual([
      'Déplacé : Ranger le salon — aujourd’hui 19:00 → demain 19:00',
      'Déplacé : Lessive — aujourd’hui 21:30 → demain 21:30',
    ]);
    expect(proposal.criterion).toBe('Critère : ce soir après 18:00, priorité non haute, sans échéance aujourd’hui');
    expect(events[2]!.data.text).toContain('\nCritère : ce soir après 18:00, priorité non haute, sans échéance aujourd’hui\n');
    const final = events[3]!.data;
    expect(final).toMatchObject({ status: 'awaiting_confirmation', riskClass: 'R2', proposal: { proposalId: proposal.proposalId, planHash: proposal.planHash } });
    expect(await task(db.pool, tidy)).toMatchObject({ scheduled_date: TODAY });

    expect((await post(`/api/v1/assistant/proposals/${proposal.proposalId}/confirm`, { planHash: 'nope' })).statusCode).toBe(400);
    const confirmed = await post(`/api/v1/assistant/proposals/${proposal.proposalId}/confirm`, { planHash: proposal.planHash });
    expect(confirmed.statusCode).toBe(200);
    expect(confirmed.json()).toMatchObject({ state: 'confirmed', undo: { actionId: expect.any(String) } });
    expect(await task(db.pool, tidy)).toMatchObject({ scheduled_date: TOMORROW, scheduled_time: '19:00:00' });
    expect(await task(db.pool, laundry)).toMatchObject({ scheduled_date: TOMORROW, scheduled_time: '21:30:00' });
    expect(await task(db.pool, urgent)).toMatchObject({ scheduled_date: TODAY, revision: 1 });
    expect(await task(db.pool, due)).toMatchObject({ scheduled_date: TODAY, revision: 1 });

    const undoRequestId = randomUUID();
    const undone = await post(`/api/v1/assistant/actions/${confirmed.json().undo.actionId}/undo`, { undoRequestId });
    expect(undone.statusCode).toBe(200);
    expect(undone.json()).toMatchObject({ outcome: 'undone' });
    expect(await task(db.pool, tidy)).toMatchObject({ scheduled_date: TODAY, scheduled_time: '19:00:00' });
    expect((await post(`/api/v1/assistant/actions/${confirmed.json().undo.actionId}/undo`, { undoRequestId })).json()).toEqual(undone.json());
    const missing = await post(`/api/v1/assistant/actions/${randomUUID()}/undo`, { undoRequestId: randomUUID() });
    expect(missing.statusCode).toBe(404);
    expect(missing.json()).toMatchObject({ error: { code: 'ACTION_NOT_FOUND' } });
  });

  it('4 — « J’ai fini le devoir C# » completes the one match, then answers « déjà terminée »', async () => {
    const homework = await seedTask(db.pool, userId, { title: 'Devoir C#' });
    const { snapshot } = await say('J’ai fini le devoir C#.');
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R1' });
    expect(snapshot.messages[1].text).toBe('Terminé : Devoir C#');
    expect(await task(db.pool, homework)).toMatchObject({ status: 'completed', revision: 2 });
    const { snapshot: again } = await say('J’ai fini le devoir C#.');
    expect(again.messages[1].text).toBe('Devoir C# était déjà terminée.');
    expect(await task(db.pool, homework)).toMatchObject({ revision: 2 });

    const bins = await seedTask(db.pool, userId, { title: 'Sortir les poubelles', schedule: { date: '2026-09-01', time: null, timeZone: null }, recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 1 } });
    const { snapshot: occurrence } = await say('J’ai sorti les poubelles.');
    expect(occurrence.messages[1].text).toBe('Terminé : Sortir les poubelles (aujourd’hui)');
    expect((await db.pool.query('SELECT occurrence_key, status FROM task_occurrences WHERE task_id = $1', [bins])).rows).toEqual([{ occurrence_key: TODAY, status: 'completed' }]);

    await seedTask(db.pool, userId, { title: 'Garage Martin' });
    await seedTask(db.pool, userId, { title: 'Garage Dupont' });
    const { snapshot: ambiguous } = await say('J’ai fini le garage.');
    expect(ambiguous).toMatchObject({ status: 'awaiting_clarification' });
    expect(ambiguous.messages[1].text).toMatch(/^Laquelle : .+ ou .+ \?$/);
    expect(ambiguous.clarification).toEqual({ question: ambiguous.messages[1].text, options: expect.arrayContaining(['Garage Martin', 'Garage Dupont']) });
  });

  it('5 — « Demain j’ai cours jusqu’à 16h, trouve-moi un bon moment pour faire ça » proposes slots after the referenced task', async () => {
    const conversationId = randomUUID();
    const { snapshot: created } = await say('Rappelle-moi de réviser le partiel demain à 8h.', { conversationId });
    expect(created.messages[1].text).toBe('Ajouté : Réviser le partiel — demain 08:00\nRappel : à l’heure prévue');
    // « Appeler le garage » (17:00–17:30 by default) is already booked tomorrow.
    const { snapshot } = await say('Demain j’ai cours jusqu’à 16h, trouve-moi un bon moment pour faire ça.', { conversationId });
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0', results: [] });
    expect(snapshot.messages[1].text).toMatch(/^Je te propose 16:00–17:00 ou 17:30–18:30 \(Journée utile 08:00–22:00 \(Europe\/Zurich\)\..*\)\. Lequel veux-tu \?$/);
  });

  it('refuses out-of-catalog requests and protects every route', async () => {
    const { snapshot } = await say('Vide la corbeille, s’il te plaît.');
    expect(snapshot).toMatchObject({ riskClass: 'R3' });
    const noToken = await built.app.inject({ method: 'POST', url: URL, headers: { 'x-client-version': '0.1.0' }, payload: turnRequest('x') });
    expect(noToken.statusCode).toBe(401);
    const old = await built.app.inject({ method: 'POST', url: URL, headers: headers({ 'x-client-version': '0.0.1' }), payload: turnRequest('x') });
    expect(old.statusCode).toBe(426);
    const invalid = await post(URL, { ...turnRequest('x'), userId });
    expect(invalid.statusCode).toBe(400);
    expect(invalid.json()).toMatchObject({ error: { code: 'INVALID_REQUEST' } });
    const reused = turnRequest('Bonjour');
    await post(URL, reused);
    const conflict = await post(URL, { ...reused, message: { ...reused.message, text: 'Autre' } });
    expect(conflict.statusCode).toBe(409);
    expect((await built.app.inject({ method: 'GET', url: `${URL}/${randomUUID()}`, headers: headers() })).statusCode).toBe(404);
    expect((await built.app.inject({ method: 'GET', url: `${URL}/not-a-uuid`, headers: headers() })).statusCode).toBe(400);
    expect((await built.app.inject({ method: 'DELETE', url: `/api/v1/conversations/${reused.conversationId}`, headers: headers() })).statusCode).toBe(204);
    expect((await built.app.inject({ method: 'DELETE', url: `/api/v1/conversations/${reused.conversationId}`, headers: headers() })).statusCode).toBe(404);
    expect((await built.app.inject({ method: 'DELETE', url: `/api/v1/messages/${randomUUID()}`, headers: headers() })).statusCode).toBe(404);
    const off = await disabled.app.inject({ method: 'POST', url: URL, headers: headers(), payload: turnRequest('x') });
    expect(off.statusCode).toBe(503);
    expect(off.json()).toMatchObject({ error: { code: 'ASSISTANT_UNAVAILABLE' } });
    for (const path of Object.keys(built.openApi.paths).filter((path) => path.includes('assistant') || path.includes('conversations'))) {
      for (const operation of Object.values(built.openApi.paths[path] as Record<string, any>)) expect(operation.security).toEqual([{ bearerAuth: [] }]);
    }
    const ready = await built.app.inject({ method: 'GET', url: '/api/v1/health/ready' });
    expect(ready.json()).toMatchObject({ assistant: 'configured' });
  });
});
