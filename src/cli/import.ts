import type pg from 'pg';
import { ImportError } from '../modules/import/formats.js';
import { readImportJson, writeImportPlan } from '../modules/import/files.js';
import { applyImport, previewImport } from '../modules/import/service.js';

export async function runImportCommand(pool: pg.Pool, input: {
  mode: string; file: string; userId: string; apiUrl: string; selection?: string; output?: string; confirmedHash?: string;
}) {
  const source = await readImportJson(input.file);
  if (input.mode === 'preview') {
    if (!input.selection || !input.output) throw new ImportError('IMPORT_PREVIEW_REQUIRES_SELECTION_AND_OUTPUT');
    const selection = await readImportJson(input.selection);
    const plan = await previewImport(pool, { source: source.value, sourceSha256: source.sha256, selection: selection.value,
      userId: input.userId, apiUrl: input.apiUrl });
    await writeImportPlan(input.output, plan);
    process.stdout.write(`Plan privé créé : ${input.output}\nUtilisateur cible : ${plan.target.userId}\n`
      + `Prévisualisation sans effet : ${plan.projects.length} liste(s), ${plan.tags.length} tag(s), ${plan.tasks.length} tâche(s).\n`
      + `Avertissements : ${plan.warnings.length}. Exclusions : ${JSON.stringify(plan.excluded)}.\n`
      + `Empreinte à confirmer après examen : ${plan.planHash}\n`
      + 'Réutilisez ce même plan pour reprendre après interruption. Un nouveau plan crée de nouveaux objets.\n');
  } else if (input.mode === 'apply') {
    if (!input.confirmedHash) throw new ImportError('IMPORT_CONFIRM_PLAN_REQUIRED');
    const result = await applyImport(pool, source.value, { planHash: input.confirmedHash, userId: input.userId, apiUrl: input.apiUrl });
    process.stdout.write(`Import ${result.outcome === 'already_applied' ? 'déjà appliqué' : 'appliqué'} : ${result.importId}, `
      + `${result.projects} liste(s), ${result.tags} tag(s), ${result.tasks} tâche(s), ${result.commandCount} reçu(s).\n`);
  } else throw new ImportError('IMPORT_UNKNOWN_MODE');
}
