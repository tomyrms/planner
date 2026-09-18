import { describe, expect, it } from 'vitest';
import { describeStep } from '../../src/modules/assistant/format.js';
import { PROMPT_VERSION, systemPrompt } from '../../src/modules/assistant/prompt.js';
import type { PreviewItem, TurnInfo } from '../../src/modules/assistant/state.js';

const turn: TurnInfo = {
  id: 'turn', userId: 'user', deviceId: null, conversationId: 'conversation',
  referenceInstant: '2026-09-18T10:00:00Z', timeZone: 'Europe/Zurich',
  localDate: '2026-09-18', localTime: '12:00', unsynced: new Set(), calendar: null,
};
const step = (commandType: string, changes: PreviewItem['changes'], title = 'Préparer le cours'): PreviewItem => ({
  index: 0, commandType, aggregateType: 'task', aggregateId: 'task', title, changes, noop: false,
});
const schedule = { date: '2026-09-19', time: '17:00', timeZone: 'Europe/Zurich' };

describe('assistant typography', () => {
  it('versions the style instruction without weakening tool or receipt requirements', () => {
    const prompt = systemPrompt(turn);
    expect(PROMPT_VERSION).toBe('assistant-v8');
    expect(prompt).toContain('n’utilise pas de tirets cadratins (U+2014)');
    expect(prompt).toContain('Ne modifie pas la ponctuation des titres, notes ou citations');
    expect(prompt).toContain('une réponse texte seule ne produit aucun effet');
    expect(prompt).toContain('le serveur construit le résultat après la transaction');
  });

  it('uses a quiet separator in receipts and previews', () => {
    const created = describeStep(step('task.create', { schedule: { before: null, after: schedule } }), turn.localDate, turn.timeZone);
    const moved = describeStep(step('task.patch', { schedule: { before: null, after: schedule } }), turn.localDate, turn.timeZone);
    expect(created).toBe('Ajouté : Préparer le cours · demain 17:00');
    expect(moved).toBe('Déplacé : Préparer le cours · sans date → demain 17:00');
    expect(created + moved).not.toContain('\u2014');
  });

  it('preserves punctuation deliberately present in user-owned titles', () => {
    const title = 'Notes \u2014 chapitre 2';
    const result = describeStep(step('task.create', { schedule: { before: null, after: schedule } }, title), turn.localDate, turn.timeZone);
    expect(result).toBe(`Ajouté : ${title} · demain 17:00`);
  });
});
