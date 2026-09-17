import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

export interface BackupMigration { name: string; sha256: string }

/** pg_restore extracts only this table. Never execute the emitted SQL to discover its version. */
export function parseDumpLedger(sql: string): BackupMigration[] {
  const rows: BackupMigration[] = [];
  let inCopy = false;
  let found = false;
  let complete = false;
  for (const line of sql.split(/\r?\n/)) {
    if (/^COPY (?:public\.)?planner_migrations \(name, sha256, applied_at\) FROM stdin;$/.test(line)) {
      if (found) throw new Error('Duplicate migration ledger in dump.');
      inCopy = true; found = true;
      continue;
    }
    if (!inCopy) continue;
    if (line === '\\.') { inCopy = false; complete = true; continue; }
    const [name, sha256, appliedAt, ...extra] = line.split('\t');
    if (!name || !/^\d{4}_[a-z0-9_]+\.sql$/.test(name) || !sha256 || !/^[a-f0-9]{64}$/.test(sha256)
      || !appliedAt || extra.length > 0 || rows.some((row) => row.name === name)) {
      throw new Error('Invalid migration ledger in dump.');
    }
    rows.push({ name, sha256 });
  }
  if (!complete || rows.length === 0) throw new Error('Missing or truncated migration ledger in dump.');
  return rows.sort((a, b) => a.name.localeCompare(b.name));
}

/** A missing middle migration, changed checksum or future migration is never treated as legacy. */
export function validateDumpLedger(ledger: readonly BackupMigration[], expected: readonly BackupMigration[]): string[] {
  if (ledger.length === 0 || ledger.length > expected.length) throw new Error('Unknown migration history in dump.');
  const ordered = [...ledger].sort((a, b) => a.name.localeCompare(b.name));
  for (const [index, row] of ordered.entries()) {
    const known = expected[index];
    if (!known || row.name !== known.name || row.sha256 !== known.sha256) throw new Error('Migration history in dump differs from this release.');
  }
  // Earlier development dumps had CHECK helpers that cannot restore under pg_restore's search_path.
  if (!ordered.some((row) => row.name === '0004_restorable_checks.sql')) throw new Error('Dump predates restorable migration 0004.');
  return ordered.map((row) => row.name);
}

export async function expectedBackupMigrations(): Promise<BackupMigration[]> {
  const directory = fileURLToPath(new URL('../../../migrations/', import.meta.url));
  const names = (await readdir(directory)).filter((name) => /^\d{4}_[a-z0-9_]+\.sql$/.test(name)).sort();
  return Promise.all(names.map(async (name) => ({ name, sha256: createHash('sha256').update(await readFile(`${directory}/${name}`)).digest('hex') })));
}
