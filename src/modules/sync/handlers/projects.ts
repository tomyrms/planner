import { and, asc, eq } from 'drizzle-orm';
import { projects, tasks } from '../../../infrastructure/db/schema.js';
import { CommandRejection, type CommandContext, type Handler } from '../types.js';
import { assertNewAggregate, noop, payloadOf, rejectMissing, revisionOf, searchTextFor, type ProjectRow } from './shared.js';

type ProjectChanges = Partial<typeof projects.$inferInsert>;

/** A list command locks the list first, then its tasks (same global order as task commands). */
async function lockProject(context: CommandContext): Promise<ProjectRow> {
  const [project] = await context.db.select().from(projects)
    .where(and(eq(projects.id, context.aggregateId), eq(projects.userId, context.actor.userId))).for('update');
  if (!project) return rejectMissing(context, 'project', context.aggregateId);
  context.observedRevision = revisionOf(project);
  return project;
}

async function saveProject(context: CommandContext, project: ProjectRow, changes: ProjectChanges): Promise<number> {
  const revision = project.revision + 1n;
  await context.db.update(projects).set({ ...changes, revision, updatedAt: context.now.toISOString() })
    .where(and(eq(projects.id, project.id), eq(projects.userId, context.actor.userId)));
  return Number(revision);
}

function lockMembers(context: CommandContext, projectId: string) {
  return context.db.select({ id: tasks.id, title: tasks.title, notes: tasks.notes, deletedAt: tasks.deletedAt }).from(tasks)
    .where(and(eq(tasks.projectId, projectId), eq(tasks.userId, context.actor.userId)))
    .orderBy(asc(tasks.id)).for('update');
}

export const projectCreate: Handler = async (context) => {
  const payload = payloadOf(context, 'project.create');
  await assertNewAggregate(context, 'project');
  const inserted = await context.db.insert(projects).values({
    id: context.aggregateId, userId: context.actor.userId, name: payload.name,
    colorKey: payload.colorKey ?? null, sortOrder: payload.sortOrder ?? null,
  }).onConflictDoNothing().returning({ id: projects.id });
  if (inserted.length === 0) throw new CommandRejection('ENTITY_ALREADY_EXISTS');
  return { revision: 1 };
};

export const projectPatch: Handler = async (context) => {
  const { set } = payloadOf(context, 'project.patch');
  const project = await lockProject(context);
  if (project.deletedAt !== null) throw new CommandRejection('PROJECT_DELETED');
  await context.checkPrecondition(revisionOf(project));
  const changes: ProjectChanges = {};
  if (set.name !== undefined && set.name !== project.name) changes.name = set.name;
  if (set.colorKey !== undefined && set.colorKey !== project.colorKey) changes.colorKey = set.colorKey;
  if (set.sortOrder !== undefined && set.sortOrder !== project.sortOrder) changes.sortOrder = set.sortOrder;
  if (Object.keys(changes).length === 0) return noop(project);
  if (changes.name !== undefined) {
    // search_text is derived; refreshing it is not a user change, so task revisions stay as they are.
    const members = await lockMembers(context, project.id);
    if (members.length > 0) {
      await context.client.query(
        `UPDATE tasks AS t SET search_text = v.search_text
         FROM unnest($1::uuid[], $2::text[]) AS v(id, search_text)
         WHERE t.id = v.id AND t.user_id = $3`,
        [members.map((task) => task.id), members.map((task) => searchTextFor(task, { name: changes.name! })), context.actor.userId],
      );
    }
  }
  return { revision: await saveProject(context, project, changes) };
};

const archive = (archived: boolean): Handler => async (context) => {
  const project = await lockProject(context);
  if (project.deletedAt !== null) throw new CommandRejection('PROJECT_DELETED');
  await context.checkPrecondition(revisionOf(project));
  if ((project.archivedAt !== null) === archived) return noop(project);
  return { revision: await saveProject(context, project, { archivedAt: archived ? context.now.toISOString() : null }) };
};

export const projectArchive = archive(true);
export const projectUnarchive = archive(false);

/** Never an implicit cascade: the client names what happens to the tasks (03_Data_Model.md §3). */
export const projectDelete: Handler = async (context) => {
  const { taskPolicy } = payloadOf(context, 'project.delete');
  const project = await lockProject(context);
  await context.checkPrecondition(revisionOf(project));
  if (project.deletedAt !== null) return noop(project, { taskPolicy, affectedTaskIds: [] });
  const now = context.now.toISOString();
  const members = await lockMembers(context, project.id);
  let affectedTaskIds: string[];
  if (taskPolicy === 'move_tasks_to_inbox') {
    // Trashed tasks move too, so restoring them later never depends on this list.
    affectedTaskIds = members.map((task) => task.id);
    if (affectedTaskIds.length > 0) {
      await context.client.query(
        `UPDATE tasks AS t SET project_id = NULL, search_text = v.search_text, revision = t.revision + 1, updated_at = $3
         FROM unnest($1::uuid[], $2::text[]) AS v(id, search_text)
         WHERE t.id = v.id AND t.user_id = $4`,
        [affectedTaskIds, members.map((task) => searchTextFor(task, null)), now, context.actor.userId],
      );
    }
  } else {
    // Tasks already in the trash keep their own deletion.
    affectedTaskIds = members.filter((task) => task.deletedAt === null).map((task) => task.id);
    if (affectedTaskIds.length > 0) {
      await context.client.query(
        `UPDATE tasks SET deleted_at = $2, deleted_by_command_id = $3, revision = revision + 1, updated_at = $2
         WHERE id = ANY($1::uuid[]) AND user_id = $4`,
        [affectedTaskIds, now, context.commandId, context.actor.userId],
      );
    }
  }
  const revision = await saveProject(context, project, { deletedAt: now, deletedByCommandId: context.commandId });
  return { revision, taskPolicy, affectedTaskIds };
};

/** Brings back the tasks trashed by the same deletion command, and only those. */
export const projectRestore: Handler = async (context) => {
  const project = await lockProject(context);
  await context.checkPrecondition(revisionOf(project));
  if (project.deletedAt === null) return noop(project, { affectedTaskIds: [] });
  const now = context.now.toISOString();
  let affectedTaskIds: string[] = [];
  if (project.deletedByCommandId !== null) {
    const members = await lockMembers(context, project.id);
    const restored = await context.client.query<{ id: string }>(
      `UPDATE tasks SET deleted_at = NULL, deleted_by_command_id = NULL, revision = revision + 1, updated_at = $1
       WHERE id = ANY($2::uuid[]) AND user_id = $3 AND deleted_by_command_id = $4
       RETURNING id`,
      [now, members.map((task) => task.id), context.actor.userId, project.deletedByCommandId],
    );
    affectedTaskIds = restored.rows.map((row) => row.id).sort();
  }
  const revision = await saveProject(context, project, { deletedAt: null, deletedByCommandId: null });
  return { revision, affectedTaskIds };
};
