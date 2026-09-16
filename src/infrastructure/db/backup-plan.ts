/** Pure rules of the backup tool (04_Backend/05_Homelab_Deployment.md, ADR-022). */

export const DUMP_PATTERN = /^planner-(\d{8}T\d{6}Z)\.dump$/;
/** Tables whose data must be present in every dump. PowerSync bucket storage is derived and never dumped. */
export const REQUIRED_TABLES = [
  'planner_migrations', 'users', 'projects', 'tasks', 'task_occurrences', 'reminders',
  'command_receipts', 'tombstones', 'server_meta', 'devices', 'auth_sessions',
] as const;

export function backupStamp(now: Date): string {
  return now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

export function stampDate(stamp: string): Date {
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(stamp);
  if (!match) throw new Error('Invalid backup stamp');
  return new Date(`${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}Z`);
}

/** ISO 8601 week key, e.g. 2026-W38. */
export function isoWeek(date: Date): string {
  const day = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  const weekday = day.getUTCDay() || 7;
  day.setUTCDate(day.getUTCDate() + 4 - weekday);
  const yearStart = Date.UTC(day.getUTCFullYear(), 0, 1);
  const week = Math.ceil(((day.getTime() - yearStart) / 86_400_000 + 1) / 7);
  return `${day.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

/** Keeps the 7 newest dumps plus the newest dump of each of the 4 most recent weeks; returns the dumps to delete. */
export function dumpsToPrune(fileNames: readonly string[], keepRecent = 7, keepWeeks = 4): string[] {
  const dumps = fileNames.filter((name) => DUMP_PATTERN.test(name)).sort().reverse();
  const keep = new Set(dumps.slice(0, keepRecent));
  const weeks = new Set<string>();
  for (const name of dumps) {
    const week = isoWeek(stampDate(DUMP_PATTERN.exec(name)![1]!));
    if (weeks.has(week)) continue;
    if (weeks.size >= keepWeeks) break;
    weeks.add(week);
    keep.add(name);
  }
  return dumps.filter((name) => !keep.has(name));
}

/** Tables whose data appears in a `pg_restore --list` output. */
export function tablesWithData(listing: string): Set<string> {
  const tables = new Set<string>();
  for (const line of listing.split(/\r?\n/)) {
    const match = /\bTABLE DATA \S+ (\S+) /.exec(line);
    if (match && !line.trimStart().startsWith(';')) tables.add(match[1]!);
  }
  return tables;
}

export function missingTables(listing: string): string[] {
  const present = tablesWithData(listing);
  return REQUIRED_TABLES.filter((table) => !present.has(table));
}
