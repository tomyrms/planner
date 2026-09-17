-- An upload can be retried in another UTC month. Count individual admitted attempts,
-- never a lifetime attempt multiplier against the original transcription's creation date.
CREATE TABLE transcription_attempts (
  transcription_id uuid NOT NULL,
  attempt integer NOT NULL CHECK (attempt BETWEEN 1 AND 10),
  user_id uuid NOT NULL,
  duration_ms integer NOT NULL CHECK (duration_ms BETWEEN 1000 AND 120000),
  state text NOT NULL CHECK (state IN ('reserved','dispatched','released','legacy')),
  reserved_at timestamptz NOT NULL,
  budget_at timestamptz NOT NULL,
  dispatched_at timestamptz,
  released_at timestamptz,
  PRIMARY KEY (transcription_id, attempt),
  FOREIGN KEY (user_id, transcription_id) REFERENCES transcriptions(user_id, id) ON DELETE CASCADE,
  CONSTRAINT transcription_attempt_state_consistent CHECK (
    (state IN ('reserved','legacy') AND dispatched_at IS NULL AND released_at IS NULL AND budget_at = reserved_at)
    OR (state = 'dispatched' AND dispatched_at IS NOT NULL AND released_at IS NULL AND budget_at = dispatched_at)
    OR (state = 'released' AND dispatched_at IS NULL AND released_at IS NOT NULL AND budget_at = reserved_at)
  )
);
CREATE INDEX transcription_attempts_month_idx ON transcription_attempts(user_id, budget_at) WHERE state <> 'released';

-- The earlier schema did not record individual attempt dates. Preserve its accounting,
-- explicitly marked estimated, instead of fabricating past provider-dispatch timestamps.
INSERT INTO transcription_attempts (transcription_id, attempt, user_id, duration_ms, state, reserved_at, budget_at)
SELECT t.id, n.attempt, t.user_id, t.duration_ms, 'legacy', t.created_at, t.created_at
FROM transcriptions t CROSS JOIN LATERAL generate_series(1, t.attempts) AS n(attempt);
