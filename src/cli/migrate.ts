import { loadConfig } from '../config.js';
import { createPool } from '../infrastructure/db/pool.js';
import { migrate } from '../infrastructure/db/migrate.js';

const config = loadConfig();
if (!config.databaseAdminUrl) throw new Error('DATABASE_ADMIN_URL is required for migrations.');
const pool = createPool(config.databaseAdminUrl);
try {
  await migrate(pool);
  console.log('Migrations appliquées et empreintes vérifiées.');
} finally {
  await pool.end();
}
