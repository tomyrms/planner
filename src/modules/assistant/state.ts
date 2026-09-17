import type { RawCommand } from '../sync/index.js';

export interface CalendarEvent { start: string; end: string; allDay: boolean; title: string; calendarName: string }
export interface CalendarContext { capturedAt: string; from: string; to: string; calendars: string[]; events: CalendarEvent[] }

/** Everything a turn knows about its time and device context. */
export interface TurnInfo {
  id: string;
  userId: string;
  deviceId: string | null;
  conversationId: string;
  referenceInstant: string;
  timeZone: string;
  /** Civil date and time of referenceInstant in timeZone. */
  localDate: string;
  localTime: string;
  unsynced: ReadonlySet<string>;
  calendar: CalendarContext | null;
  /** Trusted server preference, never chosen by the provider. Missing means disabled. */
  autoTags?: boolean;
}

/**
 * How a task entered the turn, which decides whether a mutation targets it explicitly (R1)
 * or through an interpretation (R2): 04_AI_Orchestration.md §5.
 */
export type Selection = 'explicit' | 'ambiguous' | 'filter';

export interface TaskObservation {
  revision: number;
  title: string;
  recurring: boolean;
  selection: Selection;
}

export interface StagedCommand {
  command: RawCommand;
  tool: string;
  /** True when the aggregate existed before the turn. */
  existing: boolean;
  preview: PreviewItem | null;
  automaticTagIds?: string[];
}

export interface PreviewItem {
  index: number;
  commandType: string;
  aggregateType: 'task' | 'project';
  aggregateId: string;
  title: string;
  changes: Record<string, { before: unknown; after: unknown }>;
  noop: boolean;
  automaticTagIds?: string[];
}

export interface ProposedSlot { date: string; start: string; end: string }

export class TurnState {
  readonly tasks = new Map<string, TaskObservation>();
  readonly projects = new Set<string>();
  /** reminderId → taskId, for reminders seen in a read. */
  readonly reminders = new Map<string, string>();
  readonly tags = new Map<string, string>();
  readonly catalogueTagIds = new Set<string>();
  tagsCatalogueRead = false;
  /** subtaskId → parent taskId, scoped to reads or staged creations in this turn. */
  readonly subtasks = new Map<string, string>();
  readonly plan: StagedCommand[] = [];
  readonly proposedSlots: ProposedSlot[] = [];
  /** Tasks worth naming in the next turn's context ("ça", "la même"). */
  readonly referenced = new Map<string, string>();
  invalidArguments = 0;
  /** Mutations that could not be prepared and were not retried later: reported next to the result. */
  readonly unprepared = new Map<string, { code: string; round: number }>();
  round = 0;
  createdTasks = 0;
  createdProjects = 0;

  constructor(readonly turn: TurnInfo) {}

  observeTask(id: string, observation: Omit<TaskObservation, 'selection'>, selection: Selection): void {
    const previous = this.tasks.get(id);
    // An explicit sighting wins; otherwise the weakest evidence is kept.
    const rank: Record<Selection, number> = { explicit: 2, ambiguous: 1, filter: 0 };
    const kept = previous === undefined ? selection
      : rank[selection] === 2 || rank[previous.selection] === 2 ? 'explicit'
        : previous.selection === 'ambiguous' || selection === 'ambiguous' ? 'ambiguous' : 'filter';
    this.tasks.set(id, { ...observation, selection: kept });
  }
}
