-- Voice messages (03_iOS/04_Audio_Transcription.md, ADR-006, ADR-021) and the record of
-- maintenance runs shown by /diagnostics. The audio itself is never stored in the database.

CREATE TABLE transcriptions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  device_id uuid,
  -- "erased": the text was removed (history deleted, or never used within 24 h); the row keeps the billed minutes.
  status text NOT NULL DEFAULT 'received' CHECK (status IN ('received','transcribing','completed','failed','abandoned','erased')),
  duration_ms integer NOT NULL CHECK (duration_ms BETWEEN 1000 AND 120000),
  byte_size integer NOT NULL CHECK (byte_size BETWEEN 1 AND 10485760),
  audio_sha256 text NOT NULL CHECK (audio_sha256 ~ '^[0-9a-f]{64}$'),
  languages text[] NOT NULL DEFAULT '{}' CHECK (cardinality(languages) <= 10),
  text text CHECK (text IS NULL OR length(text) BETWEEN 1 AND 8000),
  error_code text,
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 10),
  provider text,
  model text,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- Last status change; a job silent for too long was interrupted by a restart.
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  audio_deleted_at timestamptz,
  UNIQUE (user_id, id),
  CONSTRAINT transcription_text_consistent CHECK ((status = 'completed') = (text IS NOT NULL)),
  CONSTRAINT transcription_completion_consistent CHECK ((status = 'completed') = (completed_at IS NOT NULL))
);

ALTER TABLE messages ADD CONSTRAINT messages_transcription_fk
  FOREIGN KEY (user_id, transcription_id) REFERENCES transcriptions(user_id, id);

CREATE INDEX transcriptions_month_idx ON transcriptions(user_id, created_at);
CREATE INDEX transcriptions_open_idx ON transcriptions(updated_at) WHERE status IN ('received','transcribing');
CREATE INDEX messages_transcription_idx ON messages(transcription_id) WHERE transcription_id IS NOT NULL;

-- Written by the backup tool and the purge job; read by /diagnostics. No user content.
CREATE TABLE maintenance_runs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('backup','backup_verify','restore','purge','audio_cleanup')),
  outcome text NOT NULL CHECK (outcome IN ('succeeded','failed')),
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  finished_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX maintenance_runs_kind_idx ON maintenance_runs(kind, finished_at DESC);
