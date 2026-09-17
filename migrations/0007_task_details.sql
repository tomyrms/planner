-- One bounded checklist belongs to its task aggregate. No recurrence semantics are implied.
CREATE FUNCTION planner_valid_subtasks(value jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE item jsonb; seen uuid[] := '{}'; item_id uuid; item_order float8;
BEGIN
  IF jsonb_typeof(value) <> 'array' OR jsonb_array_length(value) > 50 THEN RETURN false; END IF;
  FOR item IN SELECT jsonb_array_elements(value) LOOP
    IF jsonb_typeof(item) <> 'object' OR NOT (item ?& ARRAY['id','title','isCompleted','sortOrder'])
       OR item - ARRAY['id','title','isCompleted','sortOrder'] <> '{}'::jsonb
       OR jsonb_typeof(item->'id') <> 'string' OR jsonb_typeof(item->'title') <> 'string'
       OR jsonb_typeof(item->'isCompleted') <> 'boolean' OR jsonb_typeof(item->'sortOrder') <> 'number'
       OR length(btrim(item->>'title')) NOT BETWEEN 1 AND 500 THEN RETURN false; END IF;
    item_id := (item->>'id')::uuid;
    IF item->>'id' <> item_id::text OR item_id = ANY(seen) THEN RETURN false; END IF;
    seen := array_append(seen, item_id);
    item_order := (item->>'sortOrder')::float8;
    IF item_order IN ('Infinity'::float8, '-Infinity'::float8, 'NaN'::float8) THEN RETURN false; END IF;
  END LOOP;
  RETURN true;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

ALTER TABLE tasks ADD COLUMN subtasks jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE tasks ADD CONSTRAINT task_subtasks_valid CHECK (planner_valid_subtasks(subtasks));
ALTER TABLE tasks ADD CONSTRAINT task_subtasks_nonrecurring CHECK (recurrence IS NULL OR subtasks = '[]'::jsonb);

CREATE TABLE tags (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  name text NOT NULL CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 50),
  normalized_name text NOT NULL CHECK (normalized_name = normalize(casefold(normalize(name, NFC) COLLATE pg_catalog.pg_unicode_fast), NFC)),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id)
);
CREATE UNIQUE INDEX tags_live_name_idx ON tags(user_id, normalized_name) WHERE deleted_at IS NULL;

CREATE TABLE task_tags (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  task_id uuid NOT NULL,
  tag_id uuid NOT NULL,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, tag_id),
  FOREIGN KEY (user_id, task_id) REFERENCES tasks(user_id, id) ON DELETE CASCADE,
  FOREIGN KEY (user_id, tag_id) REFERENCES tags(user_id, id) ON DELETE CASCADE
);
CREATE INDEX task_tags_owner_task_idx ON task_tags(user_id, task_id);
CREATE INDEX task_tags_tag_idx ON task_tags(tag_id);

CREATE TABLE user_settings (
  id uuid PRIMARY KEY REFERENCES users(id),
  auto_tags boolean NOT NULL DEFAULT false,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE tombstones DROP CONSTRAINT tombstones_entity_type_check;
ALTER TABLE tombstones ADD CONSTRAINT tombstones_entity_type_check CHECK (entity_type IN ('task','project','tag'));
-- The closed executor can now journal details/settings commands too.
ALTER TABLE ai_actions DROP CONSTRAINT ai_actions_aggregate_type_check;
ALTER TABLE ai_actions ADD CONSTRAINT ai_actions_aggregate_type_check CHECK (aggregate_type IN ('task','project','tag','settings'));
