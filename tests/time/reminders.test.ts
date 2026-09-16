import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { notificationId, planReminderReconciliation, reminderRuleSchema, resolveReminderTrigger, type ReminderCandidate } from '../../src/modules/time/index.js';

const reminderId = '11111111-1111-4111-8111-111111111111';
const id = notificationId(reminderId);
const candidate = (triggerAt: string, extra: Partial<ReminderCandidate> = {}): ReminderCandidate => ({ reminderId, occurrenceKey: null, eligible: true, trigger: { state: 'active', triggerAt }, ...extra });
const base = { referenceInstant: '2026-09-17T12:00:00Z', deviceTimeZone: 'Europe/Zurich', notificationsAuthorized: true };

interface PlanFixture {
  id: string; referenceInstant: string; deviceTimeZone: string; triggerAt: string;
  candidateCount: number; notificationsAuthorized: boolean; systemPending?: boolean; acceptedAt?: string;
  expected: { desiredCount: number; addOrReplaceCount: number; stateCounts: Record<string, number> };
}
const planFixtures = JSON.parse(readFileSync(new URL('../../fixtures/time/reminder-plans-v1.json', import.meta.url), 'utf8')) as { cases: PlanFixture[] };

describe('shared literal reminder plans v1 (also required for Swift)', () => {
  for (const fixture of planFixtures.cases) it(fixture.id, () => {
    const candidates = Array.from({ length: fixture.candidateCount }, (_, index) => candidate(fixture.triggerAt, { reminderId: `11111111-1111-4111-8111-${String(index).padStart(12, '0')}` }));
    const requests = candidates.map((item) => ({ notificationId: notificationId(item.reminderId), triggerAt: fixture.triggerAt }));
    const plan = planReminderReconciliation({
      referenceInstant: fixture.referenceInstant, deviceTimeZone: fixture.deviceTimeZone,
      notificationsAuthorized: fixture.notificationsAuthorized, candidates,
      systemPending: fixture.systemPending === true ? requests : [],
      schedulingReceipts: fixture.acceptedAt === undefined ? [] : requests.map((request) => ({ ...request, acceptedAt: fixture.acceptedAt! })),
    });
    const stateCounts: Record<string, number> = {};
    for (const state of Object.values(plan.states)) stateCounts[state] = (stateCounts[state] ?? 0) + 1;
    expect({ desiredCount: plan.desired.length, addOrReplaceCount: plan.addOrReplace.length, stateCounts }).toEqual(fixture.expected);
  });
});

describe('local reminder desired state never proves display', () => {
  it('reconciliation alone never claims programmed', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T13:00:00Z')] });
    expect(plan.states[id]).toBe('needs_scheduling');
    expect(plan.addOrReplace).toEqual([{ notificationId: id, triggerAt: '2026-09-17T13:00:00Z' }]);
  });
  it('an actual system pending request proves programmed', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T13:00:00Z')], systemPending: [{ notificationId: id, triggerAt: '2026-09-17T13:00:00Z' }] });
    expect(plan.states[id]).toBe('scheduled');
    expect(plan.addOrReplace).toEqual([]);
  });
  it('a changed trigger replaces the stable request', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T14:00:00Z')], systemPending: [{ notificationId: id, triggerAt: '2026-09-17T13:00:00Z' }] });
    expect(plan.addOrReplace).toEqual([{ notificationId: id, triggerAt: '2026-09-17T14:00:00Z' }]);
    expect(plan.remove).toEqual([]);
  });
  it('past unscheduled reminders are missed and never replayed', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T11:00:00Z')] });
    expect(plan.states[id]).toBe('missed');
    expect(plan.desired).toEqual([]);
  });
  it('past programmed reminders absent from pending have unknown display', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T11:00:00Z')], schedulingReceipts: [{ notificationId: id, triggerAt: '2026-09-17T11:00:00Z', acceptedAt: '2026-09-17T10:00:00Z' }] });
    expect(plan.states[id]).toBe('display_unknown');
    expect(plan.desired).toEqual([]);
  });
  it('an acceptance for the old trigger is not evidence for the changed one', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T11:00:00Z')], schedulingReceipts: [{ notificationId: id, triggerAt: '2026-09-17T10:30:00Z', acceptedAt: '2026-09-17T10:00:00Z' }] });
    expect(plan.states[id]).toBe('missed');
  });
  it('future reminders beyond fourteen days remain pending', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-10-01T12:00:01Z')] });
    expect(plan.states[id]).toBe('pending_window');
    expect(plan.desired).toEqual([]);
  });
  it('includes the upper boundary and measures civil days across DST', () => {
    const plan = planReminderReconciliation({ ...base, referenceInstant: '2026-03-22T12:00:00Z', candidates: [candidate('2026-04-05T11:00:00Z')] });
    expect(plan.states[id]).toBe('needs_scheduling');
    const outside = planReminderReconciliation({ ...base, referenceInstant: '2026-03-22T12:00:00Z', candidates: [candidate('2026-04-05T11:00:01Z')] });
    expect(outside.states[id]).toBe('pending_window');
  });
  it('keeps at most fifty requests and leaves the rest pending', () => {
    const candidates = Array.from({ length: 51 }, (_, index) => candidate('2026-09-17T13:00:00Z', { reminderId: `11111111-1111-4111-8111-${String(index).padStart(12, '0')}` })).reverse();
    const plan = planReminderReconciliation({ ...base, candidates });
    expect(plan.desired).toHaveLength(50);
    expect(plan.states[notificationId('11111111-1111-4111-8111-000000000050')]).toBe('pending_capacity');
    expect(plan.desired[0]?.notificationId).toBe(notificationId('11111111-1111-4111-8111-000000000000'));
  });
  it('permission denial preserves requested reminders but schedules none', () => {
    const plan = planReminderReconciliation({ ...base, notificationsAuthorized: false, candidates: [candidate('2026-09-17T13:00:00Z')], systemPending: [{ notificationId: id, triggerAt: '2026-09-17T13:00:00Z' }] });
    expect(plan.states[id]).toBe('notifications_disabled');
    expect(plan.desired).toEqual([]);
    expect(plan.remove).toEqual([id]);
  });
  it('removes requests whose task is completed or base disappeared', () => {
    const plan = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T13:00:00Z', { eligible: false })], systemPending: [{ notificationId: id, triggerAt: '2026-09-17T13:00:00Z' }, { notificationId: 'another-feature', triggerAt: '2026-09-17T13:00:00Z' }] });
    expect(plan.states[id]).toBe('removed');
    expect(plan.remove).toEqual([id]);
    const inactive = planReminderReconciliation({ ...base, candidates: [candidate('2026-09-17T13:00:00Z', { trigger: { state: 'inactive_base_missing', triggerAt: null } })] });
    expect(inactive.states[id]).toBe('inactive_base_missing');
  });
  it('rejects absolute series reminders without a specific occurrence', () => {
    expect(() => resolveReminderTrigger({ reminder: { kind: 'absolute', absolute: { date: '2026-09-17', time: '17:00', timeZone: 'Europe/Zurich' } }, schedule: null, deadline: null, deviceTimeZone: 'Europe/Zurich', isRecurring: true })).toThrow(/REQUIRES_OCCURRENCE/);
  });
  it('validates offsets and keeps after-completion notification IDs distinct', () => {
    expect(reminderRuleSchema.safeParse({ kind: 'before_start', offsetMinutes: -1 }).success).toBe(false);
    expect(reminderRuleSchema.safeParse({ kind: 'before_start', offsetMinutes: 10081 }).success).toBe(false);
    expect(notificationId(reminderId, '2026-09-17~0')).not.toBe(notificationId(reminderId, '2026-09-17~1'));
  });
});
