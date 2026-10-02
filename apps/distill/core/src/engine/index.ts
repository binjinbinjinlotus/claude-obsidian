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
import { isObject, isoDate } from '../store/json.js';
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
  selectionFor,
  SettingsStore,
} from '../store/settings.js';
import { uniqueDenials } from '../runners/permissions.js';
import { isCancelled, runProcess, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { defaultRegistry } from '../runners/registry.js';
import { JobContext, jobKind, parseWorkerStatus, queueConsumer, WorkerProtocol, type ParsedStatus } from './job-kinds.js';
import { CoreError } from './errors.js';
import { writeNote } from './notes.js';
import {
  claimFiles,
  copyIntoQueue,
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
export type Engine = Omit<DistillCore, 'ask'> & {
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
    const ctx = new JobContext(clone(job), vault, settings);
    runTurn(job.id, kind.initialPrompt(ctx), { first: true });
    return clone(findJob(job.id) ?? job);
  }

  async function approve(id: string): Promise<void> {
    const job = requireJob(id);
    if (job.state !== 'awaitingApproval') throw new CoreError('invalid_state', `Job ${id} is not awaiting approval.`);
    const plan = job.approval?.plan;
    const bundle = job.approval?.bundlePath;
    if (!plan || !plan.valid || !bundle) throw new CoreError('invalid_state', `Job ${id} has no valid plan to approve.`);
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

  async function addNote(req: AddNoteRequest): Promise<AddNoteResult> {
    const vault = req.vaultPath
      ? settings.vaults.find((v) => path.resolve(v.path) === path.resolve(req.vaultPath as string))
      : activeVault(settings);
    if (!vault) {
      throw req.vaultPath
        ? new CoreError('invalid_request', `Unknown vault ${req.vaultPath}.`)
        : new CoreError('no_vault', 'No vault selected.');
    }
    const result = writeNote(req, vault, now());
    if (vault.path === activeVault(settings)?.path) refreshQueue();
    return result;
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

    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },

    async whenIdle() {
      while (inflight.size > 0) await Promise.allSettled([...inflight]);
    },
  };
}

