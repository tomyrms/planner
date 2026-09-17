import { randomUUID } from 'node:crypto';
import type pg from 'pg';
import { executeCommand, type CommandActor, type CommandResult, type RawCommand } from '../../src/modules/sync/index.js';

export const ZURICH = 'Europe/Zurich';
export const RECORDED_AT = '2026-09-16T10:00:00+02:00';

/** A V1 command with a fresh client id; `extra` overrides any envelope field. */
export function command(type: string, aggregateId: string, payload?: Record<string, unknown>, extra: Partial<RawCommand> = {}): RawCommand {
  return {
    clientCommandId: randomUUID(),
    type,
    payloadVersion: 1,
    aggregate: { type: type.startsWith('project.') ? 'project' : type.startsWith('tag.') ? 'tag' : type.startsWith('settings.') ? 'settings' : 'task', id: aggregateId },
    clientRecordedAt: RECORDED_AT,
    ...(payload === undefined ? {} : { payload }),
    ...extra,
  };
}

export const afterCommand = (cited: RawCommand) => ({ precondition: { kind: 'afterCommand' as const, clientCommandId: cited.clientCommandId } });
export const atRevision = (revision: number) => ({ precondition: { kind: 'revision' as const, revision } });

export function commandRunner(pool: pg.Pool, actor: CommandActor, clock: () => Date) {
  const run = (input: RawCommand, as: CommandActor = actor): Promise<CommandResult> => executeCommand(pool, as, input, clock);
  /** Runs and returns the stored outcome; a duplicate is unwrapped to its original. */
  const outcome = async (input: RawCommand, as: CommandActor = actor): Promise<Record<string, unknown>> => {
    const result = await run(input, as);
    return result.outcome === 'duplicate' ? { ...result.original } : { ...result };
  };
  /** Runs and fails the test unless the command was applied. */
  const apply = async (input: RawCommand, as: CommandActor = actor): Promise<Record<string, unknown>> => {
    const result = await outcome(input, as);
    if (result.outcome !== 'applied') throw new Error(`${input.type} was not applied: ${JSON.stringify(result)}`);
    return result;
  };
  return { run, outcome, apply };
}

export async function taskRow(pool: pg.Pool, id: string) {
  const result = await pool.query(`SELECT id, project_id, title, notes, priority, status, completed_at, scheduled_date::text, scheduled_time::text,
    scheduled_time_zone, scheduled_start_at, duration_minutes, deadline_date::text, deadline_at, recurrence,
    missed_ignored_before::text, search_text, deleted_at, deleted_by_command_id, revision::int
    FROM tasks WHERE id = $1`, [id]);
  return result.rows[0] as Record<string, unknown> | undefined;
}

export async function occurrenceRows(pool: pg.Pool, taskId: string) {
  const result = await pool.query(`SELECT id, occurrence_key, status, completed_at IS NOT NULL AS completed, override_date::text,
    override_time::text, successor_occurrence_key FROM task_occurrences WHERE task_id = $1 ORDER BY occurrence_key`, [taskId]);
  return result.rows as Array<Record<string, unknown>>;
}

export async function reminderRows(pool: pg.Pool, taskId: string) {
  const result = await pool.query(`SELECT id, occurrence_key, kind, offset_minutes, state, deleted_at IS NOT NULL AS deleted
    FROM reminders WHERE task_id = $1 ORDER BY id`, [taskId]);
  return result.rows as Array<Record<string, unknown>>;
}
