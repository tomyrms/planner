import { describe, expect, it } from 'vitest';
import { backupStamp, dumpsToPrune, isoWeek, missingTables, stampDate, tablesWithData } from '../../src/infrastructure/db/backup-plan.js';

const dump = (date: string) => `planner-${backupStamp(new Date(date))}.dump`;

describe('backup plan', () => {
  it('stamps files in UTC and reads the stamp back', () => {
    expect(backupStamp(new Date('2026-09-16T14:03:09.512Z'))).toBe('20260916T140309Z');
    expect(stampDate('20260916T140309Z').toISOString()).toBe('2026-09-16T14:03:09.000Z');
    expect(() => stampDate('2026-09-16')).toThrow();
  });

  it('computes ISO weeks across year boundaries', () => {
    expect(isoWeek(new Date('2026-09-16T00:00:00Z'))).toBe('2026-W38');
    expect(isoWeek(new Date('2027-01-01T00:00:00Z'))).toBe('2026-W53');
    expect(isoWeek(new Date('2024-12-30T00:00:00Z'))).toBe('2025-W01');
  });

  it('keeps seven recent dumps and one per week for four weeks', () => {
    const daily = Array.from({ length: 40 }, (_, index) => dump(new Date(Date.UTC(2026, 8, 16 - index, 2)).toISOString()));
    const pruned = new Set(dumpsToPrune([...daily, 'planner-20260916T020000Z.dump.sha256', 'notes.txt', 'planner-latest.dump']));
    const kept = daily.filter((name) => !pruned.has(name));
    expect(kept.slice(0, 7)).toEqual(daily.slice(0, 7));
    // 7 recent (16 → 10 Sept, weeks 38 and 37) + newest of weeks 36 and 35.
    expect(kept).toEqual([...daily.slice(0, 7), dump('2026-09-06T02:00:00Z'), dump('2026-08-30T02:00:00Z')]);
    expect(pruned.size).toBe(31);
    expect([...pruned].every((name) => /^planner-\d{8}T\d{6}Z\.dump$/.test(name))).toBe(true);
    expect(dumpsToPrune([dump('2026-09-16T02:00:00Z')])).toEqual([]);
  });

  it('reads table data entries from a pg_restore listing', () => {
    const listing = [
      ';',
      '; Archive created at 2026-09-16 14:03:09 UTC',
      '3401; 0 16410 TABLE DATA public tasks planner_owner',
      '3402; 0 16420 TABLE DATA public projects planner_owner',
      ';3403; 0 16430 TABLE DATA public reminders planner_owner',
      '218; 1259 16410 TABLE public command_receipts planner_owner',
    ].join('\n');
    expect([...tablesWithData(listing)].sort()).toEqual(['projects', 'tasks']);
    expect(missingTables(listing)).toContain('reminders');
    expect(missingTables(listing)).toContain('command_receipts');
    expect(missingTables(listing)).not.toContain('tasks');
  });
});
