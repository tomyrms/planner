import { bigint, date, integer, jsonb, pgTable, text, time, timestamp, uuid, boolean, doublePrecision } from 'drizzle-orm/pg-core';
import type { RecurrenceRule } from '../../modules/time/index.js';
import type { TaskSubtask } from '../../modules/domain/details.js';

const timestamps = () => ({
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'string' }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true, mode: 'string' }).notNull().defaultNow(),
});

// Executable constraints, FKs and indexes live in reviewed numbered migrations.
// This mapping is used by Drizzle for typed domain reads and writes.
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'string' }).notNull().defaultNow(),
  locale: text('locale').notNull().default('fr-CH'),
  defaultTimeZone: text('default_time_zone').notNull().default('Europe/Zurich'),
});

export const projects = pgTable('projects', {
  id: uuid('id').primaryKey(), userId: uuid('user_id').notNull(),
  name: text('name').notNull(), colorKey: text('color_key'), sortOrder: doublePrecision('sort_order'),
  archivedAt: timestamp('archived_at', { withTimezone: true, mode: 'string' }),
  deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'string' }),
  deletedByCommandId: uuid('deleted_by_command_id'),
  revision: bigint('revision', { mode: 'bigint' }).notNull().default(1n),
  ...timestamps(),
});

export const tasks = pgTable('tasks', {
  id: uuid('id').primaryKey(), userId: uuid('user_id').notNull(), projectId: uuid('project_id'),
  title: text('title').notNull(), notes: text('notes'),
  priority: text('priority', { enum: ['none', 'low', 'medium', 'high'] }).notNull().default('none'),
  status: text('status', { enum: ['active', 'completed'] }).notNull().default('active'),
  completedAt: timestamp('completed_at', { withTimezone: true, mode: 'string' }),
  scheduledDate: date('scheduled_date'), scheduledTime: time('scheduled_time'), scheduledTimeZone: text('scheduled_time_zone'),
  scheduledStartAt: timestamp('scheduled_start_at', { withTimezone: true, mode: 'string' }),
  durationMinutes: integer('duration_minutes'),
  deadlineDate: date('deadline_date'), deadlineTime: time('deadline_time'), deadlineTimeZone: text('deadline_time_zone'),
  deadlineAt: timestamp('deadline_at', { withTimezone: true, mode: 'string' }),
  recurrence: jsonb('recurrence').$type<RecurrenceRule>(),
  subtasks: jsonb('subtasks').$type<TaskSubtask[]>().notNull().default([]),
  missedIgnoredBefore: date('missed_ignored_before'),
  searchText: text('search_text').notNull().default(''),
  deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'string' }), deletedByCommandId: uuid('deleted_by_command_id'),
  revision: bigint('revision', { mode: 'bigint' }).notNull().default(1n),
  ...timestamps(),
});

export const taskOccurrences = pgTable('task_occurrences', {
  id: uuid('id').primaryKey(), userId: uuid('user_id').notNull(), taskId: uuid('task_id').notNull(),
  occurrenceKey: text('occurrence_key').notNull(),
  status: text('status', { enum: ['open', 'completed', 'skipped'] }).notNull().default('open'),
  completedAt: timestamp('completed_at', { withTimezone: true, mode: 'string' }),
  overrideDate: date('override_date'), overrideTime: time('override_time'), overrideTimeZone: text('override_time_zone'),
  successorOccurrenceKey: text('successor_occurrence_key'),
  ...timestamps(),
});

export const tags = pgTable('tags', {
  id: uuid('id').primaryKey(), userId: uuid('user_id').notNull(),
  name: text('name').notNull(), normalizedName: text('normalized_name').notNull(),
  revision: bigint('revision', { mode: 'bigint' }).notNull().default(1n),
  deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'string' }), ...timestamps(),
});

export const taskTags = pgTable('task_tags', {
  id: uuid('id').primaryKey(), userId: uuid('user_id').notNull(),
  taskId: uuid('task_id').notNull(), tagId: uuid('tag_id').notNull(),
  deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'string' }), ...timestamps(),
});

export const userSettings = pgTable('user_settings', {
  id: uuid('id').primaryKey(), autoTags: boolean('auto_tags').notNull().default(false),
  revision: bigint('revision', { mode: 'bigint' }).notNull().default(1n), ...timestamps(),
});

export const reminders = pgTable('reminders', {
  id: uuid('id').primaryKey(), userId: uuid('user_id').notNull(), taskId: uuid('task_id').notNull(), occurrenceKey: text('occurrence_key'),
  kind: text('kind', { enum: ['before_start','on_scheduled_day_at','before_deadline','on_deadline_day_at','absolute'] }).notNull(),
  offsetMinutes: integer('offset_minutes'), localTime: time('local_time'),
  absoluteDate: date('absolute_date'), absoluteTime: time('absolute_time'), absoluteTimeZone: text('absolute_time_zone'),
  state: text('state', { enum: ['active','inactive_base_missing'] }).notNull().default('active'),
  deletedAt: timestamp('deleted_at', { withTimezone: true, mode: 'string' }), ...timestamps(),
});

export const commandReceipts = pgTable('command_receipts', {
  clientCommandId: uuid('client_command_id').primaryKey(), userId: uuid('user_id').notNull(), deviceId: uuid('device_id'),
  origin: text('origin', { enum: ['manual','assistant','undo'] }).notNull(), commandType: text('command_type').notNull(),
  payloadHash: text('payload_hash').notNull(), outcome: text('outcome', { enum: ['applied','rejected'] }).notNull(),
  result: jsonb('result').$type<Record<string, unknown>>().notNull(),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'string' }).notNull().defaultNow(),
});

export const tombstones = pgTable('tombstones', {
  entityType: text('entity_type', { enum: ['task', 'project', 'tag'] }).notNull(), entityId: uuid('entity_id').notNull(),
  userId: uuid('user_id').notNull(),
  purgedAt: timestamp('purged_at', { withTimezone: true, mode: 'string' }).notNull().defaultNow(),
});

export const serverMeta = pgTable('server_meta', {
  singleton: boolean('singleton').primaryKey().default(true), generation: uuid('generation').notNull().defaultRandom(),
});
