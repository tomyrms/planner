import { eq } from 'drizzle-orm';
import { userSettings } from '../../../infrastructure/db/schema.js';
import { CommandRejection, type Handler } from '../types.js';
import { noop, payloadOf, revisionOf } from './shared.js';

/** An absent row is the revision-1 default. Inserting it and its change share the receipt transaction. */
export const settingsPatch: Handler = async (context) => {
  if (context.aggregateId !== context.actor.userId.toLowerCase()) throw new CommandRejection('FORBIDDEN_REFERENCE');
  const { set } = payloadOf(context, 'settings.patch');
  await context.db.insert(userSettings).values({ id: context.aggregateId }).onConflictDoNothing();
  const [settings] = await context.db.select().from(userSettings).where(eq(userSettings.id, context.aggregateId)).for('update');
  context.observedRevision = revisionOf(settings!);
  await context.checkPrecondition(revisionOf(settings!));
  if (settings!.autoTags === set.autoTags) return noop(settings!);
  const revision = settings!.revision + 1n;
  await context.db.update(userSettings).set({ autoTags: set.autoTags, revision, updatedAt: context.now.toISOString() })
    .where(eq(userSettings.id, context.aggregateId));
  return { revision: Number(revision) };
};
