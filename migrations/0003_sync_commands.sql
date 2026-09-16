-- Stage 2: sync command support. Additive only.
-- "Ignore previous missed occurrences" is a series-level marker, never a batch of rows.
ALTER TABLE tasks ADD COLUMN missed_ignored_before date;
ALTER TABLE tasks ADD CONSTRAINT task_missed_ignored_requires_series
  CHECK (missed_ignored_before IS NULL OR (recurrence IS NOT NULL AND recurrence->>'mode' = 'fixed'));

-- project.restore finds the tasks trashed by the same command.
CREATE INDEX tasks_project_deleted_by_idx ON tasks(project_id, deleted_by_command_id) WHERE deleted_at IS NOT NULL;
