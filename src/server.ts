import { buildApp } from './app.js';
import { loadConfig, type AssistantProviderConfig } from './config.js';
import { createPool } from './infrastructure/db/pool.js';
import { DeepSeekProvider, RuleBasedProvider, type ReasoningProvider } from './modules/assistant/index.js';

function providerFor(config: AssistantProviderConfig): ReasoningProvider | null {
  switch (config.kind) {
    case 'deepseek': return new DeepSeekProvider({ apiKey: config.apiKey, model: config.model, baseUrl: config.baseUrl, thinking: config.thinking });
    case 'rules': return new RuleBasedProvider();
    case 'disabled': return null;
  }
}

const config = loadConfig();
const pool = createPool(config.databaseUrl);
const { app, assistant } = await buildApp({
  pool, auth: config.auth, logger: true,
  sync: { minimumClientVersion: config.minimumClientVersion },
  assistant: { provider: providerFor(config.assistant.provider), limits: { monthlyTokenBudget: config.assistant.monthlyTokenBudget } },
});
pool.on('error', () => app.log.error({ code: 'DATABASE_CONNECTION_ERROR' }, 'Database connection failed'));
let stopping = false;
// A turn cut by a restart never committed an effect (plans are atomic); pending proposals and Undo windows expire.
const interrupted = await assistant.recoverInterrupted();
if (interrupted > 0) app.log.warn({ code: 'ASSISTANT_TURNS_INTERRUPTED', count: interrupted }, 'Interrupted assistant turns marked failed');
const maintenance = setInterval(() => {
  assistant.expire().catch(() => app.log.error({ code: 'ASSISTANT_EXPIRY_FAILED' }, 'Assistant expiry failed'));
}, 60_000);
maintenance.unref();
async function shutdown() {
  if (stopping) return;
  stopping = true;
  clearInterval(maintenance);
  await app.close();
  await pool.end();
}
process.once('SIGINT', () => { void shutdown(); });
process.once('SIGTERM', () => { void shutdown(); });
try {
  await app.listen({ host: config.host, port: config.port });
} catch {
  app.log.error({ code: 'STARTUP_FAILED' }, 'Server could not start');
  await shutdown();
  process.exitCode = 1;
}
