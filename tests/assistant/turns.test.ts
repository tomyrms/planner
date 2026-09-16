import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  AssistantError, ProviderError, callTools, reply, toolCall, type Identity, type ProviderRequest, type ScriptedProvider,
} from '../../src/modules/assistant/index.js';
import { createTestDatabase } from '../db/helpers.js';
import { NOW, TODAY, TOMORROW, ZONE, ask, assistantFor, count, manual, seedTask, task, turnRequest } from './helpers.js';

const lastToolResult = (request: ProviderRequest) => {
  const message = [...request.messages].reverse().find((item) => item.role === 'tool');
  return JSON.parse((message as { content: string }).content);
};

describe('assistant turns', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let me: Identity;

  beforeAll(async () => {
    db = await createTestDatabase();
    me = { userId: (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id, deviceId: null };
  });
  afterAll(async () => { await db?.close(); });

  describe('durable pipeline', () => {
    it('applies an explicit creation with its reminder and writes the answer from the receipt', async () => {
      const { service, provider } = assistantFor(db.pool, [
        callTools(toolCall('create_task', {
          title: 'Appeler le garage', schedule: { date: TOMORROW, time: '17:00' }, reminder: { kind: 'before_start', offsetMinutes: 0 },
        })),
        reply('C’est fait, j’ai tout créé et même réservé le garage !'),
      ]);
      const { request, snapshot } = await ask(service, me, 'Demain rappelle-moi d’appeler le garage vers 17h.');
      expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R1', error: null, proposal: null });
      expect(snapshot.messages.map((message: any) => [message.role, message.kind])).toEqual([['user', 'text'], ['assistant', 'action_result']]);
      expect(snapshot.messages[1].text).toBe('Ajouté : Appeler le garage — demain 17:00\nRappel : à l’heure prévue');
      const [result] = snapshot.results;
      expect(result).toMatchObject({ commandType: 'task.create', aggregateType: 'task', revision: 1, noop: false });
      expect(snapshot.undo).toEqual({ actionId: result.actionId, state: 'available', expiresAt: new Date(NOW.getTime() + 24 * 3600_000).toISOString() });
      expect(await task(db.pool, result.aggregateId)).toMatchObject({ title: 'Appeler le garage', scheduled_date: TOMORROW, scheduled_time: '17:00:00', scheduled_time_zone: ZONE });
      expect((await db.pool.query('SELECT kind, offset_minutes, state FROM reminders WHERE task_id = $1', [result.aggregateId])).rows)
        .toEqual([{ kind: 'before_start', offset_minutes: 0, state: 'active' }]);
      expect((await db.pool.query('SELECT origin FROM command_receipts WHERE client_command_id = $1', [result.clientCommandId])).rows[0].origin).toBe('assistant');
      const scripted = provider as ScriptedProvider;
      expect(scripted.requests).toHaveLength(2);
      expect(scripted.requests[0]!.system).toContain(`Date du tour : ${TODAY} (mercredi), heure 18:42, fuseau ${ZONE}`);
      expect(scripted.requests[0]!.tools.map((tool) => tool.name)).toContain('create_task');
      expect(JSON.stringify(scripted.requests[0]!.system)).not.toContain('garage');

      // The same turn again is answered from storage, without calling the model; other content is refused.
      expect(await service.submitTurn(me, request)).toEqual({ turnId: request.turnId, created: false });
      expect(await service.run(me, request.turnId)).toEqual(snapshot);
      expect(scripted.requests).toHaveLength(2);
      await expect(service.submitTurn(me, { ...request, message: { ...request.message, text: 'Autre chose' } }))
        .rejects.toMatchObject({ code: 'IDEMPOTENCY_KEY_REUSED', statusCode: 409 });
      expect(await count(db.pool, 'SELECT 1 FROM tasks WHERE id = $1', [result.aggregateId])).toBe(1);
    });

    it('answers a read from the tools and never lets a reply claim an effect', async () => {
      await seedTask(db.pool, me.userId, { title: 'Réviser C#', schedule: { date: TODAY, time: '20:00', timeZone: ZONE } });
      const { service } = assistantFor(db.pool, [
        callTools(toolCall('list_day', { date: TODAY })),
        (request) => {
          const result = lastToolResult(request);
          const titles = result.data.commitments.map((item: any) => `${item.title} à ${item.time}`);
          return reply(`Il te reste : ${titles.join(', ')}.`);
        },
      ]);
      const { snapshot } = await ask(service, me, 'Qu’est-ce qu’il me reste aujourd’hui ?');
      expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0', results: [], undo: null });
      expect(snapshot.messages[1]).toMatchObject({ kind: 'text' });
      expect(snapshot.messages[1].text).toContain('Réviser C# à 20:00');

      const lying = assistantFor(db.pool, [reply('J’ai ajouté la tâche, c’est fait.')]);
      const { snapshot: guarded } = await ask(lying.service, me, 'Ajoute du lait.');
      expect(guarded).toMatchObject({ status: 'completed', riskClass: 'R0' });
      expect(guarded.messages[1].text).toBe('Je n’ai effectué aucune modification. Peux-tu préciser ce que tu veux changer ?');
    });

    it('ends with a question or a refusal and no effect', async () => {
      const before = await count(db.pool, 'SELECT 1 FROM tasks');
      const clarify = assistantFor(db.pool, [callTools(toolCall('ask_clarification', { question: 'Quel garage : Martin ou Dupont ?' }))]);
      const { snapshot: question } = await ask(clarify.service, me, 'Décale garage.');
      expect(question).toMatchObject({ status: 'awaiting_clarification', riskClass: null });
      expect(question.messages[1]).toMatchObject({ kind: 'clarification', text: 'Quel garage : Martin ou Dupont ?' });

      const refuse = assistantFor(db.pool, [callTools(toolCall('refuse_request', { reason: 'empty_trash' }))]);
      const { snapshot: refusal } = await ask(refuse.service, me, 'Vide la corbeille.');
      expect(refusal).toMatchObject({ status: 'completed', riskClass: 'R3' });
      expect(refusal.messages[1].text).toContain('Listes › Corbeille');
      expect(await count(db.pool, 'SELECT 1 FROM tasks')).toBe(before);
    });

    it('allows one correction of invalid arguments, then asks; unknown tools and invented ids change nothing', async () => {
      const before = await count(db.pool, 'SELECT 1 FROM tasks');
      const twice = assistantFor(db.pool, [
        callTools(toolCall('create_task', { title: '' })),
        callTools(toolCall('create_task', '{"title": "x", "userId": "someone"}')),
      ]);
      const { snapshot } = await ask(twice.service, me, 'Ajoute x.');
      expect(snapshot).toMatchObject({ status: 'awaiting_clarification' });
      expect(snapshot.messages[1].text).toBe('Je n’ai pas réussi à préparer cette action correctement. Peux-tu reformuler ?');
      const firstError = lastToolResult((twice.provider as ScriptedProvider).requests[1]!);
      expect(firstError).toMatchObject({ status: 'error', code: 'INVALID_ARGUMENTS' });

      const unknownTool = assistantFor(db.pool, [callTools(toolCall('run_sql', { sql: 'DELETE FROM tasks' })), reply('Je ne peux pas.')]);
      const { snapshot: noTool } = await ask(unknownTool.service, me, 'Supprime tout.');
      expect(lastToolResult((unknownTool.provider as ScriptedProvider).requests[1]!)).toMatchObject({ code: 'UNKNOWN_TOOL' });
      expect(noTool).toMatchObject({ status: 'completed', riskClass: 'R0' });

      // A real identifier the model did not read in this turn is as unusable as an invented one.
      const existing = await seedTask(db.pool, me.userId, { title: 'Pas lue dans ce tour' });
      for (const taskId of [existing, randomUUID()]) {
        const invented = assistantFor(db.pool, [callTools(toolCall('delete_task', { taskId })), reply('Rien n’a été fait.')]);
        const { snapshot: nothing } = await ask(invented.service, me, 'Supprime cette tâche.');
        expect(lastToolResult((invented.provider as ScriptedProvider).requests[1]!)).toMatchObject({ code: 'UNKNOWN_ID' });
        expect(nothing).toMatchObject({ status: 'completed', riskClass: 'R0', results: [] });
      }
      expect(await task(db.pool, existing)).toMatchObject({ deleted_at: null, revision: 1 });
      expect(await count(db.pool, 'SELECT 1 FROM tasks')).toBe(before + 1);
    });

    it('fails without effect on provider errors, partial outputs, too many rounds and timeouts', async () => {
      const before = await count(db.pool, 'SELECT 1 FROM tasks');
      const unavailable = assistantFor(db.pool, [new ProviderError('PROVIDER_UNAVAILABLE')]);
      const { snapshot: failed } = await ask(unavailable.service, me, 'Ajoute du pain.');
      expect(failed).toMatchObject({ status: 'failed', error: { code: 'PROVIDER_UNAVAILABLE' } });
      expect(failed.messages[1]).toMatchObject({ kind: 'error', text: 'L’assistant n’a pas pu répondre. Rien n’a été modifié.' });

      const truncated = assistantFor(db.pool, [{ ...callTools(toolCall('create_task', { title: 'Pain' })), finish: 'length' }]);
      expect((await ask(truncated.service, me, 'Ajoute du pain.')).snapshot).toMatchObject({ status: 'failed', error: { code: 'PROVIDER_TRUNCATED' } });

      const loops = assistantFor(db.pool, [
        callTools(toolCall('create_task', { title: 'Pain' })),
        callTools(toolCall('list_projects', {})),
        callTools(toolCall('list_projects', {})),
      ], { limits: { toolRounds: 2 } });
      expect((await ask(loops.service, me, 'Ajoute du pain.')).snapshot).toMatchObject({ status: 'failed', error: { code: 'TOOL_ROUNDS_EXCEEDED' } });

      const slow = assistantFor(db.pool, [
        callTools(toolCall('create_task', { title: 'Pain' })),
        (request) => new Promise((_, reject) => request.signal.addEventListener('abort', () => reject(new ProviderError('PROVIDER_TIMEOUT')))),
      ], { limits: { providerCallMs: 50 } });
      const { snapshot: timeout } = await ask(slow.service, me, 'Ajoute du pain.');
      expect(timeout).toMatchObject({ status: 'failed', error: { code: 'PROVIDER_TIMEOUT' } });
      expect(timeout.messages[1].text).toBe('L’assistant a mis trop de temps. Rien n’a été modifié.');
      expect(await count(db.pool, 'SELECT 1 FROM tasks')).toBe(before);
    });

    it('cancels a running turn before any effect', async () => {
      const { service } = assistantFor(db.pool, [
        callTools(toolCall('create_task', { title: 'Jamais créée' })),
        (request) => new Promise((_, reject) => request.signal.addEventListener('abort', () => reject(new ProviderError('PROVIDER_TIMEOUT')))),
      ]);
      const request = turnRequest('Ajoute une tâche.');
      await service.submitTurn(me, request);
      const running = service.run(me, request.turnId);
      for (let attempt = 0; attempt < 100 && (await db.pool.query('SELECT 1 FROM assistant_turns WHERE id = $1 AND status = $2', [request.turnId, 'interpreting'])).rowCount === 0; attempt++) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      const cancelled = await service.cancel(me, request.turnId) as Record<string, any>;
      expect(cancelled.status).toBe('cancelled');
      expect(cancelled.messages.map((message: any) => message.text)).toEqual(['Ajoute une tâche.', 'Demande annulée. Rien n’a été modifié.']);
      expect(await running).toEqual(cancelled);
      expect(await count(db.pool, "SELECT 1 FROM tasks WHERE title = 'Jamais créée'")).toBe(0);
      expect(await service.cancel(me, request.turnId)).toEqual(cancelled);
    });

    it('asks before touching a task with unsent iPhone changes', async () => {
      const id = await seedTask(db.pool, me.userId, { title: 'Facture électricité' });
      const { service } = assistantFor(db.pool, [
        callTools(toolCall('search_tasks', { query: 'facture' })),
        (request) => callTools(toolCall('complete_task', { taskId: lastToolResult(request).data.results[0].taskId })),
      ]);
      const { snapshot } = await ask(service, me, 'J’ai payé la facture.', { unsyncedAggregateIds: [id.toUpperCase()] });
      expect(snapshot).toMatchObject({ status: 'awaiting_clarification' });
      expect(snapshot.messages[1].text).toBe('Cette tâche a une modification pas encore envoyée depuis l’iPhone. Réessayer dans un instant ?');
      expect(await task(db.pool, id)).toMatchObject({ status: 'active', revision: 1 });
    });

    it('applies a plan all or nothing when the data changes before application', async () => {
      const id = await seedTask(db.pool, me.userId, { title: 'Arroser les plantes' });
      const { service } = assistantFor(db.pool, [
        callTools(toolCall('search_tasks', { query: 'arroser' })),
        callTools(toolCall('create_task', { title: 'Acheter du terreau' }), toolCall('update_task', { taskId: id, expectedRevision: 1, set: { priority: 'high' } })),
        async () => {
          await manual(db.pool, me.userId, 'task.patch', id, { set: { title: 'Arroser le jardin' } });
          return reply('');
        },
      ]);
      const { snapshot } = await ask(service, me, 'Ajoute du terreau et rends l’arrosage prioritaire.');
      expect(snapshot).toMatchObject({ status: 'failed', riskClass: 'R1', error: { code: 'PLAN_REJECTED' } });
      expect(snapshot.messages[1].text).toBe('Rien n’a été modifié : les données ont changé entre-temps. Peux-tu redemander ?');
      expect(await count(db.pool, "SELECT 1 FROM tasks WHERE title = 'Acheter du terreau'")).toBe(0);
      expect(await task(db.pool, id)).toMatchObject({ title: 'Arroser le jardin', priority: 'none', revision: 2 });
    });

    it('completes the occurrence of the day for a repeating task', async () => {
      const id = await seedTask(db.pool, me.userId, { title: 'Sortir les poubelles', schedule: { date: '2026-09-01', time: null, timeZone: null }, recurrence: { v: 1, mode: 'fixed', freq: 'daily', interval: 1 } });
      const { service, provider } = assistantFor(db.pool, [
        callTools(toolCall('search_tasks', { query: 'poubelles' })),
        callTools(toolCall('complete_task', { taskId: id })),
        callTools(toolCall('complete_task', { taskId: id, occurrenceKey: TODAY })),
        reply(''),
      ]);
      const { snapshot } = await ask(service, me, 'J’ai sorti les poubelles.');
      expect(lastToolResult((provider as ScriptedProvider).requests[2]!)).toMatchObject({ code: 'OCCURRENCE_REQUIRED' });
      expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R1' });
      expect(snapshot.messages[1].text).toBe('Terminé : Sortir les poubelles (aujourd’hui)');
      expect((await db.pool.query('SELECT status FROM task_occurrences WHERE task_id = $1 AND occurrence_key = $2', [id, TODAY])).rows).toEqual([{ status: 'completed' }]);
    });

    it('resolves « ça » to an object of the previous turn in the same conversation', async () => {
      const conversationId = randomUUID();
      const first = assistantFor(db.pool, [callTools(toolCall('create_task', { title: 'Préparer l’exposé', durationMinutes: 60 })), reply('')]);
      const { snapshot: created } = await ask(first.service, me, 'Ajoute préparer l’exposé.', { conversationId });
      const createdId = created.results[0].aggregateId;
      const second = assistantFor(db.pool, [
        (request) => {
          expect((request.messages[0] as { content: string }).content).toContain(createdId);
          return callTools(toolCall('update_task', { taskId: createdId, expectedRevision: 1, set: { schedule: { date: TOMORROW, time: '16:30' } } }));
        },
        reply(''),
      ]);
      const { snapshot } = await ask(second.service, me, 'Mets ça demain à 16h30.', { conversationId });
      expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R1' });
      expect(snapshot.messages[1].text).toBe('Déplacé : Préparer l’exposé — sans date → demain 16:30');
      const history = (second.provider as ScriptedProvider).requests[0]!.messages;
      expect(history.map((message) => message.role)).toEqual(['user', 'user', 'assistant', 'user']);
    });

    it('reports what could not be prepared next to what was done', async () => {
      const partial = assistantFor(db.pool, [
        callTools(
          toolCall('create_task', { title: 'Lait' }),
          toolCall('create_task', { title: 'Pain' }),
          toolCall('create_task', { title: 'Œufs', schedule: { date: '2026-02-30' } }),
        ),
        reply(''),
      ]);
      const { snapshot } = await ask(partial.service, me, 'Ajoute lait, pain et œufs le 30 février.');
      expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R1' });
      expect(snapshot.messages[1].text).toBe('2 tâches ajoutées\nAjouté : Lait\nAjouté : Pain\nNon fait : une valeur est invalide (date, heure ou format).');

      // A later successful call of the same tool is a correction: nothing is reported.
      const corrected = assistantFor(db.pool, [
        callTools(toolCall('create_task', { title: 'Beurre', schedule: { date: '2026-02-30' } })),
        callTools(toolCall('create_task', { title: 'Beurre', schedule: { date: '2026-02-28' } })),
        reply(''),
      ]);
      const { snapshot: fixed } = await ask(corrected.service, me, 'Ajoute du beurre.');
      expect(fixed.messages[1].text).toBe('Ajouté : Beurre — samedi 28 février');
    });

    it('limits turns per hour with a retry delay', async () => {
      const other: Identity = { userId: (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id, deviceId: null };
      const { service } = assistantFor(db.pool, [reply('ok'), reply('ok')], { limits: { turnsPerHour: 1 } });
      await ask(service, other, 'Bonjour');
      const refused = await service.submitTurn(other, turnRequest('Encore')).catch((error: unknown) => error as AssistantError);
      expect(refused).toMatchObject({ code: 'RATE_LIMITED', statusCode: 429 });
      expect((refused as AssistantError).details.retryAfterSeconds).toBeGreaterThan(0);
    });

    it('validates requests before storing a turn', async () => {
      const { service } = assistantFor(db.pool, [reply('ok')]);
      await expect(service.submitTurn(me, { ...turnRequest('x'), userId: me.userId })).rejects.toMatchObject({ code: 'INVALID_REQUEST', statusCode: 400 });
      const voice = turnRequest('x');
      await expect(service.submitTurn(me, { ...voice, message: { ...voice.message, transcriptionId: randomUUID() } })).rejects.toMatchObject({ code: 'TRANSCRIPTION_UNKNOWN', statusCode: 422 });
      await expect(service.submitTurn(me, turnRequest('x', { referenceInstant: '2026-09-14T10:00:00Z' }))).rejects.toMatchObject({ code: 'INVALID_REFERENCE_INSTANT' });
      const corrected = turnRequest('x');
      await expect(service.submitTurn(me, { ...corrected, message: { ...corrected.message, revisesMessageId: randomUUID() } })).rejects.toMatchObject({ code: 'REVISED_MESSAGE_UNKNOWN' });
      const other: Identity = { userId: (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id, deviceId: null };
      const { request } = await ask(service, other, 'Bonjour');
      await expect(service.submitTurn(me, turnRequest('x', { conversationId: request.conversationId }))).rejects.toMatchObject({ code: 'CONVERSATION_NOT_FOUND', statusCode: 404 });
      await expect(service.snapshot(me.userId, request.turnId)).rejects.toMatchObject({ code: 'TURN_NOT_FOUND' });
      const busy = assistantFor(db.pool, [reply('ok')], { limits: { runningTurnsPerDevice: 0 } });
      await expect(busy.service.submitTurn(me, turnRequest('x'))).rejects.toMatchObject({ code: 'TOO_MANY_TURNS', statusCode: 429 });
      const poor = assistantFor(db.pool, [reply('ok')], { limits: { monthlyTokenBudget: 1 } });
      await expect(poor.service.submitTurn(me, turnRequest('x'))).rejects.toBeInstanceOf(AssistantError);
      const disabled = new (service.constructor as any)(db.pool, null);
      await expect(disabled.submitTurn(me, turnRequest('x'))).rejects.toMatchObject({ code: 'ASSISTANT_UNAVAILABLE', statusCode: 503 });
    });
  });
});
