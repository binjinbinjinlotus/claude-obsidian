import { randomUUID } from 'node:crypto';
import path from 'node:path';
import type {
  ApprovalRequest,
  ApprovedChange,
  Job,
  JobPart,
  JobReread,
  PendingPart,
  JobActionsSummary,
  JobState,
  PermissionDenial,
  QueuedApply,
  RecoveryAttempt,
  RecoverySignature,
  RecoveryState,
  RefreshState,
  ReviewLabels,
  ReviewSource,
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
  if (Array.isArray(v.sources)) a.sources = v.sources.map(decodeReviewSource).filter((x): x is ReviewSource => !!x);
  const labels = decodeReviewLabels(v.labels);
  if (labels) a.labels = labels;
  if (isObject(v.unconfirmed)) {
    const bp = str(v.unconfirmed.bundlePath);
    const plan = decodePlan(v.unconfirmed.plan);
    if (bp !== undefined && plan) a.unconfirmed = { bundlePath: bp, plan };
  }
  if (isObject(v.rebuilt)) {
    const reason = str(v.rebuilt.reason);
    const lab = str(v.rebuilt.labels);
    if (reason === 'partial' || reason === 'remaining' || reason === 'stale') {
      a.rebuilt = { reason, pages: strArray(v.rebuilt.pages) ?? [], labels: lab === 'later' ? 'later' : 'confirm' };
    }
  }
  if (v.needsRebuild === true) a.needsRebuild = true;
  if (isObject(v.sinceApproved)) {
    const s = v.sinceApproved;
    a.sinceApproved = {
      sources: 'same', content: strArray(s.content) ?? [], added: strArray(s.added) ?? [],
      dropped: strArray(s.dropped) ?? [], bookkeeping: strArray(s.bookkeeping) ?? [],
    };
  }
  return a;
}

function stringMap(v: unknown): Record<string, string> {
  if (!isObject(v)) return {};
  return Object.fromEntries(Object.entries(v).filter((e): e is [string, string] => typeof e[1] === 'string'));
}

function sourceList(v: unknown): ReviewSource[] | undefined {
  return Array.isArray(v) ? v.map(decodeReviewSource).filter((x): x is ReviewSource => !!x) : undefined;
}

function decodePart(v: unknown): JobPart | undefined {
  if (!isObject(v)) return undefined;
  const operationID = str(v.operationID);
  if (operationID === undefined) return undefined;
  return { operationID, pages: strArray(v.pages) ?? [], labels: str(v.labels) === 'later' ? 'later' : 'confirm', at: str(v.at) ?? '' };
}

function decodePendingPart(v: unknown): PendingPart | undefined {
  if (!isObject(v)) return undefined;
  const reason = str(v.reason);
  if (reason !== 'partial' && reason !== 'remaining' && reason !== 'stale') return undefined;
  const out: PendingPart = { reason, expected: stringMap(v.expected), excluded: strArray(v.excluded) ?? [], labels: str(v.labels) === 'later' ? 'later' : 'confirm' };
  const rest = sourceList(v.rest);
  if (rest) out.rest = rest;
  if (isObject(v.restExpected)) out.restExpected = stringMap(v.restExpected);
  if (isObject(v.restFiles)) out.restFiles = stringMap(v.restFiles);
  const removed = sourceList(v.removed);
  if (removed) out.removed = removed;
  const shown = sourceList(v.shown);
  if (shown) out.shown = shown;
  const before = decodeApproval(v.before);
  if (before) out.before = before;
  const prompt = str(v.prompt);
  if (prompt !== undefined) out.prompt = prompt;
  const bundlePath = str(v.bundlePath);
  if (bundlePath !== undefined) out.bundlePath = bundlePath;
  return out;
}

const REVIEW_LABEL_STATES: ReviewLabels['state'][] = ['suggesting', 'confirming', 'confirmed', 'unconfirmed'];

function decodeReviewLabels(v: unknown): ReviewLabels | undefined {
  if (!isObject(v)) return undefined;
  const state = str(v.state) as ReviewLabels['state'] | undefined;
  if (!state || !REVIEW_LABEL_STATES.includes(state)) return undefined;
  const out: ReviewLabels = { state };
  const message = str(v.message);
  if (message !== undefined) out.message = message;
  for (const k of ['done', 'total', 'revision'] as const) {
    const n = num(v[k]);
    if (n !== undefined) out[k] = n;
  }
  return out;
}

function decodeReviewSource(v: unknown): ReviewSource | undefined {
  if (!isObject(v)) return undefined;
  const page = str(v.page);
  if (page === undefined) return undefined;
  const by = str(v.by);
  const out: ReviewSource = {
    page,
    title: str(v.title) ?? path.posix.basename(page, '.md'),
    labels: strArray(v.labels) ?? [],
    by: by === 'ai' || by === 'user' ? by : 'none',
  };
  const source = str(v.source);
  if (source !== undefined) out.source = source;
  const state = str(v.state);
  if (state === 'waiting' || state === 'suggesting' || state === 'failed') out.state = state;
  if (v.removed === true) out.removed = true;
  return out;
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
  // v6: parts applied, and the part being rebuilt.
  if (Array.isArray(v.parts)) {
    const parts = v.parts.map(decodePart).filter((x): x is JobPart => !!x);
    if (parts.length > 0) job.parts = parts;
  }
  const pendingPart = decodePendingPart(v.pendingPart);
  if (pendingPart) job.pendingPart = pendingPart;
  // v6: session continuity marker (lenient: a wrong shape is dropped).
  const su = decodeSessionUnavailable(v.sessionUnavailable);
  if (su) job.sessionUnavailable = su;
  // v8: Review after Approve (lenient: a wrong shape is dropped).
  const ac = decodeApprovedChange(v.approvedChange);
  if (ac) job.approvedChange = ac;
  const done = str(v.reviewDoneAt);
  if (done !== undefined && !Number.isNaN(Date.parse(done))) job.reviewDoneAt = done;
  // v9: re-read marker (lenient: a wrong shape is dropped).
  const reread = decodeReread(v.reread);
  if (reread) job.reread = reread;
  // review-queue.md (lenient: a wrong shape is dropped).
  const queued = decodeQueuedApply(v.queuedApply);
  if (queued) job.queuedApply = queued;
  const refresh = decodeRefresh(v.refresh);
  if (refresh) job.refresh = refresh;
  const recovery = decodeRecovery(v.recovery);
  if (recovery) job.recovery = recovery;
  return job;
}

function decodeQueuedApply(v: unknown): QueuedApply | undefined {
  if (!isObject(v) || typeof v.at !== 'string' || typeof v.order !== 'number' || typeof v.bundlePath !== 'string') return undefined;
  const mode = (x: unknown): 'confirm' | 'later' => (x === 'later' ? 'later' : 'confirm');
  const out: QueuedApply = { at: v.at, order: v.order, bundlePath: v.bundlePath, labels: mode(v.labels), carries: mode(v.carries) };
  if (typeof v.planSha256 === 'string' && v.planSha256) out.planSha256 = v.planSha256;
  return out;
}

function decodeRefresh(v: unknown): RefreshState | undefined {
  if (!isObject(v) || typeof v.since !== 'string') return undefined;
  return { since: v.since, reason: 'stale', stalePaths: strArray(v.stalePaths) ?? [], approved: v.approved === true, attempt: num(v.attempt) ?? 1 };
}

const RECOVERY_STATES: RecoveryState['state'][] = ['running', 'waiting', 'gaveUp', 'fixed'];
const SIGNATURES: RecoverySignature[] = ['stale-again', 'lock', 'plan-error', 'not-recorded', 'full-read-stop', 'session-gone', 'runner-failed', 'denial'];

function decodeRecovery(v: unknown): RecoveryState | undefined {
  if (!isObject(v)) return undefined;
  const state = str(v.state) as RecoveryState['state'] | undefined;
  const signature = str(v.signature) as RecoverySignature | undefined;
  if (!state || !RECOVERY_STATES.includes(state) || !signature || !SIGNATURES.includes(signature)) return undefined;
  const attempts: RecoveryAttempt[] = [];
  if (Array.isArray(v.attempts)) {
    for (const a of v.attempts) {
      if (!isObject(a) || typeof a.at !== 'string' || typeof a.fix !== 'string') continue;
      const att: RecoveryAttempt = {
        at: a.at,
        by: a.by === 'agent' ? 'agent' : 'rule',
        fix: a.fix as RecoveryAttempt['fix'],
        result: a.result === 'fixed' || a.result === 'running' ? a.result : 'failed',
        costUSD: typeof a.costUSD === 'number' && Number.isFinite(a.costUSD) ? a.costUSD : 0,
      };
      for (const k of ['runnerID', 'model', 'diagnosis', 'error'] as const) if (typeof a[k] === 'string') att[k] = a[k] as string;
      attempts.push(att);
    }
  }
  const out: RecoveryState = { state, signature, attempts };
  const answers = num(v.denialAnswers);
  if (answers !== undefined) out.denialAnswers = answers;
  const summary = str(v.summary);
  if (summary !== undefined) out.summary = summary;
  const wait = str(v.waitUntil);
  if (wait !== undefined) out.waitUntil = wait;
  if (v.proposal === 'new_session') out.proposal = 'new_session';
  return out;
}

function decodeReread(v: unknown): JobReread | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const group = v.group;
  const groups = v.groups;
  if (id === undefined || typeof group !== 'number' || typeof groups !== 'number') return undefined;
  const out: JobReread = { id, group, groups };
  const from = str(v.fromJob);
  if (from !== undefined) out.fromJob = from;
  const instruction = str(v.instruction);
  if (instruction !== undefined) out.instruction = instruction;
  return out;
}

function decodeApprovedChange(v: unknown): ApprovedChange | undefined {
  if (!isObject(v) || typeof v.at !== 'string' || typeof v.operationID !== 'string' || !v.operationID) return undefined;
  const n = (x: unknown) => (typeof x === 'number' && Number.isFinite(x) && x >= 0 ? Math.floor(x) : 0);
  const out: ApprovedChange = {
    at: v.at, operationID: v.operationID, changes: n(v.changes), sources: n(v.sources), concepts: n(v.concepts),
    entities: n(v.entities), otherPages: n(v.otherPages), updated: n(v.updated),
  };
  if (typeof v.sourcesApproved === 'number' && v.sourcesApproved > 0) out.sourcesApproved = Math.floor(v.sourcesApproved);
  return out;
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
  const labels = str(v.labels);
  if (labels === 'confirm' || labels === 'later') out.labels = labels;
  const pages = strArray(v.pages);
  if (pages) out.pages = pages;
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
  if (a.sinceApproved != null) out.sinceApproved = JSON.parse(JSON.stringify(a.sinceApproved)) as JSONObject;
  if (a.sources) {
    out.sources = a.sources.map((src) => {
      const o: JSONObject = { page: src.page, title: src.title, labels: [...src.labels], by: src.by };
      if (src.source != null) o.source = src.source;
      if (src.state != null) o.state = src.state;
      if (src.removed) o.removed = true;
      return o;
    });
  }
  if (a.labels != null) {
    const l: JSONObject = { state: a.labels.state };
    if (a.labels.message != null) l.message = a.labels.message;
    if (a.labels.done !== undefined) l.done = a.labels.done;
    if (a.labels.total !== undefined) l.total = a.labels.total;
    if (a.labels.revision !== undefined) l.revision = a.labels.revision;
    out.labels = l;
  }
  if (a.unconfirmed != null) out.unconfirmed = JSON.parse(JSON.stringify(a.unconfirmed)) as JSONObject;
  if (a.rebuilt != null) out.rebuilt = { reason: a.rebuilt.reason, pages: [...a.rebuilt.pages], labels: a.rebuilt.labels };
  if (a.needsRebuild === true) out.needsRebuild = true;
  return out;
}

const JOB_KEYS = [
  'id', 'kind', 'vaultPath', 'files', 'sessionID', 'runnerID', 'model', 'effort', 'state',
  'createdAt', 'updatedAt', 'approval', 'turns', 'grantedTools', 'operationID', 'changedPaths', 'error', 'actionsFound', 'folders', 'sessionUnavailable',
  'parts', 'pendingPart', 'approvedChange', 'reviewDoneAt', 'reread', 'queuedApply', 'refresh', 'recovery',
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
  if (job.parts != null && job.parts.length > 0) out.parts = JSON.parse(JSON.stringify(job.parts)) as JSONObject[];
  if (job.pendingPart != null) out.pendingPart = JSON.parse(JSON.stringify(job.pendingPart)) as JSONObject;
  if (job.sessionUnavailable != null) {
    const u = job.sessionUnavailable;
    const m: JSONObject = { place: u.place, reason: u.reason, message: u.message, detail: u.detail };
    if (u.action != null) m.action = u.action;
    if (u.text != null) m.text = u.text;
    if (u.rules != null) m.rules = [...u.rules];
    if (u.labels != null) m.labels = u.labels;
    if (u.pages != null) m.pages = [...u.pages];
    if (u.at != null) m.at = u.at;
    out.sessionUnavailable = m;
  }
  if (job.approvedChange != null) out.approvedChange = JSON.parse(JSON.stringify(job.approvedChange)) as JSONObject;
  if (job.reviewDoneAt != null) out.reviewDoneAt = job.reviewDoneAt;
  if (job.reread != null) {
    const r = job.reread;
    const m: JSONObject = { id: r.id, group: r.group, groups: r.groups };
    if (r.fromJob != null) m.fromJob = r.fromJob;
    if (r.instruction != null) m.instruction = r.instruction;
    out.reread = m;
  }
  for (const k of ['queuedApply', 'refresh', 'recovery'] as const) {
    if (job[k] != null) out[k] = JSON.parse(JSON.stringify(job[k])) as JSONObject;
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
