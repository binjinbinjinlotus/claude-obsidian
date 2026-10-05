/**
 * Session continuity (docs/specs/session-continuity.md). Every resume of an AI session goes
 * through `checkResume` (before) and `resumeFailure` (after the runner refused). Both answer
 * only on positive evidence; anything else is an ordinary failure and stays one.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  CoreError,
  type AgentRunner,
  type SessionAction,
  type SessionPlace,
  type SessionStoreStatus,
  type SessionUnavailable,
  type SessionUnavailableReason,
} from '../contracts.js';
import { RunnerError } from './process.js';

// ───────────── what the runners say ─────────────

/**
 * The exact refusals of the CLIs when the session to resume does not exist, verified
 * 2026-10-05 against Claude Code 2.1.289 and codex-cli (temp config homes):
 *   claude -p --resume ID  → exit 1, empty stdout, stderr "No conversation found with session ID: ID"
 *   codex exec resume ID   → exit 1, stderr "Error: thread/resume: thread/resume failed: no rollout found for thread id ID (code -32600)"
 */
const NOT_FOUND = [/No conversation found with session ID:\s*([A-Za-z0-9-]+)/, /no rollout found for thread id\s+([A-Za-z0-9-]+)/];

/** True only when the text carries a runner's not-found refusal for exactly this session id. */
export function sessionNotFoundIn(text: string, sessionID: string): boolean {
  if (!text || !sessionID) return false;
  for (const re of NOT_FOUND) {
    const m = re.exec(text);
    if (m && m[1]!.toLowerCase() === sessionID.toLowerCase()) return true;
  }
  return false;
}

/** The runner-level error for a refused resume (RunnerError code `sessionNotFound`). */
export function sessionNotFoundError(stderr: string, sessionID: string): RunnerError | undefined {
  if (!sessionNotFoundIn(stderr, sessionID)) return undefined;
  const line = stderr.split('\n').find((l) => sessionNotFoundIn(l, sessionID))?.trim() ?? stderr.trim();
  return new RunnerError(line.slice(0, 500), 'sessionNotFound');
}

export function isSessionNotFound(err: unknown): err is RunnerError {
  return err instanceof RunnerError && err.code === 'sessionNotFound';
}

// ───────────── what the runners keep on disk ─────────────

function readableDir(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.R_OK | fs.constants.X_OK);
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** Claude Code keeps one `<id>.jsonl` per session under `<config>/projects/<cwd-slug>/`. */
export function claudeTranscriptStatus(sessionID: string, configDir: string): SessionStoreStatus {
  if (!/^[A-Za-z0-9-]+$/.test(sessionID)) return 'unknown';
  const projects = path.join(configDir, 'projects');
  if (!readableDir(projects)) return 'unknown';
  let dirs: string[];
  try {
    dirs = fs.readdirSync(projects);
  } catch {
    return 'unknown';
  }
  for (const d of dirs) {
    if (fs.existsSync(path.join(projects, d, `${sessionID}.jsonl`))) return 'present';
  }
  return 'missing';
}

/** Codex keeps `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` (and archived_sessions/). */
export function codexRolloutStatus(sessionID: string, home: string): SessionStoreStatus {
  if (!/^[A-Za-z0-9-]+$/.test(sessionID)) return 'unknown';
  const sessions = path.join(home, 'sessions');
  if (!readableDir(sessions)) return 'unknown';
  const suffix = `-${sessionID}.jsonl`.toLowerCase();
  let complete = true;
  const walk = (dir: string, depth: number): boolean => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      complete = false;
      return false;
    }
    for (const e of entries) {
      if (e.isFile() && e.name.toLowerCase().endsWith(suffix)) return true;
      if (e.isDirectory() && depth < 4 && walk(path.join(dir, e.name), depth + 1)) return true;
    }
    return false;
  };
  if (walk(sessions, 0)) return 'present';
  const archived = path.join(home, 'archived_sessions');
  if (readableDir(archived) && walk(archived, 0)) return 'present'; // archived: let codex decide
  return complete ? 'missing' : 'unknown';
}

export function claudeConfigDir(env: Record<string, string | undefined> = process.env): string {
  return env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

export function codexHome(env: Record<string, string | undefined> = process.env): string {
  return env.CODEX_HOME || path.join(os.homedir(), '.codex');
}

// ───────────── the shared helper ─────────────

const NOUN: Record<SessionPlace, string> = { batch: 'batch', conversation: 'conversation', terminal: 'batch' };

/** The plain sentence (SessionReplaceConfirm's heading, reason and next step in one line). */
export function sessionMessage(place: SessionPlace, reason: SessionUnavailableReason, runnerName: string): string {
  const why: Record<SessionUnavailableReason, string> = {
    missing: 'its history is no longer on this Mac',
    notFound: `${runnerName} couldn’t find it`,
    neverStarted: `it never started: the batch stopped before ${runnerName} read the sources`,
    runnerGone: `${runnerName} isn’t available anymore`,
  };
  const next = place === 'terminal' ? 'Distill will open a new session in Terminal instead.' : 'Distill will start a new session to continue.';
  return `This ${NOUN[place]}’s AI session isn’t available anymore (${why[reason]}). ${next}`;
}

export interface ResumeTarget {
  place: SessionPlace;
  /** The runner the session belongs to; undefined when it is no longer registered. */
  runner: AgentRunner | undefined;
  runnerID: string;
  sessionID: string;
  /** The owner knows no turn ever ran in this session (a batch cancelled before its first turn). */
  neverStarted?: boolean;
  environment?: Record<string, string | undefined>;
  action?: SessionAction;
}

function unavailable(t: ResumeTarget, reason: SessionUnavailableReason, detail: string, now = new Date()): SessionUnavailable {
  const u: SessionUnavailable = {
    place: t.place,
    reason,
    message: sessionMessage(t.place, reason, t.runner?.displayName ?? t.runnerID),
    detail,
    at: now.toISOString(),
  };
  if (t.action) u.action = t.action;
  return u;
}

/** Before a resume: null when it may go ahead (including every case that can't be told). */
export function checkResume(t: ResumeTarget): SessionUnavailable | null {
  if (!t.runner) return unavailable(t, 'runnerGone', `runner ${t.runnerID} is not installed in this core`);
  if (!t.runner.capabilities.has('sessionResume')) return unavailable(t, 'runnerGone', `${t.runner.displayName} can't resume sessions`);
  if (t.neverStarted) return unavailable(t, 'neverStarted', 'No AI turn ran in this session');
  let status: SessionStoreStatus = 'unknown';
  try {
    status = t.runner.sessionStatus?.(t.sessionID, t.environment) ?? 'unknown';
  } catch {
    status = 'unknown';
  }
  if (status === 'missing') return unavailable(t, 'missing', `${t.runner.displayName} has no transcript for session ${t.sessionID}`);
  return null;
}

/** After a resume failed: the SessionUnavailable when the runner refused it as not found, else null. */
export function resumeFailure(t: ResumeTarget, err: unknown): SessionUnavailable | null {
  if (isSessionNotFound(err)) return unavailable(t, 'notFound', err.message);
  return null;
}

/** The API error for it: 409 `session_unavailable`, the SessionUnavailable in the body. */
export function sessionUnavailableError(u: SessionUnavailable): CoreError {
  return new CoreError('session_unavailable', u.message, { ...u });
}

export function isSessionUnavailableError(err: unknown): err is CoreError {
  return err instanceof CoreError && err.code === 'session_unavailable';
}
