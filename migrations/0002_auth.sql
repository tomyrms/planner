-- Private authentication state: never publish these tables to a sync service.
CREATE TABLE devices (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  platform text NOT NULL CHECK (platform = 'ios'),
  os_version text NOT NULL CHECK (length(os_version) BETWEEN 1 AND 50),
  app_version text NOT NULL CHECK (length(app_version) BETWEEN 1 AND 50),
  created_at timestamptz NOT NULL,
  revoked_at timestamptz,
  UNIQUE (id, user_id)
);

CREATE TABLE auth_pairing_secrets (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  console_name text NOT NULL CHECK (length(console_name) BETWEEN 1 AND 100),
  secret_hash text NOT NULL CHECK (secret_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts BETWEEN 0 AND 5),
  consumed_at timestamptz,
  CHECK (expires_at > created_at)
);

CREATE TABLE auth_pair_rate_limits (
  ip_hash text PRIMARY KEY CHECK (ip_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz NOT NULL,
  attempts integer NOT NULL CHECK (attempts > 0)
);

CREATE TABLE auth_sessions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  device_id uuid NOT NULL,
  created_at timestamptz NOT NULL,
  revoked_at timestamptz,
  FOREIGN KEY (device_id, user_id) REFERENCES devices(id, user_id)
);
CREATE INDEX auth_sessions_device_idx ON auth_sessions(device_id);

CREATE TABLE auth_refresh_tokens (
  id uuid PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES auth_sessions(id),
  token_hash text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  rotated_at timestamptz,
  replacement_id uuid UNIQUE REFERENCES auth_refresh_tokens(id),
  retry_used_at timestamptz,
  CHECK (expires_at > issued_at),
  CHECK ((rotated_at IS NULL) = (replacement_id IS NULL)),
  CHECK (retry_used_at IS NULL OR rotated_at IS NOT NULL)
);
CREATE INDEX auth_refresh_session_idx ON auth_refresh_tokens(session_id);
