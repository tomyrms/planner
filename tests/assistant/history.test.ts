import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { callTools, reply, toolCall, type Identity, type ProviderRequest } from '../../src/modules/assistant/index.js';
import { claimsAnEffect, templates } from '../../src/modules/assistant/format.js';
import { createTestDatabase } from '../db/helpers.js';
import { TODAY, TOMORROW, ZONE, ask, assistantFor, count, manual, seedTask, task } from './helpers.js';

const history = (request: ProviderRequest): Array<Record<string, any>> => {
  const message = request.messages.find((item) => item.content?.startsWith('[Données du serveur — historique vérifié'));
  return message ? JSON.parse(message.content!.slice(message.content!.indexOf('\n') + 1)) : [];
};
const lastRead = (request: ProviderRequest) => {
  const result = [...request.messages].reverse().find((item) => item.role === 'tool');
  return JSON.parse(result!.content!);
};

describe('receipt imitation guard', () => {
  it.each([
    'J’ai ajouté la tâche.', 'C’est créé.', 'Ajouté : Faire la vaisselle — aujourd’hui',
    '**Ajouté :** Faire la vaisselle', '✅ Ajouté : Faire la vaisselle',
    '2 tâches ajoutées\nAjouté : Pain\nAjouté : Lait', 'Tag ajouté automatiquement : Maison',
    'Voici le résultat.\nSous-tâche ajoutée : Réserver le train', 'Annulé :\nSupprimé : Pain',
  ])('rejects an uncommitted effect: %s', (text) => {
    expect(claimsAnEffect(text)).toBe(true);
  });

  it.each([
    'Il te reste Faire la vaisselle, sans heure.',
    'Le reçu précédent confirme la création de la tâche ; elle est maintenant terminée.',
    'La proposition précédente a été refusée ; aucune tâche n’a été modifiée.',
    'La tâche « Ajouté : un titre de test » est prévue aujourd’hui.',
    'Note : la tâche est prévue aujourd’hui, sans heure.',
    'Programme : acheter du lait et appeler le dentiste.',
    '3 tâches terminées aujourd’hui.',
  ])('preserves factual reads and receipt references: %s', (text) => {
    expect(claimsAnEffect(text)).toBe(false);
  });
});

describe('day reads and durable conversation evidence', () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  let me: Identity;
  beforeAll(async () => { db = await createTestDatabase(); });
  beforeEach(async () => {
    me = { userId: (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id, deviceId: null };
  });
  afterAll(async () => { await db?.close(); });

  it('creates today without an hour and reads it alongside timed tasks, excluding other days and inactive tasks', async () => {
    const conversationId = randomUUID();
    const creator = assistantFor(db.pool, [callTools(toolCall('create_task', { title: 'Faire la vaisselle', schedule: { date: TODAY } })), reply('')]);
    const { snapshot: created } = await ask(creator.service, me, 'Ajoute Faire la vaisselle aujourd’hui.', { conversationId });
    const taskId = created.results[0].aggregateId;
    expect(created.messages[1]).toMatchObject({ kind: 'action_result', text: 'Ajouté : Faire la vaisselle · aujourd’hui' });
    expect(await task(db.pool, taskId)).toMatchObject({ scheduled_date: TODAY, scheduled_time: null, scheduled_time_zone: null });
    const timed = await seedTask(db.pool, me.userId, { title: 'Appeler le garage', schedule: { date: TODAY, time: '20:00', timeZone: ZONE } });
    await seedTask(db.pool, me.userId, { title: 'Demain seulement', schedule: { date: TOMORROW } });
    await seedTask(db.pool, me.userId, { title: 'Sans date' });
    const done = await seedTask(db.pool, me.userId, { title: 'Déjà terminée', schedule: { date: TODAY } });
    await manual(db.pool, me.userId, 'task.complete', done);
    const deleted = await seedTask(db.pool, me.userId, { title: 'Corbeille', schedule: { date: TODAY } });
    await manual(db.pool, me.userId, 'task.delete', deleted);
    const reader = assistantFor(db.pool, [
      callTools(toolCall('list_day', { date: TODAY })),
      (request) => {
        expect(lastRead(request)).toMatchObject({ status: 'ok', data: { date: TODAY, todo: [{ taskId, time: null }], commitments: [{ taskId: timed, time: '20:00' }] } });
        expect(lastRead(request).data.todo).toHaveLength(1);
        expect(lastRead(request).data.commitments).toHaveLength(1);
        expect(request.system).toContain('Sans heure ne veut jamais dire sans date');
        return reply('Il te reste Faire la vaisselle, sans heure, et Appeler le garage à 20:00.');
      },
    ]);
    const { snapshot } = await ask(reader.service, me, 'Quelles sont mes tâches à faire aujourd’hui ?', { conversationId });
    expect(snapshot).toMatchObject({ riskClass: 'R0', results: [] });
    expect(snapshot.messages[1].text).toContain('Faire la vaisselle');
    expect(await count(db.pool, 'SELECT 1 FROM ai_actions WHERE user_id = $1', [me.userId])).toBe(1);
  });

  it('never publishes a receipt-shaped model reply without a committed command', async () => {
    const liar = assistantFor(db.pool, [reply('Ajouté : Faire la vaisselle — aujourd’hui\nTag ajouté automatiquement : Maison')]);
    const { snapshot } = await ask(liar.service, me, 'Ajoute Faire la vaisselle aujourd’hui.');
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0', results: [], undo: null });
    expect(snapshot.messages[1]).toMatchObject({ kind: 'text', text: templates.noEffectClaim });
    expect(await count(db.pool, 'SELECT 1 FROM tasks WHERE user_id = $1', [me.userId])).toBe(0);
    expect(await count(db.pool, 'SELECT 1 FROM ai_actions WHERE user_id = $1', [me.userId])).toBe(0);
  });

  it('marks legacy false receipts as uncommitted instead of teaching the next turn a fictitious creation', async () => {
    const conversationId = randomUUID();
    const first = assistantFor(db.pool, [reply('D’accord.')]);
    const { request: old } = await ask(first.service, me, 'Ajoute Faire la vaisselle aujourd’hui.', { conversationId });
    // Reproduce a pre-v6 persisted model reply, without writing any action or task.
    await db.pool.query("UPDATE messages SET text = $2 WHERE turn_id = $1 AND role = 'assistant'", [old.turnId, 'Ajouté : Faire la vaisselle — aujourd’hui']);
    const next = assistantFor(db.pool, [(request) => {
      const records = history(request);
      expect(records).toHaveLength(2);
      expect(records[1]).toMatchObject({ kind: 'text', source: 'message_without_receipt', turnStatus: 'completed', actions: [], text: templates.noEffectClaim });
      expect(records[1]!.text).not.toContain('Ajouté');
      return callTools(toolCall('search_tasks', { query: 'vaisselle', status: 'all' }));
    }, (request) => {
      expect(lastRead(request).data.results).toEqual([]);
      return reply('Le message précédent n’avait aucun reçu de création. Je ne trouve pas cette tâche.');
    }]);
    const { snapshot } = await ask(next.service, me, 'Tu ne l’avais pas créée ?', { conversationId });
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0' });
    expect(snapshot.results).toEqual([]);
    expect(await count(db.pool, 'SELECT 1 FROM tasks WHERE user_id = $1', [me.userId])).toBe(0);
  });

  it('recognizes a genuine past receipt while rereading the changed current task', async () => {
    const conversationId = randomUUID();
    const first = assistantFor(db.pool, [callTools(toolCall('create_task', { title: 'Faire la vaisselle', schedule: { date: TODAY } })), reply('')]);
    const { snapshot: created } = await ask(first.service, me, 'Ajoute Faire la vaisselle aujourd’hui.', { conversationId });
    const taskId = created.results[0].aggregateId;
    await manual(db.pool, me.userId, 'task.complete', taskId);
    const next = assistantFor(db.pool, [(request) => {
      expect(history(request)[1]).toMatchObject({ kind: 'action_result', source: 'server_receipt', turnStatus: 'completed', proposalState: null,
        actions: [{ commandType: 'task.create', aggregateId: taskId, revision: 1, noop: false, undoState: 'available', isUndo: false }] });
      return callTools(toolCall('get_task', { taskId }));
    }, (request) => {
      expect(lastRead(request).data).toMatchObject({ taskId, status: 'completed', revision: 2 });
      return reply('Le reçu précédent confirme la création de Faire la vaisselle. Elle est maintenant terminée.');
    }]);
    const { snapshot } = await ask(next.service, me, 'Tu ne l’avais pas créée ?', { conversationId });
    expect(snapshot.messages[1].text).toContain('Le reçu précédent confirme');
    expect(snapshot.results).toEqual([]);
    expect(await count(db.pool, 'SELECT 1 FROM ai_actions WHERE user_id = $1', [me.userId])).toBe(1);
  });

  it.each([
    ['get_task', 'active'], ['search_tasks', 'completed'], ['get_task', 'undone'],
  ] as const)('replaces a blocked effect claim with exact receipt/current-read facts (%s, %s)', async (reader, currentStatus) => {
    const conversationId = randomUUID();
    const first = assistantFor(db.pool, [callTools(toolCall('create_task', { title: 'Faire la vaisselle', schedule: { date: TODAY } })), reply('')]);
    const { snapshot: created } = await ask(first.service, me, 'Ajoute Faire la vaisselle aujourd’hui.', { conversationId });
    const taskId = created.results[0].aggregateId;
    if (currentStatus === 'completed') await manual(db.pool, me.userId, 'task.complete', taskId);
    if (currentStatus === 'undone') await first.service.undo(me, created.results[0].actionId, randomUUID());
    const actionsBefore = await count(db.pool, 'SELECT 1 FROM ai_actions WHERE user_id = $1', [me.userId]);
    const next = assistantFor(db.pool, [
      callTools(reader === 'get_task' ? toolCall('get_task', { taskId }) : toolCall('search_tasks', { query: 'vaisselle', status: 'all' })),
      // None of this free-form statement may pass through, even though another creation is proved.
      reply('J’ai ajouté la tâche imaginaire et supprimé toutes les autres.\nAjouté : Tâche imaginaire'),
    ]);
    const { snapshot } = await ask(next.service, me, 'Est-ce qu’elle avait été créée et où en est-elle ?', { conversationId });
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0', results: [] });
    const answer = snapshot.messages[1].text as string;
    expect(answer).toContain('Création confirmée lors d’un tour précédent : « Faire la vaisselle ».');
    expect(answer).toContain(`État lu : ${currentStatus === 'active' ? 'active' : currentStatus === 'completed' ? 'terminée' : 'dans la corbeille'}, prévue aujourd’hui, sans heure.`);
    expect(answer.includes('Cette création a ensuite été annulée.')).toBe(currentStatus === 'undone');
    expect(answer).toContain('Aucun nouveau changement n’a été effectué dans ce tour.');
    expect(answer).not.toContain('imaginaire');
    expect(answer).not.toContain('supprimé toutes');
    expect(await count(db.pool, 'SELECT 1 FROM ai_actions WHERE user_id = $1', [me.userId])).toBe(actionsBefore);
  });

  it.each(['none', 'unrelated', 'day_only'] as const)('never uses a prior receipt as a global bypass without a matching targeted fresh read (%s)', async (reading) => {
    const conversationId = randomUUID();
    const first = assistantFor(db.pool, [callTools(toolCall('create_task', { title: 'Faire la vaisselle', schedule: { date: TODAY } })), reply('')]);
    await ask(first.service, me, 'Ajoute Faire la vaisselle.', { conversationId });
    const unrelated = await seedTask(db.pool, me.userId, { title: 'Une autre tâche' });
    const claim = reply('Ajouté : Autre création inventée');
    const next = assistantFor(db.pool, reading === 'none' ? [claim] : [
      callTools(reading === 'unrelated' ? toolCall('get_task', { taskId: unrelated }) : toolCall('list_day', { date: TODAY })), claim,
    ]);
    const { snapshot } = await ask(next.service, me, 'As-tu créé la tâche ?', { conversationId });
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0', results: [] });
    expect(snapshot.messages[1].text).toBe(templates.noEffectClaim);
  });

  it('does not turn a fresh read of a manually created task into proof of an assistant creation', async () => {
    const taskId = await seedTask(db.pool, me.userId, { title: 'Création manuelle' });
    const service = assistantFor(db.pool, [callTools(toolCall('get_task', { taskId })), reply('J’ai créé cette tâche.')]);
    const { snapshot } = await ask(service.service, me, 'As-tu créé cette tâche ?');
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0', results: [] });
    expect(snapshot.messages[1].text).toBe(templates.noEffectClaim);
  });

  it('keeps confirmed proposals, original receipts and Undo receipts distinct', async () => {
    const conversationId = randomUUID();
    const taskId = await seedTask(db.pool, me.userId, { title: 'Ancienne tâche' });
    const first = assistantFor(db.pool, [callTools(toolCall('get_task', { taskId })), callTools(toolCall('delete_task', { taskId })), reply('')]);
    const { snapshot: proposal } = await ask(first.service, me, 'Supprime Ancienne tâche.', { conversationId });
    expect(proposal.status).toBe('awaiting_confirmation');
    const confirmed = await first.service.confirm(me, proposal.proposal.proposalId, proposal.proposal.planHash) as Record<string, any>;
    await first.service.undo(me, confirmed.results[0].actionId, randomUUID());
    const next = assistantFor(db.pool, [(request) => {
      const records = history(request);
      expect(records).toHaveLength(4);
      expect(records[1]).toMatchObject({ kind: 'proposal', source: 'server_proposal', proposalState: 'confirmed', actions: [] });
      expect(records[2]).toMatchObject({ source: 'server_receipt', actions: [{ commandType: 'task.delete', aggregateId: taskId, undoState: 'undone', isUndo: false }] });
      expect(records[3]).toMatchObject({ source: 'server_receipt', actions: [{ commandType: 'task.restore', aggregateId: taskId, isUndo: true }] });
      return callTools(toolCall('get_task', { taskId }));
    }, (request) => {
      expect(lastRead(request).data).toMatchObject({ taskId, deleted: false });
      return reply('Le reçu confirme la suppression passée, puis son annulation. La tâche existe actuellement.');
    }]);
    const { snapshot } = await ask(next.service, me, 'Où en est cette suppression ?', { conversationId });
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0' });
  });

  it('does not treat a superseded proposal as applied, and isolates conversations and owners', async () => {
    const conversationId = randomUUID();
    const taskId = await seedTask(db.pool, me.userId, { title: 'À conserver' });
    const first = assistantFor(db.pool, [callTools(toolCall('get_task', { taskId })), callTools(toolCall('delete_task', { taskId })), reply('')]);
    await ask(first.service, me, 'Supprime À conserver.', { conversationId });
    const next = assistantFor(db.pool, [(request) => {
      expect(history(request)[1]).toMatchObject({ source: 'server_proposal', proposalState: 'superseded', actions: [] });
      return reply('La proposition n’a pas été appliquée.');
    }]);
    const { snapshot } = await ask(next.service, me, 'As-tu supprimé la tâche ?', { conversationId });
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0' });
    expect(await task(db.pool, taskId)).toMatchObject({ deleted_at: null, revision: 1 });
    const isolated = assistantFor(db.pool, [(request) => { expect(history(request)).toEqual([]); return reply('Bonjour.'); }]);
    const isolatedResult = await ask(isolated.service, me, 'Bonjour.');
    expect(isolatedResult.snapshot).toMatchObject({ status: 'completed', riskClass: 'R0' });
    const other = { userId: (await db.pool.query<{ id: string }>('INSERT INTO users DEFAULT VALUES RETURNING id')).rows[0]!.id, deviceId: null };
    await expect(ask(isolated.service, other, 'Bonjour.', { conversationId })).rejects.toMatchObject({ code: 'CONVERSATION_NOT_FOUND' });
  });

  it('bounds verified history to the latest ten messages', async () => {
    const conversationId = randomUUID();
    for (let index = 0; index < 6; index++) {
      const turn = assistantFor(db.pool, [reply(`Réponse ${index}`)]);
      await ask(turn.service, me, `Message ${index}`, { conversationId });
    }
    const next = assistantFor(db.pool, [(request) => {
      const records = history(request);
      expect(records).toHaveLength(10);
      expect(records[0]).toMatchObject({ role: 'user', text: 'Message 1' });
      expect(records[9]).toMatchObject({ role: 'assistant', text: 'Réponse 5' });
      return reply('Bonjour.');
    }]);
    const { snapshot } = await ask(next.service, me, 'Bonjour.', { conversationId });
    expect(snapshot).toMatchObject({ status: 'completed', riskClass: 'R0' });
  });
});
