import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  closeAfterCompletion, countMissedFixed, fixedOccurrences, isFixedOccurrence, isOverdue, nextAfterCompletion, nextAfterCompletionFromLocalDate,
  occurrenceId, projectTimeValue, relativeDate, reopenAfterCompletion, resolveReminderTrigger,
  resolveTimeValue, type AfterCompletionState, type FixedWindowInput, type TimeValue,
} from '../../src/modules/time/index.js';

interface Fixture { id: string; operation: string; input: unknown; expected: unknown }
const fixtureFile = JSON.parse(readFileSync(new URL('../../fixtures/time/v1.json', import.meta.url), 'utf8')) as { schemaVersion: number; cases: Fixture[] };
const taskId = '11111111-1111-4111-8111-111111111111';

function run(fixture: Fixture): unknown {
  switch (fixture.operation) {
    case 'resolve': return resolveTimeValue(fixture.input as TimeValue | null);
    case 'project': {
      const input = fixture.input as { value: TimeValue; displayTimeZone: string };
      return projectTimeValue(input.value, input.displayTimeZone);
    }
    case 'overdue': {
      const input = fixture.input as { value: TimeValue | null; referenceInstant: string; deviceTimeZone: string };
      return isOverdue(input.value, input.referenceInstant, input.deviceTimeZone);
    }
    case 'relative': {
      const input = fixture.input as { referenceInstant: string; timeZone: string; days: number };
      return relativeDate(input.referenceInstant, input.timeZone, input.days);
    }
    case 'fixedKeys': return fixedOccurrences({ ...(fixture.input as Omit<FixedWindowInput, 'taskId'>), taskId }).map((row) => row.occurrenceKey);
    case 'missed': return countMissedFixed(fixture.input as Parameters<typeof countMissedFixed>[0]);
    case 'nextAfter': return nextAfterCompletion(fixture.input as Parameters<typeof nextAfterCompletion>[0]);
    case 'nextAfterFromDate': {
      const input = fixture.input as { rule: Parameters<typeof nextAfterCompletionFromLocalDate>[0]; completedLocalDate: string };
      return nextAfterCompletionFromLocalDate(input.rule, input.completedLocalDate);
    }
    case 'fixedMember': {
      const input = fixture.input as { anchor: string; rule: FixedWindowInput['rule']; dates: string[] };
      return input.dates.map((date) => isFixedOccurrence({ anchor: input.anchor, rule: input.rule, date }));
    }
    case 'occurrenceId': {
      const input = fixture.input as { taskId: string; occurrenceKey: string };
      return occurrenceId(input.taskId, input.occurrenceKey);
    }
    case 'closeAfter': return closeAfterCompletion(fixture.input as Parameters<typeof closeAfterCompletion>[0]);
    case 'reopenAfter': {
      const input = fixture.input as { state: AfterCompletionState; successorMaterialized: boolean };
      return reopenAfterCompletion(input.state, input.successorMaterialized);
    }
    case 'reminderTrigger': return resolveReminderTrigger(fixture.input as Parameters<typeof resolveReminderTrigger>[0]);
    default: throw new Error(`Unknown fixture operation: ${fixture.operation}`);
  }
}

describe('shared literal temporal fixtures v1 (also required for Swift)', () => {
  it('has one supported version and unique IDs', () => {
    expect(fixtureFile.schemaVersion).toBe(1);
    expect(new Set(fixtureFile.cases.map((fixture) => fixture.id)).size).toBe(fixtureFile.cases.length);
  });
  for (const fixture of fixtureFile.cases) it(fixture.id, () => expect(run(fixture)).toEqual(fixture.expected));
});
