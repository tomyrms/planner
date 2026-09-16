import type { TimeValue } from '../time/index.js';
import type { TurnState } from './state.js';

export type RiskReason =
  | 'series_change' | 'several_existing_targets' | 'too_many_creations' | 'too_many_objects'
  | 'interpreted_selection' | 'notes_replaced' | 'unchosen_slot';

const SERIES_TYPES = new Set(['series.update', 'series.end']);
const MAX_R1_CREATIONS = 10;
const MAX_R1_OBJECTS = 10;

/**
 * Risk of the whole plan (04_AI_Orchestration.md §5). R1 is a closed list; anything else that is valid
 * needs confirmation. Splitting a set into several calls changes nothing: the plan is evaluated at once.
 */
export function evaluateRisk(state: TurnState): { riskClass: 'R1' | 'R2'; reasons: RiskReason[] } {
  const reasons = new Set<RiskReason>();
  const existing = new Set<string>();
  let creations = 0;
  for (const staged of state.plan) {
    const { command, preview } = staged;
    if (SERIES_TYPES.has(command.type)) reasons.add('series_change');
    if (command.type === 'task.create' || command.type === 'project.create') creations++;
    if (staged.existing) {
      existing.add(command.aggregate.id);
      const observation = command.aggregate.type === 'task' ? state.tasks.get(command.aggregate.id) : undefined;
      if (observation && observation.selection !== 'explicit') reasons.add('interpreted_selection');
    }
    const notes = preview?.changes.notes;
    if (staged.existing && notes && typeof notes.before === 'string' && notes.before.trim().length > 0) reasons.add('notes_replaced');
    // A slot computed in this turn and applied in the same turn was not chosen by the user.
    for (const [field, change] of Object.entries(preview?.changes ?? {})) {
      const value = (field === 'schedule' ? change.after : field.startsWith('occurrence:') ? (change.after as { override?: TimeValue } | null)?.override : null) as TimeValue | null | undefined;
      if (value?.time && state.proposedSlots.some((slot) => slot.date === value.date && slot.start === value.time)) reasons.add('unchosen_slot');
    }
  }
  if (existing.size > 1) reasons.add('several_existing_targets');
  if (creations > MAX_R1_CREATIONS) reasons.add('too_many_creations');
  if (existing.size + creations > MAX_R1_OBJECTS) reasons.add('too_many_objects');
  return { riskClass: reasons.size > 0 ? 'R2' : 'R1', reasons: [...reasons] };
}
