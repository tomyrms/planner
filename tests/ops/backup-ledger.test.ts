import { describe, expect, it } from 'vitest';
import { expectedBackupMigrations, parseDumpLedger, validateDumpLedger, type BackupMigration } from '../../src/infrastructure/db/backup-ledger.js';
import { missingTables, REQUIRED_TABLES, TABLE_INTRODUCED_IN } from '../../src/infrastructure/db/backup-plan.js';

const sqlFor = (rows: readonly BackupMigration[]) => `-- Ledger only\nCOPY public.planner_migrations (name, sha256, applied_at) FROM stdin;\n${rows.map((row) => `${row.name}\t${row.sha256}\t2026-09-17 12:00:00+00`).join('\n')}\n\\.\n`;
const listingFor = (tables: readonly string[]) => tables.map((table) => `200; 0 0 TABLE DATA public ${table} planner_owner`).join('\n');

describe('backup migration compatibility', () => {
  it('accepts a real pre-0007 ledger and requires all tables that existed then', async () => {
    const expected = await expectedBackupMigrations();
    const legacy = expected.filter((row) => row.name < '0007');
    const applied = validateDumpLedger(parseDumpLedger(sqlFor(legacy)), expected);
    const legacyTables = REQUIRED_TABLES.filter((table) => TABLE_INTRODUCED_IN[table] === null || applied.includes(TABLE_INTRODUCED_IN[table]!));
    expect(missingTables(listingFor(legacyTables), applied)).toEqual([]);
    expect(missingTables(listingFor(legacyTables.filter((table) => table !== 'messages')), applied)).toEqual(['messages']);
  });

  it('requires every new table once the dump ledger includes its migration; old-looking omissions cannot bypass it', async () => {
    const expected = await expectedBackupMigrations();
    const applied = validateDumpLedger(parseDumpLedger(sqlFor(expected)), expected);
    expect(missingTables(listingFor(REQUIRED_TABLES), applied)).toEqual([]);
    for (const omitted of ['tags', 'task_tags', 'user_settings', 'transcription_attempts']) {
      expect(missingTables(listingFor(REQUIRED_TABLES.filter((table) => table !== omitted)), applied)).toEqual([omitted]);
    }
    expect(missingTables(listingFor(REQUIRED_TABLES).replaceAll('DATA public', 'DATA foreign'), applied)).toContain('tasks');
  });

  it('accepts a pre-0008 dump without a voice ledger but still requires all 0007 tables', async () => {
    const expected = await expectedBackupMigrations();
    const legacy = expected.filter((row) => row.name < '0008');
    const applied = validateDumpLedger(parseDumpLedger(sqlFor(legacy)), expected);
    const legacyTables = REQUIRED_TABLES.filter((table) => table !== 'transcription_attempts');
    expect(missingTables(listingFor(legacyTables), applied)).toEqual([]);
    expect(missingTables(listingFor(legacyTables.filter((table) => table !== 'tags')), applied)).toEqual(['tags']);
  });

  it('refuses changed, missing-middle, future and pre-restorable migration history', async () => {
    const expected = await expectedBackupMigrations();
    expect(() => validateDumpLedger([...expected.slice(0, 1), ...expected.slice(2)], expected)).toThrow();
    expect(() => validateDumpLedger(expected.map((row, i) => i === 0 ? { ...row, sha256: '0'.repeat(64) } : row), expected)).toThrow();
    expect(() => validateDumpLedger([...expected, { name: '9999_future.sql', sha256: '0'.repeat(64) }], expected)).toThrow();
    expect(() => validateDumpLedger(expected.slice(0, 3), expected)).toThrow('0004');
  });

  it('rejects absent, truncated, duplicate and SQL-injection-like ledgers without executing their text', async () => {
    const expected = await expectedBackupMigrations();
    const valid = sqlFor(expected);
    for (const invalid of ['', valid.replace('\\.\n', ''), `${valid}${valid}`, sqlFor([expected[0]!, expected[0]!]), valid.replace(expected[0]!.name, "0001.sql'; DROP DATABASE planner;")]) {
      expect(() => parseDumpLedger(invalid)).toThrow();
    }
    expect(parseDumpLedger(valid)).toEqual(expected);
  });
});
