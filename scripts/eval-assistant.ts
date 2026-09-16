// Live evaluation of the configured provider on fixtures/assistant/eval-v1.json (npm run eval:assistant).
// Uses a disposable PostgreSQL schema, never the real data. Prints ids, verdicts and metrics, never prompts.
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { loadConfig } from '../src/config.js';
import { migrate } from '../src/infrastructure/db/migrate.js';
import { DeepSeekProvider } from '../src/modules/assistant/index.js';
import { loadEvalSet, runCase, type CaseReport } from './assistant-eval-lib.js';

const config = loadConfig();
if (config.assistant.provider.kind !== 'deepseek') {
  throw new Error('Set DEEPSEEK_API_KEY (and optionally ASSISTANT_PROVIDER=deepseek) to evaluate the real model.');
}
if (!config.databaseAdminUrl) throw new Error('DATABASE_ADMIN_URL is required for the disposable schema.');
const provider = new DeepSeekProvider(config.assistant.provider);
const set = loadEvalSet();
const only = process.argv.slice(2);
const schema = `planner_eval_${randomUUID().replaceAll('-', '')}`;
const admin = new pg.Pool({ connectionString: config.databaseAdminUrl, max: 1 });
await admin.query(`CREATE SCHEMA "${schema}"`);
const pool = new pg.Pool({ connectionString: config.databaseAdminUrl, options: `-c search_path=${schema},public`, max: 4 });
const reports: CaseReport[] = [];
try {
  await migrate(pool);
  for (const evalCase of set.cases) {
    if (only.length > 0 && !only.includes(evalCase.id)) continue;
    const report = await runCase(pool, set, evalCase, { live: provider });
    reports.push(report);
    const verdict = report.skipped ? '–' : report.passed ? '✓' : '✗';
    process.stdout.write(`${verdict} ${evalCase.category.padEnd(12)} ${evalCase.id.padEnd(38)} ${report.status.padEnd(24)} ${String(report.riskClass).padEnd(5)} ${report.durationMs} ms  ${report.toolsCalled.join(',')}\n`);
    for (const failure of report.failures) process.stdout.write(`    ${failure}\n`);
  }
} finally {
  await pool.end();
  if (/^planner_eval_[a-f0-9]{32}$/.test(schema)) await admin.query(`DROP SCHEMA "${schema}" CASCADE`);
  await admin.end();
}
const run = reports.filter((report) => !report.skipped);
const durations = run.map((report) => report.durationMs).sort((left, right) => left - right);
const percentile = (share: number) => durations[Math.min(durations.length - 1, Math.floor(share * durations.length))] ?? 0;
const falseSuccess = run.filter((report) => report.failures.some((failure) => failure.includes('forbidden'))).length;
const unconfirmed = run.filter((report) => report.failures.some((failure) => failure.includes('without confirmation'))).length;
process.stdout.write(`\n${provider.model} · ${run.filter((report) => report.passed).length}/${run.length} réussis · faux succès ${falseSuccess} · mutation R2 sans confirmation ${unconfirmed}`
  + ` · p50 ${percentile(0.5)} ms · p95 ${percentile(0.95)} ms · ${run.reduce((sum, report) => sum + report.tokens, 0)} tokens\n`);
process.exitCode = run.every((report) => report.passed) ? 0 : 1;
