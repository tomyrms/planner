import pg from 'pg';

/** The caller owns lifecycle; no network connection is opened on import. */
export function createPool(connectionString: string): pg.Pool {
  return new pg.Pool({ connectionString, max: 10, application_name: 'planner-api' });
}
