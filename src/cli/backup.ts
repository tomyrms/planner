import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync } from 'node:fs';
import { chmod, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { loadEnvFile } from 'node:process';
import { pipeline } from 'node:stream/promises';
import { parseArgs } from 'node:util';
import pg from 'pg';
import { DUMP_PATTERN, backupStamp, dumpsToPrune, missingTables } from '../infrastructure/db/backup-plan.js';
import { migrate } from '../infrastructure/db/migrate.js';
import { defaultSyncProvisioning, provisionSync } from '../infrastructure/db/provision-sync.js';
import { rotateGeneration } from '../infrastructure/db/recovery.js';

const usage = `Sauvegarde et restauration (04_Backend/05_Homelab_Deployment.md) :
  npm run backup -- create [--dir backups]
  npm run backup -- verify backups/planner-AAAAMMJJTHHMMSSZ.dump
  npm run backup -- restore backups/planner-….dump [--globals backups/planner-…-globals.sql] [--keep-devices] --confirm

create  : pg_dump -Fc + rôles (pg_dumpall --globals-only), empreintes, contrôle de lisibilité, rétention 7 + 4 hebdo.
verify  : restauration réelle dans une base temporaire, migrations vérifiées, puis suppression de cette base.
restore : api et powersync arrêtés ; l'ancienne base est renommée (preuve), le dump restauré, le stockage
          PowerSync réinitialisé, une nouvelle génération créée et, sauf --keep-devices, tous les appareils révoqués.
Les fichiers contiennent des données personnelles et des empreintes de mots de passe : permissions 600,
copie chiffrée hors machine.`;

const OWNER = 'planner_owner';
const DATABASE = 'planner';

if (existsSync('.env')) loadEnvFile('.env');

/** Runs a PostgreSQL client tool inside the Compose postgres container (same major version as the server). */
function inContainer(args: string[], io: { input?: string; output?: string } = {}): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn('docker', ['compose', 'exec', '-T', 'postgres', ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
    const chunks: Buffer[] = [];
    let errors = '';
    child.stderr.on('data', (chunk: Buffer) => { errors += chunk.toString(); });
    const pending: Promise<unknown>[] = [];
    if (io.output) pending.push(pipeline(child.stdout, createWriteStream(io.output, { flags: 'wx', mode: 0o600 })));
    else child.stdout.on('data', (chunk: Buffer) => chunks.push(chunk));
    if (io.input) pending.push(pipeline(createReadStream(io.input), child.stdin));
    else child.stdin.end();
    child.on('error', reject);
    child.on('close', (code) => {
      Promise.all(pending).then(() => {
        if (code === 0) resolve(Buffer.concat(chunks).toString());
        // Tool diagnostics can name objects but never contain passwords; keep only the last lines.
        else reject(new Error(`${args[0]} a échoué (code ${code}) : ${errors.trim().split('\n').slice(-3).join(' | ')}`));
      }, reject);
    });
  });
}

const sql = (statement: string, database = 'postgres') =>
  inContainer(['psql', '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-t', '-A', '-U', OWNER, '-d', database, '-c', statement]);

async function sha256(path: string): Promise<string> {
  const hash = createHash('sha256');
  await pipeline(createReadStream(path), hash);
  return hash.digest('hex');
}

async function checkListing(dump: string): Promise<void> {
  const listing = await inContainer(['pg_restore', '--list'], { input: dump });
  const missing = missingTables(listing);
  if (missing.length > 0) throw new Error(`Dump incomplet, tables sans données : ${missing.join(', ')}`);
}

async function checkDigest(dump: string): Promise<void> {
  const digestFile = `${dump}.sha256`;
  if (!existsSync(digestFile)) throw new Error(`Empreinte absente : ${basename(digestFile)}`);
  const expected = new Map((await readFile(digestFile, 'utf8')).trim().split('\n').map((line) => {
    const [hash, name] = line.split(/\s+/);
    return [name!, hash!] as const;
  }));
  for (const [name, hash] of expected) {
    if (await sha256(join(dirname(dump), name)) !== hash) throw new Error(`Empreinte différente : ${name}`);
  }
}

function adminUrl(database: string): string {
  const raw = process.env.DATABASE_ADMIN_URL;
  if (!raw) throw new Error('DATABASE_ADMIN_URL est requis.');
  const url = new URL(raw);
  url.pathname = `/${database}`;
  return url.toString();
}

async function withPool<T>(database: string, work: (pool: pg.Pool) => Promise<T>): Promise<T> {
  const pool = new pg.Pool({ connectionString: adminUrl(database), max: 2 });
  try { return await work(pool); } finally { await pool.end(); }
}

async function create(directory: string): Promise<void> {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const stamp = backupStamp(new Date());
  const dump = join(directory, `planner-${stamp}.dump`);
  const globals = join(directory, `planner-${stamp}-globals.sql`);
  await inContainer(['pg_dump', '-U', OWNER, '-d', DATABASE, '-Fc', '--no-password'], { output: dump });
  await inContainer(['pg_dumpall', '-U', OWNER, '--globals-only', '--no-password'], { output: globals });
  await checkListing(dump);
  const lines = [];
  for (const file of [dump, globals]) {
    await chmod(file, 0o600);
    lines.push(`${await sha256(file)}  ${basename(file)}`);
  }
  await writeFile(`${dump}.sha256`, `${lines.join('\n')}\n`, { mode: 0o600 });
  const pruned = dumpsToPrune(await readdir(directory));
  for (const name of pruned) {
    const stampOf = DUMP_PATTERN.exec(name)![1];
    for (const file of [name, `${name}.sha256`, `planner-${stampOf}-globals.sql`]) await rm(join(directory, file), { force: true });
  }
  const size = (await stat(dump)).size;
  process.stdout.write(`Sauvegarde créée : ${dump} (${Math.ceil(size / 1024)} Kio) + ${basename(globals)}\n`
    + `Lisibilité vérifiée (pg_restore --list), empreintes écrites. Anciennes sauvegardes supprimées : ${pruned.length}.\n`
    + 'À faire : copie chiffrée hors machine.\n');
}

async function verify(dump: string): Promise<void> {
  await checkDigest(dump);
  await checkListing(dump);
  const scratch = `planner_verify_${randomBytes(6).toString('hex')}`;
  await sql(`CREATE DATABASE ${scratch} OWNER ${OWNER} TEMPLATE template0`);
  try {
    await inContainer(['pg_restore', '-U', OWNER, '-d', scratch, '--exit-on-error', '--no-password'], { input: dump });
    const counts = await withPool(scratch, async (pool) => {
      await migrate(pool);
      const result = await pool.query<{ table_name: string; rows: string }>(`
        SELECT 'projects' AS table_name, count(*)::text AS rows FROM projects
        UNION ALL SELECT 'tasks', count(*)::text FROM tasks
        UNION ALL SELECT 'task_occurrences', count(*)::text FROM task_occurrences
        UNION ALL SELECT 'reminders', count(*)::text FROM reminders
        UNION ALL SELECT 'command_receipts', count(*)::text FROM command_receipts
        UNION ALL SELECT 'server_meta', count(*)::text FROM server_meta`);
      const meta = result.rows.find((row) => row.table_name === 'server_meta');
      if (meta?.rows !== '1') throw new Error('server_meta restauré invalide');
      return result.rows.map((row) => `${row.table_name}=${row.rows}`).join(', ');
    });
    process.stdout.write(`Restauration de test réussie dans une base temporaire : ${counts}. Migrations et empreintes vérifiées.\n`);
  } finally {
    await sql(`DROP DATABASE IF EXISTS ${scratch} WITH (FORCE)`);
  }
}

async function restore(dump: string, globals: string | undefined, keepDevices: boolean): Promise<void> {
  const running = (await new Promise<string>((resolve, reject) => {
    const child = spawn('docker', ['compose', '--profile', 'app', 'ps', '--status', 'running', '--services']);
    let out = '';
    child.stdout.on('data', (chunk: Buffer) => { out += chunk.toString(); });
    child.on('error', reject);
    child.on('close', (code) => code === 0 ? resolve(out) : reject(new Error('docker compose ps a échoué')));
  })).split(/\r?\n/);
  if (running.includes('api') || running.includes('powersync')) {
    throw new Error('Arrêtez d’abord les écritures : docker compose --profile app stop api powersync');
  }
  const replicationPassword = process.env.PLANNER_POWERSYNC_PASSWORD;
  const storagePassword = process.env.PLANNER_POWERSYNC_STORAGE_PASSWORD;
  if (!replicationPassword || !storagePassword) throw new Error('Mots de passe PowerSync absents du .env (npm run setup:local).');
  await checkDigest(dump);
  await checkListing(dump);
  if (globals) {
    // Existing roles make CREATE ROLE fail harmlessly; ALTER ROLE then restores their attributes and password hashes.
    await inContainer(['psql', '-X', '-q', '-U', OWNER, '-d', 'postgres'], { input: globals });
  }
  const evidence = `planner_before_restore_${backupStamp(new Date()).toLowerCase()}`;
  const exists = await sql(`SELECT 1 FROM pg_database WHERE datname = '${DATABASE}'`);
  if (exists.trim() === '1') {
    await sql(`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DATABASE}' AND pid <> pg_backend_pid()`);
    await sql(`ALTER DATABASE ${DATABASE} RENAME TO ${evidence}`);
  }
  // Slots of the previous database would retain WAL forever; PowerSync creates a new one.
  await sql("SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name LIKE 'powersync%' AND NOT active");
  await inContainer(['pg_restore', '-U', OWNER, '-d', 'postgres', '--create', '--exit-on-error', '--no-password'], { input: dump });
  await sql(`DROP DATABASE IF EXISTS ${defaultSyncProvisioning.storageDatabase} WITH (FORCE)`);
  const result = await withPool(DATABASE, async (pool) => {
    await migrate(pool);
    await provisionSync(pool, { ...defaultSyncProvisioning, replicationPassword, storagePassword });
    return rotateGeneration(pool, { revokeDevices: !keepDevices });
  });
  process.stdout.write(`Base restaurée depuis ${basename(dump)}. Nouvelle génération serveur : ${result.generation}.\n`
    + `Appareils révoqués : ${result.revokedDevices}. Stockage PowerSync réinitialisé.\n`
    + `Ancienne base conservée pour analyse : ${exists.trim() === '1' ? evidence : 'aucune'}.\n`
    + 'Suite : docker compose --profile app up -d --wait, puis npm run admin -- pair --name "iPhone".\n'
    + 'Sur l’iPhone : exporter la base locale avant d’accepter la récupération.\n');
}

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      dir: { type: 'string' }, globals: { type: 'string' }, confirm: { type: 'boolean' },
      'keep-devices': { type: 'boolean' }, help: { type: 'boolean' },
    },
  });
  const [command, file] = positionals;
  if (values.help || !command) { process.stdout.write(`${usage}\n`); return; }
  if (command === 'create' && positionals.length === 1) return create(values.dir ?? process.env.BACKUP_DIR ?? 'backups');
  if (command === 'verify' && file && positionals.length === 2) return verify(file);
  if (command === 'restore' && file && positionals.length === 2) {
    if (!values.confirm) throw new Error('Restauration destructive : relancez avec --confirm.');
    return restore(file, values.globals, values['keep-devices'] ?? false);
  }
  throw new Error(usage);
}

main().catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : 'Commande impossible.'}\n`);
  process.exitCode = 1;
});
