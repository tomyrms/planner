import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { loadEvalSet, runCase } from '../../scripts/assistant-eval-lib.js';
import { PROMPT_VERSION } from '../../src/modules/assistant/index.js';
import { createTestDatabase } from '../db/helpers.js';

const set = loadEvalSet();

describe(`assistant evaluation set v${set.version} (scripted model)`, () => {
  let db: Awaited<ReturnType<typeof createTestDatabase>>;
  beforeAll(async () => { db = await createTestDatabase(); });
  afterAll(async () => { await db?.close(); });

  it('matches the prompt version and covers every required category', () => {
    expect(set.promptVersion).toBe(PROMPT_VERSION);
    expect(new Set(set.cases.map((item) => item.id)).size).toBe(set.cases.length);
    const categories = new Set(set.cases.map((item) => item.category));
    for (const category of ['creation', 'multiple', 'update', 'complete', 'ambiguous', 'deadline', 'recurrence', 'destructive', 'code-switch', 'reference', 'adversarial']) {
      expect(categories, category).toContain(category);
    }
    expect(set.cases.filter((item) => item.category === 'reference')).toHaveLength(5);
  });

  for (const evalCase of set.cases) {
    it(`${evalCase.category} — ${evalCase.id}`, async () => {
      const report = await runCase(db.pool, set, evalCase);
      expect(report.failures).toEqual([]);
    });
  }
});
