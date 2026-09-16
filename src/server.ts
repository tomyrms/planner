import { buildApp } from './app.js';
import { loadConfig, type AssistantProviderConfig, type TranscriptionProviderConfig } from './config.js';
import { createPool } from './infrastructure/db/pool.js';
import { DeepSeekProvider, RuleBasedProvider, type ReasoningProvider } from './modules/assistant/index.js';
import { OpenAITranscriptionProvider, SimulatedTranscriptionProvider, type TranscriptionProvider } from './modules/voice/index.js';

function providerFor(config: AssistantProviderConfig): ReasoningProvider | null {
  switch (config.kind) {
    case 'deepseek': return new DeepSeekProvider({ apiKey: config.apiKey, model: config.model, baseUrl: config.baseUrl, thinking: config.thinking });
    case 'rules': return new RuleBasedProvider();
    case 'disabled': return null;
  }
}

function transcriberFor(config: TranscriptionProviderConfig): TranscriptionProvider | null {
  switch (config.kind) {
    case 'openai': return new OpenAITranscriptionProvider({ apiKey: config.apiKey, model: config.model, baseUrl: config.baseUrl });
    case 'simulated': return new SimulatedTranscriptionProvider();
    case 'disabled': return null;
  }
}

const config = loadConfig();
const pool = createPool(config.databaseUrl);
const { app, assistant, voice } = await buildApp({
  pool, auth: config.auth, logger: true,
  sync: { minimumClientVersion: config.minimumClientVersion },
  assistant: { provider: providerFor(config.assistant.provider), limits: { monthlyTokenBudget: config.assistant.monthlyTokenBudget } },
  voice: {
    provider: transcriberFor(config.voice.provider),
    limits: { monthlyMinutes: config.voice.monthlyMinutes },
    ...(config.voice.audioDir ? { audioDir: config.voice.audioDir } : {}),
  },
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
// Audio never outlives its transcription: leftovers of a crash are removed at start, then hourly.
const cleanAudio = () => voice.cleanup().catch(() => app.log.error({ code: 'AUDIO_CLEANUP_FAILED' }, 'Audio cleanup failed'));
await cleanAudio();
const audioCleanup = setInterval(() => { void cleanAudio(); }, 3_600_000);
audioCleanup.unref();
async function shutdown() {
  if (stopping) return;
  stopping = true;
  clearInterval(maintenance);
  clearInterval(audioCleanup);
  await voice.shutdown();
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
