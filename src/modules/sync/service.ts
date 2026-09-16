import type pg from 'pg';
import type { Envelope } from './commands.js';
import { executeCommand } from './executor.js';
import type { CommandActor, CommandResult } from './types.js';

/** The client saw another database lifetime (restore): nothing may be applied (02_API_Contract.md §3.2). */
export class ServerGenerationChanged extends Error {
  constructor(public readonly serverGeneration: string) {
    super('The server generation changed.');
  }
}

export async function currentGeneration(pool: pg.Pool): Promise<string> {
  const result = await pool.query<{ generation: string }>('SELECT generation FROM server_meta');
  if (result.rowCount !== 1) throw new Error('server_meta must hold exactly one generation');
  return result.rows[0]!.generation;
}

/** Commands run in queue order, each committed with its receipt; a rejection never stops the batch. */
export async function applyEnvelope(pool: pg.Pool, actor: CommandActor, envelope: Envelope, clock?: () => Date): Promise<{ serverGeneration: string; results: CommandResult[] }> {
  const serverGeneration = await currentGeneration(pool);
  if (envelope.serverGeneration.toLowerCase() !== serverGeneration) throw new ServerGenerationChanged(serverGeneration);
  const results: CommandResult[] = [];
  for (const command of envelope.commands) results.push(await executeCommand(pool, actor, command, clock));
  return { serverGeneration, results };
}
