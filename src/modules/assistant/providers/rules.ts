import { Temporal } from '@js-temporal/polyfill';
import type { ProviderMessage, ProviderRequest, ProviderResponse, ReasoningProvider, ToolCall } from '../provider.js';

/**
 * Deterministic stand-in for development and smoke tests when no provider key is configured.
 * It understands only a few French patterns (the five reference requests of 04_AI_Orchestration.md §12)
 * and goes through the same tools, validation and risk policy as a real model. Never used in production.
 */

let sequence = 0;
const call = (name: string, args: unknown): ToolCall => ({ id: `rules_${++sequence}`, name, arguments: JSON.stringify(args) });
const tools = (...calls: ToolCall[]): ProviderResponse => ({ text: null, toolCalls: calls, finish: 'tool_calls', usage: { inputTokens: 0, outputTokens: 0 } });
const say = (text: string): ProviderResponse => ({ text, toolCalls: [], finish: 'stop', usage: { inputTokens: 0, outputTokens: 0 } });

const normalize = (text: string) => text.normalize('NFKD').replace(/\p{M}+/gu, '').toLowerCase().replace(/[’]/g, "'");
const capitalize = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);
const addDays = (date: string, days: number) => Temporal.PlainDate.from(date).add({ days }).toString();
const hour = (value: string, minutes?: string) => `${value.padStart(2, '0')}:${(minutes ?? '00').padStart(2, '0')}`;

type ToolResult = { status: string; data?: any; code?: string };

export class RuleBasedProvider implements ReasoningProvider {
  readonly name = 'rules';
  readonly model = 'rules-v1';

  async respond(request: ProviderRequest): Promise<ProviderResponse> {
    const today = /Date du tour : (\d{4}-\d{2}-\d{2})/.exec(request.system)?.[1];
    if (!today) return say('Je n’ai pas compris.');
    const messages = request.messages;
    const lastUser = messages.map((message) => message.role).lastIndexOf('user');
    const original = (messages[lastUser] as Extract<ProviderMessage, { role: 'user' }>).content.normalize('NFC');
    const text = normalize(original);
    // Accents are removed one character for one: indices in text match the original when lengths agree.
    const source = (start: number, end: number) => (text.length === original.length ? original : text).slice(start, end);
    const results = messages.slice(lastUser + 1).filter((message) => message.role === 'tool')
      .map((message) => JSON.parse((message as Extract<ProviderMessage, { role: 'tool' }>).content) as ToolResult);
    const last = results.at(-1);
    const day = /\bdemain\b/.test(text) ? addDays(today, 1) : today;

    if (/\b(vide|vider)\b.*\bcorbeille\b/.test(text)) return results.length ? say('') : tools(call('refuse_request', { reason: 'empty_trash' }));
    if (/\bsupprime(r)?\b.*\bliste\b/.test(text)) return results.length ? say('') : tools(call('refuse_request', { reason: 'delete_project' }));

    const reminder = /rappelle-moi d(?:e |')(.+?)(?: vers| a)? (\d{1,2})h(\d{2})?/.exec(text);
    if (reminder) {
      if (results.length) return say('');
      const start = reminder.index + reminder[0].indexOf(reminder[1]!);
      const title = capitalize(source(start, start + reminder[1]!.length).replace(/\s*\bdemain\b\s*/i, ' ').trim());
      return tools(call('create_task', {
        title, schedule: { date: day, time: hour(reminder[2]!, reminder[3]) }, reminder: { kind: 'before_start', offsetMinutes: 0 },
      }));
    }

    if (/qu'est-ce qu'il me reste|que me reste-t-il/.test(text)) {
      if (!last) return tools(call('list_day', { date: day }));
      if (last.status !== 'ok') return say('Je n’ai pas pu lire ton programme ; je ne peux pas conclure.');
      const program = last.data;
      const items = [
        ...program.commitments.map((item: any) => `${item.time} ${item.title}`),
        ...program.todo.map((item: any) => item.title),
      ];
      const late = program.toReschedule?.length ? ` À replanifier : ${program.toReschedule.map((item: any) => item.title).join(', ')}.` : '';
      return say(items.length ? `Il te reste : ${items.join(' ; ')}.${late}` : `Rien de prévu pour ${day === today ? 'aujourd’hui' : 'ce jour'}.${late}`);
    }

    const finished = /j'ai (?:fini|termine|sorti) (?:le |la |les |l')?(.+?)\.?$/.exec(text);
    if (finished) {
      if (results.length === 0) return tools(call('search_tasks', { query: finished[1]!, status: 'all', limit: 5 }));
      const found = results[0]!;
      if (found.status !== 'ok') return say('Je n’ai pas pu chercher cette tâche.');
      const matches = found.data.results as Array<{ taskId: string; title: string; recurring: boolean; revision: number }>;
      if (matches.length === 0) return say('Je ne vois pas cette tâche côté serveur.');
      if (matches.length > 1) {
        return tools(call('ask_clarification', { question: `Laquelle : ${matches.map((match) => match.title).join(' ou ')} ?`, options: matches.map((match) => match.title).slice(0, 5) }));
      }
      const target = matches[0]!;
      if (results.length === 1) {
        return target.recurring ? tools(call('get_task', { taskId: target.taskId })) : tools(call('complete_task', { taskId: target.taskId }));
      }
      if (results.length === 2 && target.recurring) {
        const detail = results[1]!.data;
        return tools(call('complete_task', { taskId: target.taskId, occurrenceKey: detail.currentOccurrenceKey ?? today }));
      }
      return say('');
    }

    if (/decale .*non urgentes? de ce soir a demain/.test(text)) {
      if (!last) return tools(call('list_day', { date: today }));
      if (results.length > 1) return say('Critère : ce soir après 18:00, priorité non haute, sans échéance aujourd’hui.');
      if (last.status !== 'ok') return say('Je n’ai pas pu lire ta soirée.');
      const evening = (last.data.commitments as any[]).filter((item) => item.time >= '18:00' && item.priority !== 'high' && !item.hasDeadlineToday && item.occurrenceKey === null);
      if (evening.length === 0) return say('Rien à décaler ce soir.');
      return tools(...evening.map((item) => call('update_task', {
        taskId: item.taskId, expectedRevision: item.revision, set: { schedule: { date: addDays(today, 1), time: item.time } },
      })));
    }

    if (/trouve-moi un (bon )?moment/.test(text)) {
      const references = messages.find((message) => message.role === 'user' && message.content.startsWith('[Données du serveur'));
      const referenced = references ? JSON.parse((references as { content: string }).content.split('\n')[1]!) as Array<{ taskId: string }> : [];
      if (referenced.length !== 1) return tools(call('ask_clarification', { question: 'De quelle tâche parles-tu ?' }));
      const until = /jusqu'a (\d{1,2})h(\d{2})?/.exec(text);
      if (!last) return tools(call('get_task', { taskId: referenced[0]!.taskId }));
      if (results.length === 1) {
        return tools(call('find_free_slots', {
          date: day, durationMinutes: last.data?.durationMinutes ?? 60,
          ...(until ? { extraBusy: [{ start: '00:00', end: hour(until[1]!, until[2]), label: 'cours' }] } : {}),
        }));
      }
      if (last.status !== 'ok' || last.data.slots.length === 0) return say('Je ne trouve pas de créneau libre ce jour-là.');
      const slots = (last.data.slots as Array<{ start: string; end: string }>).slice(0, 2).map((slot) => `${slot.start}–${slot.end}`);
      return say(`Je te propose ${slots.join(' ou ')} (${last.data.assumptions.join(' ')}). Lequel veux-tu ?`);
    }

    return say('Je n’ai pas compris. Peux-tu reformuler ?');
  }
}
