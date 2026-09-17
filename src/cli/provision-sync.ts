import { existsSync } from 'node:fs';
import { loadEnvFile } from 'node:process';
import { z } from 'zod';
import { createPool } from '../infrastructure/db/pool.js';
import { defaultSyncProvisioning, provisionSync, SYNC_TABLES } from '../infrastructure/db/provision-sync.js';

// Needs only the owner URL and the two PowerSync passwords; never prints a secret.
if (existsSync('.env')) loadEnvFile('.env');
const secret = z.string().regex(/^[\x21-\x7e]{32,}$/);
const parsed = z.object({
  DATABASE_ADMIN_URL: z.url(),
  PLANNER_POWERSYNC_PASSWORD: secret,
  PLANNER_POWERSYNC_STORAGE_PASSWORD: secret,
}).safeParse(process.env);
if (!parsed.success) {
  throw new Error(`Invalid configuration fields: ${parsed.error.issues.map((issue) => issue.path.join('.')).join(', ')} (run npm run setup:local)`);
}
const pool = createPool(parsed.data.DATABASE_ADMIN_URL);
try {
  await provisionSync(pool, {
    ...defaultSyncProvisioning,
    replicationPassword: parsed.data.PLANNER_POWERSYNC_PASSWORD,
    storagePassword: parsed.data.PLANNER_POWERSYNC_STORAGE_PASSWORD,
  });
  console.log(`PowerSync provisionné : rôle de réplication en lecture seule, publication « powersync » (${SYNC_TABLES.length} tables), base de stockage séparée.`);
} finally {
  await pool.end();
}
