import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  runnerSupports,
  type AddNoteRequest,
  type AddNoteResult,
  type ApprovalRequest,
  type CoreEvent,
  type DistillCore,
  type Job,
  type LabelCount,
  type LabelReview,
  type LabelSuggestion,
  type ModelSelection,
  type QueueEntry,
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
import { noteFileFor, readManifest, validateNote, writeManifest, writeNote, type NoteLabelState } from './notes.js';
import { draftBatchLabels } from '../labels/batch.js';
import { bodyOf, parseFrontmatter, scalarValue, setLabelProperties } from '../labels/frontmatter.js';
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
  claimFiles,
  copyIntoQueue,
  inboxDir,
  pendingFiles,
  queueIsInbox,
  settledFiles,
  toQueueEntry,
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
export type EngineOwned = Exclude<keyof DistillCore, AskOwned | RunnerAdminOwned>;
export type AskOwned = 'ask' | 'listConversations' | 'getConversation' | 'deleteConversation' | 'setConversationPinned';
export type RunnerAdminOwned = 'listRunners' | 'setRunnerSecret';

export type Engine = Pick<DistillCore, EngineOwned> & {
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
  const version = readVersion();

  const settingsStore = new SettingsStore(paths.settings);
  const jobStore = new JobStore(paths.jobs);
  let settings: Settings = settingsStore.load();
  let jobs: Job[] = jobStore.load(now());
  let queued: ScanEntry[] = [];
  let lastQueueKey = '';
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
    change(job);
    job.updatedAt = isoDate(now());
    persistJobs();
    emit({ type: 'job', job: clone(job) });
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

  function queueEntries(): QueueEntry[] {
    const t = now();
    return queued.map((e) => toQueueEntry(e, settings.settleSeconds, t));
  }

  function refreshQueue(): void {
    const vault = activeVault(settings);
    if (!vault) {
      queued = [];
    } else {
      const entries = pendingFiles(vault.queueDirectory);
      if (queueIsInbox(vault)) {
        const claimed = claimedFiles(vault);
        queued = entries.filter((e) => !claimed.has('inbox/' + e.name));
      } else {
        queued = entries;
      }
    }
    const entries = queueEntries();
    const key = JSON.stringify(entries);
    if (key !== lastQueueKey) {
      lastQueueKey = key;
      emit({ type: 'queue', entries });
    }
  }

  function tick(): void {
    refreshQueue();
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
    const ready = settledFiles(pendingFiles(vault.queueDirectory), settle, now());
    if (ready.length === 0) return null;
    let files: string[];
    try {
      files = claimFiles(ready, vault, claimedFiles(vault));
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
    job.runnerID = selection.runnerID;
    if (selection.effort) job.effort = selection.effort;
    job.turns.push(newTurn('app', `Batched ${files.length} file(s):\n` + files.map((f) => `- ${f}`).join('\n'), now()));
    insert(job);
    const draft = draftBatchLabels(vault.path, files, labelingPreferences(settings));
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
      runTurn(job.id, kind.initialPrompt(new JobContext(clone(current), vault, settings, plan)), { first: true });
    };
    if (draft.pending.length === 0) {
      start(draft.plan);
    } else {
      // Pre-step: AI labels for queue-folder files and CLI notes nobody labeled, before the first turn.
      const controller = new AbortController();
      controllers.set(job.id, controller);
      track(
        (async () => {
          let cost = 0;
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
    if (coreApplies(job)) {
      mutate(id, (j) => {
        j.state = 'running';
        delete j.error;
        j.turns.push(newTurn('user', `Approved ${plan.operation_id} (${plan.approval_sha256.slice(0, 12)}…)`, now()));
      });
      track(applyInCore(id, plan, bundle));
      return;
    }
    const ctx = new JobContext(clone(job), vaultProfileFor(job), settings);
    // Only the exact approved command is permitted, and only for this turn.
    const applyRule = `Bash(${WorkerProtocol.applyCommand(ctx, plan, bundle)})`;
    mutate(id, (j) => j.turns.push(newTurn('user', `Approved ${plan.operation_id} (${plan.approval_sha256.slice(0, 12)}…)`, now())));
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
    o: { signal?: AbortSignal; selection?: ModelSelection } = {},
  ): Promise<SuggestOutcome> {
    const existing = await existingLabels(vault.path);
    return suggestLabels(input, { runners, settings: clone(settings), existing, scratchDir: labelScratch, ...o });
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
    if (suggest === 'wait') {
      // Suggest first, then write: the batch can never pick the note up mid-wait.
      try {
        state.suggestedLabels = (await suggestFor(vault, input)).labels;
      } catch (err) {
        state.suggestError = (err as Error).message;
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
    return out;
  }

  async function suggestInBackground(vault: VaultProfile, requestID: string, notePath: string, input: SuggestInput): Promise<void> {
    let labels: LabelSuggestion[] = [];
    let error: string | undefined;
    try {
      labels = (await suggestFor(vault, input)).labels;
    } catch (err) {
      error = (err as Error).message;
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
    emit({ type: 'labelSuggestions', requestID, notePath, labels, ...(error ? { error } : {}) });
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

  async function suggestLabelsForPages(
    rawPaths: string[],
    o: { vaultPath?: string; selection?: ModelSelection } = {},
  ): Promise<Job> {
    const files = pagePaths(rawPaths);
    const vault = resolveVault(o.vaultPath);
    requireFreeVault(vault);
    const selection = o.selection ?? labelSuggestSelection(settings);
    const job = newLabelJob(vault, files, `Suggest labels for ${files.length} page(s).`, selection);
    insert(job);
    const controller = new AbortController();
    controllers.set(job.id, controller);
    const work = (async () => {
      const edits: LabelEdit[] = [];
      const skipped: string[] = [];
      let cost = 0;
      try {
        for (const rel of files) {
          if (controller.signal.aborted) break;
          const page = readPage(vault.path, rel);
          if (typeof page === 'string') {
            skipped.push(`${rel}: ${page}`);
            continue;
          }
          const title = scalarValue(parseFrontmatter(page.text), 'title') ?? path.posix.basename(rel, '.md');
          try {
            const out = await suggestFor(vault, { title, text: bodyOf(page.text) }, { signal: controller.signal, selection });
            cost += out.costUSD;
            // Keep the page's current labels; the AI ones are added (all unconfirmed until reviewed).
            const labels = normalizeLabels([...pageTags(page.text), ...out.labels.map((l) => l.name)]);
            edits.push({ path: rel, labels, by: 'ai', origin: 'suggest' });
          } catch (err) {
            if (controller.signal.aborted) break;
            skipped.push(`${rel}: ${(err as Error).message}`);
          }
        }
      } finally {
        if (controllers.get(job.id) === controller) controllers.delete(job.id);
      }
      if (controller.signal.aborted) {
        mutate(job.id, (j) => {
          j.state = 'cancelled';
          j.turns.push(newTurn('app', 'Cancelled.', now()));
        });
        return;
      }
      mutate(job.id, (j) =>
        j.turns.push(newTurn('worker', `Suggested labels for ${edits.length} of ${files.length} page(s).`, now(), cost)),
      );
      if (edits.length === 0) {
        fail(job.id, ['No labels could be suggested.', ...skipped.map((s) => `- ${s}`)].join('\n'));
        return;
      }
      await planLabelJob(job.id, { mode: 'suggest', edits }, skipped);
    })().catch((err: unknown) => fail(job.id, (err as Error).message));
    track(work);
    await work;
    return clone(requireJob(job.id));
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
      queueCount: queued.length,
      pendingApprovals: jobs.filter((j) => j.state === 'awaitingApproval').length,
      runningJobs: jobs.filter((j) => j.state === 'running').length,
      nextBatchAt: nextBatchAt ? isoDate(nextBatchAt) : null,
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
      if (timer) clearInterval(timer);
      timer = setInterval(tick, tickMs);
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

