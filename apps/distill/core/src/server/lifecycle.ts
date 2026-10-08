import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { StatePaths } from '../contracts.js';

/** Contents of `<state dir>/server.json`. Written only after the server listens. */
export interface ServerLock {
  pid: number;
  port: number;
  startedAt: string; // ISO-8601
  version: string;
}

export class ServerAlreadyRunningError extends Error {
  readonly code = 'server_already_running';
  constructor(readonly lock: ServerLock) {
    super(`a Distill server is already running (pid ${lock.pid}, port ${lock.port})`);
    this.name = 'ServerAlreadyRunningError';
  }
}

/** Version of @distill/core (core/package.json), read relative to this module (src/ or dist/). */
export function coreVersion(): string {
  try {
    const pkgPath = new URL('../../package.json', import.meta.url);
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8')) as { version?: unknown };
    return typeof pkg.version === 'string' ? pkg.version : '0.0.0';
  } catch {
    return '0.0.0';
  }
}

/** True when a process with this pid exists (EPERM means it exists but belongs to someone else). */
export function isPidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM';
  }
}

function ensureStateDir(paths: StatePaths): void {
  fs.mkdirSync(paths.dir, { recursive: true, mode: 0o700 });
}

/**
 * Return the per-user API token, creating it (32 random bytes, hex, mode 0600)
 * when absent. An existing token file with looser permissions is tightened to 0600.
 */
export function ensureToken(paths: StatePaths): string {
  ensureStateDir(paths);
  try {
    const token = randomBytes(32).toString('hex');
    fs.writeFileSync(paths.token, token, { flag: 'wx', mode: 0o600 }); // exactly 64 hex chars, no newline
    fs.chmodSync(paths.token, 0o600); // in case the umask stripped bits we did not want stripped
    return token;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err;
  }
  const stat = fs.statSync(paths.token);
  if ((stat.mode & 0o777) !== 0o600) fs.chmodSync(paths.token, 0o600);
  const token = fs.readFileSync(paths.token, 'utf8').trim();
  if (!/^[0-9a-f]{64}$/.test(token)) {
    throw new Error(`token file ${paths.token} is malformed; delete it to create a new one`);
  }
  return token;
}

/** Read the token without creating it (clients). */
export function readToken(paths: StatePaths): string | null {
  try {
    const token = fs.readFileSync(paths.token, 'utf8').trim();
    return token.length > 0 ? token : null;
  } catch {
    return null;
  }
}

/** Parse server.json, or null when absent/unreadable/malformed. */
export function readLock(paths: StatePaths): ServerLock | null {
  let raw: string;
  try {
    raw = fs.readFileSync(paths.serverLock, 'utf8');
  } catch {
    return null;
  }
  try {
    const v = JSON.parse(raw) as Partial<ServerLock>;
    if (typeof v.pid !== 'number' || typeof v.port !== 'number') return null;
    return {
      pid: v.pid,
      port: v.port,
      startedAt: typeof v.startedAt === 'string' ? v.startedAt : '',
      version: typeof v.version === 'string' ? v.version : '',
    };
  } catch {
    return null;
  }
}

/** The lock of a server whose process is alive, or null. */
export function liveServer(paths: StatePaths): ServerLock | null {
  const lock = readLock(paths);
  return lock && isPidAlive(lock.pid) ? lock : null;
}

/** Throw ServerAlreadyRunningError when a live server holds the lock; remove a stale lock. */
export function assertNoLiveServer(paths: StatePaths): void {
  const lock = readLock(paths);
  if (lock && lock.pid !== process.pid && isPidAlive(lock.pid)) throw new ServerAlreadyRunningError(lock);
  if (fs.existsSync(paths.serverLock) && (!lock || !isPidAlive(lock.pid))) removeIfUnchanged(paths.serverLock);
}

function removeIfUnchanged(file: string): void {
  try {
    fs.unlinkSync(file);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
  }
}

/**
 * Atomically create server.json for this process. The full JSON goes to a temp
 * file that is hard-linked into place, so readers never see a partial file and
 * two servers cannot both win (link fails with EEXIST). A stale lock (dead pid
 * or unparsable file) is removed and the claim retried once.
 */
export function writeLock(paths: StatePaths, lock: Omit<ServerLock, 'pid'> & { pid?: number }): ServerLock {
  ensureStateDir(paths);
  const full: ServerLock = { pid: lock.pid ?? process.pid, port: lock.port, startedAt: lock.startedAt, version: lock.version };
  const tmp = path.join(paths.dir, `server.json.${full.pid}.${randomBytes(4).toString('hex')}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(full, null, 2) + '\n', { mode: 0o600 });
  try {
    for (let attempt = 0; ; attempt++) {
      try {
        fs.linkSync(tmp, paths.serverLock);
        return full;
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== 'EEXIST' || attempt > 0) throw err;
      }
      const existing = readLock(paths);
      if (existing && existing.pid !== full.pid && isPidAlive(existing.pid)) {
        throw new ServerAlreadyRunningError(existing);
      }
      removeIfUnchanged(paths.serverLock);
    }
  } finally {
    removeIfUnchanged(tmp);
  }
}

/** Remove server.json only if it belongs to this process (or the given pid). */
export function releaseLock(paths: StatePaths, pid = process.pid): void {
  const lock = readLock(paths);
  if (lock && lock.pid === pid) removeIfUnchanged(paths.serverLock);
}
