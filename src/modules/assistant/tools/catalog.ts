import { z } from 'zod';
import {
  civilDateSchema, localTimeSchema, occurrenceKeySchema, reminderRuleSchema, timeZoneSchema, weekdaySchema,
} from '../../time/index.js';
import type { ToolSpec } from '../provider.js';

/** Catalogue canonique v1 (04_AI_Orchestration.md §4), plus two control tools that end the loop. */

const id = z.uuid();
const title = z.string().trim().min(1).max(500);
const priority = z.enum(['none', 'low', 'medium', 'high']);
const revision = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);
/** The model may omit the zone; the server fills it with the turn's zone when a time is given. */
const timeInput = z.strictObject({
  date: civilDateSchema,
  time: localTimeSchema.nullable().optional(),
  timeZone: timeZoneSchema.nullable().optional(),
});
const fixedRecurrenceInput = z.strictObject({
  mode: z.literal('fixed'),
  freq: z.enum(['daily', 'weekly', 'monthly']),
  interval: z.number().int().min(1).max(365).default(1),
  byWeekday: z.array(weekdaySchema).min(1).max(7).optional(),
  byMonthDay: z.number().int().min(1).max(31).optional(),
  lastDayOfMonth: z.literal(true).optional(),
  until: civilDateSchema.optional(),
  count: z.number().int().min(1).max(3_652_059).optional(),
});
const afterCompletionInput = z.strictObject({
  mode: z.literal('after_completion'),
  unit: z.enum(['day', 'week', 'month']),
  interval: z.number().int().min(1).max(365),
});
export const recurrenceInput = z.discriminatedUnion('mode', [fixedRecurrenceInput, afterCompletionInput]);
const busyInterval = z.strictObject({ start: localTimeSchema, end: localTimeSchema, label: z.string().max(100).optional() });

export const toolSchemas = {
  search_tasks: z.strictObject({
    query: z.string().trim().min(1).max(100),
    status: z.enum(['active', 'completed', 'all']).default('active'),
    limit: z.number().int().min(1).max(20).default(10),
  }),
  get_task: z.strictObject({ taskId: id }),
  list_day: z.strictObject({ date: civilDateSchema }),
  list_upcoming: z.strictObject({ fromDate: civilDateSchema, toDate: civilDateSchema }),
  list_projects: z.strictObject({}),
  find_free_slots: z.strictObject({
    date: civilDateSchema,
    durationMinutes: z.number().int().min(5).max(480),
    notBefore: localTimeSchema.optional(),
    notAfter: localTimeSchema.optional(),
    extraBusy: z.array(busyInterval).max(10).optional(),
  }),
  create_task: z.strictObject({
    title,
    notes: z.string().max(10_000).optional(),
    projectId: id.optional(),
    priority: priority.optional(),
    schedule: timeInput.optional(),
    deadline: timeInput.optional(),
    durationMinutes: z.number().int().min(1).max(1440).optional(),
    reminder: reminderRuleSchema.optional(),
    recurrence: recurrenceInput.optional(),
  }),
  update_task: z.strictObject({
    taskId: id,
    expectedRevision: revision,
    set: z.strictObject({
      title: title.optional(),
      notes: z.string().max(10_000).nullable().optional(),
      priority: priority.optional(),
      projectId: id.nullable().optional(),
      schedule: timeInput.nullable().optional(),
      deadline: timeInput.nullable().optional(),
      durationMinutes: z.number().int().min(1).max(1440).nullable().optional(),
    }).refine((value) => Object.keys(value).length > 0, 'set must change at least one field'),
  }),
  complete_task: z.strictObject({ taskId: id, occurrenceKey: occurrenceKeySchema.optional() }),
  reopen_task: z.strictObject({ taskId: id, occurrenceKey: occurrenceKeySchema.optional() }),
  delete_task: z.strictObject({ taskId: id }),
  restore_task: z.strictObject({ taskId: id }),
  skip_occurrence: z.strictObject({ taskId: id, occurrenceKey: occurrenceKeySchema }),
  reschedule_occurrence: z.strictObject({ taskId: id, occurrenceKey: occurrenceKeySchema, schedule: timeInput }),
  update_series: z.strictObject({
    taskId: id,
    expectedRevision: revision,
    recurrence: recurrenceInput.optional(),
    set: z.strictObject({
      title: title.optional(),
      notes: z.string().max(10_000).nullable().optional(),
      priority: priority.optional(),
      projectId: id.nullable().optional(),
      durationMinutes: z.number().int().min(1).max(1440).nullable().optional(),
      schedule: timeInput.optional(),
    }).optional(),
  }).refine((value) => value.recurrence !== undefined || value.set !== undefined, 'recurrence or set is required'),
  end_series: z.strictObject({ taskId: id, expectedRevision: revision }),
  set_reminder: z.strictObject({ taskId: id, occurrenceKey: occurrenceKeySchema.optional(), reminder: reminderRuleSchema }),
  remove_reminder: z.strictObject({ taskId: id, reminderId: id }),
  create_project: z.strictObject({ name: z.string().trim().min(1).max(200) }),
  ask_clarification: z.strictObject({
    question: z.string().trim().min(1).max(500),
    options: z.array(z.string().trim().min(1).max(100)).max(5).optional(),
  }),
  refuse_request: z.strictObject({ reason: z.enum(['purge', 'empty_trash', 'delete_project', 'administration', 'other']) }),
} as const;

export type ToolName = keyof typeof toolSchemas;
export type ToolArgs<T extends ToolName> = z.infer<(typeof toolSchemas)[T]>;

export const READ_TOOLS = new Set<ToolName>(['search_tasks', 'get_task', 'list_day', 'list_upcoming', 'list_projects', 'find_free_slots']);
export const CONTROL_TOOLS = new Set<ToolName>(['ask_clarification', 'refuse_request']);

const descriptions: Record<ToolName, string> = {
  search_tasks: 'Cherche des tâches par texte (titre, note, liste). Renvoie id, titre, planification et revision.',
  get_task: 'Détail d’une tâche : rappels, occurrences récentes, revision.',
  list_day: 'Programme d’une date civile : engagements horaires, à faire, occurrences dues, échéances, à replanifier, événements du calendrier partagé.',
  list_upcoming: 'Programme jour par jour entre deux dates (14 jours au plus).',
  list_projects: 'Listes de l’utilisateur.',
  find_free_slots: 'Jusqu’à 3 créneaux libres calculés pour une durée donnée, avec hypothèses. extraBusy : contraintes dites dans le message (HH:mm).',
  create_task: 'Prépare la création d’une tâche (appliquée ou proposée par le serveur à la fin du tour). Heure sans fuseau = fuseau du tour.',
  update_task: 'Prépare la modification d’une tâche. expectedRevision vient d’une lecture de ce tour. Absent = inchangé, null = effacer.',
  complete_task: 'Prépare la complétion. occurrenceKey obligatoire pour une tâche récurrente (occurrence du jour).',
  reopen_task: 'Prépare la réouverture d’une tâche ou d’une occurrence.',
  delete_task: 'Prépare la mise à la corbeille d’une tâche.',
  restore_task: 'Prépare la restauration d’une tâche de la corbeille.',
  skip_occurrence: 'Prépare le saut d’une occurrence.',
  reschedule_occurrence: 'Prépare le déplacement d’une occurrence ; sa clé ne change pas.',
  update_series: 'Prépare la modification de toute la série (toujours soumise à confirmation).',
  end_series: 'Prépare la fin d’une série (toujours soumise à confirmation).',
  set_reminder: 'Prépare le réglage du rappel d’une tâche (remplace le rappel existant de même portée).',
  remove_reminder: 'Prépare la suppression d’un rappel.',
  create_project: 'Prépare la création d’une liste.',
  ask_clarification: 'Pose une question à l’utilisateur quand la cible, l’heure ou la portée est incertaine (options : réponses touchables, par exemple les titres candidats avec leur date). Termine le tour sans effet.',
  refuse_request: 'Refuse une demande hors catalogue (purge, vider la corbeille, supprimer une liste, administration). Termine le tour sans effet.',
};

/** JSON Schema projection sent to the provider; the server always revalidates with the full Zod schema. */
export const toolSpecs: ToolSpec[] = (Object.keys(toolSchemas) as ToolName[]).map((name) => {
  const { $schema: _schema, ...parameters } = z.toJSONSchema(toolSchemas[name], { target: 'draft-7', io: 'input' }) as Record<string, unknown>;
  return { name, description: descriptions[name], parameters };
});

export function isToolName(name: string): name is ToolName {
  return Object.hasOwn(toolSchemas, name);
}
