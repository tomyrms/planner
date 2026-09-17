import type pg from 'pg';
import { v5 as uuidv5 } from 'uuid';
import { executePlan, type CommandActor, type Precondition, type RawCommand, type RejectionCode } from '../sync/index.js';
import type { TimeValue } from '../time/index.js';
import { assistantAggregateType, diffSnapshots, snapshotAggregate, type Snapshot } from './snapshot.js';
import type { PreviewItem, StagedCommand, TurnState } from './state.js';
import { recurrenceInput, type ToolArgs, type ToolName } from './tools/catalog.js';
import { ToolFailure } from './tools/read.js';
import type { z } from 'zod';

/** Frozen namespace for identifiers derived from a turn, a proposal or an Undo request. */
export const ASSISTANT_NAMESPACE = 'c0a39c7e-5b36-4f7e-9d7e-2a8f9a4c1b6d';
export const MAX_PLAN_COMMANDS = 25;

export const derivedId = (seed: string, kind: string, index: number): string => uuidv5(`${seed.toLowerCase()}:${kind}:${index}`, ASSISTANT_NAMESPACE);

/** Control signals that end the model loop with a server-written answer. */
export class UnsyncedTarget extends Error {}
export class PlanTooLarge extends Error {}

const rejectionHints: Partial<Record<RejectionCode, string>> = {
  TASK_DELETED: 'La tâche est dans la corbeille : utiliser restore_task d’abord.',
  PROJECT_DELETED: 'La liste est dans la corbeille.',
  REVISION_MISMATCH: 'La tâche a changé depuis la lecture : relire avec get_task.',
  REMINDER_BASE_MISSING: 'Ce rappel exige une heure ou une date que la tâche n’a pas.',
  RECURRING_TASK_DEADLINE_UNSUPPORTED: 'Une tâche récurrente ne peut pas avoir d’échéance.',
  OCCURRENCE_NOT_IN_SERIES: 'Cette clé d’occurrence n’appartient pas à la série.',
  OCCURRENCE_NOT_CURRENT: 'Seule l’occurrence ouverte courante peut être modifiée (voir currentOccurrenceKey).',
  SUCCESSOR_ALREADY_CHANGED: 'L’occurrence suivante a déjà changé : réouverture impossible.',
  SERIES_COMMAND_REQUIRED: 'Pour une tâche récurrente, utiliser complete_task avec occurrenceKey, reschedule_occurrence ou update_series.',
  NOT_A_SERIES: 'Cette tâche ne se répète pas.',
  SERIES_ENDED: 'Cette série est terminée.',
  FORBIDDEN_REFERENCE: 'Référence inconnue (liste ou rappel).',
  VALIDATION_FAILED: 'Arguments refusés par les règles du domaine.',
};

function timeValue(state: TurnState, input: { date: string; time?: string | null | undefined; timeZone?: string | null | undefined }): TimeValue {
  if (input.time == null) return { date: input.date, time: null, timeZone: null };
  return { date: input.date, time: input.time, timeZone: input.timeZone ?? state.turn.timeZone };
}

const withV = (rule: z.infer<typeof recurrenceInput>) => {
  const { mode, ...rest } = rule;
  return { v: 1, mode, ...rest };
};

function requireTask(state: TurnState, taskId: string) {
  const id = taskId.toLowerCase();
  const observation = state.tasks.get(id);
  if (!observation) throw new ToolFailure('UNKNOWN_ID', 'Identifiant de tâche inconnu : le lire d’abord (search_tasks, list_day, get_task).');
  if (state.turn.unsynced.has(id)) throw new UnsyncedTarget();
  return { id, observation };
}

function requireProject(state: TurnState, projectId: string | null | undefined): string | null | undefined {
  if (projectId == null) return projectId;
  const id = projectId.toLowerCase();
  if (!state.projects.has(id)) throw new ToolFailure('UNKNOWN_ID', 'Identifiant de liste inconnu : utiliser list_projects.');
  return id;
}

function requireTag(state: TurnState, tagId: string): string {
  const id = tagId.toLowerCase();
  if (!state.tags.has(id)) throw new ToolFailure('UNKNOWN_ID', 'Tag inconnu : lire list_tags ou get_task dans ce tour.');
  if (state.turn.unsynced.has(id)) throw new UnsyncedTarget();
  return id;
}

function requireSubtask(state: TurnState, taskId: string, subtaskId: string): string {
  const id = subtaskId.toLowerCase();
  if (state.subtasks.get(id) !== taskId) throw new ToolFailure('UNKNOWN_ID', 'Sous-tâche inconnue pour cette tâche : lire get_task.');
  return id;
}

function checkExpectedRevision(observation: { revision: number }, expected: number): void {
  if (observation.revision !== expected) {
    throw new ToolFailure('STALE_REVISION', `expectedRevision doit être la revision lue dans ce tour (${observation.revision}).`);
  }
}

interface Draft { type: string; aggregate: { type: 'task' | 'project'; id: string }; payload?: Record<string, unknown>; created?: boolean; automaticTagIds?: string[] }

async function draftsFor(pool: pg.Pool, state: TurnState, name: ToolName, rawArgs: unknown): Promise<Draft[]> {
  const occurrenceCommand = (type: string, id: string, key: string, extra: Record<string, unknown> = {}): Draft =>
    ({ type, aggregate: { type: 'task', id }, payload: { occurrenceKey: key, ...extra } });
  switch (name) {
    case 'create_task': {
      const args = rawArgs as ToolArgs<'create_task'>;
      const seed = state.turn.id;
      const id = derivedId(seed, 'task', state.createdTasks);
      const projectId = requireProject(state, args.projectId);
      if (state.turn.autoTags === true && !state.tagsCatalogueRead) {
        throw new ToolFailure('TAG_CATALOG_REQUIRED', 'autoTags actif : lire list_tags avant de créer la tâche, même si aucun tag ne paraît pertinent.');
      }
      const explicit = (args.tagIds ?? []).map((tagId) => requireTag(state, tagId));
      const automatic = (args.automaticTagIds ?? []).map((tagId) => requireTag(state, tagId));
      if (automatic.length > 0 && state.turn.autoTags !== true) throw new ToolFailure('AUTO_TAGS_DISABLED', 'Le classement automatique est désactivé. Ne pas déplacer ces IDs vers tagIds : ce champ exige une demande explicite.');
      if (automatic.some((tagId) => !state.catalogueTagIds.has(tagId))) throw new ToolFailure('TAG_CATALOG_REQUIRED', 'Les tags automatiques doivent venir de list_tags dans ce tour.');
      const tagIds = [...new Set([...explicit, ...automatic])];
      if (tagIds.length > 10) throw new ToolFailure('INVALID_ARGUMENTS', '10 tags au maximum par tâche, explicites et automatiques réunis.');
      return [{
        type: 'task.create', aggregate: { type: 'task', id }, created: true,
        automaticTagIds: automatic.filter((tagId) => !explicit.includes(tagId)),
        payload: {
          title: args.title,
          ...(args.notes === undefined ? {} : { notes: args.notes }),
          ...(args.priority === undefined ? {} : { priority: args.priority }),
          ...(projectId ? { projectId } : {}),
          ...(args.schedule ? { schedule: timeValue(state, args.schedule) } : {}),
          ...(args.deadline ? { deadline: timeValue(state, args.deadline) } : {}),
          ...(args.durationMinutes === undefined ? {} : { durationMinutes: args.durationMinutes }),
          ...(args.recurrence ? { recurrence: withV(args.recurrence) } : {}),
          ...(args.reminder ? { reminders: [{ id: derivedId(seed, 'reminder', state.createdTasks), rule: args.reminder }] } : {}),
          ...(tagIds.length ? { tagIds } : {}),
          ...(args.subtasks ? { subtasks: args.subtasks.map((item, index) => ({ ...item, id: derivedId(seed, `task-${state.createdTasks}-subtask`, index) })) } : {}),
        },
      }];
    }
    case 'create_project': {
      const args = rawArgs as ToolArgs<'create_project'>;
      return [{ type: 'project.create', aggregate: { type: 'project', id: derivedId(state.turn.id, 'project', state.createdProjects) }, created: true, payload: { name: args.name } }];
    }
    case 'add_subtask': {
      const args = rawArgs as ToolArgs<'add_subtask'>;
      const { id } = requireTask(state, args.taskId);
      return [{ type: 'task.subtask.add', aggregate: { type: 'task', id }, payload: {
        subtask: { ...args.subtask, id: derivedId(state.turn.id, 'subtask', state.plan.length) },
      } }];
    }
    case 'update_subtask': {
      const args = rawArgs as ToolArgs<'update_subtask'>;
      const { id } = requireTask(state, args.taskId);
      return [{ type: 'task.subtask.patch', aggregate: { type: 'task', id }, payload: { subtaskId: requireSubtask(state, id, args.subtaskId), set: args.set } }];
    }
    case 'remove_subtask': {
      const args = rawArgs as ToolArgs<'remove_subtask'>;
      const { id } = requireTask(state, args.taskId);
      return [{ type: 'task.subtask.remove', aggregate: { type: 'task', id }, payload: { subtaskId: requireSubtask(state, id, args.subtaskId) } }];
    }
    case 'add_task_tag':
    case 'remove_task_tag': {
      const args = rawArgs as ToolArgs<'add_task_tag'>;
      const { id } = requireTask(state, args.taskId);
      return [{ type: name === 'add_task_tag' ? 'task.tag.add' : 'task.tag.remove', aggregate: { type: 'task', id }, payload: { tagId: requireTag(state, args.tagId) } }];
    }
    case 'update_task': {
      const args = rawArgs as ToolArgs<'update_task'>;
      const { id, observation } = requireTask(state, args.taskId);
      checkExpectedRevision(observation, args.expectedRevision);
      const set: Record<string, unknown> = { ...args.set };
      if (args.set.projectId !== undefined) set.projectId = requireProject(state, args.set.projectId);
      if (args.set.schedule !== undefined) set.schedule = args.set.schedule === null ? null : timeValue(state, args.set.schedule);
      if (args.set.deadline !== undefined) set.deadline = args.set.deadline === null ? null : timeValue(state, args.set.deadline);
      return [{ type: 'task.patch', aggregate: { type: 'task', id }, payload: { set } }];
    }
    case 'complete_task':
    case 'reopen_task': {
      const args = rawArgs as ToolArgs<'complete_task'>;
      const { id, observation } = requireTask(state, args.taskId);
      const verb = name === 'complete_task' ? 'complete' : 'reopen';
      if (observation.recurring) {
        if (!args.occurrenceKey) {
          throw new ToolFailure('OCCURRENCE_REQUIRED', `occurrenceKey obligatoire pour une tâche récurrente (série fixe : ${state.turn.localDate} ; après complétion : currentOccurrenceKey de get_task).`);
        }
        return [occurrenceCommand(`occurrence.${verb}`, id, args.occurrenceKey, verb === 'complete' ? { actionLocalDate: state.turn.localDate } : {})];
      }
      if (args.occurrenceKey) throw new ToolFailure('NOT_A_SERIES', 'Cette tâche ne se répète pas : ne pas donner occurrenceKey.');
      return [{ type: `task.${verb}`, aggregate: { type: 'task', id } }];
    }
    case 'delete_task':
    case 'restore_task': {
      const { id } = requireTask(state, (rawArgs as ToolArgs<'delete_task'>).taskId);
      return [{ type: name === 'delete_task' ? 'task.delete' : 'task.restore', aggregate: { type: 'task', id } }];
    }
    case 'skip_occurrence': {
      const args = rawArgs as ToolArgs<'skip_occurrence'>;
      const { id } = requireTask(state, args.taskId);
      return [occurrenceCommand('occurrence.skip', id, args.occurrenceKey, { actionLocalDate: state.turn.localDate })];
    }
    case 'reschedule_occurrence': {
      const args = rawArgs as ToolArgs<'reschedule_occurrence'>;
      const { id } = requireTask(state, args.taskId);
      return [occurrenceCommand('occurrence.reschedule', id, args.occurrenceKey, { schedule: timeValue(state, args.schedule) })];
    }
    case 'update_series': {
      const args = rawArgs as ToolArgs<'update_series'>;
      const { id, observation } = requireTask(state, args.taskId);
      checkExpectedRevision(observation, args.expectedRevision);
      const payload: Record<string, unknown> = {};
      if (args.recurrence) payload.recurrence = withV(args.recurrence);
      if (args.set) {
        const set: Record<string, unknown> = { ...args.set };
        if (args.set.projectId !== undefined) set.projectId = requireProject(state, args.set.projectId);
        if (args.set.schedule) set.schedule = timeValue(state, args.set.schedule);
        payload.set = set;
      }
      return [{ type: 'series.update', aggregate: { type: 'task', id }, payload }];
    }
    case 'end_series': {
      const args = rawArgs as ToolArgs<'end_series'>;
      const { id, observation } = requireTask(state, args.taskId);
      checkExpectedRevision(observation, args.expectedRevision);
      return [{ type: 'series.end', aggregate: { type: 'task', id } }];
    }
    case 'set_reminder': {
      const args = rawArgs as ToolArgs<'set_reminder'>;
      const { id } = requireTask(state, args.taskId);
      const scope = args.occurrenceKey ?? null;
      // The V1 editor shows one reminder per scope: an existing one is replaced, not duplicated.
      const planned = state.plan.flatMap((staged) => staged.command.aggregate.id === id && staged.command.type === 'task.create'
        ? ((staged.command.payload?.reminders as Array<{ id: string; occurrenceKey?: string | null }> | undefined) ?? [])
        : []).find((reminder) => (reminder.occurrenceKey ?? null) === scope);
      const existing = planned ? null : (await pool.query<{ id: string }>(`SELECT id FROM reminders
        WHERE task_id = $1 AND user_id = $2 AND deleted_at IS NULL AND occurrence_key IS NOT DISTINCT FROM $3
        ORDER BY created_at, id LIMIT 1`, [id, state.turn.userId, scope])).rows[0];
      const reminderId = planned?.id ?? existing?.id ?? derivedId(state.turn.id, 'reminder', 100 + state.plan.length);
      state.reminders.set(reminderId, id);
      return [{ type: 'reminder.set', aggregate: { type: 'task', id }, payload: { id: reminderId, rule: args.reminder, ...(scope ? { occurrenceKey: scope } : {}) } }];
    }
    case 'remove_reminder': {
      const args = rawArgs as ToolArgs<'remove_reminder'>;
      const { id } = requireTask(state, args.taskId);
      const reminderId = args.reminderId.toLowerCase();
      if (state.reminders.get(reminderId) !== id) throw new ToolFailure('UNKNOWN_ID', 'Rappel inconnu pour cette tâche : utiliser get_task.');
      return [{ type: 'reminder.remove', aggregate: { type: 'task', id }, payload: { id: reminderId } }];
    }
    default:
      throw new ToolFailure('NOT_A_MUTATION', `${name} n’est pas un outil de modification.`);
  }
}

/** Precondition of a command: the revision read in this turn, then a chain inside the plan. */
function preconditionFor(state: TurnState, draft: Draft, previous: readonly RawCommand[]): Precondition | undefined {
  if (draft.created) return undefined;
  const earlier = [...previous].reverse().find((command) => command.aggregate.id === draft.aggregate.id);
  if (earlier) return { kind: 'afterCommand', clientCommandId: earlier.clientCommandId };
  if (draft.aggregate.type === 'project') return undefined;
  return { kind: 'revision', revision: state.tasks.get(draft.aggregate.id)!.revision };
}

export function actorFor(state: TurnState): CommandActor {
  return { userId: state.turn.userId, deviceId: state.turn.deviceId, origin: 'assistant' };
}

export interface PlanPreview { steps: PreviewItem[]; rejected: { index: number; code: RejectionCode; message: string } | null }

/** Runs the whole plan in a rolled-back transaction: the real handlers validate it and describe its effect. */
export async function previewPlan(pool: pg.Pool, actor: CommandActor, commands: readonly RawCommand[], clock: () => Date): Promise<PlanPreview> {
  const steps: PreviewItem[] = [];
  const outcome = await executePlan(pool, actor, commands, {
    clock,
    dryRun: true,
    hooks: {
      before: (client, command, index) => {
        if (index === 0) steps.length = 0;
        return snapshotAggregate(client, actor.userId, command.aggregate.type, command.aggregate.id.toLowerCase());
      },
      after: async (client, step, index, before) => {
        const after = await snapshotAggregate(client, actor.userId, step.command.aggregate.type, step.command.aggregate.id.toLowerCase());
        const result = step.result.outcome === 'duplicate' ? step.result.original : step.result;
        steps.push({
          index,
          commandType: step.command.type,
          aggregateType: assistantAggregateType(step.command.aggregate.type),
          aggregateId: step.command.aggregate.id.toLowerCase(),
          title: after?.title ?? (before as Snapshot)?.title ?? '',
          changes: diffSnapshots(before as Snapshot, after),
          noop: (result as { noop?: unknown }).noop === true,
        });
      },
    },
  });
  if (outcome.status === 'rejected') {
    return { steps, rejected: { index: outcome.index, code: outcome.rejection.code, message: outcome.rejection.message } };
  }
  return { steps, rejected: null };
}

/** Adds a mutation to the turn's plan after a full dry run; nothing is written. */
export async function stageMutation(pool: pg.Pool, state: TurnState, name: ToolName, args: unknown, clock: () => Date) {
  const drafts = await draftsFor(pool, state, name, args);
  if (state.plan.length + drafts.length > MAX_PLAN_COMMANDS) throw new PlanTooLarge();
  const previous = state.plan.map((staged) => staged.command);
  const added: RawCommand[] = [];
  for (const draft of drafts) {
    const precondition = preconditionFor(state, draft, [...previous, ...added]);
    added.push({
      clientCommandId: derivedId(state.turn.id, 'command', previous.length + added.length),
      type: draft.type,
      payloadVersion: 1,
      aggregate: draft.aggregate,
      ...(precondition ? { precondition } : {}),
      clientRecordedAt: state.turn.referenceInstant,
      ...(draft.payload ? { payload: draft.payload } : {}),
    });
  }
  const preview = await previewPlan(pool, actorFor(state), [...previous, ...added], clock);
  if (preview.rejected) {
    if (preview.rejected.index < previous.length) {
      throw new ToolFailure('PLAN_INVALIDATED', 'Les données ont changé pendant le tour : les modifications préparées ne sont plus valables.');
    }
    throw new ToolFailure(preview.rejected.code, rejectionHints[preview.rejected.code] ?? preview.rejected.message);
  }
  for (const [offset, draft] of drafts.entries()) {
    const command = added[offset]!;
    const createdInTurn = state.plan.some((item) => item.command.type === 'task.create' && item.command.aggregate.id === draft.aggregate.id);
    state.plan.push({ command, tool: name, existing: !draft.created && !createdInTurn, preview: null,
      ...(draft.automaticTagIds?.length ? { automaticTagIds: draft.automaticTagIds } : {}) });
    for (const item of (draft.payload?.subtasks as Array<{ id: string }> | undefined) ?? []) state.subtasks.set(item.id, draft.aggregate.id);
    if (draft.type === 'task.subtask.add') state.subtasks.set((draft.payload!.subtask as { id: string }).id, draft.aggregate.id);
    if (draft.created && draft.aggregate.type === 'task') {
      state.observeTask(draft.aggregate.id, { revision: 1, title: String(draft.payload?.title ?? ''), recurring: draft.payload?.recurrence !== undefined }, 'explicit');
      state.createdTasks++;
    }
    if (draft.created && draft.aggregate.type === 'project') {
      state.projects.add(draft.aggregate.id);
      state.createdProjects++;
    }
  }
  for (const [index, staged] of state.plan.entries()) {
    staged.preview = preview.steps[index] ?? null;
    if (staged.preview && staged.automaticTagIds) staged.preview.automaticTagIds = staged.automaticTagIds;
  }
  for (const staged of state.plan.slice(previous.length)) {
    if (staged.command.aggregate.type === 'task') state.referenced.set(staged.command.aggregate.id, staged.preview?.title ?? '');
  }
  return {
    status: 'staged',
    note: 'Pas encore appliqué : le serveur appliquera ou proposera le plan complet à la fin du tour.',
    staged: preview.steps.slice(previous.length).map((step) => ({
      commandType: step.commandType,
      [step.aggregateType === 'task' ? 'taskId' : 'projectId']: step.aggregateId,
      title: step.title,
      changes: Object.keys(step.changes),
      unchanged: step.noop,
      subtasks: Object.entries(step.changes).filter(([key, change]) => key.startsWith('subtask:') && change.after !== null).map(([key, change]) => ({ subtaskId: key.slice('subtask:'.length), ...change.after as object })),
    })),
  };
}
