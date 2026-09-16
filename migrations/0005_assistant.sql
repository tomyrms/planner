-- Step 3: assistant conversations, durable turns, proposals and the private AI action journal
-- (03_Data_Model.md §7, ADR-019, ADR-021). Deleting a conversation removes its messages, turns and
-- proposals; AI actions stay while their task exists (Undo within 24 h).

CREATE TABLE conversations (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  title text CHECK (title IS NULL OR length(btrim(title)) BETWEEN 1 AND 200),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id)
);

CREATE TABLE messages (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  seq bigint NOT NULL CHECK (seq >= 1),
  role text NOT NULL CHECK (role IN ('user','assistant')),
  kind text NOT NULL CHECK (kind IN ('text','voice','clarification','proposal','action_result','error')),
  text text NOT NULL CHECK (length(text) BETWEEN 1 AND 8000),
  original_transcript text CHECK (original_transcript IS NULL OR length(original_transcript) <= 8000),
  transcription_id uuid,
  turn_id uuid,
  revises_message_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  UNIQUE (conversation_id, seq),
  FOREIGN KEY (user_id, conversation_id) REFERENCES conversations(user_id, id) ON DELETE CASCADE,
  FOREIGN KEY (user_id, revises_message_id) REFERENCES messages(user_id, id) ON DELETE SET NULL (revises_message_id),
  CONSTRAINT message_kind_matches_role CHECK (
    (role = 'user' AND kind IN ('text','voice')) OR (role = 'assistant' AND kind <> 'voice')
  ),
  CONSTRAINT message_voice_has_transcription CHECK ((kind = 'voice') = (transcription_id IS NOT NULL))
);

CREATE TABLE assistant_turns (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  device_id uuid,
  conversation_id uuid NOT NULL,
  user_message_id uuid,
  request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'received' CHECK (status IN (
    'received','interpreting','awaiting_clarification','awaiting_confirmation','applying','completed','failed','cancelled')),
  reference_instant timestamptz NOT NULL,
  time_zone text NOT NULL CHECK (planner_valid_zone(time_zone)),
  unsynced_aggregate_ids uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(unsynced_aggregate_ids) <= 500),
  calendar_context jsonb CHECK (calendar_context IS NULL OR jsonb_typeof(calendar_context) = 'object'),
  provider text,
  model text,
  tool_rounds integer NOT NULL DEFAULT 0 CHECK (tool_rounds >= 0),
  input_tokens integer NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
  output_tokens integer NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
  risk_class text CHECK (risk_class IN ('R0','R1','R2','R3')),
  reply_message_id uuid,
  result jsonb CHECK (result IS NULL OR jsonb_typeof(result) = 'object'),
  error_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, conversation_id) REFERENCES conversations(user_id, id) ON DELETE CASCADE,
  FOREIGN KEY (user_id, user_message_id) REFERENCES messages(user_id, id) ON DELETE SET NULL (user_message_id),
  FOREIGN KEY (user_id, reply_message_id) REFERENCES messages(user_id, id) ON DELETE SET NULL (reply_message_id),
  CONSTRAINT turn_finished_consistent CHECK (
    (status IN ('completed','failed','cancelled','awaiting_clarification')) = (finished_at IS NOT NULL))
);

-- A user message is written before its turn; the reference is checked at commit.
ALTER TABLE messages ADD CONSTRAINT messages_turn_fk
  FOREIGN KEY (user_id, turn_id) REFERENCES assistant_turns(user_id, id)
  ON DELETE SET NULL (turn_id) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE assistant_proposals (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  turn_id uuid NOT NULL,
  plan jsonb NOT NULL CHECK (jsonb_typeof(plan) = 'array' AND jsonb_array_length(plan) BETWEEN 1 AND 25),
  plan_hash text NOT NULL CHECK (plan_hash ~ '^[0-9a-f]{64}$'),
  preview jsonb NOT NULL CHECK (jsonb_typeof(preview) = 'object'),
  risk_class text NOT NULL DEFAULT 'R2' CHECK (risk_class = 'R2'),
  target_revisions jsonb NOT NULL CHECK (jsonb_typeof(target_revisions) = 'object'),
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','confirmed','rejected','expired','superseded')),
  expires_at timestamptz NOT NULL,
  decided_at timestamptz,
  result jsonb CHECK (result IS NULL OR jsonb_typeof(result) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  UNIQUE (turn_id),
  FOREIGN KEY (user_id, turn_id) REFERENCES assistant_turns(user_id, id) ON DELETE CASCADE,
  CONSTRAINT proposal_decision_consistent CHECK ((state = 'pending') = (decided_at IS NULL)),
  CONSTRAINT proposal_result_consistent CHECK ((state = 'confirmed') = (result IS NOT NULL))
);

CREATE TABLE ai_actions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  -- One applied plan (a turn or a confirmed proposal). Undo reverts the whole group.
  group_id uuid NOT NULL,
  plan_index integer NOT NULL CHECK (plan_index BETWEEN 0 AND 24),
  turn_id uuid,
  proposal_id uuid,
  client_command_id uuid NOT NULL UNIQUE,
  aggregate_type text NOT NULL CHECK (aggregate_type IN ('task','project')),
  aggregate_id uuid NOT NULL,
  command_type text NOT NULL,
  changes jsonb NOT NULL CHECK (jsonb_typeof(changes) = 'object'),
  resulting_revision bigint NOT NULL CHECK (resulting_revision >= 1),
  undo_state text NOT NULL CHECK (undo_state IN ('available','expired','undone','conflict','not_undoable')),
  undo_expires_at timestamptz,
  undo_of_action_id uuid REFERENCES ai_actions(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  UNIQUE (group_id, plan_index),
  FOREIGN KEY (user_id, turn_id) REFERENCES assistant_turns(user_id, id) ON DELETE SET NULL (turn_id),
  FOREIGN KEY (user_id, proposal_id) REFERENCES assistant_proposals(user_id, id) ON DELETE SET NULL (proposal_id),
  CONSTRAINT action_undo_window CHECK ((undo_state = 'not_undoable') = (undo_expires_at IS NULL))
);

-- Idempotent Undo requests: the same undoRequestId always returns the same answer.
CREATE TABLE assistant_undos (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  group_id uuid NOT NULL,
  action_id uuid NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('undone','conflict','expired')),
  result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX assistant_turns_conversation_idx ON assistant_turns(conversation_id, created_at);
CREATE INDEX assistant_turns_running_idx ON assistant_turns(device_id) WHERE status IN ('received','interpreting','applying');
CREATE INDEX assistant_turns_month_idx ON assistant_turns(user_id, created_at);
CREATE INDEX assistant_proposals_pending_idx ON assistant_proposals(user_id, state) WHERE state = 'pending';
CREATE INDEX ai_actions_aggregate_idx ON ai_actions(aggregate_id, created_at);
