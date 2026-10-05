import { randomUUID } from 'node:crypto';
import { asScheduler } from '../activity/context.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_QUEUE_SCAN_MINUTES,
  DEFAULT_SOURCE_TAXONOMY,
  runnerSupports,
  type AddNoteRequest,
  type AddNoteResult,
  type ApprovalRequest,
  type CoreEvent,
  type DistillCore,
  type Job,
  type JobActionsSummary,
  type LabelCount,
  type LabelReview,
  type LabelSuggestion,
  type ModelSelection,
  type Progress,
  type QueueEntry,
  type QueueScanResult,
  type RunRequest,
  type RunResult,
  type RunnerRegistry,
  type Settings,
  type StatePaths,
  type StatusResponse,
  type TransactionPlan,
  type VaultProfile,
} from '../contracts.js';
import { encodeJSON, isObject, isoDate, writeFileAtomic } from '../store/json.js';
import {
  holdsVault,
  isFinished,
  jobRunnerID,
  jobStateDirectory,
  JobStore,
  makeJobID,
  MAX_STORED_JOBS,
  newJob,
  newTurn,
} from '../store/jobs.js';
import {
  activeVault,
  coreScriptPath,
  decodeSettings,
  defaultQueueDirectory,
  encodeSettings,
  labelingPreferences,
  selectionFor,
  SettingsStore,
} from '../store/settings.js';
import { uniqueDenials } from '../runners/permissions.js';
import { isCancelled, runProcess, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { defaultRegistry } from '../runners/registry.js';
import {
  JobContext,
  jobKind,
  LabelsJobKind,
  NOTE_MANIFEST_SUFFIX,
  parseWorkerStatus,
  queueConsumer,
  WorkerProtocol,
  type ParsedStatus,
  type SourceLabels,
} from './job-kinds.js';
import { CoreError } from './errors.js';
import { searchVaultPages } from './pages.js';
import { noteFileFor, readManifest, validateNote, writeManifest, writeNote, type NoteLabelState } from './notes.js';
import { draftBatchLabels } from '../labels/batch.js';
import { bodyOf, parseFrontmatter, scalarValue, setLabelProperties } from '../labels/frontmatter.js';
import { extractImageText } from './image-text.js';
import { labelSuggestSelection, suggestLabels, type SuggestInput, type SuggestOutcome } from '../labels/suggest.js';
import {
  buildLabelBundle,
  readLabelRequest,
  readPage,
  wikiPagePath,
  writeLabelRequest,
  type LabelEdit,
  type LabelRequest,
} from '../labels/transaction.js';
import { countLabels, existingLabels, normalizeLabels, pageTags, reviewLabels, scanPages, userLabels } from '../labels/vault.js';
import {
  claimItems,
  copyIntoQueue,
  inboxDir,
  moveFolderIntoDirNoOverwrite,
  moveIntoDirNoOverwrite,
  noteSetOfMember,
  noteSets,
  pendingFiles,
  queueIsInbox,
  queueList,
  readyFiles,
  scanQueueFolder,
  type FolderWalk,
  type ScanEntry,
} from './queue.js';
import { setupProblems } from './validator.js';

/**
 * Tools an ingest turn can see. Allow rules still gate them; tools outside the
 * rules stay visible so a blocked call becomes an approval the user can grant.
 */
const INGEST_AVAILABLE_TOOLS = ['Skill', 'Read', 'Glob', 'Grep', 'Edit', 'Write', 'Bash', 'WebFetch'] as const;

/** Everything in DistillCore except `ask`, plus what Ask needs from the engine. */
/** Ask (ask/) and runner admin (runners/admin.ts) are composed in index.ts. */
export type EngineOwned = Exclude<keyof DistillCore, AskOwned | RunnerAdminOwned | CompositionOwned | ActionsOwned | CollectorsOwned>;
/** Collectors: core/src/collectors (createCollectorsService). */
export type CollectorsOwned =
  | 'listCollectors' | 'getCollector' | 'createCollector' | 'updateCollector' | 'deleteCollector' | 'runCollector'
  | 'stopCollector' | 'allowCollector' | 'revokeCollector' | 'listCollectorRuns' | 'listCollected' | 'forgetCollected'
  | 'restoreCollected' | 'createCollectorFolder' | 'checkSchedule'
  | 'getCollectorScript' | 'writeCollectorScript' | 'installCollectorPackages' | 'stopCollectorInstall' | 'getCollectorInstall';
/** Actions and connections: core/src/actions (createActionsService). */
export type ActionsOwned =
  | 'listActionTypes' | 'listActions' | 'getAction' | 'createAction' | 'updateAction' | 'confirmActions'
  | 'dismissActions' | 'draftAction' | 'improveAction' | 'undoImprove' | 'performAction' | 'sendActionTo'
  | 'removeAction' | 'restoreAction' | 'deleteActionForever' | 'detectAskActions'
  | 'listConnections' | 'connect' | 'signInURL' | 'disconnect';
export type AskOwned = 'ask' | 'listConversations' | 'getConversation' | 'deleteConversation' | 'setConversationPinned' | 'cancelAsk';
/** Implemented in index.ts from the merged event stream. */
export type CompositionOwned = 'listProgress';
export type RunnerAdminOwned = 'listRunners' | 'setRunnerSecret';

/**
 * Engine methods beyond the DistillCore contract (proposed contract additions;
 * the server exposes them when present).
 */
export interface EngineExtras {
  /** Remove a finished job (completed, failed, rejected, cancelled) from the list; else invalid_state. */
  deleteJob(id: string): Promise<void>;
  /** argv that reopens the job's AI session in a terminal, or null when there is none. */
  jobResumeCommand(id: string): Promise<string[] | null>;
  /** Move a file in the active queue folder to the Trash; returns the queue afterwards. */
  removeQueueEntry(path: string): Promise<QueueEntry[]>;
  /** v3: record what "Finding actions" found for a job (actions service). */
  setJobActions?(id: string, summary: JobActionsSummary): void;
  /**
   * v3: run "Finding actions" again for an applied batch (Try again after a failure).
   * Returns the job at once (actionsFound.status "finding"); progress and action events follow.
   * Composed in index.ts.
   */
  findJobActions?(id: string): Promise<Job>;
}

/** Steps of a batch, in order (`Progress.steps`); "Suggesting labels" only when the batch has a label pre-step. */
export const BATCH_STEPS = ['Moved to inbox', 'Suggesting labels', 'Read sources', 'Drafting page changes', 'Ready for review'] as const;

export type Engine = Pick<DistillCore, EngineOwned> & EngineExtras & {
  readonly runners: RunnerRegistry;
  readonly paths: StatePaths;
  /** Resolves once no turn or inspect is in flight (tests, headless runs). */
  whenIdle(): Promise<void>;
};

export interface EngineOptions {
  paths: StatePaths;
  /** Inject runners in tests; default is the real registry. */
  runners?: RunnerRegistry;
  /** Scheduler tick in ms (default 5000). */
  tickMs?: number;
  now?: () => Date;
  /** Subprocess launcher for `transaction inspect` (tests). */
  launch?: (opts: RunProcessOptions) => Promise<ProcessOutput>;
  /** Where removeQueueEntry moves files (default ~/.Trash). */
  trashDir?: string;
  /** v3: a batch (queue-consumer job) was applied: completed with changed paths. Runs once per transition. */
  onJobApplied?: (job: Job) => void | Promise<void>;
}

export type { Settings };

function readVersion(): string {
  try {
    const here = path.dirname(fileURLToPath(import.meta.url));
    const pkg: unknown = JSON.parse(fs.readFileSync(path.resolve(here, '../../package.json'), 'utf8'));
    if (isObject(pkg) && typeof pkg.version === 'string') return pkg.version;
  } catch {
    /* fall through */
  }
  return '0.0.0';
}

const clone = <T>(v: T): T => structuredClone(v);

/** "1 source", "3 sources". */
export function plural(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? '' : 's'}`;
}

type InspectOutcome = { plan: TransactionPlan } | { error: string };

function decodePlanOutput(stdout: string): TransactionPlan | undefined {
  let v: unknown;
  try {
    v = JSON.parse(stdout);
  } catch {
    return undefined;
  }
  if (!isObject(v)) return undefined;
  const { operation_id, operation_type, valid, changed_paths, approval_sha256 } = v;
  if (typeof operation_id !== 'string' || typeof operation_type !== 'string' || typeof approval_sha256 !== 'string') {
    return undefined;
  }
  if (typeof valid !== 'boolean' || !Array.isArray(changed_paths)) return undefined;
  return {
    operation_id,
    operation_type,
    valid,
    changed_paths: changed_paths.filter((p): p is string => typeof p === 'string'),
    approval_sha256,
  };
}

/**
 * Owns the schedule, the job list and the approval/resume state machine
 * (port of Swift `WorkerEngine`). Returned as a plain object of closures:
 * `createCore` spreads it.
 *
 * Every public action does its precondition checks and the state change to
 * `running` synchronously (no await in between), so two quick calls can never
 * start two turns on one session or claim the same files twice.
 */
export function createEngine(opts: EngineOptions): Engine {
  const paths = opts.paths;
  const runners = opts.runners ?? defaultRegistry();
  const tickMs = opts.tickMs ?? 5000;
  const now = opts.now ?? (() => new Date());
  const launch = opts.launch ?? runProcess;
  const trashDir = opts.trashDir ?? path.join(os.homedir(), '.Trash');
  const version = readVersion();

  const settingsStore = new SettingsStore(paths.settings);
  const jobStore = new JobStore(paths.jobs);
  let settings: Settings = settingsStore.load();
  let jobs: Job[] = jobStore.load(now());
  let queued: ScanEntry[] = [];
  /** mtime of each queued path when the core first saw it; a later mtime = "still changing". */
  const firstSeen = new Map<string, number>();
  let lastQueueKey = '';
  /** Folder walks reused by the 5-second rescan; a full scan (Refresh, window, queue check, batch) walks again. */
  const folderCache = new Map<string, FolderWalk>();
  let lastQueueScanAt: Date | undefined;
  let nextQueueScanAt: Date | undefined;
  /** Why the last scan couldn't read the queue folder (undefined when it could, or it doesn't exist yet). */
  let queueReadProblem: string | undefined;
  let nextBatchAt: Date | undefined;
  let timer: NodeJS.Timeout | undefined;
  const controllers = new Map<string, AbortController>();
  const inflight = new Set<Promise<void>>();
  const listeners = new Set<(e: CoreEvent) => void>();
  /** Where each addNote request's manifest was written (a hint; the queue is rescanned when stale). */
  const noteRequests = new Map<string, { vaultPath: string; manifest: string }>();
  /** Empty working directory for label suggestion runs (never the vault). */
  const labelScratch = path.join(paths.dir, 'labels', 'scratch');

  // ───────────── events & persistence ─────────────

  function emit(event: CoreEvent): void {
    for (const l of [...listeners]) {
      try {
        l(event);
      } catch {
        /* a listener must not break the engine */
      }
    }
  }

  function log(level: 'info' | 'warn' | 'error', message: string): void {
    emit({ type: 'log', level, message });
  }

  function persistJobs(): void {
    try {
      jobStore.save(jobs);
    } catch (err) {
      log('error', `Could not save jobs: ${(err as Error).message}`);
    }
  }

  function track(p: Promise<void>): void {
    inflight.add(p);
    void p.finally(() => inflight.delete(p));
  }

  // ───────────── progress (loading states) ─────────────

  /** In-flight progress by key; every key that starts gets exactly one `finished` event. */
  const activeProgress = new Map<string, Progress>();
  /** Steps of each batch job (with or without the label pre-step), for later turns. */
  const jobSteps = new Map<string, string[]>();

  function publishProgress(p: Progress): void {
    emit({ type: 'progress', progress: clone(p) });
  }

  function startProgress(p: Omit<Progress, 'startedAt'> & { startedAt?: string }): void {
    const next: Progress = { ...p, startedAt: p.startedAt ?? isoDate(now()) };
    activeProgress.set(next.key, next);
    publishProgress(next);
  }

  function updateProgress(key: string, patch: Partial<Omit<Progress, 'key' | 'startedAt' | 'finished'>>): void {
    const current = activeProgress.get(key);
    if (!current) return;
    const next: Progress = { ...current, ...patch };
    activeProgress.set(key, next);
    publishProgress(next);
  }

  function finishProgress(key: string, o: { error?: string; patch?: Partial<Omit<Progress, 'key' | 'startedAt'>> } = {}): void {
    const current = activeProgress.get(key);
    if (!current) return;
    activeProgress.delete(key);
    const next: Progress = { ...current, ...o.patch, finished: true };
    if (o.error) next.error = o.error;
    publishProgress(next);
  }

  /** A job left `running`: close its progress with the outcome. */
  function finishJobProgress(job: Job): void {
    const current = activeProgress.get(job.id);
    if (!current) return;
    const patch: Partial<Progress> = {};
    if (job.state === 'awaitingApproval') patch.message = 'Ready for review';
    else if (job.state === 'completed') patch.message = current.kind === 'apply' ? 'Applied' : 'Done';
    else if (job.state === 'cancelled') patch.message = 'Cancelled';
    else if (job.state === 'failed') patch.message = 'Failed';
    else if (job.state === 'rejected') patch.message = 'Rejected';
    if (current.steps && (job.state === 'awaitingApproval' || job.state === 'completed')) {
      patch.stepIndex = current.steps.length - 1;
    }
    finishProgress(job.id, job.state === 'failed' ? { error: job.error ?? 'Failed', patch } : { patch });
  }

  function batchSteps(withLabels: boolean): string[] {
    return BATCH_STEPS.filter((s) => withLabels || s !== 'Suggesting labels');
  }

  function vaultName(vaultPath: string): string {
    return path.basename(path.resolve(vaultPath));
  }

  function selectionFields(sel: { runnerID?: string | null; model?: string | null }): Pick<Progress, 'runnerID' | 'model'> {
    return {
      ...(sel.runnerID ? { runnerID: sel.runnerID } : {}),
      ...(sel.model && sel.model !== 'none' ? { model: sel.model } : {}),
    };
  }

  /** Batch-style progress for an agent turn on a job (first turn, reply, allow). */
  function startTurnProgress(job: Job, step: (typeof BATCH_STEPS)[number], message: string): void {
    const steps = jobSteps.get(job.id) ?? batchSteps(false);
    const current = activeProgress.get(job.id);
    startProgress({
      key: job.id,
      kind: 'batch',
      message,
      steps,
      stepIndex: Math.max(0, steps.indexOf(step)),
      ...selectionFields({ runnerID: jobRunnerID(job), model: job.model }),
      // The same batch keeps its timer across steps.
      ...(current ? { startedAt: current.startedAt } : {}),
    });
  }

  // ───────────── derived state ─────────────

  const problems = () => setupProblems(settings, runners);
  const findJob = (id: string) => jobs.find((j) => j.id === id);

  function requireJob(id: string): Job {
    const job = findJob(id);
    if (!job) throw new CoreError('not_found', `Unknown job ${id}.`);
    return job;
  }

  /** Why the next batch cannot start right now, if anything. */
  function batchBlocker(): string | undefined {
    const p = problems()[0];
    if (p) return p.message;
    const vault = activeVault(settings);
    if (!vault) return 'No vault selected.';
    const holder = jobs.find((j) => j.vaultPath === vault.path && holdsVault(j.state));
    if (holder) {
      return holder.state === 'running'
        ? `Waiting for ${holder.id} to finish.`
        : `Waiting for your decision on ${holder.id}.`;
    }
    return undefined;
  }

  function vaultProfileFor(job: Job): VaultProfile {
    return (
      settings.vaults.find((v) => v.path === job.vaultPath) ?? {
        path: job.vaultPath,
        queueDirectory: defaultQueueDirectory(job.vaultPath),
      }
    );
  }

  function holdsOtherJob(job: Job): boolean {
    return jobs.some((j) => j.id !== job.id && j.vaultPath === job.vaultPath && holdsVault(j.state));
  }

  function claimedFiles(vault: VaultProfile): Set<string> {
    return new Set(jobs.filter((j) => j.vaultPath === vault.path).flatMap((j) => j.files));
  }

  // ───────────── job mutation ─────────────

  function mutate(id: string, change: (job: Job) => void): void {
    const job = findJob(id);
    if (!job) return;
    const wasCompleted = job.state === 'completed';
    change(job);
    job.updatedAt = isoDate(now());
    persistJobs();
    emit({ type: 'job', job: clone(job) });
    if (job.state !== 'running') finishJobProgress(job);
    if (!wasCompleted && job.state === 'completed' && job.kind === queueConsumer().id && job.changedPaths.length > 0 && opts.onJobApplied) {
      const hook = opts.onJobApplied;
      const applied = clone(job);
      track(Promise.resolve().then(() => hook(applied)).catch((err: unknown) => log('warn', `After apply: ${(err as Error).message}`)));
    }
  }

  function insert(job: Job): void {
    jobs.unshift(job);
    if (jobs.length > MAX_STORED_JOBS) jobs = jobs.slice(0, MAX_STORED_JOBS);
    persistJobs();
    emit({ type: 'job', job: clone(job) });
  }

  function fail(id: string, message: string): void {
    mutate(id, (j) => {
      j.state = 'failed';
      j.error = message;
      j.turns.push(newTurn('app', `Failed: ${message}`, now()));
    });
  }

  // ───────────── schedule & queue ─────────────

  function scheduleNextBatch(from: Date): void {
    nextBatchAt = new Date(from.getTime() + Math.max(1, settings.batchIntervalMinutes) * 60_000);
  }

  /** A manifest's source id as its taxonomy label ("in-person" → "In person"); free text passes through. */
  function sourceLabel(source: string): string {
    for (const group of settings.sourceTaxonomy ?? DEFAULT_SOURCE_TAXONOMY) {
      const hit = group.sources.find((s) => s.id === source);
      if (hit) return hit.label;
    }
    return source;
  }

  function queueEntries(): QueueEntry[] {
    return queueList(queued, settings.settleSeconds, now(), { firstSeen, sourceLabel });
  }

  /**
   * Top-level names a batch already took when the queue is the inbox (they stay in place): a claimed
   * file, or a folder item one of whose files was claimed. Left out before any folder walk.
   */
  function claimedNames(vault: VaultProfile): Set<string> | undefined {
    if (!queueIsInbox(vault)) return undefined;
    const names = new Set<string>();
    for (const rel of claimedFiles(vault)) if (rel.startsWith('inbox/')) names.add(rel.slice(6).split('/')[0]!);
    return names;
  }

  /** The active queue folder as queue items. `fresh` walks every folder again instead of reusing the cache. */
  function scanActive(vault: VaultProfile, fresh = false): ScanEntry[] {
    const exclude = claimedNames(vault);
    try {
      const out = scanQueueFolder(vault.queueDirectory, { cache: folderCache, fresh, ...(exclude ? { exclude } : {}) });
      queueReadProblem = undefined;
      return out;
    } catch (err) {
      queueReadProblem = `Can't read the queue folder ${vault.queueDirectory}: ${(err as Error).message}`;
      return [];
    }
  }

  function scanMinutes(): number {
    const m = settings.queueScanMinutes;
    return typeof m === 'number' && Number.isFinite(m) ? Math.max(0, Math.trunc(m)) : DEFAULT_QUEUE_SCAN_MINUTES;
  }

  function scheduleNextScan(from: Date): void {
    const m = scanMinutes();
    nextQueueScanAt = m > 0 ? new Date(from.getTime() + m * 60_000) : undefined;
  }

  function refreshQueue(o: { fresh?: boolean } = {}): void {
    const vault = activeVault(settings);
    if (!vault) {
      queued = [];
      folderCache.clear();
    } else {
      queued = scanActive(vault, o.fresh === true);
    }
    // Forget paths that left the queue (or another vault became active); remember new ones.
    const present = new Set(queued.map((e) => e.path));
    for (const p of firstSeen.keys()) if (!present.has(p)) firstSeen.delete(p);
    for (const e of queued) if (!firstSeen.has(e.path)) firstSeen.set(e.path, e.modifiedMs);
    const entries = queueEntries();
    const key = JSON.stringify(entries);
    if (key !== lastQueueKey) {
      lastQueueKey = key;
      emit({ type: 'queue', entries });
    }
  }

  /** The fields that make an entry "changed" for a scan (not settled/readyAt/changing, which move with the clock). */
  function scanKey(e: QueueEntry): string {
    const { settled: _s, readyAt: _r, changing: _c, ...rest } = e;
    return JSON.stringify(rest);
  }

  /**
   * Rescans the queue folder in full: every folder is walked again and files removed by hand drop
   * out. Compares with the list the core had before; the `queue` event goes out only when the list
   * changed, `queue.scanned` after every scan.
   */
  function scanQueueNow(trigger: QueueScanResult['trigger']): QueueScanResult {
    const before = new Map(queueEntries().map((e) => [e.path, e]));
    refreshQueue({ fresh: true });
    const entries = queueEntries();
    const after = new Map(entries.map((e) => [e.path, e]));
    const addedEntries = entries.filter((e) => !before.has(e.path));
    const removedEntries = [...before.values()].filter((e) => !after.has(e.path));
    const changedEntries = entries.filter((e) => {
      const old = before.get(e.path);
      return old !== undefined && scanKey(old) !== scanKey(e);
    });
    const result: QueueScanResult = {
      added: addedEntries.length,
      removed: removedEntries.length,
      changed: changedEntries.length,
      checkedAt: isoDate(now()),
      trigger,
      addedEntries,
      removedEntries,
      changedEntries,
      entries,
    };
    if (queueReadProblem) result.problem = queueReadProblem;
    lastQueueScanAt = now();
    scheduleNextScan(now());
    emit({ type: 'queue.scanned', result: clone(result) });
    return result;
  }

  function tick(): void {
    if (nextQueueScanAt && now() >= nextQueueScanAt) scanQueueNow('periodic');
    else refreshQueue();
    if (!settings.autoProcessEnabled || !nextBatchAt || now() < nextBatchAt) return;
    scheduleNextBatch(now());
    void processQueue().catch((err: unknown) => log('error', (err as Error).message));
  }

  // ───────────── turns ─────────────

  function runTurn(id: string, prompt: string, extra: { extraTools?: string[]; first?: boolean } = {}): void {
    const job = findJob(id);
    if (!job) return;
    const vault = vaultProfileFor(job);
    const kind = jobKind(job.kind);
    if (!kind) {
      fail(id, `Unknown job kind ${job.kind}`);
      return;
    }
    const runnerID = jobRunnerID(job);
    const runner = runners.get(runnerID);
    if (!runner) {
      fail(id, `Unknown AI runner ${runnerID}.`);
      return;
    }
    if (!runnerSupports(runner, kind.task)) {
      fail(id, `${runner.displayName} can't do ${kind.task}: it lacks what this task needs.`);
      return;
    }
    mutate(id, (j) => {
      j.state = 'running';
      delete j.error;
    });
    const ctx = new JobContext(clone(job), vault, settings);
    const controller = new AbortController();
    const request: RunRequest = {
      workingDirectory: vault.path,
      prompt,
      session: extra.first ? { start: job.sessionID } : { resume: job.sessionID },
      selection: { runnerID, model: job.model, effort: job.effort ?? null },
      allowedTools: [...kind.allowedTools(ctx), ...(extra.extraTools ?? [])],
      availableTools: [...INGEST_AVAILABLE_TOOLS],
      readableDirectories: [settings.productRoot],
      pluginDirectory: settings.productRoot,
      outputSchema: WorkerProtocol.schema,
      systemPrompt: WorkerProtocol.systemPrompt(ctx),
      environment: { CLAUDE_OBSIDIAN_VAULT: vault.path },
      signal: controller.signal,
    };
    const settingsSnapshot = clone(settings);
    const stateDir = jobStateDirectory(job);
    const turnIndex = job.turns.length;
    controllers.set(id, controller);

    track(
      (async () => {
        try {
          fs.mkdirSync(stateDir, { recursive: true });
          const result = await runner.run(request, settingsSnapshot);
          try {
            fs.writeFileSync(path.join(stateDir, `turn-${turnIndex}.json`), result.raw);
          } catch {
            /* the raw envelope is a debugging aid */
          }
          await handle(result, id, vault);
        } catch (err) {
          if (isCancelled(err) || controller.signal.aborted) {
            mutate(id, (j) => {
              j.state = 'cancelled';
              j.turns.push(newTurn('app', 'Cancelled. Reply to resume the session.', now()));
            });
          } else {
            fail(id, err instanceof Error ? err.message : String(err));
          }
        } finally {
          if (controllers.get(id) === controller) controllers.delete(id);
        }
      })(),
    );
  }

  async function handle(result: RunResult, id: string, vault: VaultProfile): Promise<void> {
    const status = parseWorkerStatus(result.structured);
    const summary = status?.summary ?? result.resultText;
    mutate(id, (j) => {
      if (result.sessionID) j.sessionID = result.sessionID;
      j.turns.push(newTurn('worker', summary, now(), result.costUSD));
    });
    if (!status) {
      if (result.isError) fail(id, result.resultText);
      else await requestDecision(id, { status: 'needs_input', summary, questions: [], changed_paths: [], skipped: [] }, result, vault);
      return;
    }
    switch (status.status) {
      case 'done':
      case 'nothing_to_do':
        if (result.denials.length > 0 && status.status !== 'done') {
          await requestDecision(id, status, result, vault);
          return;
        }
        mutate(id, (j) => {
          j.state = 'completed';
          delete j.approval;
          if (status.operation_id) j.operationID = status.operation_id;
          if (status.changed_paths.length > 0) j.changedPaths = status.changed_paths;
        });
        return;
      case 'needs_approval':
      case 'needs_input':
        await requestDecision(id, status, result, vault);
        return;
      case 'failed':
        if (result.denials.length === 0) fail(id, status.summary);
        else await requestDecision(id, status, result, vault);
        return;
    }
  }

  async function requestDecision(id: string, status: ParsedStatus, result: RunResult, vault: VaultProfile): Promise<void> {
    const request: ApprovalRequest = {
      summary: status.summary,
      questions: status.questions,
      denials: uniqueDenials(result.denials),
      skipped: status.skipped,
    };
    if (status.status === 'needs_approval') {
      if (status.bundle_path) {
        const bundle = path.resolve(vault.path, status.bundle_path);
        const job = findJob(id);
        const jobDir = job ? path.resolve(jobStateDirectory(job)) : '';
        if (jobDir && bundle.startsWith(jobDir + '/')) {
          request.bundlePath = bundle;
          const p = activeProgress.get(id);
          if (p?.kind === 'batch' && p.steps) {
            updateProgress(id, { stepIndex: Math.max(0, p.steps.indexOf('Drafting page changes')), message: 'Checking the page changes' });
          }
          const outcome = await inspect(bundle, vault);
          if ('plan' in outcome) request.plan = outcome.plan;
          else request.planError = outcome.error;
        } else {
          request.planError = `Bundle ${bundle} is outside this job's directory; refusing to inspect it.`;
        }
      } else {
        request.planError = 'Claude asked for approval but returned no bundle_path.';
      }
    }
    mutate(id, (j) => {
      j.state = 'awaitingApproval';
      j.approval = request;
    });
  }

  /** The approval screen shows what the core says, not the agent's summary of it. */
  async function inspect(bundle: string, vault: VaultProfile): Promise<InspectOutcome> {
    try {
      const out = await launch({
        executable: settings.pythonPath,
        args: [coreScriptPath(settings), 'transaction', 'inspect', bundle, '--vault', vault.path],
        cwd: vault.path,
      });
      const stdout = out.stdout.toString('utf8');
      if (out.status === 0) {
        const plan = decodePlanOutput(stdout);
        if (plan) return { plan };
      }
      const text = stdout + out.stderr.toString('utf8');
      return { error: `transaction inspect exited ${out.status}: ${text.slice(0, 4000)}` };
    } catch (err) {
      return { error: `transaction inspect could not run: ${(err as Error).message}` };
    }
  }

  // ───────────── public API ─────────────

  async function processQueue(o: { force?: boolean } = {}): Promise<Job | null> {
    const blocker = batchBlocker();
    if (blocker) {
      if (o.force) log('warn', blocker);
      return null;
    }
    const vault = activeVault(settings);
    if (!vault) return null;
    const settle = o.force ? 0 : settings.settleSeconds;
    // Notes written by addNote skip the wait; files the core can't read stay behind.
    // Folders are walked again here (never from the cache), so the wait follows the newest change inside them.
    const ready = readyFiles(scanActive(vault, true), settle, now());
    if (ready.length === 0) return null;
    let files: string[];
    let folders: string[];
    try {
      ({ files, folders } = claimItems(ready, vault, claimedFiles(vault), now()));
    } catch (err) {
      log('error', `Could not move queue files into the vault inbox: ${(err as Error).message}`);
      refreshQueue();
      return null;
    }
    refreshQueue();
    if (files.length === 0) return null;
    const kind = queueConsumer();
    const selection = selectionFor(settings, kind.task);
    const job = newJob({ id: makeJobID(now()), kind: kind.id, vaultPath: vault.path, files, model: selection.model, now: now() });
    if (folders.length > 0) job.folders = folders;
    job.runnerID = selection.runnerID;
    if (selection.effort) job.effort = selection.effort;
    // A folder item is one source: its files are listed once under it, and they get no per-file AI labels.
    const inFolder = (f: string) => folders.some((d) => f.startsWith(d + '/'));
    const loose = files.filter((f) => !inFolder(f));
    const itemCount = loose.length + folders.length;
    const batched = [
      ...loose.map((f) => `- ${f}`),
      ...folders.map((d) => `- ${d}/ (folder: ${plural(files.filter((f) => f.startsWith(d + '/')).length, 'file')})`),
    ];
    job.turns.push(newTurn('app', `Batched ${files.length} file(s):\n` + batched.join('\n'), now()));
    insert(job);
    const draft = draftBatchLabels(vault.path, loose, labelingPreferences(settings));
    jobSteps.set(job.id, batchSteps(draft.pending.length > 0));
    const reading = `Reading ${plural(itemCount, 'source')} into ${vaultName(vault.path)}`;
    const start = (plan: SourceLabels[]) => {
      if (plan.some((e) => e.labels.length > 0)) {
        try {
          writeFileAtomic(path.join(jobStateDirectory(job), 'labels.json'), encodeJSON(plan));
        } catch {
          /* a debugging aid */
        }
      }
      const current = findJob(job.id);
      if (!current) return;
      startTurnProgress(current, 'Read sources', reading);
      runTurn(job.id, kind.initialPrompt(new JobContext(clone(current), vault, settings, plan)), { first: true });
    };
    if (draft.pending.length === 0) {
      start(draft.plan);
    } else {
      // Pre-step: AI labels for queue-folder files and CLI notes nobody labeled, before the first turn.
      const controller = new AbortController();
      controllers.set(job.id, controller);
      const steps = jobSteps.get(job.id) ?? batchSteps(true);
      startProgress({
        key: job.id,
        kind: 'batch',
        message: `Suggesting labels for ${plural(draft.pending.length, 'source')}`,
        steps,
        stepIndex: steps.indexOf('Suggesting labels'),
        done: 0,
        total: draft.pending.length,
        ...selectionFields(labelSuggestSelection(settings)),
      });
      track(
        (async () => {
          let cost = 0;
          let done = 0;
          const failures: string[] = [];
          const existing = await existingLabels(vault.path).catch(() => [] as string[]);
          for (const { entry, input } of draft.pending) {
            if (controller.signal.aborted) break;
            try {
              const out = await suggestLabels(input, {
                runners,
                settings: clone(settings),
                existing,
                scratchDir: labelScratch,
                signal: controller.signal,
              });
              cost += out.costUSD;
              entry.labels = out.labels.map((l) => l.name);
            } catch (err) {
              if (controller.signal.aborted) break;
              failures.push(`${entry.file}: ${(err as Error).message}`);
            }
            done += 1;
            updateProgress(job.id, { done });
          }
          if (controllers.get(job.id) === controller) controllers.delete(job.id);
          if (controller.signal.aborted) {
            mutate(job.id, (j) => {
              j.state = 'cancelled';
              j.turns.push(newTurn('app', 'Cancelled before the first turn.', now()));
            });
            return;
          }
          const labeled = draft.pending.filter((p) => p.entry.labels.length > 0).length;
          const lines = [`Suggested labels for ${labeled} of ${draft.pending.length} file(s).`];
          if (failures.length > 0) lines.push('Left unlabeled:', ...failures.map((f) => `- ${f}`));
          mutate(job.id, (j) => j.turns.push(newTurn('app', lines.join('\n'), now(), cost)));
          if (failures.length > 0) log('warn', `Label suggestions failed for ${failures.length} file(s) in ${job.id}.`);
          start(draft.plan);
        })().catch((err: unknown) => fail(job.id, (err as Error).message)),
      );
    }
    return clone(findJob(job.id) ?? job);
  }

  async function approve(id: string): Promise<void> {
    const job = requireJob(id);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${id} is not awaiting approval.`);
    const plan = job.approval?.plan;
    const bundle = job.approval?.bundlePath;
    if (!plan || !plan.valid || !bundle) throw new CoreError('invalid_state', `Job ${id} has no valid plan to approve.`);
    const applying = (agent: boolean) =>
      startProgress({
        key: id,
        kind: 'apply',
        message: `Applying ${plural(plan.changed_paths.length, 'change')}`,
        ...(agent ? selectionFields({ runnerID: jobRunnerID(job), model: job.model }) : {}),
      });
    if (coreApplies(job)) {
      mutate(id, (j) => {
        j.state = 'running';
        delete j.error;
        j.turns.push(newTurn('user', `Approved ${plan.operation_id} (${plan.approval_sha256.slice(0, 12)}…)`, now()));
      });
      applying(false);
      track(applyInCore(id, plan, bundle));
      return;
    }
    const ctx = new JobContext(clone(job), vaultProfileFor(job), settings);
    // Only the exact approved command is permitted, and only for this turn.
    const applyRule = `Bash(${WorkerProtocol.applyCommand(ctx, plan, bundle)})`;
    mutate(id, (j) => j.turns.push(newTurn('user', `Approved ${plan.operation_id} (${plan.approval_sha256.slice(0, 12)}…)`, now())));
    applying(true);
    runTurn(id, WorkerProtocol.approvedPrompt(ctx, plan, bundle), { extraTools: [applyRule] });
  }

  async function reply(id: string, text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) throw new CoreError('invalid_request', 'Reply text is empty.');
    const job = requireJob(id);
    requireSession(job);
    if (job.state === 'running') throw new CoreError('busy', `Job ${id} is running.`);
    if (job.state !== 'awaitingApproval' && holdsOtherJob(job)) throw new CoreError('busy', 'Another job holds this vault.');
    mutate(id, (j) => j.turns.push(newTurn('user', trimmed, now())));
    const current = findJob(id);
    if (current) startTurnProgress(current, 'Drafting page changes', 'Working on your reply');
    runTurn(id, WorkerProtocol.replyPrompt(trimmed));
  }

  /** Grants rules for previously denied calls for the rest of this job, then resumes. */
  async function allow(id: string, rules: string[]): Promise<void> {
    const clean = rules.map((r) => r.trim()).filter(Boolean);
    if (clean.length === 0) throw new CoreError('invalid_request', 'No rules to allow.');
    const job = requireJob(id);
    requireSession(job);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${id} is not awaiting approval.`);
    mutate(id, (j) => {
      j.grantedTools = [...new Set([...j.grantedTools, ...clean])].sort();
      j.turns.push(newTurn('user', 'Allowed:\n' + clean.map((r) => `- ${r}`).join('\n'), now()));
    });
    const current = findJob(id);
    if (current) startTurnProgress(current, 'Drafting page changes', 'Continuing with the tools you allowed');
    runTurn(id, WorkerProtocol.grantedPrompt(clean));
  }

  async function reject(id: string): Promise<void> {
    const job = requireJob(id);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${id} is not awaiting approval.`);
    mutate(id, (j) => {
      j.state = 'rejected';
      j.turns.push(newTurn('user', 'Rejected. Inbox files are kept; nothing was applied.', now()));
    });
  }

  /** Stops a running turn; the job becomes `cancelled` (reply resumes it). No-op otherwise. */
  async function cancel(id: string): Promise<void> {
    requireJob(id);
    controllers.get(id)?.abort();
  }

  /** Removes a finished job from the list (its job directory in the vault is kept). */
  async function deleteJob(id: string): Promise<void> {
    const job = requireJob(id);
    if (!isFinished(job.state)) {
      throw new CoreError('invalid_state', `Job ${id} is ${job.state}; only finished jobs can be deleted.`);
    }
    // When the queue is the vault inbox, a job's files count as taken only while the job is
    // listed; deleting it would put files still in inbox/ back into the next batch.
    const vault = vaultProfileFor(job);
    if (queueIsInbox(vault)) {
      const stillThere = job.files.filter((f) => f.startsWith('inbox/') && fs.existsSync(path.join(vault.path, f)));
      if (stillThere.length > 0) {
        throw new CoreError(
          'invalid_state',
          `Deleting ${id} would put ${plural(stillThere.length, 'file')} in inbox/ back into the queue (${stillThere.join(', ')}). Move them out of the inbox first.`,
        );
      }
    }
    jobs = jobs.filter((j) => j.id !== id);
    jobSteps.delete(id);
    persistJobs();
    // Proposed contract: a `job` event with deleted: true (mirrors `conversation`).
    emit({ type: 'job', job: clone(job), deleted: true } as CoreEvent);
    refreshQueue();
  }

  async function jobResumeCommand(id: string): Promise<string[] | null> {
    const job = requireJob(id);
    if (jobKind(job.kind)?.appliesInCore) return null; // no AI session
    const runner = runners.get(jobRunnerID(job));
    const argv = runner?.resumeCommand?.(job.sessionID, job.model, clone(settings));
    return argv && argv.length > 0 ? argv : null;
  }

  /** Moves a pending file of the active queue folder to the Trash (a note's manifest goes with it). */
  async function removeQueueEntry(file: string): Promise<QueueEntry[]> {
    if (typeof file !== 'string' || file.trim() === '') throw new CoreError('invalid_request', 'path is required.');
    const vault = activeVault(settings);
    if (!vault) throw new CoreError('no_vault', 'No vault selected.');
    const abs = path.resolve(file);
    let st: fs.Stats;
    try {
      st = fs.lstatSync(abs);
    } catch {
      throw new CoreError('not_found', `${file} is not in the queue.`);
    }
    if (!st.isFile() && !st.isDirectory()) throw new CoreError('invalid_request', `${file} is not a regular file or folder.`);
    const real = (p: string) => {
      try {
        return fs.realpathSync(p);
      } catch {
        return path.resolve(p);
      }
    };
    const name = path.basename(abs);
    if (real(path.dirname(abs)) !== real(vault.queueDirectory) || name.startsWith('.')) {
      throw new CoreError('invalid_request', `${file} is not in the active queue folder (${vault.queueDirectory}).`);
    }
    const taken = (n: string) => queueIsInbox(vault) && claimedFiles(vault).has('inbox/' + n);
    if (taken(name)) throw new CoreError('invalid_state', `A batch already took ${name}.`);
    if (st.isDirectory()) {
      // A folder item goes to the Trash whole.
      fs.mkdirSync(trashDir, { recursive: true });
      moveFolderIntoDirNoOverwrite(abs, trashDir);
      refreshQueue();
      return queueEntries();
    }
    // Paths as the scanner sees them (the queue folder may be reached through a symlink).
    refreshQueue();
    const scanned = path.join(path.resolve(vault.queueDirectory), name);
    const owner = noteSetOfMember(queued, scanned);
    if (owner) {
      // Removing a manifest or image alone would break the note: remove the note instead.
      throw new CoreError('invalid_request', `${name} belongs to the note ${path.basename(owner.note)}; remove the note instead.`);
    }
    const targets = [abs];
    const set = noteSets(queued).find((s) => s.note === scanned);
    if (set) {
      // Members first, the .md last: a failure part-way leaves files the queue still lists.
      const members = [...set.images, set.manifest].filter((p) => !taken(path.basename(p)));
      targets.unshift(...members.map((p) => path.join(path.dirname(abs), path.basename(p))));
    } else if (name.toLowerCase().endsWith('.md')) {
      const manifest = abs.slice(0, -'.md'.length) + NOTE_MANIFEST_SUFFIX;
      const m = fs.lstatSync(manifest, { throwIfNoEntry: false });
      if (m?.isFile() && !taken(path.basename(manifest))) targets.unshift(manifest);
    }
    fs.mkdirSync(trashDir, { recursive: true });
    for (const t of targets) moveIntoDirNoOverwrite(t, trashDir);
    refreshQueue();
    return queueEntries();
  }

  async function updateSettings(patch: Partial<Settings>): Promise<Settings> {
    const before = settings;
    // Round-trip through the tolerant codec so mistyped values fall back to defaults.
    // A null optional (activeVaultPath, nodePath) clears it.
    const merged = decodeSettings({ ...encodeSettings(settings), ...(patch as Record<string, unknown>) });
    merged.batchIntervalMinutes = Math.max(1, merged.batchIntervalMinutes);
    merged.settleSeconds = Math.max(0, merged.settleSeconds);
    settings = merged;
    settingsStore.save(settings);
    if (
      settings.batchIntervalMinutes !== before.batchIntervalMinutes ||
      activeVault(settings)?.path !== activeVault(before)?.path
    ) {
      scheduleNextBatch(now());
    }
    if (settings.queueScanMinutes !== before.queueScanMinutes) scheduleNextScan(now());
    emit({ type: 'settings', settings: clone(settings) });
    refreshQueue();
    return clone(settings);
  }

  async function addQueueFiles(files: string[]): Promise<QueueEntry[]> {
    const vault = activeVault(settings);
    if (!vault) throw new CoreError('no_vault', 'No vault selected.');
    const copies = new Set(copyIntoQueue(files.map((f) => path.resolve(f)), vault.queueDirectory));
    refreshQueue();
    return queueEntries().filter((e) => copies.has(e.path));
  }

  function resolveVault(vaultPath?: string | null): VaultProfile {
    const vault = vaultPath
      ? settings.vaults.find((v) => path.resolve(v.path) === path.resolve(vaultPath))
      : activeVault(settings);
    if (!vault) {
      throw vaultPath ? new CoreError('invalid_request', `Unknown vault ${vaultPath}.`) : new CoreError('no_vault', 'No vault selected.');
    }
    return vault;
  }

  function cleanLabels(raw: unknown): string[] {
    if (!Array.isArray(raw)) throw new CoreError('invalid_request', 'labels must be an array of strings.');
    try {
      return userLabels(raw);
    } catch (err) {
      throw new CoreError('invalid_request', (err as Error).message);
    }
  }

  async function suggestFor(
    vault: VaultProfile,
    input: SuggestInput,
    o: { signal?: AbortSignal; selection?: ModelSelection; existing?: string[] } = {},
  ): Promise<SuggestOutcome> {
    const { existing: known, ...rest } = o;
    const existing = known ?? (await existingLabels(vault.path));
    return suggestLabels(input, { runners, settings: clone(settings), existing, scratchDir: labelScratch, ...rest });
  }

  // ───────────── labels: queued notes ─────────────

  type Located = { state: 'queued' | 'claimed'; vault: VaultProfile; manifest: string };

  /** Find a note's manifest by requestID: still in a queue (labelNote may change it) or already claimed by a batch. */
  function locateRequest(requestID: string): Located | undefined {
    const claimed = (vault: VaultProfile, manifest: string) =>
      queueIsInbox(vault) && claimedFiles(vault).has('inbox/' + path.basename(manifest));
    const hint = noteRequests.get(requestID);
    if (hint && readManifest(hint.manifest)?.requestID === requestID) {
      const vault = settings.vaults.find((v) => v.path === hint.vaultPath);
      if (vault && path.dirname(hint.manifest) === path.resolve(vault.queueDirectory)) {
        return { state: claimed(vault, hint.manifest) ? 'claimed' : 'queued', vault, manifest: hint.manifest };
      }
    }
    const scan = (dir: string) =>
      pendingFiles(dir)
        .filter((e) => e.name.endsWith(NOTE_MANIFEST_SUFFIX))
        .find((e) => readManifest(e.path)?.requestID === requestID)?.path;
    for (const vault of settings.vaults) {
      const found = scan(path.resolve(vault.queueDirectory));
      if (found) return { state: claimed(vault, found) ? 'claimed' : 'queued', vault, manifest: found };
    }
    for (const vault of settings.vaults) {
      const found = scan(inboxDir(vault));
      if (found) return { state: 'claimed', vault, manifest: found };
    }
    return undefined;
  }

  async function addNote(req: AddNoteRequest): Promise<AddNoteResult> {
    const vault = resolveVault(req.vaultPath);
    const { title } = validateNote(req); // fail before any AI spend
    const confirmed = req.labels !== undefined ? cleanLabels(req.labels) : undefined;
    const origin = req.origin === 'cli' ? 'cli' : 'app';
    const suggest = confirmed ? 'none' : (req.suggest ?? 'background');
    if (suggest !== 'wait' && suggest !== 'background' && suggest !== 'none') {
      throw new CoreError('invalid_request', `Unknown suggest mode ${String(suggest)}.`);
    }
    const input: SuggestInput = { title, text: req.text };
    if (req.source) input.source = req.source;
    if (req.sourceRef) input.sourceRef = req.sourceRef;
    const state: NoteLabelState = { requestID: randomUUID().toLowerCase(), origin };
    if (confirmed) state.labels = confirmed;
    let costUSD: number | undefined;
    if (suggest === 'wait') {
      // Suggest first, then write: the batch can never pick the note up mid-wait.
      const outcome = await suggestWithProgress(vault, state.requestID, input);
      if ('labels' in outcome) {
        state.suggestedLabels = outcome.labels;
        costUSD = outcome.costUSD;
      } else {
        state.suggestError = outcome.error;
      }
    }
    const result = writeNote(req, vault, now(), state);
    const manifest = result.queued.find((q) => q.endsWith(NOTE_MANIFEST_SUFFIX));
    if (manifest) noteRequests.set(state.requestID, { vaultPath: vault.path, manifest });
    if (vault.path === activeVault(settings)?.path) refreshQueue();
    if (suggest === 'background') track(suggestInBackground(vault, state.requestID, result.notePath, input));
    const out: AddNoteResult = { ...result, requestID: state.requestID };
    if (state.suggestedLabels) out.suggestedLabels = state.suggestedLabels;
    if (state.suggestError) out.suggestError = state.suggestError;
    if (costUSD !== undefined) out.costUSD = costUSD;
    return out;
  }

  /** One note's label suggestion, wrapped in `labelSuggest` progress (key `note:<requestID>`). Never throws. */
  async function suggestWithProgress(
    vault: VaultProfile,
    requestID: string,
    input: SuggestInput,
  ): Promise<{ labels: LabelSuggestion[]; costUSD: number } | { error: string }> {
    const key = `note:${requestID}`;
    startProgress({ key, kind: 'labelSuggest', message: 'Suggesting labels', ...selectionFields(labelSuggestSelection(settings)) });
    let outcome: { labels: LabelSuggestion[]; costUSD: number } | { error: string } = { error: 'The label suggestion did not finish.' };
    try {
      const out = await suggestFor(vault, input);
      outcome = { labels: out.labels, costUSD: out.costUSD };
    } catch (err) {
      outcome = { error: (err as Error).message };
    } finally {
      finishProgress(key, 'error' in outcome ? { error: outcome.error } : {});
    }
    return outcome;
  }

  async function suggestInBackground(vault: VaultProfile, requestID: string, notePath: string, input: SuggestInput): Promise<void> {
    let labels: LabelSuggestion[] = [];
    let error: string | undefined;
    let costUSD: number | undefined;
    const outcome = await suggestWithProgress(vault, requestID, input);
    if ('labels' in outcome) {
      labels = outcome.labels;
      costUSD = outcome.costUSD;
    } else {
      error = outcome.error;
    }
    // Check and write in one synchronous step so a batch can't claim the note in between.
    const where = locateRequest(requestID);
    if (where?.state === 'queued') {
      const m = readManifest(where.manifest);
      if (m) {
        if (error) m.suggestError = error;
        else {
          m.suggestedLabels = labels;
          delete m.suggestError;
        }
        writeManifest(where.manifest, m);
      }
    } else if (!error) {
      error = 'The batch already picked this note up.';
    }
    emit({
      type: 'labelSuggestions',
      requestID,
      notePath,
      labels,
      ...(error ? { error } : {}),
      ...(costUSD !== undefined ? { costUSD } : {}),
    });
  }

  async function labelNote(requestID: string, labels: string[]): Promise<{ notePath: string; labels: string[] }> {
    const clean = cleanLabels(labels);
    const where = locateRequest(requestID);
    if (!where) throw new CoreError('not_found', `No queued note for request ${requestID}.`);
    if (where.state === 'claimed') {
      throw new CoreError('invalid_state', 'The batch already picked this note up; change its labels in Labels.');
    }
    const m = readManifest(where.manifest);
    if (!m) throw new CoreError('not_found', `No queued note for request ${requestID}.`);
    m.labels = clean; // [] = confirmed: no labels (no AI fallback)
    writeManifest(where.manifest, m);
    const notePath = noteFileFor(where.manifest);
    const page = readPage(path.dirname(notePath), path.basename(notePath));
    if (typeof page !== 'string') {
      const next = setLabelProperties(page.text, { tags: clean });
      if (next !== page.text) writeFileAtomic(notePath, next);
    }
    if (where.vault.path === activeVault(settings)?.path) refreshQueue();
    return { notePath, labels: clean };
  }

  // ───────────── labels: vault pages ─────────────

  async function listLabels(vaultPath?: string): Promise<LabelCount[]> {
    return countLabels(await scanPages(resolveVault(vaultPath).path));
  }

  async function labelReview(vaultPath?: string): Promise<LabelReview> {
    return reviewLabels(await scanPages(resolveVault(vaultPath).path));
  }

  function requireFreeVault(vault: VaultProfile): void {
    const holder = jobs.find((j) => j.vaultPath === vault.path && holdsVault(j.state));
    if (holder) throw new CoreError('busy', `${holder.id} holds this vault; finish or reject it first.`);
  }

  function pagePaths(raw: unknown): string[] {
    if (!Array.isArray(raw) || raw.length === 0) throw new CoreError('invalid_request', 'No pages given.');
    const out: string[] = [];
    for (const r of raw) {
      const p = typeof r === 'string' ? wikiPagePath(r) : undefined;
      if (!p) throw new CoreError('invalid_request', `Not a wiki page path: ${String(r)}`);
      if (out.includes(p)) throw new CoreError('invalid_request', `Page listed twice: ${p}`);
      out.push(p);
    }
    return out;
  }

  function newLabelJob(vault: VaultProfile, files: string[], text: string, selection?: ModelSelection): Job {
    const job = newJob({
      id: makeJobID(now()),
      kind: LabelsJobKind.id,
      vaultPath: vault.path,
      files,
      model: selection?.model ?? 'none',
      now: now(),
    });
    if (selection) {
      job.runnerID = selection.runnerID;
      if (selection.effort) job.effort = selection.effort;
    }
    job.turns.push(newTurn('app', text, now()));
    return job;
  }

  function describeEdits(request: LabelRequest): string {
    const head = request.mode === 'confirm' ? 'Confirm labels' : 'AI labels to review later (unconfirmed)';
    return (
      `${head}:\n` +
      request.edits.map((e) => `- ${e.path}: ${e.labels.length > 0 ? e.labels.join(', ') : '(no labels)'}`).join('\n')
    );
  }

  /**
   * Build the bundle for a label job from the pages as they are now, inspect
   * it with the core, and wait for approval. A fresh operation_id each time:
   * the core treats a reused one as a replay.
   */
  async function planLabelJob(id: string, request: LabelRequest, extraSkipped: string[] = []): Promise<void> {
    const job = findJob(id);
    if (!job) return;
    const vault = vaultProfileFor(job);
    const dir = jobStateDirectory(job);
    fs.mkdirSync(dir, { recursive: true });
    writeLabelRequest(path.join(dir, 'request.json'), request);
    const built = buildLabelBundle(vault.path, request.edits, `${job.id}-${randomUUID().slice(0, 8).toLowerCase()}`);
    const skipped = [...extraSkipped, ...built.skipped];
    if (built.bundle.writes.length === 0) {
      mutate(id, (j) => {
        j.state = 'completed';
        delete j.approval;
        j.turns.push(newTurn('app', ['Nothing to change.', ...skipped.map((s) => `- ${s}`)].join('\n'), now()));
      });
      return;
    }
    const bundlePath = path.join(dir, 'bundle.json');
    writeFileAtomic(bundlePath, encodeJSON(built.bundle));
    const outcome = await inspect(bundlePath, vault);
    const changing = new Set(built.bundle.writes.map((w) => w.path));
    const approval: ApprovalRequest = {
      summary: describeEdits({ ...request, edits: request.edits.filter((e) => changing.has(e.path)) }),
      questions: [],
      denials: [],
      skipped,
      bundlePath,
    };
    if ('plan' in outcome) approval.plan = outcome.plan;
    else approval.planError = outcome.error;
    mutate(id, (j) => {
      j.state = 'awaitingApproval';
      j.approval = approval;
    });
  }

  async function confirmLabels(items: { path: string; labels: string[] }[], vaultPath?: string): Promise<Job> {
    if (!Array.isArray(items) || items.length === 0) throw new CoreError('invalid_request', 'No pages given.');
    const vault = resolveVault(vaultPath);
    const files = pagePaths(items.map((i) => i?.path));
    const edits: LabelEdit[] = items.map((item, i) => ({ path: files[i] as string, labels: cleanLabels(item.labels), by: 'user' }));
    requireFreeVault(vault);
    const job = newLabelJob(vault, files, `Confirm labels on ${files.length} page(s).`);
    insert(job);
    const work = planLabelJob(job.id, { mode: 'confirm', edits }).catch((err: unknown) => fail(job.id, (err as Error).message));
    track(work);
    await work;
    return clone(requireJob(job.id));
  }

  /**
   * AI labels for UNLABELED pages. Pages that already have tags are skipped (counted in the first
   * turn). Returns the job at once in `running`; suggestions run one page at a time with
   * `labelPages` progress, then the bundle is built and inspected → awaitingApproval. cancel()
   * keeps the pages that finished (awaitingApproval when at least one did, else cancelled).
   */
  async function suggestLabelsForPages(
    rawPaths: string[],
    o: { vaultPath?: string; selection?: ModelSelection } = {},
  ): Promise<Job> {
    const files = pagePaths(rawPaths);
    const vault = resolveVault(o.vaultPath);
    requireFreeVault(vault);
    const selection = o.selection ?? labelSuggestSelection(settings);
    const todo: string[] = [];
    const tagged: string[] = [];
    for (const rel of files) {
      const page = readPage(vault.path, rel);
      if (typeof page !== 'string' && pageTags(page.text).length > 0) tagged.push(rel);
      else todo.push(rel); // a missing page is reported as skipped by the run
    }
    if (todo.length === 0) {
      throw new CoreError(
        'invalid_request',
        `${files.length === 1 ? 'The page already has' : `All ${files.length} pages already have`} labels; nothing to suggest.`,
      );
    }
    const intro =
      `Suggest labels for ${plural(todo.length, 'page')}.` +
      (tagged.length > 0 ? ` Skipped ${plural(tagged.length, 'page')} that already ${tagged.length === 1 ? 'has' : 'have'} labels.` : '');
    const job = newLabelJob(vault, todo, intro, selection);
    insert(job);
    const controller = new AbortController();
    controllers.set(job.id, controller);
    startProgress({
      key: job.id,
      kind: 'labelPages',
      message: `Suggesting labels for ${plural(todo.length, 'page')}`,
      done: 0,
      total: todo.length,
      ...selectionFields(selection),
    });
    const alreadyLabeled = tagged.map((p) => `${p}: already has labels`);
    const work = (async () => {
      const edits: LabelEdit[] = [];
      const skipped: string[] = [...alreadyLabeled];
      let cost = 0;
      let done = 0;
      try {
        const existing = await existingLabels(vault.path); // once, not per page
        for (const rel of todo) {
          if (controller.signal.aborted) break;
          const page = readPage(vault.path, rel);
          if (typeof page === 'string') {
            skipped.push(`${rel}: ${page}`);
          } else {
            const title = scalarValue(parseFrontmatter(page.text), 'title') ?? path.posix.basename(rel, '.md');
            try {
              const out = await suggestFor(vault, { title, text: bodyOf(page.text) }, { signal: controller.signal, selection, existing });
              if (controller.signal.aborted) break; // stopped mid-call: the page did not finish
              cost += out.costUSD;
              // Keep any current labels; the AI ones are added (all unconfirmed until reviewed).
              const labels = normalizeLabels([...pageTags(page.text), ...out.labels.map((l) => l.name)]);
              edits.push({ path: rel, labels, by: 'ai', origin: 'suggest' });
            } catch (err) {
              if (controller.signal.aborted) break;
              skipped.push(`${rel}: ${(err as Error).message}`);
            }
          }
          done += 1;
          updateProgress(job.id, { done });
        }
      } finally {
        if (controllers.get(job.id) === controller) controllers.delete(job.id);
      }
      const stopped = controller.signal.aborted;
      if (stopped && edits.length === 0) {
        mutate(job.id, (j) => {
          j.state = 'cancelled';
          j.turns.push(newTurn('app', 'Cancelled.', now(), cost));
        });
        return;
      }
      const notDone = stopped ? todo.slice(done).map((p) => `${p}: not done (stopped)`) : [];
      const head = stopped
        ? `Stopped after ${done} of ${plural(todo.length, 'page')}; suggested labels for ${plural(edits.length, 'page')}.`
        : `Suggested labels for ${edits.length} of ${plural(todo.length, 'page')}.`;
      mutate(job.id, (j) => j.turns.push(newTurn('worker', head, now(), cost)));
      if (edits.length === 0) {
        fail(job.id, ['No labels could be suggested.', ...skipped.map((s) => `- ${s}`)].join('\n'));
        return;
      }
      updateProgress(job.id, { message: 'Preparing the change for Review' });
      await planLabelJob(job.id, { mode: 'suggest', edits }, [...skipped, ...notDone]);
    })().catch((err: unknown) => fail(job.id, (err as Error).message));
    track(work);
    return clone(job);
  }

  // ───────────── the "core applies" approval path ─────────────

  /** Label jobs, and jobs whose runner cannot be limited to one exact apply command. */
  function coreApplies(job: Job): boolean {
    if (jobKind(job.kind)?.appliesInCore) return true;
    const runner = runners.get(jobRunnerID(job));
    return runner !== undefined && !runner.capabilities.has('toolPermissions');
  }

  function requireSession(job: Job): void {
    if (jobKind(job.kind)?.appliesInCore) {
      throw new CoreError('invalid_state', `Job ${job.id} has no AI session to reply to; approve or reject it.`);
    }
  }

  /** Runs the exact approved apply itself (never an agent), then completes the job with the core's changed paths. */
  async function applyInCore(id: string, plan: TransactionPlan, bundle: string): Promise<void> {
    const job = findJob(id);
    if (!job) return;
    const vault = vaultProfileFor(job);
    try {
      const out = await launch({
        executable: settings.pythonPath,
        args: [coreScriptPath(settings), 'transaction', 'apply', bundle, '--vault', vault.path, '--approved-plan-sha256', plan.approval_sha256],
        cwd: vault.path,
      });
      const stdout = out.stdout.toString('utf8');
      if (out.status === 0) {
        let result: unknown;
        try {
          result = JSON.parse(stdout);
        } catch {
          result = undefined;
        }
        const changed =
          isObject(result) && Array.isArray(result.changed_paths)
            ? result.changed_paths.filter((p): p is string => typeof p === 'string')
            : plan.changed_paths;
        const operationID = isObject(result) && typeof result.operation_id === 'string' ? result.operation_id : plan.operation_id;
        mutate(id, (j) => {
          j.state = 'completed';
          delete j.approval;
          j.operationID = operationID;
          j.changedPaths = changed;
          j.turns.push(newTurn('app', `Applied ${operationID}:\n` + changed.map((p) => `- ${p}`).join('\n'), now()));
        });
        return;
      }
      if (out.status === 75) {
        const request =
          jobKind(job.kind) === LabelsJobKind ? readLabelRequest(path.join(jobStateDirectory(job), 'request.json')) : undefined;
        if (request) {
          mutate(id, (j) =>
            j.turns.push(newTurn('app', 'The pages changed after you reviewed them; the plan was rebuilt. Review it again.', now())),
          );
          await planLabelJob(id, request);
          return;
        }
        mutate(id, (j) => {
          j.state = 'awaitingApproval';
          if (j.approval) {
            delete j.approval.plan;
            j.approval.planError =
              'The vault changed after this plan was reviewed (transaction apply exited 75). Reply to have it rebuilt, or reject.';
          }
          j.turns.push(newTurn('app', 'Not applied: the vault changed after review.', now()));
        });
        return;
      }
      fail(id, `transaction apply exited ${out.status}: ${(stdout + out.stderr.toString('utf8')).slice(0, 4000)}`);
    } catch (err) {
      fail(id, `transaction apply could not run: ${(err as Error).message}`);
    }
  }


  async function status(): Promise<StatusResponse> {
    refreshQueue();
    const probs = problems();
    return {
      version,
      activeVault: activeVault(settings) ?? null,
      problems: probs,
      queueCount: queueEntries().length,
      pendingApprovals: jobs.filter((j) => j.state === 'awaitingApproval').length,
      runningJobs: jobs.filter((j) => j.state === 'running').length,
      nextBatchAt: nextBatchAt ? isoDate(nextBatchAt) : null,
      lastQueueScanAt: lastQueueScanAt ? isoDate(lastQueueScanAt) : null,
      nextQueueScanAt: nextQueueScanAt ? isoDate(nextQueueScanAt) : null,
      runners: runners.all().map((r) => ({
        id: r.id,
        displayName: r.displayName,
        enabled: settings.enabledRunners.includes(r.id),
        problems: r.problems(settings),
      })),
    };
  }

  return {
    runners,
    paths,

    async start() {
      refreshQueue();
      scheduleNextBatch(now());
      scheduleNextScan(now());
      if (timer) clearInterval(timer);
      // Batches and queue checks the timer starts are logged as the scheduler's (activity-log.md).
      timer = setInterval(asScheduler(tick), tickMs);
    },
    async stop() {
      if (timer) clearInterval(timer);
      timer = undefined;
    },

    status,
    getSettings: () => clone(settings),
    updateSettings,

    listQueue() {
      refreshQueue();
      return queueEntries();
    },
    addQueueFiles,
    processQueue,
    addNote,
    async scanQueue(o) {
      const trigger = o?.trigger === 'window' ? 'window' : 'manual';
      return scanQueueNow(trigger);
    },

    listJobs: () => clone(jobs),
    getJob: (id) => {
      const j = findJob(id);
      return j ? clone(j) : undefined;
    },
    approve,
    reply,
    allow,
    reject,
    cancel,
    async extractImageText(req, o) {
      // A vault only scopes the request (it must be known); nothing in it is read or written.
      if (req.vaultPath) resolveVault(req.vaultPath);
      return extractImageText(req, {
        runners,
        settings: clone(settings),
        selection: selectionFor(settings, 'imageText'),
        scratchRoot: path.join(paths.dir, 'images', 'scratch'),
        ...(o?.signal ? { signal: o.signal } : {}),
      });
    },
    async searchPages(query, opts) {
      return searchVaultPages(resolveVault(opts?.vaultPath).path, query, opts?.limit);
    },
    deleteJob,
    jobResumeCommand,
    removeQueueEntry,
    setJobActions(id: string, summary: JobActionsSummary) {
      mutate(id, (j) => {
        j.actionsFound = { ...summary, byType: { ...summary.byType } };
      });
    },

    labelNote,
    listLabels,
    labelReview,
    suggestLabelsForPages,
    confirmLabels,

    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },

    async whenIdle() {
      while (inflight.size > 0) await Promise.allSettled([...inflight]);
    },
  };
}

