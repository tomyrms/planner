import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import type pg from 'pg';

export interface MigrationOptions { directory?: string }

/** Numbered SQL accommodates CHECK functions that Drizzle cannot generate.
 * The ledger detects edited history; one transaction commits schema and hash.
 * Invoke with the migration role, never automatically from the API process.
 */
export async function migrate(pool: pg.Pool, options: MigrationOptions = {}): Promise<void> {
  const directory = options.directory ?? fileURLToPath(new URL('../../../migrations/', import.meta.url));
  const files = (await readdir(directory)).filter((name) => /^\d{4}_[a-z0-9_]+\.sql$/.test(name)).sort();
  if (new Set(files.map((name) => name.slice(0, 4))).size !== files.length) {
    throw new Error('Migration number repeated');
  }
  const connection = await pool.connect();
  try {
    await connection.query('BEGIN');
    await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(current_database() || ':' || current_schema() || ':planner:migrations', 0))");
    await connection.query(`CREATE TABLE IF NOT EXISTS planner_migrations (
      name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
    )`);
    // Default privileges grant DML to the runtime role; the ledger stays owner-only.
    await connection.query(`DO $$
      DECLARE grantee_name text;
      BEGIN
        FOR grantee_name IN SELECT DISTINCT grantee FROM information_schema.role_table_grants
          WHERE table_schema = current_schema() AND table_name = 'planner_migrations' AND grantee <> current_user
        LOOP
          IF grantee_name = 'PUBLIC' THEN EXECUTE 'REVOKE ALL ON TABLE planner_migrations FROM PUBLIC';
          ELSE EXECUTE format('REVOKE ALL ON TABLE planner_migrations FROM %I', grantee_name);
          END IF;
        END LOOP;
      END $$`);
    const ledger = await connection.query<{ name: string; sha256: string }>('SELECT name, sha256 FROM planner_migrations ORDER BY name');
    const installed = new Map(ledger.rows.map((row) => [row.name, row.sha256]));
    for (const name of installed.keys()) {
      if (!files.includes(name)) throw new Error(`Applied migration is missing: ${name}`);
    }
    for (const name of files) {
      const sql = await readFile(`${directory}/${name}`, 'utf8');
      const hash = createHash('sha256').update(sql).digest('hex');
      const existing = installed.get(name);
      if (existing !== undefined) {
        if (existing !== hash) throw new Error(`Applied migration was changed: ${name}`);
        continue;
      }
      if (ledger.rows.some((row) => row.name > name)) throw new Error(`Migration inserted before applied history: ${name}`);
      await connection.query(sql);
      await connection.query('INSERT INTO planner_migrations(name, sha256) VALUES ($1, $2)', [name, hash]);
    }
    await connection.query('COMMIT');
  } catch (error) {
    await connection.query('ROLLBACK');
    throw error;
  } finally {
    connection.release();
  }
}
