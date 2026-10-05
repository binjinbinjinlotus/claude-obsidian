import { randomUUID } from 'node:crypto';
import path from 'node:path';
import type {
  ApprovalRequest,
  Job,
  JobActionsSummary,
  JobState,
  PermissionDenial,
  SessionUnavailable,
  TransactionPlan,
  TurnRecord,
} from '../contracts.js';
import { encodeJSON, isObject, isoDate, normalizeDate, num, preserveUnreadable, readJSON, str, strArray, writeFileAtomic, type JSONObject } from './json.js';
import { DEFAULT_RUNNER_ID } from './settings.js';

export const MAX_STORED_JOBS = 300;

export const RECOVERY_NOTE =
  'The worker quit while this turn was running. Reply to resume the same session, or reject.';

export const LABELS_RECOVERY_NOTE =
  'Distill quit while applying this. Approve again to finish (an operation that already applied is not applied twice), or reject.';

const JOB_STATES: JobState[] = ['running', 'awaitingApproval', 'completed', 'failed', 'rejected', 'cancelled'];

/** A job in these states blocks the next batch for the same vault. */
export function holdsVault(state: JobState): boolean {
  return state === 'running' || state === 'awaitingApproval';
}

export function isFinished(state: JobState): boolean {
  return !holdsVault(state);
}

export function totalCostUSD(job: Job): number {
  return job.turns.reduce((sum, t) => sum + t.costUSD, 0);
}

/** `<vault>/.vault-meta/worker/<job-id>` */
export function jobStateDirectory(job: Pick<Job, 'vaultPath' | 'id'>): string {
  return path.join(job.vaultPath, '.vault-meta', 'worker', job.id);
}

/** `job-yyyyMMdd-HHmmss-xxxx` in local time (Swift `Job.makeID`). */
export function makeJobID(date = new Date()): string {
  const p = (n: number) => String(n).padStart(2, '0');
  const stamp =
    `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}-` +
    `${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`;
  return `job-${stamp}-${randomUUID().slice(0, 4).toLowerCase()}`;
}

export function newJob(init: { id: string; kind: string; vaultPath: string; files: string[]; model: string; now: Date }): Job {
  const at = isoDate(init.now);
  return {
    id: init.id,
    kind: init.kind,
    vaultPath: init.vaultPath,
    files: init.files,
    sessionID: randomUUID().toLowerCase(),
    model: init.model,
    state: 'running',
    createdAt: at,
    updatedAt: at,
    turns: [],
    grantedTools: [],
    changedPaths: [],
  };
}

/** Swift encodes `UUID` uppercase. */
export function newTurn(author: TurnRecord['author'], text: string, now: Date, costUSD = 0): TurnRecord {
  return { id: randomUUID().toUpperCase(), date: isoDate(now), author, text, costUSD };
}

// ───────────── decode (tolerant) ─────────────

function decodePlan(v: unknown): TransactionPlan | undefined {
  if (!isObject(v)) return undefined;
  const operation_id = str(v.operation_id);
  const operation_type = str(v.operation_type);
  const approval_sha256 = str(v.approval_sha256);
  if (operation_id === undefined || operation_type === undefined || approval_sha256 === undefined) return undefined;
  return {
    operation_id,
    operation_type,
    valid: v.valid === true,
    changed_paths: strArray(v.changed_paths) ?? [],
    approval_sha256,
  };
}

function decodeDenial(v: unknown): PermissionDenial | undefined {
  if (!isObject(v)) return undefined;
  const toolName = str(v.toolName);
  if (toolName === undefined) return undefined;
  return { toolName, input: isObject(v.input) ? v.input : {} };
}

function decodeApproval(v: unknown): ApprovalRequest | undefined {
  if (!isObject(v)) return undefined;
  const a: ApprovalRequest = {
    summary: str(v.summary) ?? '',
    questions: strArray(v.questions) ?? [],
    denials: Array.isArray(v.denials) ? v.denials.map(decodeDenial).filter((d): d is PermissionDenial => !!d) : [],
    skipped: strArray(v.skipped) ?? [],
  };
  const bundlePath = str(v.bundlePath);
  if (bundlePath !== undefined) a.bundlePath = bundlePath;
  const plan = decodePlan(v.plan);
  if (plan) a.plan = plan;
  const planError = str(v.planError);
  if (planError !== undefined) a.planError = planError;
  return a;
}

function decodeTurn(v: unknown, fallback: Date): TurnRecord | undefined {
  if (!isObject(v)) return undefined;
  const author = str(v.author);
  if (author !== 'worker' && author !== 'user' && author !== 'app') return undefined;
  return {
    id: str(v.id) ?? randomUUID().toUpperCase(),
    date: normalizeDate(v.date, fallback),
    author,
    text: str(v.text) ?? '',
    costUSD: num(v.costUSD) ?? 0,
  };
}

export function decodeJob(v: unknown, now = new Date()): Job | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const vaultPath = str(v.vaultPath);
  if (id === undefined || vaultPath === undefined) return undefined;
  const state = str(v.state) as JobState | undefined;
  const createdAt = normalizeDate(v.createdAt, now);
  const job: Job = {
    id,
    kind: str(v.kind) ?? 'ingest',
    vaultPath,
    files: strArray(v.files) ?? [],
    sessionID: str(v.sessionID) ?? randomUUID().toLowerCase(),
    model: str(v.model) ?? 'sonnet',
    state: state && JOB_STATES.includes(state) ? state : 'failed',
    createdAt,
    updatedAt: normalizeDate(v.updatedAt, new Date(createdAt)),
    turns: Array.isArray(v.turns)
      ? v.turns.map((t) => decodeTurn(t, now)).filter((t): t is TurnRecord => !!t)
      : [],
    grantedTools: strArray(v.grantedTools) ?? [],
    changedPaths: strArray(v.changedPaths) ?? [],
  };
  const runnerID = str(v.runnerID);
  if (runnerID !== undefined) job.runnerID = runnerID;
  const effort = str(v.effort);
  if (effort !== undefined) job.effort = effort;
  const approval = decodeApproval(v.approval);
  if (approval) job.approval = approval;
  const operationID = str(v.operationID);
  if (operationID !== undefined) job.operationID = operationID;
  const error = str(v.error);
  if (error !== undefined) job.error = error;
  const actionsFound = decodeActionsSummary(v.actionsFound);
  if (actionsFound) job.actionsFound = actionsFound;
  // v5: folder items in the batch; absent (or not a string list) stays absent.
  const folders = strArray(v.folders);
  if (folders && folders.length > 0) job.folders = folders;
  // v6: session continuity marker (lenient: a wrong shape is dropped).
  const su = decodeSessionUnavailable(v.sessionUnavailable);
  if (su) job.sessionUnavailable = su;
  return job;
}

const PLACES: SessionUnavailable['place'][] = ['batch', 'conversation', 'terminal'];
const REASONS: SessionUnavailable['reason'][] = ['notFound', 'missing', 'neverStarted', 'runnerGone'];
const ACTIONS: NonNullable<SessionUnavailable['action']>[] = ['approve', 'reply', 'allow', 'ask', 'resume'];

export function decodeSessionUnavailable(v: unknown): SessionUnavailable | undefined {
  if (!isObject(v)) return undefined;
  const place = str(v.place) as SessionUnavailable['place'] | undefined;
  const reason = str(v.reason) as SessionUnavailable['reason'] | undefined;
  if (!place || !PLACES.includes(place) || !reason || !REASONS.includes(reason)) return undefined;
  const out: SessionUnavailable = { place, reason, message: str(v.message) ?? '', detail: str(v.detail) ?? '' };
  const action = str(v.action) as SessionUnavailable['action'] | undefined;
  if (action && ACTIONS.includes(action)) out.action = action;
  const text = str(v.text);
  if (text !== undefined) out.text = text;
  const rules = strArray(v.rules);
  if (rules) out.rules = rules;
  const at = str(v.at);
  if (at !== undefined) out.at = at;
  return out;
}

const SUMMARY_STATES: JobActionsSummary['status'][] = ['finding', 'done', 'failed', 'skipped'];

/** v3: what "Finding actions" found after the batch was applied (lenient). */
function decodeActionsSummary(v: unknown): JobActionsSummary | undefined {
  if (!isObject(v)) return undefined;
  const status = str(v.status) as JobActionsSummary['status'] | undefined;
  const byType: Record<string, number> = {};
  if (isObject(v.byType)) for (const [k, n] of Object.entries(v.byType)) if (typeof n === 'number' && Number.isFinite(n)) byType[k] = n;
  const out: JobActionsSummary = {
    status: status && SUMMARY_STATES.includes(status) ? status : 'done',
    found: num(v.found) ?? 0,
    pending: num(v.pending) ?? 0,
    added: num(v.added) ?? 0,
    byType,
  };
  const error = str(v.error);
  if (error !== undefined) out.error = error;
  const model = str(v.model);
  if (model !== undefined) out.model = model;
  return out;
}

/** Jobs saved before runners existed have no runnerID = Claude Code. */
export function jobRunnerID(job: Job): string {
  return job.runnerID ?? DEFAULT_RUNNER_ID;
}

/** A job that was mid-turn when the core quit keeps its session; the user can reply to resume it. */
export function recoverInterrupted(job: Job): Job {
  if (job.state !== 'running') return job;
  // A core-applied label job has no session; keep its reviewed plan so it can be
  // approved again (re-applying the same operation_id is an idempotent replay).
  if (job.kind === 'labels' && job.approval?.plan) {
    return {
      ...job,
      state: 'awaitingApproval',
      approval: { ...job.approval, summary: `${LABELS_RECOVERY_NOTE}\n\n${job.approval.summary}` },
    };
  }
  return {
    ...job,
    state: 'awaitingApproval',
    approval: { summary: RECOVERY_NOTE, questions: [], denials: [], skipped: [] },
  };
}

// ───────────── encode (Swift-decodable) ─────────────

function encodeApproval(a: ApprovalRequest): JSONObject {
  const out: JSONObject = {
    summary: a.summary,
    questions: [...a.questions],
    denials: a.denials.map((d) => ({ toolName: d.toolName, input: d.input })),
    skipped: [...a.skipped],
  };
  if (a.bundlePath != null) out.bundlePath = a.bundlePath;
  if (a.plan != null) {
    out.plan = {
      operation_id: a.plan.operation_id,
      operation_type: a.plan.operation_type,
      valid: a.plan.valid,
      changed_paths: [...a.plan.changed_paths],
      approval_sha256: a.plan.approval_sha256,
    };
  }
  if (a.planError != null) out.planError = a.planError;
  return out;
}

const JOB_KEYS = [
  'id', 'kind', 'vaultPath', 'files', 'sessionID', 'runnerID', 'model', 'effort', 'state',
  'createdAt', 'updatedAt', 'approval', 'turns', 'grantedTools', 'operationID', 'changedPaths', 'error', 'actionsFound', 'folders', 'sessionUnavailable',
];

/** Every non-optional key is always written; nil optionals are omitted (never `null`). */
export function encodeJob(job: Job, raw: JSONObject = {}): JSONObject {
  const out: JSONObject = { ...raw };
  for (const k of JOB_KEYS) delete out[k];
  Object.assign(out, {
    id: job.id,
    kind: job.kind,
    vaultPath: job.vaultPath,
    files: [...job.files],
    sessionID: job.sessionID,
    model: job.model,
    state: job.state,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    turns: job.turns.map((t) => ({ id: t.id, date: t.date, author: t.author, text: t.text, costUSD: t.costUSD })),
    grantedTools: [...job.grantedTools],
    changedPaths: [...job.changedPaths],
  });
  if (job.runnerID != null) out.runnerID = job.runnerID;
  if (job.effort != null) out.effort = job.effort;
  if (job.approval != null) out.approval = encodeApproval(job.approval);
  if (job.operationID != null) out.operationID = job.operationID;
  if (job.error != null) out.error = job.error;
  if (job.actionsFound != null) {
    const a = job.actionsFound;
    const summary: JSONObject = { status: a.status, found: a.found, pending: a.pending, added: a.added, byType: { ...a.byType } };
    if (a.error != null) summary.error = a.error;
    if (a.model != null) summary.model = a.model;
    out.actionsFound = summary;
  }
  if (job.folders != null && job.folders.length > 0) out.folders = [...job.folders];
  if (job.sessionUnavailable != null) {
    const u = job.sessionUnavailable;
    const m: JSONObject = { place: u.place, reason: u.reason, message: u.message, detail: u.detail };
    if (u.action != null) m.action = u.action;
    if (u.text != null) m.text = u.text;
    if (u.rules != null) m.rules = [...u.rules];
    if (u.at != null) m.at = u.at;
    out.sessionUnavailable = m;
  }
  return out;
}

export class JobStore {
  /** Last-seen raw object per job id, so unknown keys written by other builds survive. */
  private raw = new Map<string, JSONObject>();

  /** Path of the copy kept by the last load, when jobs.json had something this build couldn't read. */
  preserved?: string;

  constructor(readonly file: string) {}

  /** Newest first, capped, with interrupted jobs recovered. */
  load(now = new Date()): Job[] {
    const raw = readJSON(this.file);
    this.raw.clear();
    if (!Array.isArray(raw)) {
      this.preserved = preserveUnreadable(this.file) ?? this.preserved;
      return [];
    }
    const jobs: Job[] = [];
    let undecodable = 0;
    for (const item of raw) {
      const job = decodeJob(item, now);
      if (!job) {
        undecodable++;
        continue;
      }
      if (isObject(item)) this.raw.set(job.id, item);
      jobs.push(recoverInterrupted(job));
    }
    // A job this build can't decode would be dropped by the next save: keep the file first.
    if (undecodable > 0) this.preserved = preserveUnreadable(this.file) ?? this.preserved;
    return jobs.slice(0, MAX_STORED_JOBS);
  }

  save(jobs: Job[]): void {
    const kept = jobs.slice(0, MAX_STORED_JOBS);
    const encoded = kept.map((j) => encodeJob(j, this.raw.get(j.id)));
    writeFileAtomic(this.file, encodeJSON(encoded));
    const next = new Map<string, JSONObject>();
    kept.forEach((j, i) => next.set(j.id, encoded[i] as JSONObject));
    this.raw = next;
  }
}
