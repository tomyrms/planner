-- pg_dump/pg_restore run with an empty search_path. The CHECK helper functions call one another
-- unqualified, so a dump could not be restored. Pin each helper to the schema it lives in
-- (public in production, the suite schema in tests); pg_catalog stays implicitly first.
DO $$
DECLARE
  target text := current_schema();
  signature text;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'planner_valid_date(text)',
    'planner_valid_occurrence_key(text)',
    'planner_valid_zone(text)',
    'planner_valid_temporal(date, time, text)',
    'planner_valid_recurrence(jsonb)'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %I.%s SET search_path = %I', target, signature, target);
  END LOOP;
END $$;
