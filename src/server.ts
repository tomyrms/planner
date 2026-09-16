import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createPool } from './infrastructure/db/pool.js';

const config = loadConfig();
const pool = createPool(config.databaseUrl);
const { app } = await buildApp({ pool, auth: config.auth, logger: true, sync: { minimumClientVersion: config.minimumClientVersion } });
pool.on('error', () => app.log.error({ code: 'DATABASE_CONNECTION_ERROR' }, 'Database connection failed'));
let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
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
