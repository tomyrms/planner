import type pg from 'pg';
import { toTimeValue } from '../domain/derive.js';

export const EXPORT_VERSION = 1;

type Row = Record<string, any>;
const iso = (value: Date | null): string | null => value === null ? null : value.toISOString();
const time = (row: Row, prefix: string) => toTimeValue({ date: row[`${prefix}_date`], time: row[`${prefix}_time`], zone: row[`${prefix}_time_zone`] });

/** Versioned archive of one user's data (02_API_Contract.md §5), read from one consistent snapshot. */
export async function buildExport(pool: pg.Pool, userId: string, now: Date = new Date()) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const read = async (sql: string) => (await client.query(sql, [userId])).rows as Row[];
    const [meta] = (await client.query<{ generation: string }>('SELECT generation FROM server_meta')).rows;
    // Dates and times come back as text so that no local time zone can shift them.
    const projects = await read(`SELECT id, name, color_key, sort_order, archived_at, deleted_at, revision::text, created_at, updated_at
      FROM projects WHERE user_id = $1 ORDER BY created_at, id`);
    const tasks = await read(`SELECT id, project_id, title, notes, priority, status, completed_at,
        scheduled_date::text, scheduled_time::text, scheduled_time_zone, duration_minutes,
        deadline_date::text, deadline_time::text, deadline_time_zone, recurrence, missed_ignored_before::text,
        deleted_at, revision::text, created_at, updated_at
      FROM tasks WHERE user_id = $1 ORDER BY created_at, id`);
    const occurrences = await read(`SELECT id, task_id, occurrence_key, status, completed_at,
        override_date::text, override_time::text, override_time_zone, successor_occurrence_key, created_at, updated_at
      FROM task_occurrences WHERE user_id = $1 ORDER BY task_id, occurrence_key`);
    const conversations = await read(`SELECT id, title, created_at, updated_at FROM conversations WHERE user_id = $1 ORDER BY created_at, id`);
    const messages = await read(`SELECT id, conversation_id, seq::int AS seq, role, kind, text, original_transcript, transcription_id, revises_message_id, created_at
      FROM messages WHERE user_id = $1 ORDER BY conversation_id, seq`);
    const reminders = await read(`SELECT id, task_id, occurrence_key, kind, offset_minutes, local_time::text,
        absolute_date::text, absolute_time::text, absolute_time_zone, state, deleted_at, created_at, updated_at
      FROM reminders WHERE user_id = $1 ORDER BY task_id, id`);
    await client.query('COMMIT');
    return {
      exportVersion: EXPORT_VERSION,
      exportedAt: now.toISOString(),
      serverGeneration: meta!.generation,
      projects: projects.map((row) => ({
        id: row.id, name: row.name, colorKey: row.color_key, sortOrder: row.sort_order,
        archivedAt: iso(row.archived_at), deletedAt: iso(row.deleted_at), revision: Number(row.revision),
        createdAt: iso(row.created_at), updatedAt: iso(row.updated_at),
      })),
      tasks: tasks.map((row) => ({
        id: row.id, projectId: row.project_id, title: row.title, notes: row.notes, priority: row.priority,
        status: row.status, completedAt: iso(row.completed_at),
        schedule: time(row, 'scheduled'), durationMinutes: row.duration_minutes, deadline: time(row, 'deadline'),
        recurrence: row.recurrence, missedIgnoredBefore: row.missed_ignored_before,
        deletedAt: iso(row.deleted_at), revision: Number(row.revision), createdAt: iso(row.created_at), updatedAt: iso(row.updated_at),
      })),
      taskOccurrences: occurrences.map((row) => ({
        id: row.id, taskId: row.task_id, occurrenceKey: row.occurrence_key, status: row.status,
        completedAt: iso(row.completed_at), override: time(row, 'override'),
        successorOccurrenceKey: row.successor_occurrence_key, createdAt: iso(row.created_at), updatedAt: iso(row.updated_at),
      })),
      reminders: reminders.map((row) => ({
        id: row.id, taskId: row.task_id, occurrenceKey: row.occurrence_key, kind: row.kind,
        offsetMinutes: row.offset_minutes, localTime: row.local_time?.slice(0, 5) ?? null,
        absolute: row.absolute_date === null ? null : { date: row.absolute_date, time: row.absolute_time.slice(0, 5), timeZone: row.absolute_time_zone },
        state: row.state, deletedAt: iso(row.deleted_at), createdAt: iso(row.created_at), updatedAt: iso(row.updated_at),
      })),
      // Conversations are kept until deleted (ADR-021); the audio never is.
      conversations: conversations.map((conversation) => ({
        id: conversation.id, title: conversation.title, createdAt: iso(conversation.created_at), updatedAt: iso(conversation.updated_at),
        messages: messages.filter((message) => message.conversation_id === conversation.id).map((message) => ({
          id: message.id, seq: message.seq, role: message.role, kind: message.kind, text: message.text,
          originalTranscript: message.original_transcript, transcriptionId: message.transcription_id,
          revisesMessageId: message.revises_message_id, createdAt: iso(message.created_at),
        })),
      })),
    };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
