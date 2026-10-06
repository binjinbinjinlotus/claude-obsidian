import { randomUUID } from 'node:crypto';
import { asScheduler } from '../activity/context.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_QUEUE_SCAN_MINUTES,
  DEFAULT_SOURCE_TAXONOMY,
  type AgentRunner,
  runnerSupports,
  type AddNoteRequest,
  type AddNoteResult,
  type ApprovalRequest,
  type ApproveOptions,
  type ApprovedChange,
  type HeldSource,
  type InboxCleanupPreview,
  type InboxCleanupRequest,
  type InboxCleanupResult,
  type RejectOptions,
  type JobPart,
  type PendingPart,
  type QueuedApply,
  type RecoveryAttempt,
  type RecoverySignature,
  type CoreEvent,
  type DistillCore,
  type Job,
  type JobActionsSummary,
  type JobActions,
  type LabelCount,
  type LabelReview,
  type LabelSuggestion,
  type ModelSelection,
  type Progress,
  type QueueEntry,
  type QueueScanResult,
  type RereadGroup,
  type RereadRequest,
  type RereadResult,
  type ReviewLabels,
  type ReviewSource,
  type SessionAction,
  type SessionOptions,
  type SessionUnavailable,
  type RunRequest,
  type RunnerStep,
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
  recoveryPreferences,
  selectionFor,
  SettingsStore,
} from '../store/settings.js';
import { gateBreakingReason, uniqueDenials } from '../runners/permissions.js';
import { isCancelled, runProcess, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { defaultRegistry } from '../runners/registry.js';
import { checkResume, resumeFailure, sessionUnavailableError, type ResumeTarget } from '../runners/session.js';
import { batchNeverStarted, CANCELLED_BEFORE_FIRST_TURN, newSessionPrompt, savedLabelPlan, terminalSeed } from './session-seed.js';
import {
  JobContext,
  jobKind,
  LabelsJobKind,
  NOTE_MANIFEST_SUFFIX,
  parseWorkerStatus,
  queueConsumer,
  WorkerProtocol,
  type ParsedStatus,
  type RereadFacts,
  type SourceFacts,
  type SourceLabels,
} from './job-kinds.js';
import {
  existingSourcePages,
  groupItems,
  packItems,
  sourceFileProblem,
  jobSourceItems,
  makeRereadID,
  MAX_REREAD_PER_BATCH,
  RereadStore,
  sourceSize,
  type RereadItem,
  type RereadPlan,
} from './reread.js';
import { CoreError } from './errors.js';
import {
  denialAnswer,
  denialSummary,
  MAX_DENIAL_ANSWERS,
  parseRecoveryAnswer,
  plainCause,
  RECOVERY_SCHEMA,
  recoveryFacts,
  recoveryFor,
  recoveryPrompt,
  validateFix,
  whoApplies,
  type FixContext,
  type RecoveryAnswer,
} from './recovery.js';
import { runStructured } from '../actions/ai.js';
import { queueOrder, queueStatus, sinceApproved, staleFor } from './apply-queue.js';
import { createFullRead, type FullReadStep } from './full-read.js';
import { archivedCopy, ledgerRecords } from '../coverage/archive.js';
import { estimateTokens } from '../coverage/copy.js';
import { searchVaultPages } from './pages.js';
import { finderTrash, previewCleanup, renameTrash, runCleanup, type TrashMover } from './inbox-cleanup.js';
import { noteFileFor, readManifest, validateNote, writeManifest, writeNote, type NoteLabelState } from './notes.js';
import { NoteLabelStore } from './note-labels.js';
import { DEFAULT_LABEL_CONCURRENCY, mapPool, QueueLabeler, suggestInputFor } from './queue-labels.js';
import {
  contentFileFor,
  inspectReason,
  needsRevision,
  pageShas,
  partPrompt,
  readBundle,
  reviewSources,
  sourcePages,
  wikiWrites,
  verifyRebuilt,
  writeRevision,
} from './review-labels.js';
import { draftBatchLabels, isTextInput } from '../labels/batch.js';
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
import { isVault, problem, queuePlacementProblem, setupProblems } from './validator.js';

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
  | 'getCollectorScript' | 'writeCollectorScript' | 'installCollectorPackages' | 'stopCollectorInstall' | 'getCollectorInstall' | 'testCollector';
/** Actions and connections: core/src/actions (createActionsService). */
export type ActionsOwned =
  | 'listActionTypes' | 'listActions' | 'getAction' | 'createAction' | 'updateAction' | 'confirmActions'
  | 'dismissActions' | 'draftAction' | 'summarizeAction' | 'previewActionButton' | 'previewButtonDraft' | 'jiraProjects' | 'jiraIssueTypes' | 'jiraFields' | 'listSlackPeople' | 'rememberSlackPerson' | 'forgetSlackPerson' | 'slackTarget' | 'runActionButton' | 'stopActionButtonRun' | 'improveAction' | 'undoImprove' | 'performAction' | 'sendActionTo'
  | 'removeAction' | 'restoreAction' | 'deleteActionForever' | 'detectAskActions'
  | 'listConnections' | 'connect' | 'signInURL' | 'disconnect';
export type AskOwned = 'ask' | 'listConversations' | 'getConversation' | 'deleteConversation' | 'setConversationPinned' | 'cancelAsk';
/** Implemented in index.ts from the merged event stream. */
export type CompositionOwned = 'listProgress' | 'listJobSteps';
export type RunnerAdminOwned = 'listRunners' | 'setRunnerSecret';

/**
 * Engine methods beyond the DistillCore contract (proposed contract additions;
 * the server exposes them when present).
 */
export interface EngineExtras {
  /** Remove a finished job (completed, failed, rejected, cancelled) from the list; else invalid_state. */
  deleteJob(id: string): Promise<void>;
  /**
   * argv that reopens the job's AI session in a terminal, or null when there is none.
   * A session that is gone throws `session_unavailable` (place terminal); `newSession` returns
   * argv for a new interactive session primed with the batch instead (the job is not changed).
   */
  jobResumeCommand(id: string, opts?: SessionOptions): Promise<string[] | null>;
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
  /** v11 (action-context.md): the actions a batch found, as Review shows them (GET /v1/jobs/:id/actions). Composed in index.ts. */
  jobActions?(id: string): Promise<JobActions>;
}

export interface ResumeBatchOptions {
  job: Job;
  prompt: string;
  /** Rules for this turn only (the exact approved apply command). */
  extraTools?: string[];
  /** The plan an approved apply turn runs. */
  applyPlan?: TransactionPlan;
  action?: SessionAction;
  /**
   * The job as it was before the caller changed it (user turn, granted tools). When the session
   * turns out to be gone, before or at the resume, the job is put back to exactly this.
   */
  snapshot?: Job;
  /** What to send again after Continue (reply text / allow rules; approve-later or the sources picked for a part). */
  text?: string;
  rules?: string[];
  labels?: 'confirm' | 'later';
  pages?: string[];
}

export type ResumeBatchOutcome = { kind: 'started' } | ({ kind: 'session_unavailable' } & SessionUnavailable);

/** Steps of a batch, in order (`Progress.steps`); "Suggesting labels" only when the batch has a label pre-step. */
export const BATCH_STEPS = ['Moved to inbox', 'Suggesting labels', 'Read sources', 'Drafting page changes', 'Ready for review'] as const;

export type Engine = Pick<DistillCore, EngineOwned> & EngineExtras & {
  readonly runners: RunnerRegistry;
  readonly paths: StatePaths;
  /**
   * Session continuity seam (review-labels' approve paths plug in here): resumes the batch's
   * session with `prompt`, or reports that it is gone. Every batch resume goes through it.
   */
  resumeBatchSession(o: ResumeBatchOptions): ResumeBatchOutcome;
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
  /**
   * v8: how Clean up inbox moves files to the Trash. Default: Finder (Put Back works), falling back to a
   * rename into ~/.Trash; with `trashDir` set (tests) a rename into it. Tests inject a fake.
   */
  trashMover?: TrashMover;
  /** v3: a batch (queue-consumer job) was applied: completed with changed paths. Runs once per transition. */
  onJobApplied?: (job: Job) => void | Promise<void>;
  /**
   * v11 (action-context.md): a batch's change reached Review with a valid plan: its source pages and every
   * wiki page it writes. The actions service looks for actions in the sources then (in the background).
   */
  onReviewReady?: (job: Job, info: ReviewReadyInfo) => void | Promise<void>;
  /** v11: a batch ended without applying (rejected, cancelled or failed). */
  onJobEnded?: (job: Job) => void | Promise<void>;
  /** v7: the live log (steps/). Gets each agent step of a turn and each file of the label pre-step. */
  steps?: EngineStepSink;
}

/** v11: what a batch's change holds when it reaches Review (onReviewReady). */
export interface ReviewReadyInfo {
  /** Source pages: the page, its source file (`source_path`), title and text. */
  pages: { page: string; source?: string; title: string; text: string }[];
  /** Every wiki page the change writes, with its text. */
  written: { path: string; text: string }[];
}

/** v7: where the engine reports what the live log can't see in events. */
export interface EngineStepSink {
  runnerStep(jobId: string, step: RunnerStep): void;
  labelFile(jobId: string, file: string, state: 'running' | 'done' | 'failed', labels?: number): void;
  /** v10: a full-read step (coverage, continuation, detail check, split, stop). */
  fullRead?(jobId: string, step: FullReadStep): void;
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

/** "Wait before picking up a file": 0 (no wait) to 24 hours (decision 2026-10-05). */
export const MAX_SETTLE_SECONDS = 24 * 60 * 60;

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
  const trashMover: TrashMover = opts.trashMover ?? (opts.trashDir ? renameTrash(opts.trashDir) : finderTrash(trashDir, runProcess, (m) => log('warn', m)));
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
  /** Label state for notes in the vault's inbox/ (never written into inbox/; decision 2026-10-04). */
  const noteLabels = NoteLabelStore.at(paths.dir);
  /** Labels for queue text files before the batch, 3 at a time (queue-labels.ts). */
  const queueLabeler = new QueueLabeler({
    store: noteLabels,
    suggest: async (input, signal) => {
      const vault = activeVault(settings);
      if (!vault) throw new Error('No vault selected.');
      const out = await suggestFor(vault, input, { signal });
      return { labels: out.labels, costUSD: out.costUSD };
    },
    enabled: () => labelingPreferences(settings).autoLabelQueueFolder,
    onChange: () => refreshQueue(),
    started: (key, item) =>
      startProgress({
        key: `label:${key.slice(5)}`,
        kind: 'labelSuggest',
        message: `Suggesting labels for ${item}`,
        item,
        ...selectionFields(labelSuggestSelection(settings)),
      }),
    finished: (key, error) => finishProgress(`label:${key.slice(5)}`, error ? { error } : {}),
    now,
    track: (p) => track(p),
  });
  /** Jobs whose Review labels are being suggested or written into a revision (Approve is refused meanwhile). */
  const revising = new Set<string>();
  /** v9: re-reads whose groups have not all started (reread.ts); kept in <state>/reread.json. */
  const rereads = new RereadStore(path.join(paths.dir, 'reread.json'));
  /** v10: full reads (full-read.md): reading copies, coverage, the gate, the repair. */
  const fullRead = createFullRead({
    paths,
    now,
    settings: () => settings,
    runners,
    jobs: () => jobs,
    findJob: (id) => findJob(id),
    mutate: (id, change) => mutate(id, change),
    runTurn: (id, prompt, extra) => runTurn(id, prompt, extra),
    sessionGone: (job) => checkResume(resumeTarget(job, 'resume')) !== null,
    vaultProfileFor: (job) => vaultProfileFor(job),
    log: (level, message) => log(level, message),
    emit: (e) => emit(e),
    signalOf: (id) => controllers.get(id)?.signal,
    step: (jobId, s) => opts.steps?.fullRead?.(jobId, s),
    readingPrompt: (job, files, facts) => {
      const vault = vaultProfileFor(job);
      const labelPlan = savedLabelPlan(jobStateDirectory(job)).filter((l) => files.includes(l.file));
      const existing = job.reread ? existingSourcePages(vault.path, files) : undefined;
      const sources = facts.sources.map((s) => ({ ...s, pages: existing?.get(s.file)?.pages ?? s.pages }));
      const ctx = new JobContext({ ...clone(job), files }, vault, settings, labelPlan, { ...facts, sources });
      return queueConsumer().initialPrompt(ctx);
    },
    rereadSources: (req) => rereadSources(req),
    waitingRereadFiles: (vaultPath) => new Set(rereads.plans.filter((p) => p.vaultPath === vaultPath).flatMap((p) => p.groups.filter((g) => !g.jobId).flatMap((g) => g.files))),
    nextPartBundle: (dir) => path.join(dir, `bundle-part-${nextPartBundle(dir)}.json`),
  });
  /**
   * v10 (owner decision 2026-10-05): batches run only on runners whose reads can be verified
   * (`readCoverage`). A saved choice of another runner (Codex) runs on one that can, and the core
   * says so once. A registry with no such runner at all keeps the choice.
   */
  let warnedIngestRunner = false;
  function ingestSelection(): ModelSelection {
    const sel = selectionFor(settings, queueConsumer().task);
    const chosen = runners.get(sel.runnerID);
    if (chosen?.capabilities.has('readCoverage')) return sel;
    const verifiable = runners.all().filter((r) => r.capabilities.has('readCoverage') && runnerSupports(r, 'ingest'));
    if (verifiable.length === 0) return sel;
    const use = verifiable.find((r) => settings.enabledRunners.includes(r.id)) ?? verifiable[0]!;
    if (!warnedIngestRunner) {
      warnedIngestRunner = true;
      log('warn', `${chosen?.displayName ?? sel.runnerID} can't show which lines it read, so batches run on ${use.displayName} (Codex batches are deferred).`);
    }
    return { runnerID: use.id, model: use.defaultModel, effort: null };
  }
  /** v10: the queue was split by size: which batch of how many is running now. */
  let overflow: { index: number; total: number } | undefined;

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
    // "Applied" only when an operation was recorded (an unverified agent apply records none).
    else if (job.state === 'completed') patch.message = current.kind === 'apply' ? (job.operationID ? 'Applied' : 'Not applied') : 'Done';
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

  /** Why the next batch cannot start right now, if anything (on `vault`, default the active one). */
  function batchBlocker(on?: VaultProfile): string | undefined {
    const p = problems()[0];
    if (p) return p.message;
    const vault = on ?? activeVault(settings);
    if (!vault) return 'No vault selected.';
    // Batches waiting in Review don't block the next batch (decision 2026-10-05); a running one does.
    const holder = jobs.find((j) => j.vaultPath === vault.path && j.state === 'running');
    if (holder) return `Waiting for ${holder.id} to finish.`;
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
    const stateBefore = job.state;
    change(job);
    // review-queue.md: a finished batch is out of the apply queue.
    if (job.state !== 'awaitingApproval' && job.state !== 'running') {
      delete job.queuedApply;
      delete job.refresh;
    }
    job.updatedAt = isoDate(now());
    persistJobs();
    emit({ type: 'job', job: clone(job) });
    if (job.state !== 'running') finishJobProgress(job);
    if (job.reread && job.state === 'cancelled') dropReread(job.reread.id, `${job.id} was cancelled`);
    // A batch that stops running frees its vault: the next re-read group may start (after this change settles).
    if (job.state !== 'running' && rereads.pending()) track(Promise.resolve().then(() => pumpRereads()));
    // review-queue.md: an apply (or a refresh) ended: the vault's next queued approval may apply.
    if (stateBefore === 'running' && job.state !== 'running') {
      const vault = job.vaultPath;
      const afterApply = job.state === 'completed' && !!job.operationID;
      track(Promise.resolve().then(() => pumpApplies(vault, { afterApply })).catch((err: unknown) => log('warn', `Apply queue: ${(err as Error).message}`)));
    }
    // v10: the queue was split by size: the next batch starts as soon as this one leaves `running`.
    if (job.state !== 'running' && job.batchOf && job.batchOf.index < job.batchOf.total && overflow && overflow.index === job.batchOf.index) {
      track(Promise.resolve().then(() => processQueue({ overflow: true })).then(() => undefined).catch((err: unknown) => log('warn', `Next batch: ${(err as Error).message}`)));
    }
    // v10: pages applied: record what was read in full, then look for sources never read in full.
    if (!wasCompleted && job.state === 'completed' && job.operationID) appliesIn.set(job.vaultPath, (appliesIn.get(job.vaultPath) ?? 0) + 1);
    if (!wasCompleted && job.state === 'completed' && job.kind === queueConsumer().id && job.operationID) {
      const vault = vaultProfileFor(job);
      track(Promise.resolve().then(() => fullRead.repairScan(vault, { force: true })).then(() => undefined));
    }
    // v11: a batch that ends without applying (rejected, cancelled, failed): its found actions are not added.
    if (stateBefore !== job.state && ['rejected', 'cancelled', 'failed'].includes(job.state) && job.kind === queueConsumer().id && opts.onJobEnded) {
      const hook = opts.onJobEnded;
      const ended = clone(job);
      track(Promise.resolve().then(() => hook(ended)).catch((err: unknown) => log('warn', `After the batch ended: ${(err as Error).message}`)));
    }
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
    const entries = queueList(queued, settings.settleSeconds, now(), {
      firstSeen,
      sourceLabel,
      labelsConfirmed: (id) => noteLabels.get(id)?.labels !== undefined,
    });
    for (const e of entries) {
      const labels = queueLabeler.describe(e);
      if (labels) e.labels = labels;
      if (QueueLabeler.held(labels)) e.heldForLabels = true;
    }
    return entries;
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

  /**
   * A plan applied outside Distill (Open in Terminal): the vault's own journal for the plan's operation
   * says `complete` with the same `approval_sha256`, so the batch is recorded as applied, exactly as an
   * approved apply in the app would be (operation, changed paths from the journal, full reads, actions).
   */
  function adoptOutsideApplies(): void {
    for (const job of jobs) {
      const plan = job.approval?.plan;
      if (job.state !== 'awaitingApproval' || !plan) continue;
      const journal = readJournal(job.vaultPath, plan.operation_id);
      if (!journal || journal.state !== 'complete' || journal.approval_sha256 !== plan.approval_sha256) continue;
      const paths = journal.changed_paths.length > 0 ? journal.changed_paths : plan.changed_paths;
      const applying = clone(job.approval!);
      mutate(job.id, (j) => {
        const prior = j.approvedChange;
        j.approvedChange = prior && prior.operationID === plan.operation_id ? { ...prior, appliedOutside: true } : { ...approvedChangeOf(j, plan), appliedOutside: true };
        delete j.reviewDoneAt;
        j.state = 'completed';
        delete j.approval;
        addPart(j, plan.operation_id, applying);
        j.operationID = plan.operation_id;
        j.changedPaths = mergedPaths(j, paths);
        j.turns.push(newTurn('app', `Applied ${plan.operation_id} outside Distill (found in the vault's journal):\n` + paths.map((p) => `- ${p}`).join('\n'), now()));
      });
      log('info', `Job ${job.id}: ${plan.operation_id} was applied outside Distill; recorded as applied.`);
      const applied = findJob(job.id);
      if (applied) {
        try {
          fullRead.recordApplied(applied, paths, applying.bundlePath ?? undefined);
        } catch (err) {
          log('warn', `Full reads: could not record ${job.id}: ${(err as Error).message}`);
        }
      }
      continueAfterPart(job.id, plan.operation_id);
    }
  }

  function tick(): void {
    adoptOutsideApplies();
    for (const v of new Set(jobs.filter((j) => j.queuedApply && j.state === 'awaitingApproval').map((j) => j.vaultPath))) {
      track(pumpApplies(v).catch((err: unknown) => log('warn', `Apply queue: ${(err as Error).message}`)));
    }
    if (nextQueueScanAt && now() >= nextQueueScanAt) scanQueueNow('periodic');
    else refreshQueue();
    if (rereads.pending()) pumpRereads();
    if (!settings.autoProcessEnabled || !nextBatchAt || now() < nextBatchAt) return;
    scheduleNextBatch(now());
    void processQueue().catch((err: unknown) => log('error', (err as Error).message));
  }

  // ───────────── turns ─────────────

  /** What a resume through resumeBatchSession restores, and sends again after Continue, when the session is gone. */
  type ResumeOf = { target: ResumeTarget; snapshot?: Job; text?: string; rules?: string[]; labels?: 'confirm' | 'later'; pages?: string[] };

  function runTurn(
    id: string,
    prompt: string,
    extra: {
      extraTools?: string[];
      first?: boolean;
      /** Set only for the turn approve() starts to run this plan's apply. */
      applyPlan?: TransactionPlan;
      /** A resume through resumeBatchSession: what to restore when the runner says the session is gone. */
      resumeOf?: ResumeOf;
      /**
       * v10: an automatic continuation of the full-read gate. The job stays `running`; a refused
       * resume never opens SessionReplaceConfirm: the sources go to a fresh session instead.
       */
      autoContinue?: boolean;
    } = {},
  ): void {
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
      delete j.sessionUnavailable; // the next turn clears an earlier "session gone" marker
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
    const stepSink = opts.steps;
    if (stepSink) request.onStep = (step) => stepSink.runnerStep(id, step);
    // Ingest turns always stream (stream-json), so which tool calls read the sources is on record
    // even without a live-log sink (decision 2026-10-05, full reads).
    else if (kind.consumesQueue) request.onStep = () => {};
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
          await handle(result, id, vault, extra.applyPlan);
        } catch (err) {
          const target = extra.resumeOf?.target ?? (extra.autoContinue ? resumeTarget(job, 'resume') : undefined);
          const gone = target && !extra.first ? resumeFailure(target, err) : null;
          if (isCancelled(err) || controller.signal.aborted) {
            mutate(id, (j) => {
              j.state = 'cancelled';
              j.turns.push(newTurn('app', 'Cancelled. Reply to resume the session.', now()));
            });
          } else if (gone && extra.autoContinue && !extra.resumeOf) {
            // v10: nobody to ask: what isn't added yet is read again in a fresh session.
            fullRead.autoContinueRefused(id);
          } else if (gone && extra.resumeOf) {
            // The runner refused the resume: put the job back as it was and ask the user (SessionReplaceConfirm).
            const marker: SessionUnavailable = { ...gone };
            if (extra.resumeOf.text !== undefined) marker.text = extra.resumeOf.text;
            if (extra.resumeOf.rules !== undefined) marker.rules = [...extra.resumeOf.rules];
            if (extra.resumeOf.labels !== undefined) marker.labels = extra.resumeOf.labels;
            if (extra.resumeOf.pages !== undefined) marker.pages = [...extra.resumeOf.pages];
            restoreJob(id, extra.resumeOf.snapshot, marker);
          } else {
            fail(id, err instanceof Error ? err.message : String(err));
            if (extra.resumeOf && !extra.applyPlan) recover(id, 'runner-failed');
          }
        } finally {
          if (controllers.get(id) === controller) controllers.delete(id);
          // A recovery turn that ended without fixing or re-triggering it never leaves "Recovering" behind.
          settleRecovery(id);
        }
      })(),
    );
  }

  async function handle(result: RunResult, id: string, vault: VaultProfile, applyPlan?: TransactionPlan): Promise<void> {
    const status = parseWorkerStatus(result.structured);
    const summary = status?.summary ?? result.resultText;
    mutate(id, (j) => {
      if (result.sessionID) j.sessionID = result.sessionID;
      j.turns.push(newTurn('worker', summary, now(), result.costUSD));
    });
    // v10 (full reads): before anything reaches Review, the core checks every line was read.
    try {
      if (await fullRead.gate(id, status ?? undefined, result, applyPlan !== undefined)) return;
    } catch (err) {
      log('warn', `Full-read check of ${id}: ${(err as Error).message}`);
    }
    if (!status) {
      if (result.isError) {
        fail(id, result.resultText);
        // A recovery turn that errored escalates (rule → agent); a first run's error stays the owner's.
        const rec = findJob(id)?.recovery;
        if (rec && rec.signature !== 'denial' && rec.state === 'running' && applyPlan === undefined) recover(id, rec.signature === 'stale-again' ? 'runner-failed' : rec.signature);
      } else await requestDecision(id, { status: 'needs_input', summary, questions: [], changed_paths: [], skipped: [] }, result, vault);
      return;
    }
    switch (status.status) {
      case 'done':
      case 'nothing_to_do':
        if (result.denials.length > 0 && status.status !== 'done') {
          await requestDecision(id, status, result, vault, applyPlan !== undefined);
          return;
        }
        // The model's report is not evidence: an operation is recorded only when this was the
        // approved apply turn and it names the approved operation; the paths come from the
        // inspected plan, never from the model.
        const applying = findJob(id)?.approval ? clone(findJob(id)!.approval!) : undefined;
        // review-queue.md, not-recorded: an apply turn that didn't report the approved operation is checked
        // against the vault's own journal; `complete` with the approved hash records it as applied (the rule).
        const journal = applyPlan && status.operation_id !== applyPlan.operation_id ? readJournal(vault.path, applyPlan.operation_id) : undefined;
        const inJournal = !!journal && journal.state === 'complete' && journal.approval_sha256 === applyPlan!.approval_sha256;
        const recorded = !!applyPlan && (inJournal || (status.status === 'done' && status.operation_id === applyPlan.operation_id));
        mutate(id, (j) => {
          j.state = 'completed';
          delete j.approval;
          if (inJournal && applyPlan) {
            const paths = journal!.changed_paths.length > 0 ? journal!.changed_paths : applyPlan.changed_paths;
            addPart(j, applyPlan.operation_id, applying);
            j.operationID = applyPlan.operation_id;
            j.changedPaths = mergedPaths(j, paths);
            j.turns.push(newTurn('app', `Applied ${applyPlan.operation_id} (the turn didn’t report it; found in the vault’s journal):\n` + paths.map((p) => `- ${p}`).join('\n'), now()));
            return;
          }
          if (status.status !== 'done') return;
          if (applyPlan && status.operation_id === applyPlan.operation_id) {
            addPart(j, applyPlan.operation_id, applying);
            j.operationID = applyPlan.operation_id;
            j.changedPaths = mergedPaths(j, applyPlan.changed_paths);
            j.turns.push(newTurn('app', `Applied ${applyPlan.operation_id}:\n` + applyPlan.changed_paths.map((p) => `- ${p}`).join('\n'), now()));
          } else if (applyPlan) {
            j.turns.push(
              newTurn(
                'app',
                `Nothing recorded as applied: the turn did not report the approved operation ${applyPlan.operation_id}` +
                  (status.operation_id ? ` (it reported ${status.operation_id}).` : '.') +
                  ' Check the vault log before running it again.',
                now(),
              ),
            );
          } else {
            j.turns.push(newTurn('app', 'Nothing was applied: this turn had no approved plan to apply.', now()));
          }
        });
        if (applyPlan && recorded) {
          const applied = findJob(id);
          if (applied) {
            try {
              fullRead.recordApplied(applied, applyPlan.changed_paths, applying?.bundlePath ?? undefined);
            } catch (err) {
              log('warn', `Full reads: could not record ${id}: ${(err as Error).message}`);
            }
          }
          continueAfterPart(id, applyPlan.operation_id);
        }
        return;
      case 'needs_approval':
      case 'needs_input':
        await requestDecision(id, status, result, vault, applyPlan !== undefined);
        return;
      case 'failed':
        if (result.denials.length === 0) fail(id, status.summary);
        else await requestDecision(id, status, result, vault, applyPlan !== undefined);
        return;
    }
  }

  async function requestDecision(id: string, status: ParsedStatus, result: RunResult, vault: VaultProfile, applyTurn = false): Promise<void> {
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
    const part = findJob(id)?.pendingPart;
    let confirm: boolean;
    if (part && (part.reason === 'covered' || part.reason === 'unread')) {
      // v10: the split's parts: checked (pages and ledger), then reviewed like any batch (labels too).
      confirm = checkSplitPart(id, request, part) && request.plan?.valid && request.bundlePath ? attachReviewSources(id, request) : false;
    } else {
      confirm = part ? checkRebuiltPart(id, request, part) : request.plan?.valid && request.bundlePath ? attachReviewSources(id, request) : false;
    }
    mutate(id, (j) => {
      j.state = 'awaitingApproval';
      j.approval = request;
      delete j.refresh;
      // review-queue.md: a plan that came back ends a blocked-command recovery.
      if (request.plan?.valid && j.recovery && j.recovery.state !== 'gaveUp') {
        j.recovery = { ...j.recovery, state: 'fixed', attempts: j.recovery.attempts.map((a) => (a.result === 'running' ? { ...a, result: 'fixed' } : a)) };
      }
    });
    // review-queue.md: blocked tool calls and no plan: Distill answers the session itself first.
    // Not on an apply turn: there the approved command itself is what ran (or was refused).
    if (!applyTurn && request.denials.length > 0 && !request.plan?.valid && recoverDenial(id)) return;
    // review-queue.md: a plan the vault core couldn't check: Distill asks the session to rebuild it, then recovery.
    if (!applyTurn && request.planError && !request.plan && request.denials.length === 0 && recover(id, 'plan-error')) return;
    // review-queue.md: an apply turn that came back because another batch changed the same pages first.
    const queued = findJob(id)?.queuedApply;
    if (applyTurn && queued) {
      const stale = staleFor(vault.path, queued.bundlePath);
      if (stale.length > 0 && refreshJob(id, true, stale.map((x) => x.path))) return;
    }
    if (confirm) track(reviseReviewLabels(id, undefined, true).catch((err: unknown) => log('warn', `Review labels: ${(err as Error).message}`)));
    // v11 (action-context.md): actions are looked for in the batch's sources while it waits in Review.
    const reviewed = findJob(id);
    if (opts.onReviewReady && reviewed && reviewed.kind === queueConsumer().id && request.plan?.valid && request.bundlePath) {
      const b = readBundle(request.bundlePath);
      if (b) {
        const info: ReviewReadyInfo = {
          pages: sourcePages(b).map((p) => ({ page: p.page, ...(p.source ? { source: p.source } : {}), title: p.title, text: p.text })),
          written: wikiWrites(b),
        };
        const hook = opts.onReviewReady;
        const snapshot = clone(reviewed);
        track(Promise.resolve().then(() => hook(snapshot, info)).catch((err: unknown) => log('warn', `Finding actions: ${(err as Error).message}`)));
      }
    }
  }

  /**
   * review-queue.md, "Blocked tool commands never reach the owner as raw shell": a turn that ended with
   * blocked calls and no plan is answered by Distill ("use Read, Grep or Glob"), at most
   * MAX_DENIAL_ANSWERS times per batch; after that the owner gets a plain sentence (recovery.summary),
   * never the command. True when the session was resumed.
   */
  function recoverDenial(id: string): boolean {
    const job = findJob(id);
    if (!job || job.state !== 'awaitingApproval' || job.approval?.plan?.valid) return false;
    const denials = job.approval?.denials ?? [];
    if (denials.length === 0 || jobKind(job.kind)?.appliesInCore) return false;
    const rec = recoveryFor(job.recovery, 'denial');
    const answers = rec.denialAnswers ?? 0;
    const where = { vaultPath: job.vaultPath, jobDir: jobStateDirectory(job) };
    const settled = rec.attempts.map((a) => (a.result === 'running' ? { ...a, result: 'failed' as const } : a));
    const giveUp = (extra = '', proposal?: 'new_session') =>
      mutate(id, (j) => {
        j.recovery = { ...rec, attempts: settled, state: 'gaveUp', summary: denialSummary(denials, { ...where, answers }) + extra, ...(proposal ? { proposal } : {}) };
      });
    // Settings → Recovery → Recover automatically off: the owner decides (plain words, never the command).
    if (!recoveryPreferences(settings).automatic) {
      giveUp();
      return false;
    }
    if (answers >= MAX_DENIAL_ANSWERS) {
      // Two answers didn't help: the recovery agent (Opus by default) looks at the facts, within its bounds.
      mutate(id, (j) => {
        j.recovery = { ...rec, attempts: settled, state: 'running' };
      });
      track(asScheduler(() => runRecoveryAgent(id, 'denial'))().catch((err: unknown) => log('warn', `Recovery: ${(err as Error).message}`)));
      return true;
    }
    const text = denialAnswer(denials, { ...where, queued: queuedOrApproved(job) });
    if (precheck(job, 'reply', { text })) {
      giveUp(' Its AI session isn’t available anymore.', 'new_session');
      return false;
    }
    const at = isoDate(now());
    mutate(id, (j) => {
      j.recovery = {
        ...rec,
        state: 'running',
        denialAnswers: answers + 1,
        attempts: [...settled, { at, by: 'rule', fix: 'answer_denial', result: 'running', costUSD: 0 }],
      };
      delete j.recovery.summary;
      j.turns.push(newTurn('app', text, now()));
    });
    const current = findJob(id)!;
    startTurnProgress(current, 'Drafting page changes', 'Recovering · told Claude to read the files instead');
    const out = resumeBatchSession({ job: current, prompt: WorkerProtocol.replyPrompt(text), action: 'reply', text });
    if (out.kind === 'session_unavailable') {
      giveUp(' Its AI session isn’t available anymore.', 'new_session');
      return false;
    }
    return true;
  }

  const RECOVERY_BACKOFF_MS = 60_000;
  const recoveryWakes = new Map<string, ReturnType<typeof setTimeout>>();

  function scheduleRecoveryWake(id: string, signature: RecoverySignature, ms: number): void {
    const old = recoveryWakes.get(id);
    if (old) clearTimeout(old);
    const t = setTimeout(() => {
      recoveryWakes.delete(id);
      // Only the wait it was set for: the owner may have acted since (the recovery reset, gave up or was fixed).
      const rec = findJob(id)?.recovery;
      if (rec?.state !== 'waiting' || rec.signature !== signature) return;
      // wait_then_retry / reinspect_same_bundle: the queued apply goes again (through the pump), no agent call.
      if (rec.wake === 'retry') {
        asScheduler(() => retryQueuedApply(id))();
        return;
      }
      track(asScheduler(() => runRecoveryAgent(id, signature))().catch((err: unknown) => log('warn', `Recovery: ${(err as Error).message}`)));
    }, Math.max(0, ms));
    t.unref?.();
    recoveryWakes.set(id, t);
  }

  /** The owner's sentence for a problem other than a blocked command (never a command or a stack trace). */
  function problemSummary(signature: RecoverySignature, job: Job): string {
    // Plain words only: the raw error stays in job.error (Show details), never in the owner's sentence.
    const cause = plainCause(signature === 'plan-error' ? job.approval?.planError : job.error);
    switch (signature) {
      case 'stale-again':
        return 'Your vault keeps changing under this plan: it was rebuilt for the latest pages and is out of date again.';
      case 'plan-error':
        return `The vault core couldn’t check this plan${cause ? `: ${cause}` : ''}.`;
      case 'runner-failed':
        return `The AI run stopped with an error${cause ? `: ${cause}` : ''}.`;
      case 'lock':
        return 'Another app kept your vault locked, so your approved change couldn’t be applied yet. Approve again when it is closed.';
      case 'session-gone':
        return 'This batch’s AI session isn’t available anymore, so your approved change can’t be applied in it.';
      default:
        return 'Distill couldn’t get this batch going again by itself.';
    }
  }

  /** The batch was approved: its apply waits in the queue (or comes back to it), Distill retries it. */
  function queuedOrApproved(job: Job): boolean {
    return job.queuedApply !== undefined || job.approvedChange !== undefined;
  }

  /** What Distill (rule) or the recovery agent (rebuild_in_session) sends the batch's session. */
  function rebuildText(signature: RecoverySignature, job: Job): string {
    if (signature === 'runner-failed') {
      return `The last run stopped with an error: ${(job.error ?? 'unknown').slice(0, 300)}. Continue the task from where you were, using only the tools you have, and finish with the structured status. ${whoApplies(queuedOrApproved(job))}`;
    }
    return (
      `The vault core couldn't check the plan: ${(job.approval?.planError ?? 'no usable bundle').slice(0, 400)}. ` +
      `Rebuild the bundle in this job directory. ${whoApplies(queuedOrApproved(job))}`
    );
  }

  /**
   * review-queue.md, Self-recovery: a batch that can't make progress gets a rule first ($0, at most once), then the
   * recovery agent within its bounds. Blocked commands have their own rule (recoverDenial). True when it took over.
   */
  /**
   * review-queue.md, "When it runs": lock, not-recorded, full-read-stop and session-gone keep their rules; this is
   * what happens when a rule is spent. Only `lock` has a fix the agent can choose (reinspect_same_bundle,
   * wait_then_retry, give_up), so only it calls the agent, within its bounds. The others allow nothing an agent
   * could do for the owner (give_up, or the new_session only the owner may start), so they settle at $0 with a
   * plain sentence and, for session-gone, the new-session proposal.
   */
  function recoverAfterRule(id: string, signature: 'lock' | 'session-gone', approvedSha256?: string): void {
    const job = findJob(id);
    // A labels confirmation has no session and no recovery (the core applies it and asks the owner itself).
    if (!job || job.state !== 'awaitingApproval' || jobKind(job.kind)?.appliesInCore) return;
    const rec = recoveryFor(job.recovery, signature);
    const attempts = rec.attempts.map((a) => (a.result === 'running' ? { ...a, result: 'failed' as const } : a));
    const approved = approvedSha256 ?? rec.approvedSha256;
    const giveUp = (proposal?: 'new_session') =>
      mutate(id, (j) => {
        j.recovery = {
          ...rec, attempts, state: 'gaveUp', summary: problemSummary(signature, j),
          ...(approved ? { approvedSha256: approved } : {}), ...(proposal ? { proposal } : {}),
        };
      });
    if (signature === 'session-gone' || !recoveryPreferences(settings).automatic) {
      giveUp(signature === 'session-gone' ? 'new_session' : undefined);
      return;
    }
    mutate(id, (j) => {
      j.recovery = { ...rec, attempts, state: 'running', ...(approved ? { approvedSha256: approved } : {}) };
    });
    track(asScheduler(() => runRecoveryAgent(id, signature))().catch((err: unknown) => log('warn', `Recovery: ${(err as Error).message}`)));
  }

  function recover(id: string, signature: RecoverySignature): boolean {
    if (signature === 'denial') return recoverDenial(id);
    const job = findJob(id);
    if (!job || jobKind(job.kind)?.appliesInCore || coreApplies(job)) return false;
    const rec = recoveryFor(job.recovery, signature);
    const settled = rec.attempts.map((a) => (a.result === 'running' ? { ...a, result: 'failed' as const } : a));
    const giveUp = (extra = '', proposal?: 'new_session') =>
      mutate(id, (j) => {
        j.recovery = { ...rec, attempts: settled, state: 'gaveUp', summary: problemSummary(signature, j) + extra, ...(proposal ? { proposal } : {}) };
      });
    if (!recoveryPreferences(settings).automatic) {
      giveUp();
      return false;
    }
    // The stale rule is the refresh itself; the others get one fixed reply first.
    if (signature !== 'stale-again' && !settled.some((a) => a.by === 'rule')) {
      const text = rebuildText(signature, job);
      if (precheck(job, 'reply', { text })) {
        giveUp(' Its AI session isn’t available anymore.', 'new_session');
        return false;
      }
      mutate(id, (j) => {
        j.recovery = { ...rec, state: 'running', attempts: [...settled, { at: isoDate(now()), by: 'rule', fix: 'rebuild_in_session', result: 'running', costUSD: 0 }] };
        delete j.recovery.summary;
        j.turns.push(newTurn('app', text, now()));
      });
      startTurnProgress(findJob(id)!, 'Drafting page changes', 'Recovering · asking Claude to try again');
      const out = resumeBatchSession({ job: findJob(id)!, prompt: WorkerProtocol.replyPrompt(text), action: 'reply', text });
      if (out.kind === 'session_unavailable') {
        giveUp(' Its AI session isn’t available anymore.', 'new_session');
        return false;
      }
      return true;
    }
    mutate(id, (j) => {
      j.recovery = { ...rec, attempts: settled, state: 'running' };
    });
    track(asScheduler(() => runRecoveryAgent(id, signature))().catch((err: unknown) => log('warn', `Recovery: ${(err as Error).message}`)));
    return true;
  }

  /** The owner's sentence for a recovery that stops (never a command). */
  function recoverySummary(signature: RecoverySignature, job: Job): string {
    if (signature !== 'denial') return problemSummary(signature, job);
    const denials = job.approval?.denials ?? [];
    if (denials.length > 0) {
      return denialSummary(denials, { vaultPath: job.vaultPath, jobDir: jobStateDirectory(job), answers: job.recovery?.denialAnswers ?? 0 });
    }
    return 'Distill answered Claude’s blocked command, but Claude stopped with questions instead of a plan.';
  }

  /** Recovery agent calls in flight (a recovery reads `running` while one is). */
  const recoveryAgents = new Map<string, number>();
  /** The latest agent call per batch: an older call's answer is never carried out. */
  const agentCalls = new Map<string, symbol>();

  /** The pages a batch's plan touches (its inspected plan; empty without one). */
  function planPaths(j: Job): string[] {
    return j.approval?.plan?.changed_paths ?? [];
  }

  /** What validateFix and the agent's facts know about the batch (never the agent's word alone). */
  function fixContext(job: Job): FixContext {
    const approvedSha256 = job.recovery?.approvedSha256 ?? job.queuedApply?.planSha256;
    return {
      vaultPath: job.vaultPath,
      paths: planPaths(job),
      others: jobs
        .filter((o) => o.id !== job.id && (o.state === 'awaitingApproval' || o.state === 'running'))
        .map((o) => ({ id: o.id, vaultPath: o.vaultPath, paths: planPaths(o) })),
      sources: (job.approval?.sources ?? []).filter((x) => !x.removed).map((x) => x.page),
      rebuiltPart: !!(job.pendingPart && job.approval?.rebuilt && !job.approval.needsRebuild),
      ...(approvedSha256 ? { approvedSha256 } : {}),
    };
  }

  /**
   * reinspect_same_bundle and wait_then_retry, when their time comes: the batch goes back to the queue under the
   * exact hash the owner approved, and the pump's `transaction inspect` proves the bytes before anything applies.
   * A plan that changed since never goes back by itself: the owner is asked.
   */
  function retryQueuedApply(id: string): void {
    const job = findJob(id);
    const rec = job?.recovery;
    if (!job || !rec || rec.state !== 'waiting') return;
    const q = job.queuedApply;
    const plan = q ? planFor(job, q.labels) : undefined;
    if (job.state !== 'awaitingApproval' || !q || !rec.approvedSha256 || plan?.approval_sha256 !== rec.approvedSha256) {
      mutate(id, (j) => {
        if (!j.recovery) return;
        const { wake: _w, waitUntil: _u, ...rest } = j.recovery;
        j.recovery = { ...rest, state: 'gaveUp', summary: `${recoverySummary(rest.signature, j)} The plan changed after you approved it, so Distill didn’t try it again; approve it as it is now.` };
      });
      return;
    }
    mutate(id, (j) => {
      if (!j.recovery || !j.queuedApply) return;
      const { wake: _w, waitUntil: _u, ...rest } = j.recovery;
      j.recovery = { ...rest, state: 'running' };
      j.queuedApply.planSha256 = rest.approvedSha256;
      j.turns.push(newTurn('app', 'Trying your approved plan again: Distill checks it is unchanged before it applies.', now()));
    });
    track(pumpApplies(job.vaultPath).catch((err: unknown) => log('warn', `Apply queue: ${(err as Error).message}`)));
  }

  /**
   * review-queue.md, Bounds: a recovery reads `running` only while a turn or an agent call works on it. When a
   * turn ends without fixing it (a valid plan) or re-triggering it (new denials, a plan error, a runner error),
   * its attempt fails: a rule's attempt escalates once to the recovery agent, anything else gives up and the
   * batch needs the owner. Also run at start for recoveries an older build left running.
   */
  function settleRecovery(id: string): void {
    const job = findJob(id);
    const rec = job?.recovery;
    if (!job || !rec || rec.state !== 'running' || job.state === 'running' || (recoveryAgents.get(id) ?? 0) > 0) return;
    // Back in the queue under the approved hash (a retry): the pump works on it.
    if (job.state === 'awaitingApproval' && job.queuedApply?.planSha256) return;
    const last = [...rec.attempts].reverse().find((a) => a.result === 'running');
    const attempts = rec.attempts.map((a) => (a.result === 'running' ? { ...a, result: 'failed' as const, error: a.error ?? 'The turn ended without a plan.' } : a));
    if (job.state === 'completed') {
      mutate(id, (j) => {
        if (j.recovery) j.recovery = { ...rec, state: 'fixed', attempts: rec.attempts.map((a) => (a.result === 'running' ? { ...a, result: 'fixed' } : a)) };
      });
      return;
    }
    if (job.state !== 'awaitingApproval' && job.state !== 'failed') {
      mutate(id, (j) => {
        delete j.recovery; // cancelled or rejected: the owner acted
      });
      return;
    }
    const escalate = last?.by === 'rule' && recoveryPreferences(settings).automatic && !jobKind(job.kind)?.appliesInCore;
    mutate(id, (j) => {
      j.recovery = escalate ? { ...rec, attempts, state: 'running' } : { ...rec, attempts, state: 'gaveUp', summary: recoverySummary(rec.signature, j) };
    });
    if (escalate) {
      track(asScheduler(() => runRecoveryAgent(id, rec.signature))().catch((err: unknown) => log('warn', `Recovery: ${(err as Error).message}`)));
    }
  }

  /**
   * review-queue.md, "The recovery agent": one structured call (no tools, no session, no vault access) picks one fix
   * from a fixed list; the core checks it and carries it out. Bounded by Settings → Recovery (attempts, cost).
   * It never applies anything and never allows a tool rule.
   */
  async function runRecoveryAgent(id: string, signature: RecoverySignature): Promise<void> {
    recoveryAgents.set(id, (recoveryAgents.get(id) ?? 0) + 1);
    try {
      await recoveryAgentCall(id, signature);
    } finally {
      const n = (recoveryAgents.get(id) ?? 1) - 1;
      if (n > 0) recoveryAgents.set(id, n);
      else recoveryAgents.delete(id);
      settleRecovery(id);
    }
  }

  async function recoveryAgentCall(id: string, signature: RecoverySignature): Promise<void> {
    const job = findJob(id);
    if (!job?.recovery || (job.state !== 'awaitingApproval' && job.state !== 'failed')) return;
    const prefs = recoveryPreferences(settings);
    const rec = job.recovery;
    const where = { vaultPath: job.vaultPath, jobDir: jobStateDirectory(job) };
    const denials = job.approval?.denials ?? [];
    const base = recoverySummary(signature, job);
    const stop = (extra: string, proposal?: 'new_session' | 'split_batch' | 'discard_stale_part', groups?: string[][]) =>
      mutate(id, (j) => {
        if (!j.recovery) return;
        j.recovery = { ...j.recovery, state: 'gaveUp', summary: base + extra, ...(proposal ? { proposal } : {}), ...(groups ? { groups } : {}) };
      });
    const context = fixContext(job);
    const spent = rec.attempts.reduce((n, a) => n + a.costUSD, 0);
    if (rec.attempts.filter((a) => a.by === 'agent').length >= prefs.maxAttempts) return stop('');
    if (spent >= prefs.maxCostUSD) return stop(` Recovery stopped at its $${prefs.maxCostUSD.toFixed(2)} limit.`);
    // A minute between agent attempts (review-queue.md, Bounds): the vault or the session may settle.
    const lastAgent = [...rec.attempts].reverse().find((a) => a.by === 'agent');
    const wait = lastAgent ? Date.parse(lastAgent.at) + RECOVERY_BACKOFF_MS - now().getTime() : 0;
    if (wait > 0) {
      const until = new Date(now().getTime() + wait);
      mutate(id, (j) => {
        if (j.recovery) j.recovery = { ...j.recovery, state: 'waiting', waitUntil: isoDate(until) };
      });
      scheduleRecoveryWake(id, signature, wait);
      return;
    }
    const selection = selectionFor(settings, 'recovery');
    const at = isoDate(now());
    const call = Symbol(id);
    agentCalls.set(id, call);
    mutate(id, (j) => {
      if (!j.recovery) return;
      delete j.recovery.waitUntil;
      j.recovery = {
        ...j.recovery,
        state: 'running',
        attempts: [...j.recovery.attempts, { at, by: 'agent', runnerID: selection.runnerID, ...(selection.model ? { model: selection.model } : {}), fix: 'give_up', result: 'running', costUSD: 0 }],
      };
    });
    let answer: RecoveryAnswer | undefined;
    let error: string | undefined;
    let cost = 0;
    try {
      const facts = recoveryFacts({
        signature,
        turns: job.turns.map((t) => ({ author: t.author, text: t.text })),
        denials,
        answersSent: job.turns.filter((t) => t.author === 'app' && /Read, Grep or Glob/.test(t.text)).map((t) => t.text),
        attempts: rec.attempts,
        ...where,
        context,
      });
      const out = await runStructured({
        runners, settings, task: 'recovery', selection, prompt: recoveryPrompt(facts), schema: RECOVERY_SCHEMA,
        scratchRoot: path.join(paths.dir, 'recovery', 'scratch'),
      });
      cost = out.costUSD;
      const parsed = parseRecoveryAnswer(out.value);
      if (typeof parsed === 'string') error = parsed;
      else {
        answer = parsed;
        error = validateFix(parsed, signature, context) ?? undefined;
      }
    } catch (err) {
      error = (err as Error).message;
    }
    const current = findJob(id);
    if (!current?.recovery || (current.state !== 'awaitingApproval' && current.state !== 'failed')) return;
    // The owner may have acted while it ran (a reply, and the recovery that turn started): an answer for a
    // recovery that is no longer this call's is dropped, never carried out.
    const last = current.recovery.attempts.at(-1);
    if (agentCalls.get(id) !== call || current.recovery.state !== 'running' || last?.by !== 'agent' || last.result !== 'running' || last.at !== at) return;
    const settle = (result: 'running' | 'failed' | 'fixed', extra: Partial<RecoveryAttempt> = {}) =>
      mutate(id, (j) => {
        if (!j.recovery) return;
        const attempts = [...j.recovery.attempts];
        const last = attempts[attempts.length - 1];
        if (last && last.at === at) {
          attempts[attempts.length - 1] = { ...last, result, costUSD: cost, ...(answer ? { fix: answer.fix, diagnosis: answer.diagnosis } : {}), ...extra };
        }
        j.recovery = { ...j.recovery, attempts };
      });
    if (error || !answer) {
      settle('failed', { error: error ?? 'No answer.' });
      return stop(answer?.diagnosis ? ` ${answer.diagnosis}` : '');
    }
    switch (answer.fix) {
      case 'answer_denial': {
        const text = answer.guidance!;
        if (precheck(current, 'reply', { text })) {
          settle('failed', { error: 'The batch’s AI session isn’t available anymore.' });
          return stop(' Its AI session isn’t available anymore.');
        }
        settle('running');
        mutate(id, (j) => j.turns.push(newTurn('app', text, now())));
        startTurnProgress(findJob(id)!, 'Drafting page changes', 'Recovering · answering a blocked command');
        const out = resumeBatchSession({ job: findJob(id)!, prompt: WorkerProtocol.replyPrompt(text), action: 'reply', text });
        if (out.kind === 'session_unavailable') stop(' Its AI session isn’t available anymore.');
        return;
      }
      case 'rebuild_in_session': {
        if (signature === 'stale-again') {
          settle('running');
          if (!refreshJob(id, !!current.queuedApply, staleFor(current.vaultPath, current.queuedApply?.bundlePath ?? current.approval?.bundlePath ?? '').map((x) => x.path), true)) {
            settle('failed', { error: 'The rebuild couldn’t start.' });
            return stop(` ${answer.diagnosis}`);
          }
          return;
        }
        const text = rebuildText(signature, current) + (answer.guidance ? `\n\n${answer.guidance}` : '');
        if (precheck(current, 'reply', { text })) {
          settle('failed', { error: 'The batch’s AI session isn’t available anymore.' });
          return stop(' Its AI session isn’t available anymore.', 'new_session');
        }
        settle('running');
        mutate(id, (j) => j.turns.push(newTurn('app', text, now())));
        startTurnProgress(findJob(id)!, 'Drafting page changes', 'Recovering · rebuilding the plan');
        const out = resumeBatchSession({ job: findJob(id)!, prompt: WorkerProtocol.replyPrompt(text), action: 'reply', text });
        if (out.kind === 'session_unavailable') stop(' Its AI session isn’t available anymore.', 'new_session');
        return;
      }
      case 'reinspect_same_bundle':
      case 'wait_then_retry': {
        // Back to the queue under the approved hash only (validateFix checked there is one); the pump re-inspects.
        const wait = answer.fix === 'wait_then_retry' ? RECOVERY_BACKOFF_MS : 0;
        settle('fixed');
        mutate(id, (j) => {
          if (!j.recovery) return;
          j.recovery = { ...j.recovery, state: 'waiting', wake: 'retry', approvedSha256: context.approvedSha256!, waitUntil: isoDate(new Date(now().getTime() + wait)) };
        });
        scheduleRecoveryWake(id, signature, wait);
        return;
      }
      case 'split_batch':
        // review-queue.md, decision 2026-10-06: a proposal the owner confirms on the card (Approve with the first group).
        settle('failed', { error: 'Only you can split the batch.' });
        return stop(` ${answer.diagnosis} Recovery suggests rebuilding ${plural(answer.groups![0]!.length, 'source')} first; the rest wait.`, 'split_batch', answer.groups!.filter((g) => g.length > 0));
      case 'discard_stale_part':
        settle('failed', { error: 'Only you can discard the rebuilt part.' });
        return stop(` ${answer.diagnosis} Recovery suggests discarding the rebuilt part; its sources stay in this batch.`, 'discard_stale_part');
      case 'new_session':
        // Session continuity asks the owner before a new session (owner decision): a proposal only.
        settle('failed', { error: 'Only you can start a new session.' });
        return stop(` ${answer.diagnosis} Recovery suggests continuing in a new session.`, 'new_session');
      default:
        settle('failed');
        return stop(` ${answer.diagnosis}`);
    }
  }

  /** Let recovery try again (the owner's click): attempts start over, the rule first. */
  function tryRecoveryAgain(id: string): Job {
    const job = requireJob(id);
    if ((job.state !== 'awaitingApproval' && job.state !== 'failed') || !job.recovery || job.recovery.state !== 'gaveUp') {
      throw new CoreError('invalid_state', `Job ${id} has nothing for recovery to try again.`);
    }
    const signature = job.recovery.signature;
    // session-gone's only way on is a new session, which the owner starts from its confirmation (never recovery).
    if (signature === 'session-gone') {
      throw new CoreError('invalid_state', 'This batch’s AI session is gone: continue it in a new session, open it in Terminal, or reject it.');
    }
    if (signature === 'lock') {
      // The rule is spent; the agent tries again under the hash the owner approved (kept on the recovery).
      const approved = job.recovery.approvedSha256;
      mutate(id, (j) => {
        delete j.recovery;
      });
      recoverAfterRule(id, 'lock', approved);
      return clone(requireJob(id));
    }
    mutate(id, (j) => {
      delete j.recovery;
    });
    if (!recover(id, signature)) throw new CoreError('invalid_state', 'Recovery can’t run for this batch now. Reply to Claude, open it in Terminal, or reject it.');
    return clone(requireJob(id));
  }

  // ───────────── the apply queue (review-queue.md) ─────────────

  /** A batch in Review that needs the owner: not waiting to apply, not being rebuilt, not recovering. */
  function needsOwner(j: Job): boolean {
    // review-queue.md: a stopped batch recovery gave up on is Couldn't fix, which needs the owner too.
    if (j.state === 'failed') return j.recovery?.state === 'gaveUp';
    if (j.state !== 'awaitingApproval') return false;
    if (j.queuedApply?.planSha256) return false;
    if (j.refresh) return false;
    if (j.recovery?.state === 'running' || j.recovery?.state === 'waiting') return false;
    return true;
  }

  /** The job applying in this vault now (an apply turn or the core's apply). */
  function applyingIn(vaultPath: string, except?: string): Job | undefined {
    return jobs.find((j) => j.id !== except && j.vaultPath === vaultPath && j.state === 'running' && activeProgress.get(j.id)?.kind === 'apply');
  }

  /** Batches in the vault's queue: approved and waiting, rebuilt and waiting for the owner, or being refreshed. */
  function vaultQueue(vaultPath: string): Job[] {
    return queueOrder(
      jobs.map((j) => (j.state === 'running' && j.refresh && j.queuedApply ? { ...j, state: 'awaitingApproval' as const } : j)),
      vaultPath,
    ).map((j) => findJob(j.id)!);
  }

  /** What must apply (or be decided) before an approval with this order. */
  function applyAhead(job: Job, order: number): Job | undefined {
    return applyingIn(job.vaultPath, job.id) ?? vaultQueue(job.vaultPath).find((j) => j.id !== job.id && j.queuedApply!.order < order);
  }

  function batchName(j: Job): string {
    const first = j.files[0];
    return first ? `“${path.basename(first).replace(/\.[^.]+$/, '')}”${j.files.length > 1 ? ` +${j.files.length - 1}` : ''}` : j.id;
  }

  function planFor(j: Job, labels: 'confirm' | 'later'): TransactionPlan | undefined {
    const a = j.approval;
    if (!a?.plan?.valid) return undefined;
    return labels === 'later' && !a.rebuilt && a.unconfirmed ? a.unconfirmed.plan : a.plan;
  }

  function backToOwner(id: string, why: string): void {
    mutate(id, (j) => {
      if (j.queuedApply) delete j.queuedApply.planSha256;
      j.turns.push(newTurn('app', why, now()));
    });
  }

  const pumping = new Set<string>();
  /** LOCK_TIMEOUT waits so far, per vault, for the batch that met the lock. */
  const lockRetries = new Map<string, { jobID: string; n: number }>();
  const lockHeldUntil = new Map<string, number>();
  /** Applies that landed per vault (this run), and the count each batch was last rebuilt against: one rebuild per change. */
  const appliesIn = new Map<string, number>();
  const refreshedAt = new Map<string, number>();

  /** LOCK_TIMEOUT: wait 30 s, then 2 min, and pump again (the head re-inspects, so nothing applies blindly). */
  function scheduleLockRetry(vaultPath: string, jobID: string): void {
    // The count is the batch's: another batch that meets a lock starts at 30 s (the last one may have failed
    // another way, been rejected or taken out of the queue while it waited).
    const prior = lockRetries.get(vaultPath);
    const n = prior?.jobID === jobID ? prior.n : 0;
    if (n >= 2) {
      lockRetries.delete(vaultPath);
      const head = findJob(jobID);
      if (head) {
        // The rule is spent (30 s, then 2 min): the recovery agent may check again or wait, within its bounds,
        // and only ever under the hash the owner approved. The owner is asked to act only when it won't.
        const approved = head.queuedApply?.planSha256;
        const recovering = recoveryPreferences(settings).automatic && !jobKind(head.kind)?.appliesInCore;
        backToOwner(
          head.id,
          recovering
            ? 'Not applied yet: the vault stayed locked for several minutes. Distill’s recovery is looking at it.'
            : 'Not applied: another app kept your vault locked for several minutes. Approve again when it is closed.',
        );
        recoverAfterRule(head.id, 'lock', approved ?? undefined);
      }
      return;
    }
    lockRetries.set(vaultPath, { jobID, n: n + 1 });
    const wait = n === 0 ? 30_000 : 120_000;
    lockHeldUntil.set(vaultPath, Date.now() + wait);
    const t = setTimeout(() => {
      lockHeldUntil.delete(vaultPath);
      void pumpApplies(vaultPath).catch(() => undefined);
    }, wait);
    t.unref?.();
  }

  /**
   * The vault's queue moves: the head applies when `transaction inspect` proves its approved hash unchanged;
   * a stale head is rebuilt and asks the owner once more; a head that needs the owner holds the rest (strict
   * order). When nothing is queued, stale batches nobody approved yet are rebuilt, one at a time.
   */
  async function pumpApplies(vaultPath: string, o: { afterApply?: boolean } = {}): Promise<void> {
    if (pumping.has(vaultPath)) return;
    if ((lockHeldUntil.get(vaultPath) ?? 0) > Date.now()) return;
    pumping.add(vaultPath);
    try {
      for (let guard = 0; guard < 20; guard++) {
        if (applyingIn(vaultPath)) return;
        const head = vaultQueue(vaultPath)[0];
        if (!head) {
          // Plans nobody approved yet go stale only when an apply lands (or were left stale before a restart).
          if (o.afterApply) refreshWaiting(vaultPath);
          return;
        }
        const q = head.queuedApply!;
        if (head.state !== 'awaitingApproval' || !q.planSha256) return;
        const plan = planFor(head, q.labels);
        if (!plan || plan.approval_sha256 !== q.planSha256 || !head.approval?.bundlePath) {
          backToOwner(head.id, 'Not applied yet: the plan changed after you approved it. Approve the plan as it is now.');
          continue;
        }
        const vault = vaultProfileFor(head);
        const outcome = await inspect(q.bundlePath, vault);
        const now_ = findJob(head.id);
        if (!now_ || now_.state !== 'awaitingApproval' || now_.queuedApply?.planSha256 !== q.planSha256) continue;
        if (applyingIn(vaultPath)) return;
        if ('plan' in outcome && outcome.plan.valid && outcome.plan.approval_sha256 === q.planSha256) {
          const again = q.labels === 'later' ? { labels: 'later' as const } : {};
          const gone = coreApplies(now_) ? null : precheck(now_, 'approve', again);
          if (gone) {
            mutate(head.id, (j) => {
              j.sessionUnavailable = { ...gone, action: 'approve' };
              if (j.queuedApply) delete j.queuedApply.planSha256;
              j.turns.push(newTurn('app', 'Not applied yet: this batch’s AI session isn’t available anymore. Continue in a new session to apply it.', now()));
            });
            // session-gone: only the owner may start a new session (session continuity), so recovery proposes it.
            recoverAfterRule(head.id, 'session-gone', q.planSha256 ?? undefined);
            return;
          }
          // The lock's count resets only when an apply lands (applyInCore), not before each try: else the
          // 30 s / 2 min rule never ends and a held lock is retried forever.
          try {
            await approve(head.id, again, true);
          } catch (err) {
            backToOwner(head.id, `Not applied yet: ${(err as Error).message}`);
          }
          return;
        }
        if (!refreshJob(head.id, true, staleFor(vault.path, q.bundlePath).map((s) => s.path))) {
          // Out of the queue first (as for a lock), the approved hash kept on the recovery: a recovery that gives
          // up then reads Couldn't fix / Needs you, and the pump doesn't re-inspect it every tick.
          // (The agent's facts are taken as it starts, while the batch still holds the approved hash.)
          const approved = q.planSha256;
          if (recover(head.id, 'stale-again')) {
            mutate(head.id, (j) => {
              if (j.queuedApply) delete j.queuedApply.planSha256;
              if (j.recovery && approved) j.recovery.approvedSha256 = approved;
            });
          } else {
            backToOwner(head.id, 'Not applied yet: your vault changed after you approved this plan (not by another batch). Reply to have it rebuilt, or reject.');
          }
        }
        return;
      }
    } finally {
      pumping.delete(vaultPath);
    }
  }

  /** Batches nobody approved yet whose plan the vault overtook: rebuilt before the owner looks, one at a time. */
  function refreshWaiting(vaultPath: string): void {
    if (jobs.some((j) => j.vaultPath === vaultPath && j.refresh)) return;
    if (jobs.some((j) => j.vaultPath === vaultPath && j.state === 'running')) return;
    const waiting = jobs
      .filter((j) => j.vaultPath === vaultPath && j.state === 'awaitingApproval' && !j.queuedApply && !j.refresh && !j.recovery)
      .filter((j) => j.approval?.plan?.valid && j.approval.bundlePath && !j.pendingPart && !j.sessionUnavailable)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    for (const j of waiting) {
      const stale = staleFor(vaultPath, j.approval!.bundlePath!);
      if (stale.length === 0) continue;
      if (refreshJob(j.id, false, stale.map((s) => s.path))) return;
    }
  }

  /** The words the core sends when a batch without sources (an older job) needs its plan rebuilt. */
  const STALE_REBUILD_PROMPT =
    'The vault changed after this plan was built (another batch applied first). Rebuild the bundle against the pages as they are now, ' +
    'run `transaction inspect`, and finish with `needs_approval`.';

  /** Rebuild a batch's plan against the vault as it is now, in its own session. False when it can't start. */
  function refreshJob(id: string, approved: boolean, stalePaths: string[], force = false): boolean {
    const job = findJob(id);
    if (!job || job.state !== 'awaitingApproval' || jobKind(job.kind)?.appliesInCore) return false;
    // Never twice against the same vault: a plan still stale after its rebuild changed for another reason
    // (then recovery decides: `force` is its rebuild_in_session).
    const applies = appliesIn.get(job.vaultPath) ?? 0;
    if (!force && refreshedAt.get(id) === applies) return false;
    refreshedAt.set(id, applies);
    const attempt = (job.refresh?.attempt ?? 0) + 1;
    mutate(id, (j) => {
      j.refresh = { since: isoDate(now()), reason: 'stale', stalePaths, approved, attempt };
      if (j.queuedApply) delete j.queuedApply.planSha256;
      if (j.approval) delete j.approval.planError;
    });
    const current = findJob(id)!;
    if (current.kind === queueConsumer().id && (current.approval?.sources?.length ?? 0) > 0 && startPart(id, 'stale', undefined)) return true;
    if (precheck(current, 'reply', { text: STALE_REBUILD_PROMPT })) {
      mutate(id, (j) => {
        delete j.refresh;
        if (j.approval) j.approval.planError = 'The vault changed after this plan was built, and its AI session isn’t available anymore. Reply in a new session to rebuild it, or reject.';
      });
      return false;
    }
    mutate(id, (j) => j.turns.push(newTurn('app', STALE_REBUILD_PROMPT, now())));
    startTurnProgress(findJob(id)!, 'Drafting page changes', 'Updating against the latest pages');
    const out = resumeBatchSession({ job: findJob(id)!, prompt: WorkerProtocol.replyPrompt(STALE_REBUILD_PROMPT), action: 'reply', text: STALE_REBUILD_PROMPT });
    if (out.kind === 'session_unavailable') {
      mutate(id, (j) => {
        delete j.refresh;
      });
      return false;
    }
    return true;
  }

  /** Don't apply yet: out of the queue, back to Ready with its plan. */
  function unqueue(id: string): Job {
    const job = requireJob(id);
    if (job.state !== 'awaitingApproval' || !job.queuedApply) throw new CoreError('invalid_state', `Job ${id} is not waiting to apply.`);
    mutate(id, (j) => {
      delete j.queuedApply;
      delete j.recovery; // the owner acted
      j.turns.push(newTurn('user', 'Not applied yet: taken out of the queue. Approve it when you want it applied.', now()));
    });
    track(pumpApplies(job.vaultPath));
    return clone(requireJob(id));
  }

  // ───────────── labels in Review (review-labels.ts) ─────────────

  /** Fills `sources` and `labels` of a batch's approval from its bundle; true when a confirm revision should run. */
  function attachReviewSources(id: string, request: ApprovalRequest): boolean {
    const job = findJob(id);
    if (!job || job.kind !== queueConsumer().id || !request.bundlePath) return false;
    const b = readBundle(request.bundlePath);
    const pages = b ? sourcePages(b) : [];
    if (pages.length === 0) return false;
    request.sources = reviewSources(pages);
    const confirm = needsRevision(pages);
    request.labels = { state: confirm ? 'confirming' : 'confirmed' };
    if (request.plan) request.unconfirmed = { bundlePath: request.bundlePath, plan: clone(request.plan) };
    return confirm;
  }

  function setReviewLabels(id: string, labels: ReviewLabels, sources?: ReviewSource[]): void {
    mutate(id, (j) => {
      if (!j.approval) return;
      j.approval.labels = labels;
      if (sources) j.approval.sources = clone(sources);
    });
  }

  /**
   * Writes a label revision of the job's bundle (confirmed labels, plus `overrides` per page) and
   * inspects it. Only a clean inspect replaces the bundle and plan. `auto` (the confirm revision
   * the core makes itself): a refusal leaves the original bundle and says the labels stay
   * unconfirmed. Otherwise (the user's edit): a refusal throws and nothing changes.
   */
  async function reviseReviewLabels(id: string, overrides: Map<string, string[]> | undefined, auto: boolean): Promise<void> {
    const job = findJob(id);
    const base = job?.approval?.bundlePath;
    if (!job || job.state !== 'awaitingApproval' || !base || !job.approval?.plan?.valid) {
      if (auto) return;
      throw new CoreError('invalid_state', `Job ${id} has no plan to change.`);
    }
    const before = job.approval.labels ? clone(job.approval.labels) : null;
    const b = readBundle(base);
    if (!b) {
      if (auto) {
        setReviewLabels(id, { state: 'unconfirmed', message: "Labels stay unconfirmed: Distill could not read this batch's bundle. Approving applies them as suggestions." });
        return;
      }
      throw new CoreError('invalid_state', "Distill could not read this batch's bundle.");
    }
    const pages = sourcePages(b);
    if (!needsRevision(pages, overrides)) {
      setReviewLabels(id, { ...(before ?? {}), state: 'confirmed' });
      return;
    }
    revising.add(id);
    setReviewLabels(id, { state: 'confirming', ...(before?.revision ? { revision: before.revision } : {}) });
    try {
      const rev = writeRevision(b, pages, overrides);
      if (!rev) {
        setReviewLabels(id, { ...(before ?? {}), state: 'confirmed' });
        return;
      }
      const outcome = await inspect(rev.bundlePath, vaultProfileFor(job));
      const current = findJob(id);
      // A reply or a rejection meanwhile: this revision is for a bundle that is no longer the job's.
      if (!current || current.state !== 'awaitingApproval' || current.approval?.bundlePath !== base) return;
      if ('plan' in outcome && outcome.plan.valid) {
        const plan = outcome.plan;
        // The user's edits go into the unconfirmed version too (the AI's own startup suggestions don't: prepareReviewLabels wrote them there unconfirmed).
        const twin = overrides && !auto ? await reviseTwin(current, overrides) : undefined;
        mutate(id, (j) => {
          if (!j.approval) return;
          j.approval.bundlePath = rev.bundlePath;
          j.approval.plan = plan;
          delete j.approval.planError;
          j.approval.labels = { state: 'confirmed', revision: rev.revision };
          if (twin !== undefined) j.approval.unconfirmed = twin;
          if (overrides && j.approval.sources) {
            j.approval.sources = j.approval.sources.map((s) => {
              const next = overrides.get(s.page);
              return next ? { ...s, labels: [...next], by: next.length > 0 ? 'user' : 'none', state: null } : s;
            });
          }
          j.turns.push(
            newTurn(
              'app',
              auto
                ? `Labels are in the change as confirmed (revision ${rev.revision}, checked by the vault core): approving confirms the labels shown.`
                : `Changed labels on ${plural(rev.changed.length, 'page')} (revision ${rev.revision}, checked by the vault core).`,
              now(),
            ),
          );
        });
        return;
      }
      const reason = inspectReason('error' in outcome ? outcome.error : 'the plan was not valid');
      if (auto) {
        setReviewLabels(id, {
          state: 'unconfirmed',
          message: `Labels stay unconfirmed: the vault core refused the change with confirmed labels (${reason}). Approving applies the batch with these labels as suggestions; confirm them later in Labels, or reply to Claude to rebuild the batch.`,
        });
        mutate(id, (j) => j.turns.push(newTurn('app', `Labels stay unconfirmed: ${reason}`, now())));
        return;
      }
      setReviewLabels(id, before ?? { state: 'confirmed' });
      throw new CoreError(
        'conflict',
        `Couldn't save your label edit: the vault core refused the edited change (${reason}). Your edit was not kept; the labels are as before.`,
      );
    } finally {
      revising.delete(id);
      // Never leave "confirming" behind (an error before the inspect, or the job moved on).
      if (findJob(id)?.approval?.labels?.state === 'confirming') {
        setReviewLabels(
          id,
          before && before.state !== 'confirming'
            ? before
            : { state: 'unconfirmed', message: 'Labels stay unconfirmed: the change with confirmed labels could not be prepared. Approving applies them as suggestions.' },
        );
      }
    }
  }

  /** The unconfirmed twin with the user's edits applied (confirmed); null when it can't be made or checked. */
  async function reviseTwin(job: Job, overrides: Map<string, string[]>): Promise<{ bundlePath: string; plan: TransactionPlan } | null> {
    const base = job.approval?.unconfirmed?.bundlePath;
    const b = base ? readBundle(base) : undefined;
    if (!b) return null;
    const rev = writeRevision(b, sourcePages(b), overrides, 'keep');
    if (!rev) return job.approval?.unconfirmed ?? null;
    const outcome = await inspect(rev.bundlePath, vaultProfileFor(job));
    return 'plan' in outcome && outcome.plan.valid ? { bundlePath: rev.bundlePath, plan: outcome.plan } : null;
  }

  /**
   * A batch already in Review when this build starts (or one interrupted while its labels were
   * being written): fill its sources, suggest labels (3 at a time) for text sources that have none
   * when it predates labels in Review, then make the confirm revision. The job stays in Review.
   */
  async function prepareReviewLabels(id: string): Promise<void> {
    const job = findJob(id);
    const bundle = job?.approval?.bundlePath;
    if (!job || job.state !== 'awaitingApproval' || !bundle || !job.approval?.plan?.valid || job.kind !== queueConsumer().id) return;
    const b = readBundle(bundle);
    const pages = b ? sourcePages(b) : [];
    if (pages.length === 0) return;
    const firstTime = job.approval.labels == null;
    const sources = clone(job.approval.sources ?? reviewSources(pages));
    const vault = vaultProfileFor(job);
    const overrides = new Map<string, string[]>();
    const missing =
      firstTime && labelingPreferences(settings).autoLabelQueueFolder
        ? pages.filter((p) => p.by === 'none' && p.source && isTextInput(p.source) && suggestInputFor(path.join(vault.path, p.source)))
        : [];
    const source = (page: string) => sources.find((x) => x.page === page);
    if (missing.length > 0) {
      revising.add(id);
      let done = 0;
      const total = missing.length;
      for (const p of missing) Object.assign(source(p.page) ?? {}, { state: 'waiting' });
      setReviewLabels(id, { state: 'suggesting', done, total }, sources);
      try {
        const existing = await existingLabels(vault.path).catch(() => [] as string[]);
        await mapPool(missing, DEFAULT_LABEL_CONCURRENCY, async (p) => {
          const abs = path.join(vault.path, p.source!);
          const known = queueLabeler.lookup(abs);
          let labels = known?.labels ?? known?.suggestedLabels?.map((l) => l.name);
          if (!labels) {
            const key = `label:${id}:${p.source}`;
            const item = path.posix.basename(p.source!);
            Object.assign(source(p.page) ?? {}, { state: 'suggesting' });
            setReviewLabels(id, { state: 'suggesting', done, total }, sources);
            startProgress({
              key,
              kind: 'labelSuggest',
              message: `Suggesting labels for ${item}`,
              item,
              group: id,
              ...selectionFields(labelSuggestSelection(settings)),
            });
            try {
              const out = await suggestFor(vault, suggestInputFor(abs)!.input, { existing });
              labels = out.labels.map((l) => l.name);
              queueLabeler.remember(abs, { labels: out.labels });
              finishProgress(key);
            } catch (err) {
              finishProgress(key, { error: (err as Error).message });
            }
          }
          done += 1;
          const s = source(p.page);
          if (s) {
            if (labels && labels.length > 0) Object.assign(s, { labels: [...labels], by: 'ai', state: null });
            else s.state = 'failed';
          }
          if (labels && labels.length > 0) overrides.set(p.page, labels);
          setReviewLabels(id, { state: 'suggesting', done, total }, sources);
        });
      } finally {
        revising.delete(id);
      }
      // Leave "suggesting"; the revision below sets confirming, then confirmed or unconfirmed.
      setReviewLabels(id, { state: 'confirming' }, sources);
    } else if (!job.approval.sources) {
      setReviewLabels(id, job.approval.labels ?? { state: 'confirming' }, sources);
    }
    await refreshUnconfirmed(id, job.approval.unconfirmed?.bundlePath ?? bundle, overrides);
    await reviseReviewLabels(id, overrides.size > 0 ? overrides : undefined, true);
    if (overrides.size === 0) return;
    const added = findJob(id)?.approval?.labels?.state === 'confirmed';
    mutate(id, (j) => {
      if (!j.approval?.sources) return;
      j.approval.sources = j.approval.sources.map((s) => {
        if (!overrides.has(s.page)) return s;
        // In the change: shown as the AI's (dashed). Not in it: Review never shows labels the change lacks.
        return added ? { ...s, by: 'ai' } : { ...s, labels: [], by: 'none', state: null };
      });
    });
  }

  /**
   * "Approve, review labels later" for a batch already in Review when this build starts: its unconfirmed version is
   * the bundle it was built with (or, when labels were suggested now, that bundle with them written as the AI's,
   * left to review), inspected again now so its approval hash is fresh. Approve stays refused meanwhile.
   */
  async function refreshUnconfirmed(id: string, base: string, suggested: Map<string, string[]>): Promise<void> {
    const job = findJob(id);
    const b = readBundle(base);
    if (!job || !b) return;
    revising.add(id);
    try {
      const rev = suggested.size > 0 ? writeRevision(b, sourcePages(b), suggested, 'suggest') : undefined;
      const target = rev?.bundlePath ?? base;
      const outcome = await inspect(target, vaultProfileFor(job));
      const ok = 'plan' in outcome && outcome.plan.valid;
      mutate(id, (j) => {
        if (!j.approval || j.state !== 'awaitingApproval') return;
        if (ok) j.approval.unconfirmed = { bundlePath: target, plan: outcome.plan };
        else delete j.approval.unconfirmed;
      });
      if (!ok) log('warn', `Review labels: ${id} has no version with unconfirmed labels (${inspectReason('error' in outcome ? outcome.error : 'the plan was not valid')}).`);
    } finally {
      revising.delete(id);
    }
  }

  async function editReviewLabels(jobID: string, edits: { page: string; labels: string[] }[]): Promise<Job> {
    if (!Array.isArray(edits) || edits.length === 0) throw new CoreError('invalid_request', 'No label edits given.');
    const job = requireJob(jobID);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${jobID} is not awaiting approval.`);
    if (revising.has(jobID)) throw new CoreError('busy', 'Distill is still saving labels into this change. Try again when that finishes.');
    const known = new Set((job.approval?.sources ?? []).map((s) => s.page));
    const overrides = new Map<string, string[]>();
    for (const e of edits) {
      if (!e || typeof e.page !== 'string' || !known.has(e.page)) {
        throw new CoreError('invalid_request', `Not a source page of this batch: ${String(e?.page)}`);
      }
      overrides.set(e.page, cleanLabels(e.labels));
    }
    await reviseReviewLabels(jobID, overrides, false);
    return clone(requireJob(jobID));
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

  // ───────────── the label gate and parts of a batch ─────────────

  /**
   * Queue paths a batch must leave for later because their labels are not in yet (decision
   * 2026-10-05). Process now (`force`) also starts labels for text files that are not settled
   * yet and holds them until they are in.
   */
  function labelGate(force: boolean): Set<string> {
    refreshQueue({ fresh: true });
    const held = new Set<string>();
    for (const e of queueEntries()) {
      let l = e.labels;
      if (force && !e.settled && (e.kind ?? 'file') === 'file' && !e.problem && !e.waiting && isTextInput(e.name)) {
        l = queueLabeler.describe({ ...e, settled: true }) ?? null;
      }
      if (QueueLabeler.held(l)) held.add(e.path);
    }
    return held;
  }

  function nextPartBundle(dir: string): number {
    let n = 1;
    while (fs.existsSync(path.join(dir, `bundle-part-${n}.json`))) n += 1;
    return n;
  }

  /**
   * Asks the batch's own session for a change holding exactly some sources: the picked ones
   * (`partial`), the same ones after the vault changed (`stale`). What the user saw is recorded
   * (sha256 per source page) so the rebuilt change can be checked before it is shown.
   */
  function startPart(id: string, reason: 'partial' | 'stale', sel?: { picked: string[]; labels: 'confirm' | 'later' }, newSession = false): boolean {
    const job = findJob(id);
    const approval = job?.approval;
    if (!job || !approval?.bundlePath) return false;
    const sources = approval.sources ?? [];
    const labels = sel?.labels ?? approval.rebuilt?.labels ?? applyingLabels.get(id) ?? 'confirm';
    const variantPath = labels === 'later' && approval.unconfirmed && !approval.rebuilt ? approval.unconfirmed.bundlePath : approval.bundlePath;
    const b = readBundle(variantPath);
    const confirmB = variantPath === approval.bundlePath ? b : readBundle(approval.bundlePath);
    if (!b || !confirmB) return false;
    const shas = pageShas(b);
    const cshas = pageShas(confirmB);
    const active = sources.filter((s) => !s.removed);
    const picked = sel?.picked ?? active.map((s) => s.page);
    const keep = active.filter((s) => picked.includes(s.page));
    const rest = active.filter((s) => !picked.includes(s.page));
    const removed = sources.filter((s) => s.removed);
    if (keep.some((s) => !shas.has(s.page)) || rest.some((s) => !cshas.has(s.page))) return false;
    const dir = jobStateDirectory(job);
    const n = nextPartBundle(dir);
    const pagesDir = path.join(dir, `part-${n}-pages`);
    const keepFiles = keep.map((s) => ({ page: s.page, source: s.source ?? null, contentFile: contentFileFor(b, s.page, pagesDir)!, sha256: shas.get(s.page)! }));
    const restFiles = Object.fromEntries(rest.map((s) => [s.page, contentFileFor(confirmB, s.page, pagesDir)!]));
    const part: PendingPart = {
      reason,
      expected: Object.fromEntries(keepFiles.map((k) => [k.page, k.sha256])),
      excluded: [...rest, ...removed].map((s) => s.page),
      labels,
      rest: clone(rest),
      restExpected: Object.fromEntries(rest.map((s) => [s.page, cshas.get(s.page)!])),
      restFiles,
      removed: clone(removed),
      shown: clone(keep),
    };
    if (reason === 'partial') part.before = clone(approval);
    if (job.pendingPart?.unread?.length) part.unread = [...job.pendingPart.unread];
    part.bundlePath = path.join(dir, `bundle-part-${n}.json`);
    const prompt = partPrompt({
      reason,
      bundlePath: part.bundlePath,
      keep: keepFiles,
      leaveOut: rest.map((s) => ({ page: s.page, source: s.source ?? null })),
      removed: removed.map((s) => ({ page: s.page, source: s.source ?? null })),
    });
    const said =
      reason === 'partial'
        ? `Approve ${plural(keep.length, 'source')} of ${active.length}${labels === 'later' ? ', labels left to review' : ''}: rebuilding the change for ${keep.length === 1 ? 'it' : 'them'} in this batch's session.` +
          (removed.length > 0 ? ` Removed: ${removed.map((s) => s.title).join(', ')}.` : '')
        : "The vault changed after review, so this batch's change is rebuilt in its own session for the vault as it is now.";
    part.prompt = prompt;
    const progress = `Rebuilding the change for ${plural(keep.length, 'source')}`;
    if (reason === 'stale') {
      // From an apply in the background: nobody to ask right now, so a gone session leaves the sources waiting in Review.
      sendPartInBackground(id, part, said, progress);
      return true;
    }
    const again = { labels: labels, pages: keep.map((s) => s.page) };
    if (newSession) {
      mutate(id, (j) => {
        j.pendingPart = part;
      });
      continueInNewSession(id, 'approve', { userTurn: said, prompt });
      const current = findJob(id);
      if (current) startTurnProgress(current, 'Drafting page changes', progress);
      return true;
    }
    const gone = precheck(job, 'approve', again);
    if (gone) throw sessionUnavailableError(gone);
    const snapshot = clone(job);
    mutate(id, (j) => {
      j.pendingPart = part;
      j.turns.push(newTurn('user', said, now()));
    });
    const current = findJob(id);
    if (current) startTurnProgress(current, 'Drafting page changes', progress);
    const out = resumeBatchSession({ job: current ?? job, prompt, action: 'approve', snapshot, ...again });
    if (out.kind === 'session_unavailable') throw sessionUnavailableError(out);
    return true;
  }

  /**
   * A part's rebuild started by the core itself (what is left after a part applied; a change rebuilt after the vault
   * changed). The sources first wait in Review with no plan (`needsRebuild`), so a session found gone leaves exactly
   * that, with the marker for SessionReplaceConfirm (Continue = Approve in a new session); otherwise the request runs.
   */
  function sendPartInBackground(id: string, part: PendingPart, said: string, progress: string): void {
    mutate(id, (j) => {
      j.pendingPart = part;
      j.state = 'awaitingApproval';
      j.approval = {
        summary: j.approval?.summary ?? '',
        questions: [],
        denials: [],
        skipped: [],
        sources: clone(part.shown ?? []),
        labels: part.labels === 'later' ? { state: 'unconfirmed', message: 'Labels stay unconfirmed: you chose to review them later in Labels.' } : { state: 'confirmed' },
        needsRebuild: true,
      };
    });
    const waiting = findJob(id);
    if (!waiting) return;
    const snapshot = clone(waiting);
    mutate(id, (j) => j.turns.push(newTurn('app', said, now())));
    startTurnProgress(findJob(id) ?? waiting, 'Drafting page changes', progress);
    const out = resumeBatchSession({ job: findJob(id) ?? waiting, prompt: part.prompt ?? '', action: 'approve', snapshot });
    if (out.kind === 'session_unavailable') {
      const { kind: _k, ...gone } = out;
      mutate(id, (j) => {
        j.sessionUnavailable = { ...gone, action: 'approve' };
        delete j.refresh;
      });
    }
  }

  /** After a part applied: the sources the user did not pick get their own rebuilt change, in the same session. */
  function continueAfterPart(id: string, operationID: string): void {
    const job = findJob(id);
    const part = job?.pendingPart;
    if (!job || !part) return;
    const rest = part.rest ?? [];
    const keep = rest
      .map((s) => ({ page: s.page, source: s.source ?? null, contentFile: part.restFiles?.[s.page] ?? '', sha256: part.restExpected?.[s.page] ?? '' }))
      .filter((k) => k.contentFile && k.sha256);
    if (keep.length === 0) {
      const unread = part.unread ?? [];
      mutate(id, (j) => {
        delete j.pendingPart;
      });
      // v10: what one session couldn't finish is read again in a fresh session, after this part applied.
      if (unread.length > 0) fullRead.startUnreadPart(id, unread);
      return;
    }
    const next: PendingPart = {
      ...(part.unread?.length ? { unread: [...part.unread] } : {}),
      reason: 'remaining',
      expected: Object.fromEntries(keep.map((k) => [k.page, k.sha256])),
      excluded: [...(job.parts ?? []).flatMap((p) => p.pages), ...(part.removed ?? []).map((s) => s.page)],
      labels: 'confirm',
      rest: [],
      removed: part.removed ?? [],
      shown: clone(rest),
    };
    const dir = jobStateDirectory(job);
    next.bundlePath = path.join(dir, `bundle-part-${nextPartBundle(dir)}.json`);
    const prompt = partPrompt({
      reason: 'remaining',
      bundlePath: next.bundlePath,
      keep,
      leaveOut: [],
      removed: (part.removed ?? []).map((s) => ({ page: s.page, source: s.source ?? null })),
      appliedOperation: operationID,
    });
    next.prompt = prompt;
    sendPartInBackground(
      id,
      next,
      `${plural(keep.length, 'source')} of this batch still ${keep.length === 1 ? 'waits' : 'wait'} for your OK; rebuilding ${keep.length === 1 ? 'its' : 'their'} change in this batch's session.`,
      `Rebuilding the change for the ${plural(keep.length, 'source')} left`,
    );
  }

  /**
   * v10: a part of the full-read split. `covered`: the covered pages byte for byte, nothing (page or
   * ledger record) for the sources left out. `unread` (a fresh session): nothing for the parts
   * already applied or the stopped sources. On a match the part is reviewed like a batch.
   */
  function checkSplitPart(id: string, request: ApprovalRequest, part: PendingPart): boolean {
    const job = findJob(id);
    if (!job || !request.plan?.valid || !request.bundlePath) return false;
    const b = readBundle(request.bundlePath);
    const out = fullRead.excludedOf(job);
    const stopped = (job.stopped ?? []).map((s) => s.file);
    const stoppedShas = (job.stopped ?? []).flatMap((s) => (s.sha256 ? [s.sha256] : []));
    let current: unknown;
    try {
      current = JSON.parse(fs.readFileSync(path.join(job.vaultPath, 'wiki', 'meta', 'ledgers', 'source-ledger.json'), 'utf8'));
    } catch {
      current = undefined;
    }
    const problems = b
      ? verifyRebuilt(b, part.reason === 'covered' ? part.expected : {}, part.excluded, [...new Set([...out.files, ...stopped])], [...new Set([...out.sha256, ...stoppedShas])], current)
      : ['its bundle could not be read'];
    if (problems.length > 0) {
      delete request.plan;
      request.planError =
        `The change doesn't hold exactly the sources that were read in full (${problems.slice(0, 5).join('; ')}${problems.length > 5 ? '; …' : ''}). ` +
        'Nothing was applied. Reply to Claude to try again, or reject.';
      return false;
    }
    if (part.reason === 'unread') {
      mutate(id, (j) => {
        delete j.pendingPart;
      });
    }
    return true;
  }

  /** A change the session rebuilt for a part: checked against what the user approved before it is shown. Never starts a label revision. */
  function checkRebuiltPart(id: string, request: ApprovalRequest, part: PendingPart): boolean {
    if (!request.plan?.valid || !request.bundlePath) return false;
    const b = readBundle(request.bundlePath);
    const problems = b ? verifyRebuilt(b, part.expected, part.excluded) : ['its bundle could not be read'];
    if (problems.length > 0) {
      delete request.plan;
      request.planError =
        `The rebuilt change doesn't match what you approved (${problems.slice(0, 5).join('; ')}${problems.length > 5 ? '; …' : ''}). ` +
        'Nothing was applied. Reply to Claude to try again, or reject.';
      return false;
    }
    request.rebuilt = { reason: part.reason === 'unread' ? 'covered' : part.reason, pages: Object.keys(part.expected), labels: part.labels };
    // review-queue.md: the owner had approved it: say what differs from what they approved (they approve once more).
    const queued = findJob(id)?.queuedApply;
    if (queued && part.reason === 'stale') request.sinceApproved = sinceApproved(queued.bundlePath, request.bundlePath, Object.keys(part.expected));
    request.sources = clone(part.shown ?? []);
    request.labels =
      part.labels === 'confirm'
        ? { state: 'confirmed' }
        : { state: 'unconfirmed', message: 'Labels stay unconfirmed: you chose to review them later in Labels.' };
    // The part's `rest` is kept on the job until this change applies (then what is left is rebuilt).
    return false;
  }

  /** Record an applied set of sources on the job (History lists the parts). */
  function addPart(j: Job, operationID: string, approval: ApprovalRequest | undefined): void {
    const pages = approval?.rebuilt?.pages ?? (approval?.sources ?? []).filter((s) => !s.removed).map((s) => s.page);
    const labels = approval?.rebuilt?.labels ?? applyingLabels.get(j.id) ?? 'confirm';
    applyingLabels.delete(j.id);
    if (pages.length === 0) return;
    const part: JobPart = { operationID, pages, labels, at: isoDate(now()) };
    j.parts = [...(j.parts ?? []), part];
    if (!(j.pendingPart?.rest?.length) && !(j.pendingPart?.unread?.length)) delete j.pendingPart;
  }

  function mergedPaths(j: Job, changed: string[]): string[] {
    return (j.parts?.length ?? 0) > 1 ? [...new Set([...j.changedPaths, ...changed])] : [...changed];
  }

  async function removeReviewSource(jobID: string, page: string, removed: boolean): Promise<Job> {
    const job = requireJob(jobID);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${jobID} is not awaiting approval.`);
    if (typeof removed !== 'boolean') throw new CoreError('invalid_request', 'removed must be true or false.');
    if (revising.has(jobID)) throw new CoreError('busy', 'Distill is still saving labels into this change. Try again when that finishes.');
    const src = job.approval?.sources?.find((s) => s.page === page);
    if (!src) throw new CoreError('not_found', `Not a source page of this batch: ${page}`);
    mutate(jobID, (j) => {
      const s = j.approval?.sources?.find((x) => x.page === page);
      if (!s) return;
      if (removed) s.removed = true;
      else delete s.removed;
    });
    return clone(requireJob(jobID));
  }

  // ───────────── re-read sources (v9) ─────────────

  function saveRereads(): void {
    try {
      rereads.save();
    } catch (err) {
      log('error', `Could not save re-reads: ${(err as Error).message}`);
    }
  }

  /** Groups of a re-read that have not started are dropped (one of its batches was cancelled). */
  function dropReread(id: string, why: string): void {
    const plan = rereads.plans.find((p) => p.id === id);
    if (!plan) return;
    const left = plan.groups.filter((g) => !g.jobId).length;
    if (left === 0) return;
    plan.groups = plan.groups.filter((g) => g.jobId);
    saveRereads();
    log('info', `Re-read ${id}: ${plural(left, 'group')} not started were dropped (${why}).`);
  }

  /** What the first prompt says about each input: sizes as text and the existing source page(s). */
  function rereadFacts(vaultPath: string, files: string[]): { facts: RereadFacts; labels: SourceLabels[] } {
    const existing = existingSourcePages(vaultPath, files);
    const facts: RereadFacts = {
      sources: files.map((file) => {
        const size = sourceSize(path.join(vaultPath, file));
        return { file, ...(size ?? {}), pages: existing.get(file)?.pages ?? [] };
      }),
    };
    // The labels already on each existing source page are written back unchanged.
    const labels = files.flatMap((f) => {
      const l = existing.get(f)?.labels;
      return l ? [l] : [];
    });
    return { facts, labels };
  }

  /**
   * Start the next waiting re-read group on every vault that is free (same rule as a batch: no
   * job running there; batches waiting in Review don't block). Synchronous from the check to the
   * job's first turn, so the timer's batch can't start in between.
   */
  function pumpRereads(): void {
    let changed = false;
    for (const plan of [...rereads.plans]) {
      const group = plan.groups.find((g) => !g.jobId);
      if (!group) continue;
      // v10: a repair's next batch starts when the previous one has APPLIED (or ended), never while it waits in
      // Review, so no repair bundle goes stale against another.
      if (plan.reason === 'repair') {
        const prev = plan.groups.filter((g) => g.jobId).map((g) => findJob(g.jobId!));
        if (prev.some((j) => j && (j.state === 'running' || j.state === 'awaitingApproval'))) continue;
      }
      const vault = settings.vaults.find((v) => v.path === plan.vaultPath);
      if (!vault) continue;
      if (batchBlocker(vault)) continue;
      startRereadGroup(plan, group, vault);
      changed = true;
    }
    if (changed) saveRereads();
  }

  function startRereadGroup(plan: RereadPlan, group: RereadGroup, vault: VaultProfile): Job {
    const kind = queueConsumer();
    const selection = ingestSelection();
    const index = plan.groups.indexOf(group) + 1;
    const job = newJob({ id: makeJobID(now()), kind: kind.id, vaultPath: vault.path, files: [...group.files], model: selection.model, now: now() });
    if (group.folders?.length) job.folders = [...group.folders];
    job.runnerID = selection.runnerID;
    if (selection.effort) job.effort = selection.effort;
    job.reread = {
      id: plan.id,
      group: index,
      groups: plan.groups.length,
      ...(plan.fromJob ? { fromJob: plan.fromJob } : {}),
      ...(plan.instruction ? { instruction: plan.instruction } : {}),
      ...(plan.reason && plan.reason !== 'manual' ? { reason: plan.reason } : {}),
    };
    group.jobId = job.id;
    const missing = group.files.map((f) => ({ f, why: sourceFileProblem(vault.path, f) })).filter((x) => x.why);
    job.turns.push(
      newTurn(
        'app',
        `Re-reading ${plural(group.files.length, 'file')} already in inbox/ (group ${index} of ${plan.groups.length} of ${plan.id}${plan.fromJob ? `, sources of ${plan.fromJob}` : ''}; read in place, nothing moved):\n` +
          group.files.map((f) => `- ${f}`).join('\n'),
        now(),
      ),
    );
    insert(job);
    if (missing.length > 0) {
      fail(job.id, `Can't re-read: ${missing.map((m) => `${m.f} is ${m.why}`).join('; ')}.`);
      return clone(findJob(job.id) ?? job);
    }
    const { facts: sizes, labels } = rereadFacts(vault.path, job.files);
    try {
      writeFileAtomic(path.join(jobStateDirectory(job), 'labels.json'), encodeJSON(labels));
    } catch {
      /* a debugging aid, and what a new session reuses */
    }
    jobSteps.set(job.id, batchSteps(false));
    const items = job.files.filter((f) => !job.folders?.some((d) => f.startsWith(d + '/'))).length + (job.folders?.length ?? 0);
    startTurnProgress(findJob(job.id)!, 'Read sources', `Re-reading ${plural(items, 'source')} in ${vaultName(vault.path)}`);
    // v10: the reading copies and this session's coverage record, with the pages each source has.
    const pagesOf = new Map(sizes.sources.map((s) => [s.file, { pages: s.pages }]));
    const prepared = fullRead.prepare(findJob(job.id)!, vault, job.files, { existing: pagesOf });
    const facts: RereadFacts = { sources: prepared.sources, unreadable: prepared.unreadable };
    const current = findJob(job.id)!;
    runTurn(job.id, kind.initialPrompt(new JobContext(clone(current), vault, settings, labels, facts)), { first: true });
    return clone(findJob(job.id) ?? job);
  }

  async function rereadSources(req: RereadRequest): Promise<RereadResult> {
    if (!req || typeof req !== 'object' || Array.isArray(req)) throw new CoreError('invalid_request', 'Expected a re-read request.');
    // v10 (decision 2026-10-05, full reads): groups are packed by tokens unless a count is asked for.
    const perBatch = req.perBatch;
    if (perBatch !== undefined && (!Number.isInteger(perBatch) || perBatch < 1 || perBatch > MAX_REREAD_PER_BATCH)) {
      throw new CoreError('invalid_request', `perBatch must be a whole number from 1 to ${MAX_REREAD_PER_BATCH}.`);
    }
    if (req.tokenBudget !== undefined && (!Number.isInteger(req.tokenBudget) || req.tokenBudget < 1000)) throw new CoreError('invalid_request', 'tokenBudget must be a whole number of tokens (at least 1000).');
    if (req.reason !== undefined && req.reason !== 'manual' && req.reason !== 'repair' && req.reason !== 'retry') throw new CoreError('invalid_request', 'reason must be manual, repair or retry.');
    const tokenBudget = perBatch === undefined ? (req.tokenBudget ?? fullRead.budget(ingestSelection().model).tokens) : undefined;
    if (req.instruction !== undefined && typeof req.instruction !== 'string') throw new CoreError('invalid_request', 'instruction must be text.');
    const hasFiles = Array.isArray(req.files) && req.files.length > 0;
    if (hasFiles === (req.jobId !== undefined)) throw new CoreError('invalid_request', 'Give either files (inbox paths) or jobId.');
    let items: RereadItem[];
    let skipped: { path: string; reason: string }[] = [];
    let vault: VaultProfile;
    let fromJob: string | undefined;
    if (req.jobId !== undefined) {
      const source = requireJob(req.jobId);
      if (source.kind !== queueConsumer().id) throw new CoreError('invalid_request', `${req.jobId} is not a batch of sources.`);
      if (source.state === 'running' || source.state === 'awaitingApproval') {
        throw new CoreError('invalid_state', `${req.jobId} is still ${source.state === 'running' ? 'running' : 'waiting in Review'}; re-read its sources after it is finished.`);
      }
      vault = req.vaultPath ? resolveVault(req.vaultPath) : vaultProfileFor(source);
      if (path.resolve(vault.path) !== path.resolve(source.vaultPath)) throw new CoreError('invalid_request', `${req.jobId} belongs to another vault.`);
      ({ items, skipped } = jobSourceItems(source));
      fromJob = source.id;
    } else {
      vault = resolveVault(req.vaultPath);
      const files = req.files!;
      if (files.some((f) => typeof f !== 'string')) throw new CoreError('invalid_request', 'files must be inbox paths.');
      const seen = new Set<string>();
      items = [];
      for (const f of files) {
        const rel = f.normalize('NFC');
        if (seen.has(rel)) continue;
        seen.add(rel);
        if (rel.endsWith(NOTE_MANIFEST_SUFFIX)) {
          skipped.push({ path: rel, reason: 'a Distill note manifest (instructions, not a source)' });
          continue;
        }
        items.push({ files: [rel] });
      }
    }
    if (!isVault(vault.path)) throw new CoreError('invalid_state', problem.notAVault(vault.path).message);
    // Every file must still be in inbox/: a missing one is an error, never a silent partial re-read.
    const unreadable = items.flatMap((i) => i.files).flatMap((f) => {
      const why = sourceFileProblem(vault.path, f);
      return why ? [`${f}: ${why}`] : [];
    });
    if (unreadable.length > 0) {
      throw new CoreError('invalid_request', `Can't re-read ${plural(unreadable.length, 'file')}:\n${unreadable.map((p) => `- ${p}`).join('\n')}`);
    }
    if (items.length === 0) throw new CoreError('invalid_request', 'No sources to re-read.');
    const plan: RereadPlan = {
      id: makeRereadID(now()),
      vaultPath: vault.path,
      createdAt: isoDate(now()),
      perBatch: perBatch ?? 0,
      groups: perBatch !== undefined ? groupItems(items, perBatch) : packItems(items, tokenBudget!, (f: string) => estimateTokens(path.join(vault.path, f))),
      ...(fromJob ? { fromJob } : {}),
      ...(req.instruction?.trim() ? { instruction: req.instruction.trim() } : {}),
      ...(tokenBudget !== undefined ? { tokenBudget } : {}),
      ...(req.reason ? { reason: req.reason } : {}),
    };
    rereads.plans.push(plan);
    saveRereads();
    log('info', `Re-read ${plan.id}: ${plural(items.length, 'source')} in ${plan.groups.length} batch(es) ${perBatch !== undefined ? `of up to ${perBatch}` : `of up to about ${Math.round(tokenBudget! / 1000)}K tokens`}.`);
    const before = new Set(jobs.map((j) => j.id));
    pumpRereads();
    const started = plan.groups
      .flatMap((g) => (g.jobId && !before.has(g.jobId) ? [findJob(g.jobId)] : []))
      .filter((j): j is Job => !!j);
    const result: RereadResult = {
      id: plan.id,
      vaultPath: plan.vaultPath,
      perBatch: perBatch ?? 0,
      ...(tokenBudget !== undefined ? { tokenBudget } : {}),
      groups: clone(plan.groups),
      started: started.map((j) => clone(j)),
      waiting: plan.groups.filter((g) => !g.jobId).length,
    };
    if (fromJob) result.fromJob = fromJob;
    if (skipped.length > 0) result.skipped = skipped;
    return result;
  }


  // ───────────── public API ─────────────

  /**
   * v10 (full reads): ready items packed by estimated tokens, oldest first; items are atomic (a note
   * with its manifest and images, a folder item); an item over the budget alone gets its own batch.
   */
  function packReady(ready: ScanEntry[], budgetTokens: number): { take: ScanEntry[]; groups: number; tokens: number } {
    const sets = noteSets(ready);
    const memberOf = new Map<string, string>();
    for (const s of sets) for (const f of [s.manifest, ...s.images]) memberOf.set(f, s.note);
    const items: { entries: ScanEntry[]; tokens: number; at: number }[] = [];
    const byPath = new Map(ready.map((e) => [e.path, e]));
    for (const e of ready) {
      if (memberOf.has(e.path)) continue;
      const set = sets.find((s) => s.note === e.path);
      const entries = set ? [e, ...[set.manifest, ...set.images].flatMap((p) => (byPath.has(p) ? [byPath.get(p)!] : []))] : [e];
      const tokens = entries.reduce((n, x) => {
        if (x.path.endsWith(NOTE_MANIFEST_SUFFIX)) return n;
        if (x.folder) return n + Math.ceil(x.folder.sourceBytes / 2.6);
        return n + estimateTokens(x.path);
      }, 0);
      items.push({ entries, tokens, at: e.modifiedMs });
    }
    items.sort((a, b) => a.at - b.at);
    const take: ScanEntry[] = [];
    let used = 0;
    let groups = 0;
    let current = 0;
    for (const item of items) {
      if (current > 0 && current + item.tokens > budgetTokens) {
        groups += 1;
        current = 0;
      }
      current += item.tokens;
      if (groups === 0) {
        take.push(...item.entries);
        used += item.tokens;
      }
    }
    if (current > 0) groups += 1;
    return { take, groups: Math.max(1, groups), tokens: used };
  }

  async function processQueue(o: { force?: boolean; overflow?: boolean } = {}): Promise<Job | null> {
    const blocker = batchBlocker();
    if (blocker) {
      if (o.force) log('warn', blocker);
      return null;
    }
    const vault = activeVault(settings);
    if (!vault) return null;
    const settle = o.force ? 0 : settings.settleSeconds;
    // Failed label suggestions with tries left are asked again (they stay held meanwhile).
    if (queueLabeler.autoRetry() > 0) refreshQueue();
    // Notes written by addNote skip the wait; files the core can't read stay behind.
    // Folders are walked again here (never from the cache), so the wait follows the newest change inside them.
    const held = labelGate(o.force === true);
    const allReady = readyFiles(scanActive(vault, true), settle, now()).filter((e) => !held.has(e.path));
    if (held.size > 0) log('info', `${plural(held.size, 'file')} still ${held.size === 1 ? 'waits' : 'wait'} for labels; ${held.size === 1 ? 'it goes' : 'they go'} in the next batch.`);
    if (allReady.length === 0) {
      overflow = undefined;
      return null;
    }
    // v10 (full reads): a batch takes only as much text as one session can read in full.
    const budget = fullRead.budget(ingestSelection().model);
    const packed = packReady(allReady, budget.tokens);
    const ready = packed.take;
    const batchOf = o.overflow && overflow ? { index: overflow.index + 1, total: Math.max(overflow.total, overflow.index + packed.groups) } : { index: 1, total: packed.groups };
    overflow = batchOf.total > 1 ? { index: batchOf.index, total: batchOf.total } : undefined;
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
    const selection = ingestSelection();
    const job = newJob({ id: makeJobID(now()), kind: kind.id, vaultPath: vault.path, files, model: selection.model, now: now() });
    if (folders.length > 0) job.folders = folders;
    job.runnerID = selection.runnerID;
    if (selection.effort) job.effort = selection.effort;
    if (batchOf.total > 1) job.batchOf = { ...batchOf, tokens: packed.tokens };
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
    const draft = draftBatchLabels(
      vault.path,
      loose,
      labelingPreferences(settings),
      (rid) => noteLabels.get(rid),
      (rel) => queueLabeler.lookup(path.join(vault.path, rel)),
    );
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
      // v10: the reading copies and this session's coverage record, before the first turn.
      const facts = fullRead.prepare(current, vault, current.files);
      runTurn(job.id, kind.initialPrompt(new JobContext(clone(findJob(job.id) ?? current), vault, settings, plan, facts)), { first: true });
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
        ...(draft.pending[0] ? { current: draft.pending[0].entry.file } : {}),
        ...selectionFields(labelSuggestSelection(settings)),
      });
      track(
        (async () => {
          let cost = 0;
          let done = 0;
          const failures: string[] = [];
          const existing = await existingLabels(vault.path).catch(() => [] as string[]);
          // What the queue did not label yet, at most 3 files at a time; each result is also kept in
          // the queue's label state so a retry or a later batch reuses it.
          await mapPool(draft.pending, DEFAULT_LABEL_CONCURRENCY, async ({ entry, input }) => {
            if (controller.signal.aborted) return;
            const abs = path.join(vault.path, entry.file);
            const known = queueLabeler.lookup(abs);
            opts.steps?.labelFile(job.id, entry.file, 'running');
            // The progress line names the file that just started (up to 3 run at once).
            updateProgress(job.id, { current: entry.file });
            if (known?.suggestedLabels && known.suggestedLabels.length > 0) {
              entry.labels = known.suggestedLabels.map((l) => l.name);
              opts.steps?.labelFile(job.id, entry.file, 'done', entry.labels.length);
            } else {
              const key = `label:${job.id}:${entry.file}`;
              const item = path.posix.basename(entry.file);
              startProgress({
                key,
                kind: 'labelSuggest',
                message: `Suggesting labels for ${item}`,
                item,
                group: job.id,
                ...selectionFields(labelSuggestSelection(settings)),
              });
              let error: string | undefined;
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
                if (entry.origin === 'queue-folder') queueLabeler.remember(abs, { labels: out.labels });
                opts.steps?.labelFile(job.id, entry.file, 'done', entry.labels.length);
              } catch (err) {
                error = controller.signal.aborted ? 'Stopped.' : (err as Error).message;
                if (!controller.signal.aborted) {
                  opts.steps?.labelFile(job.id, entry.file, 'failed');
                  failures.push(`${entry.file}: ${error}`);
                }
              } finally {
                finishProgress(key, error ? { error } : {});
              }
            }
            if (controller.signal.aborted) return;
            done += 1;
            updateProgress(job.id, { done });
          });
          if (controllers.get(job.id) === controller) controllers.delete(job.id);
          if (controller.signal.aborted) {
            mutate(job.id, (j) => {
              j.state = 'cancelled';
              j.turns.push(newTurn('app', CANCELLED_BEFORE_FIRST_TURN, now()));
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

  /** Which labels each in-flight apply carries, for the part it records. */
  const applyingLabels = new Map<string, 'confirm' | 'later'>();

  /**
   * Approve (approval-and-review.md): `labels` confirm (default) applies the plan with the labels
   * confirmed as shown; later applies its twin with them unconfirmed. `pages` picks some sources:
   * then the batch's own session rebuilds the change for just those, and the user approves that
   * rebuilt change once more (it is never applied from here). Every path that needs the batch's
   * session goes through resumeBatchSession; `newSession` (after SessionReplaceConfirm) continues
   * the same approval in a new session, with the same plan and bundle.
   */
  async function approve(id: string, given: ApproveOptions & SessionOptions = {}, fromQueue = false): Promise<void> {
    const job = requireJob(id);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${id} is not awaiting approval.`);
    // Continue after the runner refused mid-turn: the approval the refused call carried is on the job marker.
    const marker = given.newSession ? job.sessionUnavailable : undefined;
    const opts: ApproveOptions & SessionOptions = { ...given };
    if (opts.labels === undefined && marker?.labels !== undefined) opts.labels = marker.labels;
    if (opts.pages === undefined && marker?.pages !== undefined) opts.pages = [...marker.pages];
    const approval = job.approval;
    if (approval?.needsRebuild && job.pendingPart) {
      retryPart(id, job.pendingPart, opts.newSession === true);
      return;
    }
    if (!approval?.plan || !approval.plan.valid || !approval.bundlePath) throw new CoreError('invalid_state', `Job ${id} has no valid plan to approve.`);
    // v10 (full reads): a source that couldn't be read in full is never part of what is approved.
    const stoppedFiles = new Set((job.stopped ?? []).map((s) => s.file));
    const stoppedPage = (approval.sources ?? []).find((s) => s.source && stoppedFiles.has(s.source) && !s.removed);
    if (stoppedPage) throw new CoreError('invalid_state', `${stoppedPage.source} couldn't be read in full, so its page can't be approved.`);
    const labelState = approval.labels?.state;
    if (labelState === 'suggesting') {
      throw new CoreError('invalid_state', 'Labels are still being suggested for this batch. Approve when they are in, so you approve the labels you see.');
    }
    if (revising.has(id) || labelState === 'confirming') {
      throw new CoreError('invalid_state', 'Distill is still saving the labels into this change and checking it again. Approve when that finishes.');
    }
    if (opts.labels !== undefined && opts.labels !== 'confirm' && opts.labels !== 'later') {
      throw new CoreError('invalid_request', 'labels must be "confirm" or "later".');
    }
    const mode = opts.labels === 'later' ? 'later' : 'confirm';
    const sources = approval.sources ?? [];
    const active = sources.filter((s) => !s.removed).map((s) => s.page);
    let picked = active;
    if (opts.pages !== undefined) {
      if (!Array.isArray(opts.pages) || opts.pages.some((p) => typeof p !== 'string')) throw new CoreError('invalid_request', 'pages must be an array of page paths.');
      const unknown = opts.pages.filter((p) => !active.includes(p));
      if (unknown.length > 0) throw new CoreError('invalid_request', `Not a source of this batch (or removed): ${unknown.join(', ')}`);
      picked = active.filter((p) => opts.pages!.includes(p));
    }
    if (sources.length > 0 && picked.length === 0) throw new CoreError('invalid_request', 'Pick at least one source to approve, or reject the batch.');
    const partial = sources.length > 0 && (picked.length < active.length || sources.some((s) => s.removed));
    if (partial) {
      // The owner acted (a pick, or confirming recovery's split): recovery starts over.
      if (!fromQueue) mutate(id, (j) => {
        delete j.recovery;
      });
      if (!startPart(id, 'partial', { picked, labels: mode }, opts.newSession === true)) {
        throw new CoreError('invalid_state', "Distill couldn't prepare the rebuild for the sources you picked (the change's pages could not be read).");
      }
      return;
    }
    let plan: TransactionPlan = approval.plan;
    let bundle: string = approval.bundlePath;
    if (mode === 'later' && !approval.rebuilt) {
      if (!approval.unconfirmed) throw new CoreError('invalid_state', 'This change has no version with unconfirmed labels; approve it with the labels shown.');
      plan = approval.unconfirmed.plan;
      bundle = approval.unconfirmed.bundlePath;
    }
    const carries = approval.rebuilt?.labels ?? mode;
    // review-queue.md: one apply at a time per vault, in the order the owner approved (a re-approval keeps its place).
    const order = job.queuedApply?.order ?? now().getTime();
    const queued: QueuedApply = { at: isoDate(now()), order, bundlePath: bundle, labels: mode, carries };
    if (!fromQueue && !opts.newSession) {
      const ahead = applyAhead(job, order);
      if (ahead) {
        mutate(id, (j) => {
          j.queuedApply = { ...queued, planSha256: plan.approval_sha256 };
          delete j.recovery;
          delete j.refresh;
          delete j.approval?.sinceApproved;
          j.turns.push(newTurn('user', `Approved ${plan.operation_id} (${plan.approval_sha256.slice(0, 12)}…). Queued: it applies after ${batchName(ahead)}.`, now()));
        });
        return;
      }
      // Nothing ahead, but the plan is already out of date (the vault changed since it was built): the cheap hash
      // check sends it straight to the refresh instead of spending an apply turn that would come back with exit 75.
      const stale = jobKind(job.kind)?.appliesInCore ? [] : staleFor(job.vaultPath, bundle).map((s) => s.path);
      if (stale.length > 0 && !precheck(job, 'reply', { text: STALE_REBUILD_PROMPT })) {
        const before = job.queuedApply;
        mutate(id, (j) => {
          j.queuedApply = queued;
          delete j.recovery;
          j.turns.push(newTurn('user', `Approved ${plan.operation_id} (${plan.approval_sha256.slice(0, 12)}…). Your vault changed since this plan was built, so it is rebuilt first.`, now()));
        });
        if (refreshJob(id, true, stale)) return;
        mutate(id, (j) => {
          j.turns.pop();
          if (before) j.queuedApply = before;
          else delete j.queuedApply;
        });
      }
    }
    const startingApply = (j: Job) => {
      j.queuedApply = queued; // no planSha256: it never re-applies by itself if it comes back
      // A recovery's retry under the approved hash keeps its attempts while it applies: a lock that comes back
      // continues the same bounds instead of starting over (review-queue.md, Bounds).
      if (!(fromQueue && j.recovery?.approvedSha256 === plan.approval_sha256)) delete j.recovery;
      delete j.refresh;
    };
    const applying = (agent: boolean) =>
      startProgress({
        key: id,
        kind: 'apply',
        message: `Applying ${plural(plan.changed_paths.length, 'change')}`,
        ...(agent ? selectionFields({ runnerID: jobRunnerID(job), model: job.model }) : {}),
      });
    const record = () =>
      mutate(id, (j) => {
        j.approvedChange = approvedChangeOf(j, plan);
        delete j.reviewDoneAt;
        startingApply(j);
      });
    const approvedTurn = `Approved ${plan.operation_id} (${plan.approval_sha256.slice(0, 12)}…)${mode === 'later' && !approval.rebuilt ? ', labels left to review' : ''}`;
    const applyByCore = () => {
      applyingLabels.set(id, carries);
      record();
      mutate(id, (j) => {
        j.state = 'running';
        delete j.error;
        delete j.sessionUnavailable;
        j.turns.push(newTurn('user', approvedTurn, now()));
      });
      applying(false);
      track(applyInCore(id, plan, bundle));
    };
    if (coreApplies(job)) {
      applyByCore();
      return;
    }
    // What a refused call carries, so Continue approves the same version (later) or part.
    const again: { labels?: 'later' } = mode === 'later' ? { labels: 'later' } : {};
    if (opts.newSession) {
      // The batch's runner may be gone: when the runner that would continue can't be limited to the
      // exact apply command, the core applies the approved plan itself (no AI session needed).
      const kind = jobKind(job.kind);
      const current = runners.get(jobRunnerID(job));
      const next = current && kind && runnerSupports(current, kind.task) ? current : kind ? runners.get(selectionFor(settings, kind.task).runnerID) : undefined;
      if (next && !next.capabilities.has('toolPermissions')) {
        applyByCore();
        return;
      }
      applyingLabels.set(id, carries);
      record();
      continueInNewSession(id, 'approve', { userTurn: approvedTurn, plan, bundle });
      applying(true);
      return;
    }
    const gone = precheck(job, 'approve', again);
    if (gone) throw sessionUnavailableError(gone);
    const snapshot = clone(job);
    const ctx = new JobContext(clone(job), vaultProfileFor(job), settings);
    // Only the exact approved command is permitted, and only for this turn.
    const applyRule = `Bash(${WorkerProtocol.applyCommand(ctx, plan, bundle)})`;
    applyingLabels.set(id, carries);
    mutate(id, (j) => {
      j.approvedChange = approvedChangeOf(j, plan);
      delete j.reviewDoneAt;
      startingApply(j);
      j.turns.push(newTurn('user', approvedTurn, now()));
    });
    applying(true);
    const out = resumeBatchSession({
      job: findJob(id) ?? job,
      prompt: WorkerProtocol.approvedPrompt(ctx, plan, bundle),
      extraTools: [applyRule],
      applyPlan: clone(plan),
      action: 'approve',
      snapshot,
      ...again,
    });
    if (out.kind === 'session_unavailable') {
      applyingLabels.delete(id);
      throw sessionUnavailableError(out);
    }
  }

  async function reply(id: string, text: string, opts: SessionOptions = {}): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) throw new CoreError('invalid_request', 'Reply text is empty.');
    const job = requireJob(id);
    requireSession(job);
    if (job.state === 'running') throw new CoreError('busy', `Job ${id} is running.`);
    if (job.state !== 'awaitingApproval' && holdsOtherJob(job)) throw new CoreError('busy', 'Another job holds this vault.');
    if (opts.newSession) {
      // The owner acted (Continue in a new session, the recovery card's too): recovery starts over.
      mutate(id, (j) => {
        delete j.recovery;
      });
      // After the switch: its first change (state not yet running) would close a progress started before.
      continueInNewSession(id, 'reply', { userTurn: trimmed, text: trimmed });
      const current = findJob(id);
      if (current) startTurnProgress(current, 'Drafting page changes', 'Working on your reply in a new session');
      return;
    }
    const gone = precheck(job, 'reply', { text: trimmed });
    if (gone) throw sessionUnavailableError(gone);
    const snapshot = clone(job);
    // The owner acted: recovery's attempts start over (review-queue.md, Bounds).
    mutate(id, (j) => {
      delete j.recovery;
      j.turns.push(newTurn('user', trimmed, now()));
    });
    const current = findJob(id);
    if (current) startTurnProgress(current, 'Drafting page changes', 'Working on your reply');
    const out = resumeBatchSession({ job: current ?? job, prompt: WorkerProtocol.replyPrompt(trimmed), action: 'reply', snapshot, text: trimmed });
    if (out.kind === 'session_unavailable') throw sessionUnavailableError(out);
  }

  /** Grants rules for previously denied calls for the rest of this job, then resumes. */
  async function allow(id: string, rules: string[], opts: SessionOptions = {}): Promise<void> {
    const clean = rules.map((r) => r.trim()).filter(Boolean);
    if (clean.length === 0) throw new CoreError('invalid_request', 'No rules to allow.');
    const job = requireJob(id);
    requireSession(job);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${id} is not awaiting approval.`);
    // Nothing that gets round the approval gate is granted; the whole call is refused before any change.
    const ctx = new JobContext(clone(job), vaultProfileFor(job), settings);
    const refused = clean.flatMap((r) => {
      const why = gateBreakingReason(r, ctx);
      return why ? [`${r} (${why})`] : [];
    });
    if (refused.length > 0) {
      // Rules first: the app's error banner shows three lines.
      throw new CoreError(
        'invalid_request',
        `Distill can't allow ${refused.join('; ')}. ${refused.length === 1 ? 'It' : 'They'} would change the vault without your review; reply with guidance instead.`,
      );
    }
    const allowedTurn = 'Allowed:\n' + clean.map((r) => `- ${r}`).join('\n');
    if (opts.newSession) {
      continueInNewSession(id, 'allow', { userTurn: allowedTurn, rules: clean });
      const current = findJob(id);
      if (current) startTurnProgress(current, 'Drafting page changes', 'Continuing with the tools you allowed, in a new session');
      return;
    }
    const gone = precheck(job, 'allow', { rules: clean });
    if (gone) throw sessionUnavailableError(gone);
    const snapshot = clone(job);
    mutate(id, (j) => {
      j.grantedTools = [...new Set([...j.grantedTools, ...clean])].sort();
      delete j.recovery;
      j.turns.push(newTurn('user', allowedTurn, now()));
    });
    const current = findJob(id);
    if (current) startTurnProgress(current, 'Drafting page changes', 'Continuing with the tools you allowed');
    const out = resumeBatchSession({ job: current ?? job, prompt: WorkerProtocol.grantedPrompt(clean), action: 'allow', snapshot, rules: clean });
    if (out.kind === 'session_unavailable') throw sessionUnavailableError(out);
  }

  async function reject(id: string, opts: RejectOptions = {}): Promise<void> {
    const job = requireJob(id);
    // review-queue.md: a batch whose run stopped and that recovery works on (or gave up on) can be rejected too.
    const stopped = job.state === 'failed' && job.recovery !== undefined;
    if (job.state !== 'awaitingApproval' && !stopped) throw new CoreError('invalid_state', `Job ${id} is not awaiting approval.`);
    if (opts.scope !== undefined && opts.scope !== 'part' && opts.scope !== 'batch') throw new CoreError('invalid_request', 'scope must be "part" or "batch".');
    const part = job.pendingPart;
    if (opts.scope !== 'batch' && part && job.approval?.rebuilt && !job.approval.needsRebuild) {
      mutate(id, (j) => {
        delete j.recovery; // the owner acted (or confirmed recovery's discard)
      });
      discardPart(id, part);
      return;
    }
    if (opts.scope === 'part') throw new CoreError('invalid_state', 'This batch has no rebuilt part to discard; reject the batch instead.');
    mutate(id, (j) => {
      j.state = 'rejected';
      delete j.recovery;
      delete j.queuedApply;
      delete j.refresh;
      j.turns.push(newTurn('user', 'Rejected. Inbox files are kept; nothing was applied.', now()));
    });
  }

  /**
   * Rejecting a rebuilt part discards only that change: nothing is applied and its sources stay in this batch.
   * Part of a batch the user picked: the Review as it was before the pick comes back (every source pending again,
   * with its labels as shown). What is left after a part applied, or a change rebuilt after the vault changed: the
   * sources stay in Review without a plan, and Approve asks the batch's session to rebuild their change again.
   */
  function discardPart(id: string, part: PendingPart): void {
    const n = Object.keys(part.expected).length;
    const what = `the rebuilt change for ${plural(n, 'source')}`;
    mutate(id, (j) => {
      if (part.reason === 'partial' && part.before) {
        j.approval = clone(part.before);
        delete j.pendingPart;
        const total = (j.approval.sources ?? []).filter((s) => !s.removed).length;
        j.turns.push(newTurn('user', `Discarded ${what}; nothing was applied. ${total === 1 ? 'The source is' : `All ${total} sources are`} back in this batch's Review.`, now()));
        return;
      }
      const later = part.labels === 'later';
      j.approval = {
        summary: j.approval?.summary ?? '',
        questions: [],
        denials: [],
        skipped: [],
        sources: clone(part.shown ?? []),
        labels: later ? { state: 'unconfirmed', message: 'Labels stay unconfirmed: you chose to review them later in Labels.' } : { state: 'confirmed' },
        needsRebuild: true,
      };
      j.turns.push(
        newTurn('user', `Discarded ${what}; nothing was applied. ${n === 1 ? 'It stays' : 'They stay'} in this batch: Approve rebuilds ${n === 1 ? 'its' : 'their'} change again, or reject the batch.`, now()),
      );
    });
  }

  /** Approve after a discarded rebuild: the same request goes to the batch's session again, to a new bundle path. */
  function retryPart(id: string, part: PendingPart, newSession = false): void {
    const job = findJob(id);
    if (!job || !part.prompt) throw new CoreError('invalid_state', "Distill can't rebuild this part: its request was not kept. Reply to Claude, or reject the batch.");
    const dir = jobStateDirectory(job);
    const fresh = path.join(dir, `bundle-part-${nextPartBundle(dir)}.json`);
    const prompt = part.bundlePath ? part.prompt.split(part.bundlePath).join(fresh) : part.prompt;
    const n = Object.keys(part.expected).length;
    const said = `Approve ${plural(n, 'source')}: rebuilding ${n === 1 ? 'its' : 'their'} change again in this batch's session.`;
    const progress = `Rebuilding the change for ${plural(n, 'source')}`;
    const update = (j: Job) => {
      if (j.pendingPart) Object.assign(j.pendingPart, { prompt, bundlePath: fresh });
      if (j.approval) delete j.approval.needsRebuild;
    };
    if (newSession) {
      mutate(id, update);
      continueInNewSession(id, 'approve', { userTurn: said, prompt });
      const current = findJob(id);
      if (current) startTurnProgress(current, 'Drafting page changes', progress);
      return;
    }
    const gone = precheck(job, 'approve');
    if (gone) throw sessionUnavailableError(gone);
    const snapshot = clone(job);
    mutate(id, (j) => {
      update(j);
      j.turns.push(newTurn('user', said, now()));
    });
    const current = findJob(id);
    if (current) startTurnProgress(current, 'Drafting page changes', progress);
    const out = resumeBatchSession({ job: current ?? job, prompt, action: 'approve', snapshot });
    if (out.kind === 'session_unavailable') throw sessionUnavailableError(out);
  }

  /** Stops a running turn; the job becomes `cancelled` (reply resumes it). No-op otherwise. */
  async function cancel(id: string): Promise<void> {
    requireJob(id);
    controllers.get(id)?.abort();
  }

  /** Removes a finished job from the list (its job directory in the vault is kept). */
  /** v8: counts of the approved change, from the plan and the vault as it is before the apply. */
  function approvedChangeOf(job: Job, plan: TransactionPlan): ApprovedChange {
    const c: ApprovedChange = { at: isoDate(now()), operationID: plan.operation_id, changes: plan.changed_paths.length, sources: 0, concepts: 0, entities: 0, otherPages: 0, updated: 0, approvalSha256: plan.approval_sha256 };
    for (const p of plan.changed_paths) {
      if (!p.startsWith('wiki/') || !p.endsWith('.md')) continue;
      if (fs.existsSync(path.join(job.vaultPath, p))) c.updated += 1;
      else if (p.startsWith('wiki/sources/')) c.sources += 1;
      else if (p.startsWith('wiki/concepts/')) c.concepts += 1;
      else if (p.startsWith('wiki/entities/')) c.entities += 1;
      else c.otherPages += 1;
    }
    const sources = job.approval?.sources?.filter((x) => !x.removed).length;
    if (sources !== undefined && sources > 0) c.sourcesApproved = job.approval?.rebuilt ? job.approval.rebuilt.pages.length : sources;
    return c;
  }

  /** v8: Done on an approved batch in Review: it is only in History from now on. */
  async function finishReview(id: string): Promise<Job> {
    const job = requireJob(id);
    if (!job.approvedChange) throw new CoreError('invalid_state', `Job ${id} was not approved.`);
    if (job.state === 'running') throw new CoreError('invalid_state', 'This batch is still being added to your vault.');
    if (job.state === 'awaitingApproval') throw new CoreError('invalid_state', 'This batch still waits for your review.');
    if (!job.reviewDoneAt) mutate(id, (j) => { j.reviewDoneAt = isoDate(now()); });
    return clone(findJob(id)!);
  }

  /** v8: the scope of a clean-up: the vault, its jobs, and what the queue still holds when the queue is inbox/. */
  function cleanupScope(o: { jobId?: string; vaultPath?: string } = {}) {
    const job = o.jobId ? requireJob(o.jobId) : undefined;
    const vault = job ? vaultProfileFor(job) : resolveVault(o.vaultPath);
    let queuedRel: Set<string> | undefined;
    if (queueIsInbox(vault)) {
      const taken = claimedFiles(vault);
      queuedRel = new Set(
        queued
          .map((e) => path.relative(vault.path, e.path).split(path.sep).join('/').normalize('NFC'))
          .filter((r) => !taken.has(r)),
      );
    }
    const heldShas = new Set(jobs.flatMap((j) => (j.stopped ?? []).flatMap((s) => (s.sha256 ? [s.sha256] : []))));
    const heldFiles = new Set(jobs.filter((j) => j.vaultPath === vault.path).flatMap((j) => (j.stopped ?? []).map((s) => s.file.normalize('NFC'))));
    return {
      vaultPath: vault.path,
      jobs: clone(jobs),
      ...(o.jobId ? { jobId: o.jobId } : {}),
      ...(queuedRel ? { queued: queuedRel } : {}),
      now: now(),
      // v10 (full reads): only what a batch that applied read in full, with its original archived.
      fullRead: {
        full: (sha: string) => fullRead.index.isFull(sha),
        archived: (sha: string) => archivedCopy(vault.path, sha) !== undefined,
        held: (rel: string, sha: string) => heldShas.has(sha) && heldFiles.has(rel.normalize('NFC')) && !fullRead.index.isFull(sha),
      },
    };
  }

  async function previewInboxCleanup(o: { jobId?: string; vaultPath?: string } = {}): Promise<InboxCleanupPreview> {
    refreshQueue();
    return previewCleanup(cleanupScope(o));
  }

  async function cleanUpInbox(req: InboxCleanupRequest): Promise<InboxCleanupResult> {
    if (!req || !Array.isArray(req.paths) || req.paths.some((p) => typeof p !== 'string')) throw new CoreError('invalid_request', 'paths must be an array of inbox paths.');
    if (req.paths.some((p) => !p.startsWith('inbox/') || p.split('/').includes('..'))) throw new CoreError('invalid_request', 'Only paths inside inbox/ can be cleaned up.');
    refreshQueue();
    const result = await runCleanup(cleanupScope({ ...(req.jobId ? { jobId: req.jobId } : {}), ...(req.vaultPath ? { vaultPath: req.vaultPath } : {}) }), req.paths, trashMover);
    if (result.moved.length > 0) refreshQueue();
    return result;
  }

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

  async function jobResumeCommand(id: string, opts: SessionOptions = {}): Promise<string[] | null> {
    const job = requireJob(id);
    if (jobKind(job.kind)?.appliesInCore) return null; // no AI session
    const runner = runners.get(jobRunnerID(job));
    const gone = precheck(job, 'resume', {}, 'terminal');
    if (opts.newSession) {
      // A new interactive session primed with the batch; the job keeps its own session record.
      const kind = jobKind(job.kind);
      let target: { runner: AgentRunner | undefined; model: string } = { runner, model: job.model };
      if (!runner?.newSessionCommand && kind) {
        const fallback = selectionFor(settings, kind.task);
        target = { runner: runners.get(fallback.runnerID), model: fallback.model };
      }
      const argv = target.runner?.newSessionCommand?.(terminalSeed(job), target.model, clone(settings));
      if (!argv || argv.length === 0) return null;
      emit({ type: 'session.replaced', place: 'terminal', objectID: job.id, ...(gone ? { reason: gone.reason } : {}) });
      return argv;
    }
    if (gone) throw sessionUnavailableError(gone);
    const argv = runner?.resumeCommand?.(job.sessionID, job.model, clone(settings));
    return argv && argv.length > 0 ? argv : null;
  }

  // ───────────── session continuity ─────────────

  function resumeTarget(job: Job, action: SessionAction, place: 'batch' | 'terminal' = 'batch'): ResumeTarget {
    const runnerID = jobRunnerID(job);
    return { place, runner: runners.get(runnerID), runnerID, sessionID: job.sessionID, neverStarted: batchNeverStarted(job), action };
  }

  /** Before changing anything: is the batch's session gone? (positive evidence only) */
  function precheck(
    job: Job,
    action: SessionAction,
    extra: { text?: string; rules?: string[]; labels?: 'confirm' | 'later'; pages?: string[] } = {},
    place: 'batch' | 'terminal' = 'batch',
  ): SessionUnavailable | null {
    const gone = checkResume(resumeTarget(job, action, place));
    if (!gone) return null;
    if (extra.text !== undefined) gone.text = extra.text;
    if (extra.rules !== undefined) gone.rules = [...extra.rules];
    if (extra.labels !== undefined) gone.labels = extra.labels;
    if (extra.pages !== undefined) gone.pages = [...extra.pages];
    return gone;
  }

  /**
   * Puts a job back exactly as it was before a resume that could not happen. `marker` is set when
   * the runner refused after the turn started (the app shows the confirmation from it).
   */
  function restoreJob(id: string, snapshot: Job | undefined, marker?: SessionUnavailable): void {
    const i = jobs.findIndex((j) => j.id === id);
    if (i < 0) return;
    const restored = snapshot ? clone(snapshot) : clone(jobs[i]!);
    if (!snapshot && restored.state === 'running') restored.state = 'awaitingApproval';
    if (marker) restored.sessionUnavailable = marker;
    else delete restored.sessionUnavailable;
    restored.updatedAt = isoDate(now());
    jobs[i] = restored;
    persistJobs();
    // Progress first, with an error, so the live log closes an "Applying…" step instead of leaving
    // it spinning; then the job event puts the review step back.
    finishProgress(id, { error: 'The AI session isn’t available anymore', patch: { message: 'Needs a new session' } });
    emit({ type: 'job', job: clone(restored) });
  }

  function resumeBatchSession(o: ResumeBatchOptions): ResumeBatchOutcome {
    const target = resumeTarget(o.job, o.action ?? 'reply');
    const gone = checkResume(target);
    if (gone) {
      if (o.text !== undefined) gone.text = o.text;
      if (o.rules !== undefined) gone.rules = [...o.rules];
      if (o.labels !== undefined) gone.labels = o.labels;
      if (o.pages !== undefined) gone.pages = [...o.pages];
      if (o.snapshot) restoreJob(o.job.id, o.snapshot); // the caller throws; nothing it changed stays
      return { kind: 'session_unavailable', ...gone };
    }
    const resumeOf: ResumeOf = { target };
    if (o.snapshot) resumeOf.snapshot = o.snapshot;
    if (o.text !== undefined) resumeOf.text = o.text;
    if (o.rules !== undefined) resumeOf.rules = o.rules;
    if (o.labels !== undefined) resumeOf.labels = o.labels;
    if (o.pages !== undefined) resumeOf.pages = o.pages;
    runTurn(o.job.id, o.prompt, {
      ...(o.extraTools ? { extraTools: o.extraTools } : {}),
      ...(o.applyPlan ? { applyPlan: o.applyPlan } : {}),
      resumeOf,
    });
    return { kind: 'started' };
  }

  /**
   * Continue in a NEW session after the user confirmed SessionReplaceConfirm: a fresh session id,
   * seeded with the batch (sources, labels, conversation, plan) and the pending action.
   */
  function continueInNewSession(
    id: string,
    action: 'approve' | 'reply' | 'allow',
    o: {
      userTurn: string;
      text?: string;
      rules?: string[];
      plan?: TransactionPlan;
      bundle?: string;
      /** A part of a batch: the request that rebuilds its change (self-contained: files and sha256). */
      prompt?: string;
    },
  ): void {
    const job = requireJob(id);
    const kind = jobKind(job.kind);
    if (!kind) throw new CoreError('invalid_state', `Unknown job kind ${job.kind}`);
    const known = job.sessionUnavailable ?? checkResume(resumeTarget(job, action));
    // The batch's runner may be the reason; the new session then uses the batch default.
    const current = runners.get(jobRunnerID(job));
    const selection = !current || !runnerSupports(current, kind.task) ? selectionFor(settings, kind.task) : undefined;
    if (selection) {
      const next = runners.get(selection.runnerID);
      if (!next || !runnerSupports(next, kind.task)) throw new CoreError('invalid_state', 'No AI runner can continue this batch. Check Settings → AI runners.');
    }
    // The conversation so far, before the pending action is added.
    const before = clone(job);
    mutate(id, (j) => {
      j.sessionID = randomUUID().toLowerCase();
      if (selection) {
        j.runnerID = selection.runnerID;
        j.model = selection.model;
        if (selection.effort) j.effort = selection.effort;
        else delete j.effort;
      }
      if (o.rules) j.grantedTools = [...new Set([...j.grantedTools, ...o.rules])].sort();
      j.turns.push(newTurn('app', 'Continued in a new AI session: the earlier one was not available. It starts with this batch’s sources, labels, conversation and plan.', now()));
      j.turns.push(newTurn('user', o.userTurn, now()));
      delete j.sessionUnavailable;
    });
    const fresh = requireJob(id);
    const vault = vaultProfileFor(fresh);
    const labelPlan = savedLabelPlan(jobStateDirectory(fresh));
    const ctx = new JobContext(clone(fresh), vault, settings, labelPlan);
    let pending: string;
    const extra: { extraTools?: string[]; applyPlan?: TransactionPlan; first: true } = { first: true };
    if (action === 'approve' && o.prompt) {
      pending = o.prompt;
    } else if (action === 'approve' && o.plan && o.bundle) {
      pending = WorkerProtocol.approvedPrompt(ctx, o.plan, o.bundle);
      extra.extraTools = [`Bash(${WorkerProtocol.applyCommand(ctx, o.plan, o.bundle)})`];
      extra.applyPlan = clone(o.plan);
    } else if (action === 'allow') {
      pending = WorkerProtocol.grantedPrompt(o.rules ?? []);
    } else {
      pending = WorkerProtocol.replyPrompt(o.text ?? '');
    }
    // v10: a new session gets a new coverage record; sources this batch already read in full stay full.
    const carryFull = (fresh.coverage?.sources ?? []).filter((s) => s.state === 'full').map((s) => s.file);
    const pagesOf = fresh.reread ? new Map(rereadFacts(vault.path, fresh.files).facts.sources.map((s) => [s.file, { pages: s.pages }])) : undefined;
    const prepared = fullRead.prepare(fresh, vault, fresh.files, { carryFull, ...(pagesOf ? { existing: pagesOf } : {}) });
    const seedFacts: RereadFacts = { sources: prepared.sources, unreadable: prepared.unreadable };
    const seedCtx = new JobContext({ ...before, sessionID: fresh.sessionID, grantedTools: fresh.grantedTools }, vault, settings, labelPlan, seedFacts);
    emit({ type: 'session.replaced', place: 'batch', objectID: id, ...(known ? { reason: known.reason } : {}) });
    runTurn(id, newSessionPrompt(kind, seedCtx, pending), extra);
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
    merged.settleSeconds = Math.min(MAX_SETTLE_SECONDS, Math.max(0, merged.settleSeconds));
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

  /** Nothing is written into a queue folder inside the vault other than exactly `<vault>/inbox`. */
  function requireQueuePlacement(vault: VaultProfile): void {
    const p = queuePlacementProblem(vault.path, vault.queueDirectory);
    if (p) throw new CoreError('invalid_state', p.message);
  }

  async function addQueueFiles(files: string[]): Promise<QueueEntry[]> {
    const vault = activeVault(settings);
    if (!vault) throw new CoreError('no_vault', 'No vault selected.');
    requireQueuePlacement(vault);
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
    // A vault is a folder with .claude-obsidian.json (root vault-resolution rule), for every caller:
    // labels, notes, page search and label review, not only batches.
    if (!isVault(vault.path)) throw new CoreError('invalid_state', problem.notAVault(vault.path).message);
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
    requireQueuePlacement(vault);
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
    if (where?.state === 'queued' && queueIsInbox(where.vault)) {
      // The note is in inbox/: its files are the user's now; keep the result in Distill's state.
      noteLabels.setSuggestion(requestID, error ? { error } : { labels }, now());
    } else if (where?.state === 'queued') {
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
    const notePath = noteFileFor(where.manifest);
    if (queueIsInbox(where.vault)) {
      // The queue is the vault's inbox/: Distill never edits a file already there (decision
      // 2026-10-04). The labels live in Distill's state; the batch reads them from there.
      noteLabels.setLabels(requestID, clean, now());
    } else {
      m.labels = clean; // [] = confirmed: no labels (no AI fallback)
      writeManifest(where.manifest, m);
      const page = readPage(path.dirname(notePath), path.basename(notePath));
      if (typeof page !== 'string') {
        const next = setLabelProperties(page.text, { tags: clean });
        if (next !== page.text) writeFileAtomic(notePath, next);
      }
    }
    if (where.vault.path === activeVault(settings)?.path) refreshQueue();
    return { notePath, labels: clean };
  }

  /** A path that is a file listed in the active queue right now (labels are only kept for those). */
  function queueFile(file: string): string {
    if (typeof file !== 'string' || file.trim() === '') throw new CoreError('invalid_request', 'path is required.');
    refreshQueue();
    const abs = path.resolve(file);
    const hit = queueEntries().find((e) => path.resolve(e.path) === abs);
    if (!hit || (hit.kind ?? 'file') !== 'file') throw new CoreError('not_found', `${file} is not a file in the queue.`);
    return hit.path;
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
        const applying = findJob(id)?.approval ? clone(findJob(id)!.approval!) : undefined;
        mutate(id, (j) => {
          addPart(j, operationID, applying);
          j.state = 'completed';
          delete j.approval;
          if (j.recovery) j.recovery = { ...j.recovery, state: 'fixed' }; // a recovery's retry that applied
          j.operationID = operationID;
          lockRetries.delete(j.vaultPath); // the vault is free again
          j.changedPaths = mergedPaths(j, changed);
          j.turns.push(newTurn('app', `Applied ${operationID}:\n` + changed.map((p) => `- ${p}`).join('\n'), now()));
        });
        continueAfterPart(id, operationID);
        return;
      }
      if (out.status === 75) {
        // Exit 75 is any TransactionConflict: stale hashes, but also a held lock or a reused
        // operation id. The core prints `ERR <CODE>: <message>` on stderr.
        const code = /^ERR ([A-Z_]+):/m.exec(out.stderr.toString('utf8'))?.[1];
        if (code === 'LOCK_TIMEOUT') {
          // Nothing changed and the plan is still valid: it goes back to the head of the queue and applies
          // again under the same approval once the lock is free (the pump re-inspects first).
          mutate(id, (j) => {
            j.state = 'awaitingApproval';
            if (j.approval) delete j.approval.planError;
            if (j.queuedApply) j.queuedApply.planSha256 = plan.approval_sha256;
            j.turns.push(newTurn('app', 'Not applied yet: another process held the vault lock. Nothing changed; Distill tries again shortly.', now()));
          });
          scheduleLockRetry(job.vaultPath, id);
          return;
        }
        const request =
          jobKind(job.kind) === LabelsJobKind ? readLabelRequest(path.join(jobStateDirectory(job), 'request.json')) : undefined;
        if (request) {
          const why =
            code === 'OPERATION_ID_REUSED'
              ? 'This operation ID was already used in the vault; the plan was rebuilt with a new one. Review it again.'
              : 'The pages changed after you reviewed them; the plan was rebuilt. Review it again.';
          mutate(id, (j) => j.turns.push(newTurn('app', why, now())));
          await planLabelJob(id, request);
          return;
        }
        const reused = code === 'OPERATION_ID_REUSED';
        // review-queue.md: another batch changed the same pages first: rebuilt against the vault as it is now.
        if (!reused) {
          mutate(id, (j) => {
            j.state = 'awaitingApproval';
          });
          if (refreshJob(id, true, staleFor(vault.path, bundle).map((s) => s.path))) return;
        }
        mutate(id, (j) => {
          j.state = 'awaitingApproval';
          if (j.approval) {
            delete j.approval.plan;
            j.approval.planError = reused
              ? 'The vault already has an operation with this ID (transaction apply exited 75, OPERATION_ID_REUSED); it may already be applied. Check the vault log, then reply to have the bundle rebuilt with a new ID, or reject.'
              : `The vault changed after this plan was reviewed (transaction apply exited 75${code ? `, ${code}` : ''}). Reply to have it rebuilt, or reject.`;
          }
          j.turns.push(newTurn('app', reused ? 'Not applied: this operation ID was already used in the vault.' : 'Not applied: the vault changed after review.', now()));
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
      pendingApprovals: jobs.filter(needsOwner).length,
      runningJobs: jobs.filter((j) => j.state === 'running').length,
      ...queueStatus(jobs),
      nextBatchAt: nextBatchAt ? isoDate(nextBatchAt) : null,
      lastQueueScanAt: lastQueueScanAt ? isoDate(lastQueueScanAt) : null,
      nextQueueScanAt: nextQueueScanAt ? isoDate(nextQueueScanAt) : null,
      batchBudget: fullRead.budget(ingestSelection().model),
      heldCount: (() => {
        const v = activeVault(settings);
        return v ? fullRead.listHeld(v.path).length : 0;
      })(),
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
      adoptOutsideApplies();
      for (const j of jobs) {
        const st = j.approval?.labels?.state;
        if (j.state === 'awaitingApproval' && (st === undefined || st === 'confirming' || st === 'suggesting')) {
          track(prepareReviewLabels(j.id).catch((err: unknown) => log('warn', `Review labels for ${j.id}: ${(err as Error).message}`)));
        }
      }
      // review-queue.md: queued approvals go on after a restart. Stale plans are rebuilt only after an apply lands.
      for (const v of new Set(jobs.filter((j) => j.state === 'awaitingApproval').map((j) => j.vaultPath))) {
        track(asScheduler(() => pumpApplies(v))().catch((err: unknown) => log('warn', `Apply queue: ${(err as Error).message}`)));
      }
      // review-queue.md: a batch left waiting on blocked calls (before this build) gets Distill's answer once.
      for (const j of jobs) {
        if (j.state === 'awaitingApproval' && !j.recovery && (j.approval?.denials.length ?? 0) > 0 && !j.approval?.plan?.valid) {
          asScheduler(() => recoverDenial(j.id))();
        }
      }
      // Recovery that was waiting out its minute, or whose agent call a restart cut off, goes on.
      for (const j of jobs) {
        const rec = j.recovery;
        if (!rec || j.state === 'running' || (j.state !== 'awaitingApproval' && j.state !== 'failed')) continue;
        if (rec.state === 'waiting') {
          scheduleRecoveryWake(j.id, rec.signature, rec.waitUntil ? Date.parse(rec.waitUntil) - now().getTime() : 0);
        } else if (rec.state === 'running' && [...rec.attempts].reverse().find((a) => a.result === 'running')?.by === 'agent') {
          mutate(j.id, (x) => {
            if (x.recovery) x.recovery = { ...x.recovery, attempts: x.recovery.attempts.map((a) => (a.result === 'running' ? { ...a, result: 'failed', error: 'Distill restarted.' } : a)) };
          });
          track(asScheduler(() => runRecoveryAgent(j.id, rec.signature))().catch((err: unknown) => log('warn', `Recovery: ${(err as Error).message}`)));
        } else if (rec.state === 'running') {
          // Nothing works on it any more (no turn, no agent call): the rule's attempt escalates, else the owner.
          settleRecovery(j.id);
        }
      }
      scheduleNextBatch(now());
      scheduleNextScan(now());
      if (timer) clearInterval(timer);
      // Batches and queue checks the timer starts are logged as the scheduler's (activity-log.md).
      timer = setInterval(asScheduler(tick), tickMs);
      // v9: re-read groups that waited when the core stopped go on (one at a time per vault).
      if (rereads.pending()) asScheduler(pumpRereads)();
      // v10 (full reads): past batches' coverage from their saved turns, then sources never read in full.
      track(
        Promise.resolve()
          .then(() => fullRead.backfill())
          .then(async () => {
            const v = activeVault(settings);
            if (v) await asScheduler(() => fullRead.repairScan(v))();
          })
          .catch((err: unknown) => log('warn', `Full reads at start: ${(err as Error).message}`)),
      );
    },
    async stop() {
      if (timer) clearInterval(timer);
      timer = undefined;
      for (const t of recoveryWakes.values()) clearTimeout(t);
      recoveryWakes.clear();
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
    approve: (id: string, opts?: ApproveOptions & SessionOptions) => approve(id, opts),
    unqueue,
    tryRecoveryAgain,
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
    finishReview,
    previewInboxCleanup,
    cleanUpInbox,
    rereadSources,
    async listHeld(vaultPath?: string): Promise<HeldSource[]> {
      return fullRead.listHeld(resolveVault(vaultPath).path);
    },
    async retryHeld(file: string, vaultPath?: string) {
      const vault = resolveVault(vaultPath);
      const held = fullRead.listHeld(vault.path).find((h) => h.file === file.normalize('NFC'));
      if (!held) throw new CoreError('not_found', `${file} is not held in inbox/ (read in full since, or removed).`);
      return rereadSources({ vaultPath: vault.path, files: [held.file], perBatch: 1, reason: 'retry' });
    },
    jobResumeCommand,
    resumeBatchSession,
    removeQueueEntry,
    setJobActions(id: string, summary: JobActionsSummary) {
      mutate(id, (j) => {
        j.actionsFound = { ...summary, byType: { ...summary.byType } };
      });
    },

    labelNote,
    async labelQueueItem(file: string, labels: string[]) {
      const clean = cleanLabels(labels);
      if (!queueLabeler.confirm(queueFile(file), clean)) throw new CoreError('not_found', `${file} is not a readable file in the queue.`);
      refreshQueue();
      return queueEntries();
    },
    async retryQueueLabels(file: string) {
      if (!queueLabeler.retry(queueFile(file))) throw new CoreError('not_found', `${file} is not a readable file in the queue.`);
      refreshQueue();
      return queueEntries();
    },
    editReviewLabels,
    removeReviewSource,
    async skipQueueLabels(file: string) {
      if (!queueLabeler.skip(queueFile(file))) throw new CoreError('not_found', `${file} is not a readable file in the queue.`);
      refreshQueue();
      return queueEntries();
    },
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

/** The vault's transaction journal for an operation (`.vault-meta/transactions/<op>/journal.json`). */
export function readJournal(vaultPath: string, operationID: string): { state: string; approval_sha256: string; changed_paths: string[] } | undefined {
  if (!/^[A-Za-z0-9._-]+$/.test(operationID)) return undefined;
  const dir = path.join(vaultPath, '.vault-meta', 'transactions', operationID);
  try {
    const j = JSON.parse(fs.readFileSync(path.join(dir, 'journal.json'), 'utf8')) as Record<string, unknown>;
    let changed: string[] = [];
    try {
      const c = JSON.parse(fs.readFileSync(path.join(dir, 'changed-paths.json'), 'utf8')) as Record<string, unknown>;
      if (Array.isArray(c.changed_paths)) changed = c.changed_paths.filter((p): p is string => typeof p === 'string');
    } catch {
      // No changed-paths file: the plan's paths are used.
    }
    if (typeof j.state !== 'string' || typeof j.approval_sha256 !== 'string') return undefined;
    return { state: j.state, approval_sha256: j.approval_sha256, changed_paths: changed };
  } catch {
    return undefined;
  }
}

