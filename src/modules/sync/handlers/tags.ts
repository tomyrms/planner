import { and, eq } from 'drizzle-orm';
import { tags } from '../../../infrastructure/db/schema.js';
import { MAX_TAGS, MAX_TASK_TAGS } from '../../domain/details.js';
import { CommandRejection, type CommandContext, type Handler } from '../types.js';
import { assertNewAggregate, noop, payloadOf, rejectMissing, revisionOf } from './shared.js';

type TagRow = typeof tags.$inferSelect;

/** Serializes catalog capacity and unique-name checks across distinct tag IDs. */
async function lockCatalog(context: CommandContext): Promise<void> {
  await context.client.query("SELECT pg_advisory_xact_lock(hashtextextended('planner:tags:' || $1::uuid::text, 0))", [context.actor.userId]);
}

async function lockTag(context: CommandContext): Promise<TagRow> {
  await lockCatalog(context);
  const [tag] = await context.db.select().from(tags)
    .where(and(eq(tags.id, context.aggregateId), eq(tags.userId, context.actor.userId))).for('update');
  if (!tag) return rejectMissing(context, 'tag', context.aggregateId);
  context.observedRevision = revisionOf(tag);
  await context.checkPrecondition(revisionOf(tag));
  return tag;
}

async function normalizedName(context: CommandContext, name: string): Promise<string> {
  const result = await context.client.query<{ name: string }>(
    'SELECT normalize(casefold(normalize($1::text, NFC) COLLATE pg_catalog.pg_unicode_fast), NFC) AS name', [name]);
  return result.rows[0]!.name;
}

async function assertAvailable(context: CommandContext, name: string, consumesSlot: boolean): Promise<void> {
  const { rows: [row] } = await context.client.query<{ count: number; taken: boolean }>(
    `SELECT count(*)::int AS count, coalesce(bool_or(normalized_name = $2 AND id <> $3), false) AS taken
     FROM tags WHERE user_id = $1 AND deleted_at IS NULL`, [context.actor.userId, name, context.aggregateId]);
  if (row!.taken) throw new CommandRejection('TAG_NAME_TAKEN');
  if (consumesSlot && row!.count >= MAX_TAGS) throw new CommandRejection('TAG_LIMIT_REACHED');
}

async function save(context: CommandContext, tag: TagRow, changes: Partial<typeof tags.$inferInsert>) {
  const revision = tag.revision + 1n;
  await context.db.update(tags).set({ ...changes, revision, updatedAt: context.now.toISOString() }).where(eq(tags.id, tag.id));
  return { revision: Number(revision) };
}

export const tagCreate: Handler = async (context) => {
  const { name } = payloadOf(context, 'tag.create');
  await lockCatalog(context);
  await assertNewAggregate(context, 'tag');
  const canonical = await normalizedName(context, name);
  await assertAvailable(context, canonical, true);
  const inserted = await context.db.insert(tags).values({
    id: context.aggregateId, userId: context.actor.userId, name, normalizedName: canonical,
  }).onConflictDoNothing().returning({ id: tags.id });
  if (inserted.length === 0) throw new CommandRejection('ENTITY_ALREADY_EXISTS');
  return { revision: 1 };
};

export const tagPatch: Handler = async (context) => {
  const { set } = payloadOf(context, 'tag.patch');
  const tag = await lockTag(context);
  if (tag.deletedAt !== null) throw new CommandRejection('TAG_DELETED');
  if (set.name === tag.name) return noop(tag);
  const canonical = await normalizedName(context, set.name);
  await assertAvailable(context, canonical, false);
  return save(context, tag, { name: set.name, normalizedName: canonical });
};

export const tagDelete: Handler = async (context) => {
  const tag = await lockTag(context);
  if (tag.deletedAt !== null) return noop(tag);
  return save(context, tag, { deletedAt: context.now.toISOString() });
};

export const tagRestore: Handler = async (context) => {
  const tag = await lockTag(context);
  if (tag.deletedAt === null) return noop(tag);
  await assertAvailable(context, tag.normalizedName, true);
  // A deletion frees capacity while retaining relations. Restoring must not overflow any linked task.
  // The tag UPDATE lock blocks new attachments/removals to it; every link writer also locks its task.
  const members = await context.client.query<{ id: string }>(
    `SELECT t.id FROM tasks t JOIN task_tags tt ON tt.task_id=t.id AND tt.user_id=t.user_id
     WHERE tt.user_id=$1 AND tt.tag_id=$2 AND tt.deleted_at IS NULL ORDER BY t.id FOR UPDATE OF t`,
    [context.actor.userId, tag.id]);
  if (members.rows.length > 0) {
    const full = await context.client.query(
      `SELECT tt.task_id FROM task_tags tt JOIN tags t ON t.id=tt.tag_id AND t.user_id=tt.user_id
       WHERE tt.user_id=$1 AND tt.task_id=ANY($2::uuid[]) AND tt.deleted_at IS NULL AND t.deleted_at IS NULL
       GROUP BY tt.task_id HAVING count(*) >= $3 LIMIT 1`,
      [context.actor.userId, members.rows.map((row) => row.id), MAX_TASK_TAGS]);
    if (full.rowCount) throw new CommandRejection('TASK_TAG_LIMIT_REACHED');
  }
  return save(context, tag, { deletedAt: null });
};
