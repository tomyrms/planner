import { v5 as uuidv5 } from 'uuid';

export interface TaskSubtask { id: string; title: string; isCompleted: boolean; sortOrder: number }
export const MAX_SUBTASKS = 50;
export const MAX_TAGS = 200;
export const MAX_TASK_TAGS = 10;
export const TASK_TAG_NAMESPACE = '04c55814-dde2-539b-92f2-91a16b669f2f';

/** Shared with Swift; UUIDs are canonical lowercase, separated by one slash. */
export function taskTagId(taskId: string, tagId: string): string {
  return uuidv5(`${taskId.toLowerCase()}/${tagId.toLowerCase()}`, TASK_TAG_NAMESPACE);
}

export function orderedSubtasks(items: readonly TaskSubtask[]): TaskSubtask[] {
  return [...items].sort((a, b) => a.sortOrder - b.sortOrder || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

export function normalizeSubtask(item: { id: string; title: string; isCompleted?: boolean | undefined; sortOrder?: number | undefined }, fallbackOrder: number): TaskSubtask {
  return { id: item.id.toLowerCase(), title: item.title, isCompleted: item.isCompleted ?? false, sortOrder: item.sortOrder ?? fallbackOrder };
}
