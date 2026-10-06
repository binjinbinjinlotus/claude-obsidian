import path from 'node:path';
import { CoreError, type ActivityApi, type CoreEvent, type DistillCore, type Progress, type StatePaths } from './contracts.js';
import { createActivityService, createEventLogger, instrumentCore, type ActivityServiceOptions } from './activity/index.js';
import { createEngine, type EngineExtras, type EngineOptions } from './engine/index.js';
import { createAskService } from './ask/index.js';
import { createRunnerAdmin } from './runners/admin.js';
import { createActionsService, type ActionsService, type ScriptsAccess } from './actions/index.js';
import { createCollectorsService, type CollectorsOptions } from './collectors/index.js';
import { createStepLog, type StepLog } from './steps/index.js';
import type { FetchLike } from './runners/model-api.js';
import type { SecretStore } from './runners/secrets.js';
import { statePaths } from './store/paths.js';

export * from './contracts.js';
export { statePaths } from './store/paths.js';
export { currentSource, runWithSource, sourceFromHeaders } from './activity/context.js';

export interface CoreOptions extends Partial<Omit<EngineOptions, 'paths'>> {
  paths?: StatePaths;
  /** Secret store for connections (default: the Keychain). Tests pass a MemorySecretStore. */
  secrets?: SecretStore;
  /** Network for connections (default: global fetch). Tests pass a fake. */
  fetch?: FetchLike;
  /** Collectors: scheduler, process and environment overrides (tests). */
  collectors?: Partial<Omit<CollectorsOptions, 'emit' | 'getSettings' | 'file' | 'dir'>>;
  /** Activity log and trash limits (tests). */
  activity?: Pick<ActivityServiceOptions, 'log' | 'trash'>;
}

/** Compose the engine and Ask into the single DistillCore the server exposes. */
export function createCore(opts: CoreOptions = {}): DistillCore & EngineExtras & ActivityApi {
  const paths = opts.paths ?? statePaths();
  // The actions service is created after the engine; the hook binds late.
  let actions: ActionsService | undefined;
  // v7: the live log binds late too (it needs the merged event stream).
  let steps: StepLog | undefined;
  const engine = createEngine({
    ...opts,
    paths,
    onJobApplied: async (job) => {
      await opts.onJobApplied?.(job);
      await actions?.findInJob(job);
    },
    // v11 (action-context.md): actions are looked for while the batch waits in Review, added when it applies.
    onReviewReady: async (job, info) => {
      await opts.onReviewReady?.(job, info);
      await actions?.findForReview(job, info);
    },
    onJobEnded: async (job) => {
      await opts.onJobEnded?.(job);
      await actions?.jobEnded(job);
    },
    steps: {
      runnerStep: (jobId, step) => {
        opts.steps?.runnerStep(jobId, step);
        steps?.runnerStep(jobId, step);
      },
      labelFile: (jobId, file, state, labels) => {
        opts.steps?.labelFile(jobId, file, state, labels);
        steps?.labelFile(jobId, file, state, labels);
      },
      fullRead: (jobId, s) => {
        opts.steps?.fullRead?.(jobId, s);
        steps?.fullRead(jobId, s);
      },
    },
  });
  // Events from services outside the engine (Ask history) join the engine's stream.
  const extra = new Set<(e: CoreEvent) => void>();
  // Latest progress per key, from both streams, for clients that connect mid-run.
  const progress = new Map<string, Progress>();
  const track = (e: CoreEvent) => {
    if (e.type !== 'progress') return;
    if (e.progress.finished) progress.delete(e.progress.key);
    else progress.set(e.progress.key, e.progress);
  };
  engine.subscribe(track);
  const emit = (e: CoreEvent) => {
    track(e);
    for (const l of extra) l(e);
  };
  steps = createStepLog({
    dir: path.join(paths.dir, 'steps'),
    emit,
    getJob: (id) => engine.getJob(id),
    ...(opts.now ? { now: opts.now } : {}),
  });
  const stepLog = steps;
  stepLog.prune(engine.listJobs().map((j) => j.id));
  engine.subscribe((e) => stepLog.onEvent(e));
  const ask = createAskService({
    emit,
    getSettings: () => engine.getSettings(),
    runners: engine.runners,
    stateDir: path.join(paths.dir, 'ask'),
  });
  const admin = createRunnerAdmin({ runners: engine.runners, getSettings: () => engine.getSettings() });
  actions = createActionsService({
    emit,
    getSettings: () => engine.getSettings(),
    runners: engine.runners,
    file: paths.actions ?? path.join(paths.dir, 'actions.json'),
    stateDir: paths.dir,
    ...(opts.secrets ? { secrets: opts.secrets } : {}),
    ...(opts.fetch ? { fetch: opts.fetch } : {}),
    ...(opts.now ? { now: opts.now } : {}),
    getConversation: (id) => ask.getConversation(id),
    setJobActions: (id, summary) => engine.setJobActions?.(id, summary),
    getJob: (id) => engine.getJob(id),
    // Automations run buttons' commands; bound late (collectors are created next).
    scripts: () => collectorsRef,
  });
  let collectorsRef: ScriptsAccess | undefined;
  const collectors = createCollectorsService({
    emit,
    getSettings: () => engine.getSettings(),
    file: paths.collectors ?? path.join(paths.dir, 'collectors.json'),
    dir: path.join(paths.dir, 'collectors'),
    ...(opts.now ? { now: opts.now } : {}),
    // Distill's trash (activity) copies a deleted script collector's folder; the collector then removes it.
    trashKeepsScriptFolders: true,
    // Scripts never run while a batch runs or applies in the same vault.
    isVaultBusy: (vaultPath) =>
      engine.listJobs().some((j) => j.state === 'running' && path.resolve(j.vaultPath) === path.resolve(vaultPath)),
    ...opts.collectors,
  });
  collectorsRef = collectors;
  // A batch that finishes lets waiting scripts start.
  engine.subscribe((e) => {
    if (e.type === 'job') collectors.pump();
  });
  const {
    start: startCollectors,
    stop: stopCollectors,
    tick: _tick,
    pump: _pump,
    whenIdle: _collectorsIdle,
    restoreCollector,
    // Internal to Automations and action buttons, never on the API.
    runCommand: _runCommand,
    scriptConsent: _scriptConsent,
    ...collectorMethods
  } = collectors;
  // v6: the activity log (spec activity-log.md). New lines go out as `activity` events.
  const askDir = path.join(paths.dir, 'ask');
  const activity = createActivityService({
    stateDir: paths.dir,
    askDir,
    emit,
    restoreCollector,
    ...(opts.now ? { now: opts.now } : {}),
    ...opts.activity,
  });
  activity.log.onEntry((entry) => {
    for (const l of [...extra]) l({ type: 'activity', entry });
  });
  const service = actions;
  const {
    findInJob: _findInJob,
    afterAsk: _afterAsk,
    findForReview: _findForReview,
    jobEnded: _jobEnded,
    jobActions: _jobActions,
    sweepHistory: _sweepHistory,
    whenIdle: _actionsIdle,
    ...actionMethods
  } = service;
  const core: DistillCore & EngineExtras & ActivityApi = {
    ...engine,
    ...actionMethods,
    ...collectorMethods,
    listActivity: (query) => activity.listActivity(query),
    listTrash: () => activity.listTrash(),
    restoreFromTrash: (id) => activity.restoreFromTrash(id),
    async start() {
      await engine.start();
      startCollectors();
    },
    async stop() {
      await stopCollectors();
      await engine.stop();
    },
    async findJobActions(id: string) {
      const job = engine.getJob(id);
      if (!job) throw new CoreError('not_found', `Unknown job ${id}.`);
      // v11: also a batch in Review whose look-through failed (it runs again for the failed sources).
      const inReview = job.state === 'awaitingApproval' && job.kind !== 'labels' && job.actionsFound?.stage === 'review';
      if (!inReview && (job.state !== 'completed' || job.changedPaths.length === 0 || job.kind === 'labels')) {
        throw new CoreError('invalid_state', `Job ${id} has no applied changes to find actions in.`);
      }
      engine.setJobActions?.(id, { status: 'finding', found: 0, pending: 0, added: 0, byType: {}, ...(inReview ? { stage: 'review' as const } : {}) });
      void service.findInJob(job, { retry: true });
      return engine.getJob(id) ?? job;
    },
    async jobActions(id: string) {
      if (!engine.getJob(id)) throw new CoreError('not_found', `Unknown job ${id}.`);
      return service.jobActions(id);
    },
    async ask(req) {
      const response = await ask.ask(req);
      // Finding actions in the answer runs in the background; it never delays the answer.
      void service.afterAsk(response.conversationID, response);
      return response;
    },
    listConversations: () => ask.listConversations(),
    getConversation: (id) => ask.getConversation(id),
    deleteConversation: (id) => ask.deleteConversation(id),
    setConversationPinned: (id, pinned) => ask.setConversationPinned(id, pinned),
    cancelAsk: (id) => ask.cancelAsk(id),
    listProgress: async () => [...progress.values()],
    async listJobSteps(id: string) {
      if (!engine.getJob(id)) throw new CoreError('not_found', `Unknown job ${id}.`);
      return stepLog.list(id);
    },
    listRunners: () => admin.listRunners(),
    setRunnerSecret: (id, name, value) => admin.setRunnerSecret(id, name, value),
    subscribe(listener) {
      const off = engine.subscribe(listener);
      extra.add(listener);
      return () => {
        off();
        extra.delete(listener);
      };
    },
  };
  // Work the core does on its own (batches moving on, runs, retention, queue scans) is logged from events.
  const names = new Map<string, string>();
  const logEvent = createEventLogger(
    { log: activity.log, getSettings: () => engine.getSettings(), collectorName: (id) => names.get(id) },
    engine.listJobs(),
  );
  core.subscribe((e) => {
    if (e.type === 'collector.changed') {
      if (e.deleted) setTimeout(() => names.delete(e.collector.id), 60_000).unref();
      else names.set(e.collector.id, e.collector.name);
    }
    logEvent(e);
  });
  // After the logger listens: listing notices a kept script edited while the core was down
  // (collector.script.changed_outside), and that entry must not be lost.
  void collectors
    .listCollectors()
    .then((list) => list.forEach((c) => names.set(c.id, c.name)))
    .catch(() => undefined);
  // Every user-visible change through the core is logged here, whoever calls it.
  return instrumentCore(core, { log: activity.log, trash: activity.trash, askDir });
}
