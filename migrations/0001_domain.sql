-- Stage 1 domain foundation. Runtime writes use the restricted API role.
CREATE FUNCTION planner_valid_date(value text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE parsed date;
BEGIN
  IF value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RETURN false; END IF;
  parsed := value::date;
  RETURN parsed BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'
    AND to_char(parsed, 'YYYY-MM-DD') = value;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

CREATE FUNCTION planner_valid_occurrence_key(value text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE cycle text;
BEGIN
  IF value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}(~(0|[1-9][0-9]*))?$'
    OR NOT planner_valid_date(split_part(value, '~', 1)) THEN RETURN false; END IF;
  cycle := split_part(value, '~', 2);
  RETURN cycle = '' OR cycle::numeric <= 9007199254740991;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

CREATE FUNCTION planner_valid_zone(value text) RETURNS boolean
LANGUAGE sql STABLE STRICT AS $$
  SELECT value !~ '^(posix/|right/)' AND value <> 'localtime'
    AND EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = value)
$$;

CREATE FUNCTION planner_valid_temporal(day date, clock time, zone text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT (day IS NULL OR day BETWEEN DATE '0001-01-01' AND DATE '9999-12-31')
    AND CASE WHEN clock IS NULL THEN zone IS NULL
      ELSE day IS NOT NULL AND zone IS NOT NULL
        AND clock < TIME '24:00' AND EXTRACT(SECOND FROM clock) = 0
        AND planner_valid_zone(zone) END
$$;

CREATE FUNCTION planner_valid_recurrence(rule jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE allowed text[]; weekday jsonb; seen text[] := '{}';
BEGIN
  IF jsonb_typeof(rule) <> 'object' OR rule->'v' IS DISTINCT FROM '1'::jsonb
    OR jsonb_typeof(rule->'interval') IS DISTINCT FROM 'number'
    OR (rule->>'interval') !~ '^[0-9]+$'
    OR (rule->>'interval')::numeric NOT BETWEEN 1 AND 365 THEN RETURN false; END IF;
  IF rule->>'mode' = 'after_completion' THEN
    allowed := ARRAY['v','mode','unit','interval'];
    IF rule->>'unit' IS NULL OR rule->>'unit' NOT IN ('day','week','month') THEN RETURN false; END IF;
  ELSIF rule->>'mode' = 'fixed' THEN
    allowed := ARRAY['v','mode','freq','interval','until','count'];
    IF rule ? 'until' AND (jsonb_typeof(rule->'until') <> 'string'
      OR NOT planner_valid_date(rule->>'until')) THEN RETURN false; END IF;
    IF rule ? 'count' AND (jsonb_typeof(rule->'count') <> 'number'
      OR (rule->>'count') !~ '^[0-9]+$' OR (rule->>'count')::numeric NOT BETWEEN 1 AND 3652059)
      THEN RETURN false; END IF;
    IF rule ? 'until' AND rule ? 'count' THEN RETURN false; END IF;
    IF rule->>'freq' = 'weekly' THEN
      allowed := allowed || ARRAY['byWeekday'];
      IF jsonb_typeof(rule->'byWeekday') IS DISTINCT FROM 'array'
        OR jsonb_array_length(rule->'byWeekday') NOT BETWEEN 1 AND 7 THEN RETURN false; END IF;
      FOR weekday IN SELECT * FROM jsonb_array_elements(rule->'byWeekday') LOOP
        IF jsonb_typeof(weekday) <> 'string' OR weekday #>> '{}' NOT IN ('MO','TU','WE','TH','FR','SA','SU')
          OR weekday #>> '{}' = ANY(seen) THEN RETURN false; END IF;
        seen := array_append(seen, weekday #>> '{}');
      END LOOP;
    ELSIF rule->>'freq' = 'monthly' THEN
      allowed := allowed || ARRAY['byMonthDay','lastDayOfMonth'];
      IF (rule ? 'byMonthDay') = (rule ? 'lastDayOfMonth') THEN RETURN false; END IF;
      IF rule ? 'byMonthDay' AND (jsonb_typeof(rule->'byMonthDay') <> 'number'
        OR (rule->>'byMonthDay') !~ '^[0-9]+$'
        OR (rule->>'byMonthDay')::numeric NOT BETWEEN 1 AND 31) THEN RETURN false; END IF;
      IF rule ? 'lastDayOfMonth' AND rule->'lastDayOfMonth' IS DISTINCT FROM 'true'::jsonb THEN RETURN false; END IF;
    ELSIF rule->>'freq' IS DISTINCT FROM 'daily' THEN RETURN false;
    END IF;
  ELSE RETURN false;
  END IF;
  RETURN NOT EXISTS (SELECT 1 FROM jsonb_object_keys(rule) AS k WHERE NOT k = ANY(allowed));
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  locale text NOT NULL DEFAULT 'fr-CH' CHECK (length(locale) BETWEEN 2 AND 64),
  default_time_zone text NOT NULL DEFAULT 'Europe/Zurich' CHECK (planner_valid_zone(default_time_zone))
);

CREATE TABLE projects (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  color_key text,
  sort_order double precision CHECK (sort_order IS NULL OR sort_order NOT IN ('Infinity'::float8, '-Infinity'::float8, 'NaN'::float8)),
  archived_at timestamptz,
  deleted_at timestamptz,
  deleted_by_command_id uuid,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id)
);

CREATE TABLE tasks (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  project_id uuid,
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 500),
  notes text CHECK (length(notes) <= 10000),
  priority text NOT NULL DEFAULT 'none' CHECK (priority IN ('none','low','medium','high')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed')),
  completed_at timestamptz,
  scheduled_date date,
  scheduled_time time,
  scheduled_time_zone text,
  scheduled_start_at timestamptz,
  duration_minutes integer CHECK (duration_minutes BETWEEN 1 AND 1440),
  deadline_date date,
  deadline_time time,
  deadline_time_zone text,
  deadline_at timestamptz,
  recurrence jsonb CHECK (recurrence IS NULL OR planner_valid_recurrence(recurrence)),
  search_text text NOT NULL DEFAULT '',
  deleted_at timestamptz,
  deleted_by_command_id uuid,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, project_id) REFERENCES projects(user_id, id),
  CONSTRAINT task_completion_consistent CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
  CONSTRAINT task_schedule_consistent CHECK (planner_valid_temporal(scheduled_date, scheduled_time, scheduled_time_zone)),
  CONSTRAINT task_deadline_consistent CHECK (planner_valid_temporal(deadline_date, deadline_time, deadline_time_zone)),
  CONSTRAINT task_recurrence_anchor CHECK (recurrence IS NULL OR (scheduled_date IS NOT NULL AND deadline_date IS NULL)),
  CONSTRAINT task_schedule_projection CHECK (scheduled_start_at IS NULL OR (scheduled_time IS NOT NULL AND recurrence IS NULL)),
  CONSTRAINT task_deadline_projection CHECK (deadline_at IS NULL OR deadline_time IS NOT NULL)
);

CREATE TABLE task_occurrences (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  task_id uuid NOT NULL,
  occurrence_key text NOT NULL CHECK (planner_valid_occurrence_key(occurrence_key)),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','completed','skipped')),
  completed_at timestamptz,
  override_date date,
  override_time time,
  override_time_zone text,
  successor_occurrence_key text CHECK (planner_valid_occurrence_key(successor_occurrence_key)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (user_id, task_id) REFERENCES tasks(user_id, id),
  UNIQUE (task_id, occurrence_key),
  CONSTRAINT occurrence_completion_consistent CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
  CONSTRAINT occurrence_override_consistent CHECK (planner_valid_temporal(override_date, override_time, override_time_zone)),
  CONSTRAINT occurrence_successor_consistent CHECK (successor_occurrence_key IS NULL OR (status IN ('completed','skipped') AND successor_occurrence_key <> occurrence_key))
);

CREATE TABLE reminders (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  task_id uuid NOT NULL,
  occurrence_key text CHECK (planner_valid_occurrence_key(occurrence_key)),
  kind text NOT NULL CHECK (kind IN ('before_start','on_scheduled_day_at','before_deadline','on_deadline_day_at','absolute')),
  offset_minutes integer CHECK (offset_minutes BETWEEN 0 AND 10080),
  local_time time CHECK (local_time < TIME '24:00' AND EXTRACT(SECOND FROM local_time) = 0),
  absolute_date date,
  absolute_time time,
  absolute_time_zone text,
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active','inactive_base_missing')),
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (user_id, task_id) REFERENCES tasks(user_id, id),
  CONSTRAINT reminder_temporal_consistent CHECK (planner_valid_temporal(absolute_date, absolute_time, absolute_time_zone)),
  CONSTRAINT reminder_kind_consistent CHECK (
    (kind IN ('before_start','before_deadline') AND offset_minutes IS NOT NULL AND local_time IS NULL AND absolute_date IS NULL AND absolute_time IS NULL AND absolute_time_zone IS NULL)
    OR (kind IN ('on_scheduled_day_at','on_deadline_day_at') AND offset_minutes IS NULL AND local_time IS NOT NULL AND absolute_date IS NULL AND absolute_time IS NULL AND absolute_time_zone IS NULL)
    OR (kind = 'absolute' AND offset_minutes IS NULL AND local_time IS NULL AND absolute_date IS NOT NULL AND absolute_time IS NOT NULL AND absolute_time_zone IS NOT NULL)
  )
);

CREATE TABLE command_receipts (
  client_command_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  device_id uuid,
  origin text NOT NULL CHECK (origin IN ('manual','assistant','undo')),
  command_type text NOT NULL,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  outcome text NOT NULL CHECK (outcome IN ('applied','rejected')),
  result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tombstones (
  entity_type text NOT NULL CHECK (entity_type IN ('task','project')),
  entity_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users(id),
  purged_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (entity_type, entity_id)
);

CREATE TABLE server_meta (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  generation uuid NOT NULL DEFAULT gen_random_uuid()
);
INSERT INTO server_meta DEFAULT VALUES;

CREATE INDEX tasks_user_schedule_idx ON tasks(user_id, deleted_at, status, scheduled_date);
CREATE INDEX tasks_user_deadline_idx ON tasks(user_id, deadline_date);
CREATE INDEX tasks_user_start_idx ON tasks(user_id, scheduled_start_at);
CREATE INDEX tasks_project_idx ON tasks(project_id);
CREATE INDEX reminders_task_idx ON reminders(task_id);
CREATE INDEX receipts_user_created_idx ON command_receipts(user_id, created_at);
