import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { chmod, link, mkdir, open, unlink } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { ImportError, MAX_IMPORT_BYTES } from './formats.js';
import type { ImportPlan } from './plan.js';

const run = promisify(execFile);

export async function readImportJson(path: string): Promise<{ value: unknown; sha256: string }> {
  const file = await open(path, 'r');
  let bytes: Buffer;
  try {
    const info = await file.stat();
    if (!info.isFile()) throw new ImportError('IMPORT_REGULAR_FILE_REQUIRED');
    if (info.size > MAX_IMPORT_BYTES) throw new ImportError('IMPORT_FILE_TOO_LARGE');
    const chunks: Buffer[] = [];
    let length = 0;
    // The inclusive end bounds reads even if another process grows the file after stat.
    for await (const chunk of file.createReadStream({ autoClose: false, end: MAX_IMPORT_BYTES })) {
      length += chunk.length;
      if (length > MAX_IMPORT_BYTES) throw new ImportError('IMPORT_FILE_TOO_LARGE');
      chunks.push(chunk);
    }
    bytes = Buffer.concat(chunks, length);
  } finally { await file.close(); }
  let value: unknown;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { throw new ImportError('IMPORT_INVALID_JSON'); }
  return { value, sha256: createHash('sha256').update(bytes).digest('hex') };
}

async function restrictFile(path: string) {
  if (process.platform !== 'win32') { await chmod(path, 0o600); return; }
  const system = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32');
  const { stdout } = await run(join(system, 'whoami.exe'), ['/user', '/fo', 'csv', '/nh'], { windowsHide: true });
  const sid = /\bS-1-\d+(?:-\d+)+\b/.exec(stdout)?.[0];
  if (!sid) throw new ImportError('IMPORT_PRIVATE_FILE_FAILED');
  await run(join(system, 'icacls.exe'), [path, '/inheritance:r', '/grant:r', `*${sid}:(F)`], { windowsHide: true });
}

/** Restrict an empty sibling file before writing private data; publish with no-replace semantics. */
export async function writeImportPlan(path: string, plan: ImportPlan): Promise<void> {
  const destination = resolve(path);
  const parent = dirname(destination);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const temporary = join(parent, `.planner-import-${randomUUID()}.tmp`);
  const file = await open(temporary, 'wx', 0o600);
  try {
    await restrictFile(temporary);
    const json = `${JSON.stringify(plan, null, 2)}\n`;
    if (Buffer.byteLength(json) > MAX_IMPORT_BYTES) throw new ImportError('IMPORT_FILE_TOO_LARGE');
    await file.writeFile(json, 'utf8');
    await file.sync();
    await file.close();
    await link(temporary, destination); // Fails if destination exists. ACL/mode follows the same inode.
  } catch (error) {
    if (error instanceof ImportError) throw error;
    throw new ImportError((error as { code?: string }).code === 'EEXIST' ? 'IMPORT_PLAN_FILE_EXISTS' : 'IMPORT_PRIVATE_FILE_FAILED');
  } finally {
    await file.close().catch(() => undefined);
    await unlink(temporary).catch(() => undefined);
  }
}
