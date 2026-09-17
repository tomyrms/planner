import type pg from 'pg';
import { z } from 'zod';
import { executePlan } from '../sync/index.js';
import { checked, ImportError } from './formats.js';
import { buildImportPlan, commandsForPlan, readImportPlan, type ImportPlan } from './plan.js';

function targetUrl(value: string): string {
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.hash || url.search) throw new Error();
    return url.toString().replace(/\/$/, '');
  } catch { throw new ImportError('IMPORT_INVALID_TARGET_URL'); }
}

async function execute(pool: pg.Pool, plan: ImportPlan, dryRun: boolean) {
  const commands = commandsForPlan(plan);
  const result = await executePlan(pool, { userId: plan.target.userId, deviceId: null, origin: 'manual' }, commands, {
    dryRun,
    hooks: { before: async (client, _command, index) => {
      if (index !== 0) return;
      // A concurrent restore/rotation cannot pass between validation and committed domain effects.
      const generation = await client.query<{ generation: string }>('SELECT generation FROM server_meta FOR SHARE');
      if (generation.rows[0]?.generation !== plan.target.serverGeneration) throw new ImportError('IMPORT_SERVER_GENERATION_CHANGED');
      const owner = await client.query('SELECT id FROM users WHERE id = $1 FOR KEY SHARE', [plan.target.userId]);
      if (!owner.rowCount) throw new ImportError('IMPORT_TARGET_USER_NOT_FOUND');
    } },
  });
  if (result.status !== 'applied') throw new ImportError(`IMPORT_COMMAND_${result.rejection.code}`, commands[result.index]?.aggregate.id);
  return {
    importId: plan.importId, planHash: plan.planHash, commandCount: commands.length,
    outcome: result.steps.every((step) => step.result.outcome === 'duplicate') ? 'already_applied' as const : 'applied' as const,
    projects: plan.projects.length, tags: plan.tags.length, tasks: plan.tasks.length,
  };
}

export async function previewImport(pool: pg.Pool, input: {
  source: unknown; sourceSha256: string; selection: unknown; userId: string; apiUrl: string; now?: Date; importId?: string;
}): Promise<ImportPlan> {
  const userId = checked(z.uuid(), input.userId, 'IMPORT_INVALID_TARGET_USER').toLowerCase();
  const generation = await pool.query<{ generation: string }>('SELECT generation FROM server_meta');
  if (!generation.rows[0]) throw new ImportError('IMPORT_SERVER_GENERATION_UNKNOWN');
  const plan = buildImportPlan(input.source, input.sourceSha256, input.selection,
    { userId, serverGeneration: generation.rows[0].generation, apiUrl: targetUrl(input.apiUrl) }, input.now, input.importId);
  await execute(pool, plan, true);
  return plan;
}

export async function applyImport(pool: pg.Pool, value: unknown, confirmation: { planHash: string; userId: string; apiUrl: string }) {
  const plan = readImportPlan(value, confirmation.planHash);
  if (plan.target.userId !== confirmation.userId.toLowerCase()) throw new ImportError('IMPORT_TARGET_USER_CHANGED');
  if (plan.target.apiUrl !== targetUrl(confirmation.apiUrl)) throw new ImportError('IMPORT_TARGET_SERVER_CHANGED');
  return execute(pool, plan, false);
}
