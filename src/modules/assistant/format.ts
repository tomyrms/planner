import { Temporal } from '@js-temporal/polyfill';
import type { ReminderRule, TimeValue } from '../time/index.js';
import type { RiskReason } from './risk.js';
import type { PreviewItem } from './state.js';

/** Result texts are built from receipts and previews, never taken from the model (ADR-019). */

const weekday = new Intl.DateTimeFormat('fr-CH', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' });

export function formatDate(date: string, today: string): string {
  const offset = Temporal.PlainDate.from(today).until(date).days;
  if (offset === 0) return 'aujourd’hui';
  if (offset === 1) return 'demain';
  if (offset === -1) return 'hier';
  return weekday.format(new Date(`${date}T12:00:00Z`));
}

export function formatTime(value: TimeValue | null | undefined, today: string, zone: string): string {
  if (!value) return 'sans date';
  const day = formatDate(value.date, today);
  if (!value.time) return day;
  const place = value.timeZone && value.timeZone !== zone ? ` (${value.timeZone.split('/').pop()!.replaceAll('_', ' ')})` : '';
  return `${day} ${value.time}${place}`;
}

export function formatRule(rule: ReminderRule, today: string, zone: string): string {
  switch (rule.kind) {
    case 'before_start': return rule.offsetMinutes === 0 ? 'à l’heure prévue' : `${rule.offsetMinutes} min avant`;
    case 'on_scheduled_day_at': return `le jour même à ${rule.localTime}`;
    case 'before_deadline': return rule.offsetMinutes === 0 ? 'à l’échéance' : `${rule.offsetMinutes} min avant l’échéance`;
    case 'on_deadline_day_at': return `le jour de l’échéance à ${rule.localTime}`;
    case 'absolute': return formatTime(rule.absolute, today, zone);
  }
}

type Reminder = { rule: ReminderRule; occurrenceKey: string | null } | null;
const quote = (value: unknown) => `« ${String(value)} »`;

function reminderLines(item: PreviewItem, today: string, zone: string): string[] {
  const lines: string[] = [];
  for (const [field, change] of Object.entries(item.changes)) {
    if (!field.startsWith('reminder:')) continue;
    const after = change.after as Reminder;
    if (after) lines.push(`Rappel : ${formatRule(after.rule, today, zone)}`);
    else lines.push('Rappel retiré');
  }
  return lines;
}

function occurrenceChange(item: PreviewItem): { key: string; before: any; after: any } | null {
  const entry = Object.entries(item.changes).find(([field]) => field.startsWith('occurrence:'));
  return entry ? { key: entry[0].slice('occurrence:'.length), before: entry[1].before, after: entry[1].after } : null;
}

const occurrenceWhen = (key: string, value: TimeValue | null | undefined, today: string, zone: string) =>
  value ? formatTime(value, today, zone) : formatDate(key.split('~')[0]!, today);

/** One human line per plan step, in the order of the plan. */
export function describeStep(item: PreviewItem, today: string, zone: string): string {
  const title = item.title;
  const changes = item.changes;
  const occurrence = occurrenceChange(item);
  switch (item.commandType) {
    case 'task.create': {
      const schedule = changes.schedule?.after as TimeValue | null | undefined;
      const deadline = changes.deadline?.after as TimeValue | null | undefined;
      const parts = [`Ajouté : ${title}`];
      if (schedule) parts[0] += ` — ${formatTime(schedule, today, zone)}`;
      if (deadline) parts.push(`Échéance : ${formatTime(deadline, today, zone)}`);
      return [...parts, ...reminderLines(item, today, zone)].join('\n');
    }
    case 'project.create': return `Liste créée : ${title}`;
    case 'task.patch': {
      if (item.noop) return `${title} : rien à changer.`;
      const fields = Object.keys(changes).filter((field) => field !== 'listName');
      if (fields.length === 1 && fields[0] === 'schedule') {
        return `Déplacé : ${title} — ${formatTime(changes.schedule!.before as TimeValue, today, zone)} → ${formatTime(changes.schedule!.after as TimeValue, today, zone)}`;
      }
      const details: string[] = [];
      if (changes.title) details.push(`${quote(changes.title.before)} → ${quote(changes.title.after)}`);
      if (changes.schedule) details.push(`${formatTime(changes.schedule.before as TimeValue, today, zone)} → ${formatTime(changes.schedule.after as TimeValue, today, zone)}`);
      if (changes.deadline) details.push(`échéance ${formatTime(changes.deadline.before as TimeValue, today, zone)} → ${formatTime(changes.deadline.after as TimeValue, today, zone)}`);
      if (changes.priority) details.push(`priorité ${changes.priority.after}`);
      if (changes.listName) details.push(changes.listName.after ? `liste ${changes.listName.after}` : 'Inbox');
      if (changes.notes) details.push(changes.notes.after ? 'note modifiée' : 'note effacée');
      if (changes.durationMinutes) details.push(changes.durationMinutes.after ? `durée ${changes.durationMinutes.after} min` : 'durée retirée');
      return `Modifié : ${title}${details.length ? ` — ${details.join(', ')}` : ''}`;
    }
    case 'task.complete': return item.noop ? `${title} était déjà terminée.` : `Terminé : ${title}`;
    case 'task.reopen': return item.noop ? `${title} était déjà ouverte.` : `Rouvert : ${title}`;
    case 'task.delete': return item.noop ? `${title} était déjà dans la corbeille.` : `Mis à la corbeille : ${title}`;
    case 'task.restore': return item.noop ? `${title} n’était pas dans la corbeille.` : `Restauré : ${title}`;
    case 'occurrence.complete':
    case 'occurrence.skip': {
      const verb = item.commandType === 'occurrence.complete' ? 'Terminé' : 'Ignoré';
      if (item.noop || !occurrence) return `${title} : cette occurrence était déjà close.`;
      return `${verb} : ${title} (${occurrenceWhen(occurrence.key, occurrence.after?.override, today, zone)})`;
    }
    case 'occurrence.reopen':
      return item.noop || !occurrence ? `${title} : cette occurrence était déjà ouverte.` : `Rouvert : ${title} (${formatDate(occurrence.key.split('~')[0]!, today)})`;
    case 'occurrence.reschedule': {
      if (item.noop || !occurrence) return `${title} : déjà à cet horaire.`;
      const before = occurrence.before?.override ?? null;
      const after = occurrence.after?.override ?? null;
      return `Déplacé : ${title} — ${occurrenceWhen(occurrence.key, before, today, zone)} → ${occurrenceWhen(occurrence.key, after, today, zone)}`;
    }
    case 'series.update': return item.noop ? `${title} : série inchangée.` : `Série modifiée : ${title}`;
    case 'series.end': return item.noop ? `${title} : série déjà terminée.` : `Série terminée : ${title}`;
    case 'reminder.set':
    case 'reminder.remove': {
      if (item.noop) return `${title} : rappel inchangé.`;
      const lines = reminderLines(item, today, zone);
      return `${title} — ${lines.join(', ') || 'rappel mis à jour'}`;
    }
    default: return `${item.commandType} : ${title}`;
  }
}

function summary(items: readonly PreviewItem[]): string | null {
  const effective = items.filter((item) => !item.noop);
  if (effective.length < 2) return null;
  if (effective.every((item) => item.commandType === 'task.create')) return `${effective.length} tâches ajoutées`;
  if (effective.every((item) => item.commandType === 'task.delete')) return `${effective.length} tâches mises à la corbeille`;
  return `${effective.length} changements`;
}

/** One line per step, preceded by a grouped count when several things changed, then what could not be done. */
export function resultText(items: readonly PreviewItem[], today: string, zone: string, unprepared: readonly string[] = []): string {
  const head = summary(items);
  return [
    ...(head ? [head] : []),
    ...items.map((item) => describeStep(item, today, zone)),
    ...unprepared.map((code) => `Non fait : ${unpreparedText(code)}.`),
  ].join('\n');
}

const unpreparedTexts: Record<string, string> = {
  INVALID_ARGUMENTS: 'une valeur est invalide (date, heure ou format)',
  INVALID_JSON: 'une valeur est invalide (date, heure ou format)',
  UNKNOWN_ID: 'un élément est introuvable',
  STALE_REVISION: 'la tâche a changé entre-temps',
  PLAN_INVALIDATED: 'les données ont changé entre-temps',
  OCCURRENCE_REQUIRED: 'l’occurrence concernée n’est pas précisée',
  NOT_A_SERIES: 'la tâche ne se répète pas',
  REMINDER_BASE_MISSING: 'le rappel demande une date ou une heure que la tâche n’a pas',
  RECURRING_TASK_DEADLINE_UNSUPPORTED: 'une tâche récurrente ne peut pas avoir d’échéance',
  TASK_DELETED: 'la tâche est dans la corbeille',
  PROJECT_DELETED: 'la liste est dans la corbeille',
  OCCURRENCE_NOT_IN_SERIES: 'cette occurrence n’existe pas dans la série',
  OCCURRENCE_NOT_CURRENT: 'seule l’occurrence en cours peut être modifiée',
  SERIES_ENDED: 'la série est terminée',
};

/** User-facing reason for a mutation the model could not prepare (the model saw a technical hint). */
export function unpreparedText(code: string): string {
  return unpreparedTexts[code] ?? 'une action n’a pas pu être préparée';
}

const reasonTexts: Record<RiskReason, string> = {
  series_change: 'modification de toute une série',
  several_existing_targets: 'plusieurs éléments existants',
  too_many_creations: 'plus de 10 créations',
  too_many_objects: 'plus de 10 éléments',
  interpreted_selection: 'éléments choisis par interprétation',
  notes_replaced: 'une note existante serait remplacée',
  unchosen_slot: 'créneau non choisi explicitement',
};

export function proposalText(items: readonly PreviewItem[], reasons: readonly RiskReason[], today: string, zone: string, extra: { criterion?: string | null; unprepared?: readonly string[] } = {}): string {
  const lines = items.map((item) => `• ${describeStep(item, today, zone).replaceAll('\n', ' · ')}`);
  return [
    `À confirmer (${reasons.map((reason) => reasonTexts[reason]).join(', ')}) :`,
    ...lines,
    ...(extra.criterion ? [extra.criterion] : []),
    ...(extra.unprepared ?? []).map((code) => `Non fait : ${unpreparedText(code)}.`),
    'Rien n’est modifié avant ta confirmation.',
  ].join('\n');
}

/** A model sentence describing the selection, shown with a proposal only if it claims no effect. */
export function criterionFrom(text: string | null): string | null {
  const sentence = text?.trim().replace(/\s+/g, ' ') ?? '';
  if (!sentence || claimsAnEffect(sentence)) return null;
  const match = /crit[eè]re\s*:\s*([^\n]{1,200})/i.exec(sentence);
  return match ? `Critère : ${match[1]!.replace(/\.$/, '')}` : null;
}

export const templates = {
  unsynced: 'Cette tâche a une modification pas encore envoyée depuis l’iPhone. Réessayer dans un instant ?',
  planTooLarge: 'Cette demande touche trop d’éléments en une fois (25 au maximum). Peux-tu la préciser ou la découper ?',
  invalidTwice: 'Je n’ai pas réussi à préparer cette action correctement. Peux-tu reformuler ?',
  noEffectClaim: 'Je n’ai effectué aucune modification. Peux-tu préciser ce que tu veux changer ?',
  empty: 'Je n’ai pas de réponse à donner. Peux-tu reformuler ?',
  providerFailed: 'L’assistant n’a pas pu répondre. Rien n’a été modifié.',
  timeout: 'L’assistant a mis trop de temps. Rien n’a été modifié.',
  truncated: 'La réponse de l’assistant était incomplète. Rien n’a été modifié.',
  cancelled: 'Demande annulée. Rien n’a été modifié.',
  proposalRejected: 'Proposition annulée. Rien n’a été modifié.',
  toolRounds: 'La demande a demandé trop d’étapes. Rien n’a été modifié ; peux-tu la simplifier ?',
  planRejected: 'Rien n’a été modifié : les données ont changé entre-temps. Peux-tu redemander ?',
  refusal: {
    purge: 'Je ne peux pas purger de données. La corbeille se vide automatiquement après 30 jours.',
    empty_trash: 'Je ne peux pas vider la corbeille. Tu peux le faire dans Listes › Corbeille.',
    delete_project: 'Je ne peux pas supprimer une liste. Tu peux le faire depuis la liste elle-même.',
    administration: 'Je ne gère ni les appareils ni le serveur. Cela se fait depuis la console du homelab.',
    other: 'Je ne peux pas faire cela.',
  },
} as const;

const EFFECT_CLAIM = /\b(j['’]ai|c['’]est|c['’]est bien|voilà,? j['’]ai)\s+(bien\s+)?(ajouté|créé|créée|supprimé|supprimée|déplacé|déplacée|décalé|terminé|terminée|fait|noté|notée|programmé|planifié|planifiée|modifié|modifiée|reporté|coché|cochée|mis|mise|enregistré|enregistrée)\b/i;

/** A reply without any applied change must not claim one (false success = 0). */
export function claimsAnEffect(text: string): boolean {
  return EFFECT_CLAIM.test(text);
}
