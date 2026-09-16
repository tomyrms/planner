import type { CommandType } from '../commands.js';
import type { Handler } from '../types.js';
import { projectArchive, projectCreate, projectDelete, projectPatch, projectRestore, projectUnarchive } from './projects.js';
import { reminderRemove, reminderSet } from './reminders.js';
import {
  occurrenceComplete, occurrenceReopen, occurrenceReschedule, occurrenceSkip, occurrenceSkipMissedBefore, seriesEnd, seriesUpdate,
} from './series.js';
import { taskComplete, taskCreate, taskDelete, taskPatch, taskReopen, taskRestore } from './tasks.js';

/** One handler per V1 command type; the compiler rejects a missing one. */
export const handlers: Record<CommandType, Handler> = {
  'task.create': taskCreate,
  'task.patch': taskPatch,
  'task.complete': taskComplete,
  'task.reopen': taskReopen,
  'task.delete': taskDelete,
  'task.restore': taskRestore,
  'occurrence.complete': occurrenceComplete,
  'occurrence.skip': occurrenceSkip,
  'occurrence.reopen': occurrenceReopen,
  'occurrence.reschedule': occurrenceReschedule,
  'occurrence.skip_missed_before': occurrenceSkipMissedBefore,
  'series.update': seriesUpdate,
  'series.end': seriesEnd,
  'reminder.set': reminderSet,
  'reminder.remove': reminderRemove,
  'project.create': projectCreate,
  'project.patch': projectPatch,
  'project.archive': projectArchive,
  'project.unarchive': projectUnarchive,
  'project.delete': projectDelete,
  'project.restore': projectRestore,
};
