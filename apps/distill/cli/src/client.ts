import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { StatePaths } from '@distill/core/contracts';
import { isPidAlive, liveServer, readToken, type ServerLock } from '@distill/core/server';

/** Error with a CLI exit code (1 = runtime error, 2 = usage) and a stable machine code. */
export class CliError extends Error {
  constructor(
    message: string,
    readonly code = 'error',
    readonly exitCode = 1,
  ) {
    super(message);
  }
}

export const usageError = (message: string) => new CliError(message, 'usage', 2);

export interface SpawnedServer {
  pid: number | undefined;
  /** Exit code once the child has exited, else null. */
  exitCode(): number | null;
  logPath: string;
  /** Byte offset of the log when this server was started (only newer output is reported). */
  logOffset?: number;
}

export type ServerSpawner = (paths: StatePaths, env: NodeJS.ProcessEnv) => SpawnedServer;

/** Node flags needed to run the entry again (tsx loader in development). Drops --test, --inspect, etc. */
export function loaderArgs(execArgv: string[]): string[] {
  const out: string[] = [];
  const withValue = new Set(['--import', '--loader', '--experimental-loader', '--require', '-r']);
  for (let i = 0; i < execArgv.length; i++) {
    const a = execArgv[i]!;
    if (withValue.has(a) && i + 1 < execArgv.length) {
      out.push(a, execArgv[++i]!);
    } else if ([...withValue].some((f) => a.startsWith(`${f}=`))) {
      out.push(a);
    }
  }
  return out;
}

/** Path of the CLI entry (main.ts in development, main.js when built). */
export function cliEntry(): string {
  const here = fileURLToPath(import.meta.url);
  return path.join(path.dirname(here), `main${path.extname(here)}`);
}

/** Start `distill serve` detached, with stdout/stderr appended to <state dir>/server.log. */
export const spawnDetachedServer: ServerSpawner = (paths, env) => {
  fs.mkdirSync(paths.dir, { recursive: true, mode: 0o700 });
  const logPath = path.join(paths.dir, 'server.log');
  let logOffset = 0;
  try {
    logOffset = fs.statSync(logPath).size;
  } catch {
    logOffset = 0;
  }
  const fd = fs.openSync(logPath, 'a', 0o600);
  let code: number | null = null;
  try {
    const child = spawn(process.execPath, [...loaderArgs(process.execArgv), cliEntry(), 'serve'], {
      detached: true,
      stdio: ['ignore', fd, fd],
      env: { ...env, DISTILL_STATE_DIR: paths.dir },
    });
    child.on('exit', (c) => (code = c ?? 1));
    child.on('error', () => (code = 1));
    child.unref();
    return { pid: child.pid, exitCode: () => code, logPath, logOffset };
  } finally {
    fs.closeSync(fd);
  }
};

function tail(file: string, offset = 0, lines = 15): string {
  try {
    return fs.readFileSync(file).subarray(offset).toString('utf8').trimEnd().split('\n').slice(-lines).join('\n');
  } catch {
    return '';
  }
}

export interface ApiClient {
  lock: ServerLock;
  request<T>(method: string, path: string, body?: unknown): Promise<T>;
}

export interface ConnectOptions {
  paths: StatePaths;
  env: NodeJS.ProcessEnv;
  spawner?: ServerSpawner;
  /** Max wait for a newly started server (default 15000 ms, env DISTILL_START_TIMEOUT_MS). */
  startTimeoutMs?: number;
  onStart?: (message: string) => void;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Find the running server (server.json + token), starting one detached when none is alive. */
export async function connect(opts: ConnectOptions): Promise<ApiClient> {
  let lock = liveServer(opts.paths);
  if (!lock || lock.port <= 0) {
    const spawner = opts.spawner ?? spawnDetachedServer;
    opts.onStart?.(`starting the Distill server (state: ${opts.paths.dir})`);
    const child = spawner(opts.paths, opts.env);
    const timeout = opts.startTimeoutMs ?? (Number(opts.env.DISTILL_START_TIMEOUT_MS) || 15_000);
    const deadline = Date.now() + timeout;
    for (;;) {
      lock = liveServer(opts.paths);
      if (lock && lock.port > 0) break;
      const code = child.exitCode();
      if (code !== null && !(lock && lock.port > 0)) {
        const log = tail(child.logPath, child.logOffset);
        throw new CliError(
          `the Distill server exited (code ${code}) before it was ready. Log: ${child.logPath}${log ? `\n${log}` : ''}`,
          'server_start_failed',
        );
      }
      if (Date.now() > deadline) {
        throw new CliError(`timed out after ${timeout} ms waiting for the Distill server. Log: ${child.logPath}`, 'server_start_timeout');
      }
      await sleep(100);
    }
  }
  const token = readToken(opts.paths);
  if (!token) throw new CliError(`no API token at ${opts.paths.token}`, 'no_token');
  const found = lock;
  return {
    lock: found,
    request: (method, p, body) => apiRequest(found, token, method, p, body),
  };
}

/** One JSON request over node:http (no client-side timeout: Ask can take minutes). */
export function apiRequest<T>(lock: ServerLock, token: string, method: string, p: string, body?: unknown): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const headers: Record<string, string | number> = { authorization: `Bearer ${token}`, accept: 'application/json' };
    if (payload !== undefined) {
      headers['content-type'] = 'application/json';
      headers['content-length'] = Buffer.byteLength(payload);
    }
    const req = http.request({ host: '127.0.0.1', port: lock.port, method, path: p, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c: Buffer) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let parsed: unknown;
        try {
          parsed = text ? JSON.parse(text) : null;
        } catch {
          return reject(new CliError(`invalid response from the Distill server (HTTP ${res.statusCode})`, 'bad_response'));
        }
        const status = res.statusCode ?? 0;
        if (status >= 200 && status < 300) return resolve(parsed as T);
        const err = (parsed as { error?: { code?: string; message?: string } } | null)?.error;
        reject(new CliError(err?.message ?? `HTTP ${status}`, err?.code ?? `http_${status}`));
      });
    });
    req.on('error', (e: NodeJS.ErrnoException) => {
      const hint = e.code === 'ECONNREFUSED' && isPidAlive(lock.pid) ? ` (pid ${lock.pid} is alive but not serving; stale server.json?)` : '';
      reject(new CliError(`cannot reach the Distill server on 127.0.0.1:${lock.port}: ${e.message}${hint}`, 'server_unreachable'));
    });
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}
