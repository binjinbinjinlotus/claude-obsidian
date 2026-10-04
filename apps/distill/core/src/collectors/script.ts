/**
 * Runs a custom collector script: `<interpreter> <script> <vault> <queue>` in
 * its own process group, a fresh temp working folder, stdin closed. At the
 * timeout (or Stop) the group gets SIGTERM, then SIGKILL after a grace period.
 * stdout and stderr are captured separately; the last 64 KB of each is kept.
 *
 * No sandbox: the script runs as the user with the user's permissions.
 */
import { spawn, execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { CollectorInterpreter, ScriptSource } from '../contracts.js';

export const TAIL_BYTES = 64 * 1024;
export const DEFAULT_KILL_GRACE_MS = 10_000;
/** After the script exits, how long to wait for its output pipes to close (a background child may hold them). */
const CLOSE_WAIT_MS = 2_000;

export function sha256Text(data: string | Buffer): string {
  return createHash('sha256').update(data).digest('hex');
}

/** The bytes consent is bound to: the file's content, or the stored inline code. Throws when the file can't be read. */
export function scriptBytes(source: ScriptSource): Buffer {
  return 'inline' in source ? Buffer.from(source.inline, 'utf8') : fs.readFileSync(source.file);
}

export const INLINE_EXTENSION: Record<CollectorInterpreter, string> = { zsh: 'zsh', python3: 'py', node: 'mjs', typescript: 'ts' };

/** Last `limit` bytes of a stream. */
export class Tail {
  private chunks: Buffer[] = [];
  private size = 0;
  constructor(private limit = TAIL_BYTES) {}
  push(chunk: Buffer): void {
    this.chunks.push(chunk);
    this.size += chunk.length;
    if (this.size > this.limit * 2) this.compact();
  }
  private compact(): void {
    const all = Buffer.concat(this.chunks);
    const kept = all.subarray(Math.max(0, all.length - this.limit));
    this.chunks = [Buffer.from(kept)];
    this.size = kept.length;
  }
  text(): string {
    this.compact();
    return this.chunks[0]?.toString('utf8') ?? '';
  }
}

/** Find an executable on a PATH string. */
export function findOnPath(name: string, searchPath: string): string | undefined {
  for (const dir of searchPath.split(':')) {
    if (!dir) continue;
    const full = path.join(dir, name);
    try {
      fs.accessSync(full, fs.constants.X_OK);
      if (fs.statSync(full).isFile()) return full;
    } catch {
      // next
    }
  }
  return undefined;
}

/** The user's login-shell PATH (`$SHELL -l -c 'printf %s "$PATH"'`), falling back to this process's PATH. */
export function loginShellPath(env: NodeJS.ProcessEnv = process.env): Promise<string> {
  const shell = env.SHELL && path.isAbsolute(env.SHELL) ? env.SHELL : '/bin/zsh';
  return new Promise((resolve) => {
    execFile(shell, ['-l', '-c', 'printf %s "$PATH"'], { timeout: 5_000, env }, (err, stdout) => {
      const p = String(stdout ?? '').trim();
      resolve(!err && p ? p : (env.PATH ?? '/usr/bin:/bin:/usr/sbin:/sbin'));
    });
  });
}

export interface ScriptRunInput {
  interpreterPath: string;
  /** v6: before the script path (e.g. --experimental-strip-types, or tsx's CLI). */
  interpreterArgs?: string[];
  scriptPath: string;
  vaultPath: string;
  queueDir: string;
  cwd: string;
  env: NodeJS.ProcessEnv;
  timeoutMs: number;
  killGraceMs?: number;
  onOutput?: (stream: 'stdout' | 'stderr', chunk: Buffer) => void;
}

export interface ScriptRunOutcome {
  exitCode: number | null;
  signal: string | null;
  timedOut: boolean;
  stopped: boolean;
  /** The process couldn't start (e.g. the interpreter is missing). */
  spawnError?: string;
  stdoutTail: string;
  stderrTail: string;
}

export interface ScriptHandle {
  done: Promise<ScriptRunOutcome>;
  /** Stop: SIGTERM to the group, SIGKILL after the grace period. */
  stop(): void;
}

export function startScript(input: ScriptRunInput): ScriptHandle {
  const { interpreterPath, interpreterArgs, scriptPath, vaultPath, queueDir, ...rest } = input;
  return startProcess({ ...rest, command: interpreterPath, args: [...(interpreterArgs ?? []), scriptPath, vaultPath, queueDir] });
}

export interface ProcessInput {
  command: string;
  args: string[];
  cwd: string;
  env: NodeJS.ProcessEnv;
  timeoutMs: number;
  killGraceMs?: number;
  onOutput?: (stream: 'stdout' | 'stderr', chunk: Buffer) => void;
}

/** Any process run the collector way (own process group, stdin closed, tails, timeout, Stop). Package installs use it too. */
export function startProcess(input: ProcessInput): ScriptHandle {
  const grace = input.killGraceMs ?? DEFAULT_KILL_GRACE_MS;
  const stdout = new Tail();
  const stderr = new Tail();
  let timedOut = false;
  let stopped = false;
  let exited = false;
  let killTimer: NodeJS.Timeout | undefined;
  let timeoutTimer: NodeJS.Timeout | undefined;

  const child = spawn(input.command, input.args, {
    cwd: input.cwd,
    env: input.env,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true, // its own process group, so the whole group can be signalled
  });

  const signalGroup = (sig: NodeJS.Signals) => {
    if (child.pid === undefined) return;
    try {
      process.kill(-child.pid, sig);
    } catch {
      try {
        if (!exited) child.kill(sig);
      } catch {
        // already gone
      }
    }
  };

  const terminate = () => {
    if (killTimer) return;
    signalGroup('SIGTERM');
    killTimer = setTimeout(() => signalGroup('SIGKILL'), grace);
    killTimer.unref();
  };

  child.stdout.on('data', (c: Buffer) => {
    stdout.push(c);
    input.onOutput?.('stdout', c);
  });
  child.stderr.on('data', (c: Buffer) => {
    stderr.push(c);
    input.onOutput?.('stderr', c);
  });

  timeoutTimer = setTimeout(() => {
    timedOut = true;
    terminate();
  }, input.timeoutMs);
  timeoutTimer.unref();

  const done = new Promise<ScriptRunOutcome>((resolve) => {
    let settled = false;
    const finish = (o: Omit<ScriptRunOutcome, 'stdoutTail' | 'stderrTail' | 'timedOut' | 'stopped'>) => {
      if (settled) return;
      settled = true;
      if (timeoutTimer) clearTimeout(timeoutTimer);
      resolve({ ...o, timedOut, stopped, stdoutTail: stdout.text(), stderrTail: stderr.text() });
    };
    child.once('error', (err) => {
      exited = true;
      if (killTimer) clearTimeout(killTimer);
      finish({ exitCode: null, signal: null, spawnError: err.message });
    });
    child.once('exit', (code, signal) => {
      exited = true;
      if (timeoutTimer) clearTimeout(timeoutTimer);
      // After a timeout or Stop, stragglers in the group get SIGKILL at once.
      if (timedOut || stopped) {
        if (killTimer) clearTimeout(killTimer);
        signalGroup('SIGKILL');
      }
      let closed = false;
      const onClose = () => {
        if (closed) return;
        closed = true;
        finish({ exitCode: code, signal: signal ?? null });
      };
      child.once('close', onClose);
      // A background child that keeps the pipes open must not hold the run.
      setTimeout(() => {
        child.stdout.destroy();
        child.stderr.destroy();
        onClose();
      }, CLOSE_WAIT_MS).unref();
    });
  });

  return {
    done,
    stop() {
      if (exited) return;
      stopped = true;
      terminate();
    },
  };
}
