import { spawn } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';

export interface ProcessOutput {
  status: number;
  stdout: Buffer;
  stderr: Buffer;
}

export class RunnerError extends Error {
  constructor(
    message: string,
    readonly code:
      | 'launchFailed'
      | 'nonZeroExit'
      | 'malformedOutput'
      | 'cancelled'
      | 'unknownRunner'
      | 'unsupported'
      /** A secret (API key) the runner needs is not set. */
      | 'missingSecret'
      /** An HTTP model API answered with an error (auth, rate limit, bad request, server). */
      | 'apiError',
  ) {
    super(message);
    this.name = 'RunnerError';
  }
}

export function cancelledError(): RunnerError {
  return new RunnerError('Cancelled', 'cancelled');
}

export function isCancelled(err: unknown): boolean {
  return err instanceof RunnerError && err.code === 'cancelled';
}

/** GUI apps and services inherit a minimal PATH, so children get an explicit one. */
export function basePath(): string {
  const home = os.homedir();
  return [`${home}/.local/bin`, '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':');
}

export interface RunProcessOptions {
  executable: string;
  args: string[];
  cwd: string;
  stdin?: string | Buffer;
  environment?: Record<string, string>;
  signal?: AbortSignal;
}

/**
 * Run a subprocess, draining stdout and stderr concurrently (no pipe
 * deadlock). Abort terminates the child and rejects with a cancelled error.
 */
export function runProcess(opts: RunProcessOptions): Promise<ProcessOutput> {
  return new Promise((resolve, reject) => {
    if (opts.signal?.aborted) {
      reject(cancelledError());
      return;
    }
    const env: NodeJS.ProcessEnv = { ...process.env };
    env.PATH = `${path.dirname(opts.executable)}:${basePath()}`;
    Object.assign(env, opts.environment ?? {});
    let child;
    try {
      child = spawn(opts.executable, opts.args, { cwd: opts.cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (err) {
      reject(new RunnerError(`Could not launch: ${(err as Error).message}`, 'launchFailed'));
      return;
    }
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    let cancelled = false;
    let settled = false;
    const onAbort = () => {
      cancelled = true;
      child.kill('SIGTERM');
    };
    opts.signal?.addEventListener('abort', onAbort, { once: true });
    child.stdout.on('data', (b: Buffer) => out.push(b));
    child.stderr.on('data', (b: Buffer) => err.push(b));
    child.stdin.on('error', () => {
      /* child exited before reading stdin; reported via exit status */
    });
    child.on('error', (e) => {
      if (settled) return;
      settled = true;
      opts.signal?.removeEventListener('abort', onAbort);
      reject(cancelled ? cancelledError() : new RunnerError(`Could not launch: ${e.message}`, 'launchFailed'));
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      settled = true;
      opts.signal?.removeEventListener('abort', onAbort);
      if (cancelled) {
        reject(cancelledError());
        return;
      }
      resolve({ status: code ?? (signal ? 128 : 1), stdout: Buffer.concat(out), stderr: Buffer.concat(err) });
    });
    child.stdin.end(opts.stdin ?? '');
  });
}
