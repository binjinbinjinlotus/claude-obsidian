import { notImplemented } from '../contracts.js';
import type {
  AddNoteRequest,
  AddNoteResult,
  AskRequest,
  AskResponse,
  CoreEvent,
  DistillCore,
  Job,
  QueueEntry,
  Settings,
  StatusResponse,
} from '../contracts.js';

/**
 * In-memory DistillCore for server/CLI tests and client development. Records
 * every call; `emit` pushes a CoreEvent to subscribers. Never touches disk.
 */
export interface FakeCore extends DistillCore {
  calls: { method: string; args: unknown[] }[];
  jobs: Job[];
  emit(event: CoreEvent): void;
  listenerCount(): number;
  /** Make the next call of `method` throw this error. */
  failNext(method: keyof DistillCore, error: Error): void;
}

export function sampleJob(overrides: Partial<Job> = {}): Job {
  return {
    id: 'job-20261001-120000-abcd',
    kind: 'ingest',
    vaultPath: '/tmp/vault',
    files: ['inbox/a.md'],
    sessionID: '00000000-0000-0000-0000-000000000001',
    runnerID: 'claude-code',
    model: 'sonnet',
    state: 'awaitingApproval',
    createdAt: '2026-10-01T12:00:00Z',
    updatedAt: '2026-10-01T12:01:00Z',
    approval: null,
    turns: [],
    grantedTools: [],
    changedPaths: [],
    ...overrides,
  };
}

export function createFakeCore(init: { jobs?: Job[]; settings?: Partial<Settings> } = {}): FakeCore {
  const listeners = new Set<(e: CoreEvent) => void>();
  const failures = new Map<string, Error>();
  let settings: Settings = {
    vaults: [{ path: '/tmp/vault', queueDirectory: '/tmp/vault/inbox' }],
    activeVaultPath: '/tmp/vault',
    batchIntervalMinutes: 10,
    settleSeconds: 10,
    model: 'sonnet',
    claudePath: '/usr/local/bin/claude',
    pythonPath: '/usr/bin/python3',
    productRoot: '/tmp/claude-obsidian',
    extraAllowedTools: [],
    autoProcessEnabled: true,
    enabledRunners: ['claude-code'],
    taskDefaults: { ask: { runnerID: 'claude-code', model: 'sonnet', effort: 'medium' } },
    ...init.settings,
  };
  const queue: QueueEntry[] = [];
  const fake: FakeCore = {
    calls: [],
    jobs: init.jobs ?? [sampleJob()],
    emit(event) {
      for (const l of [...listeners]) l(event);
    },
    listenerCount: () => listeners.size,
    failNext(method, error) {
      failures.set(method, error);
    },

    async start() {
      record('start');
    },
    async stop() {
      record('stop');
    },
    async status(): Promise<StatusResponse> {
      record('status');
      return {
        version: '0.1.0-fake',
        activeVault: settings.vaults[0] ?? null,
        problems: [],
        queueCount: queue.length,
        pendingApprovals: fake.jobs.filter((j) => j.state === 'awaitingApproval').length,
        runningJobs: fake.jobs.filter((j) => j.state === 'running').length,
        nextBatchAt: null,
        runners: [{ id: 'claude-code', displayName: 'Claude Code', enabled: true, problems: [] }],
      };
    },
    getSettings() {
      record('getSettings');
      return settings;
    },
    async updateSettings(patch) {
      record('updateSettings', patch);
      settings = { ...settings, ...patch };
      return settings;
    },
    listQueue() {
      record('listQueue');
      return queue;
    },
    async addQueueFiles(paths) {
      record('addQueueFiles', paths);
      const added = paths.map((p) => ({ path: p, name: p.split('/').pop() ?? p, modified: '2026-10-01T12:00:00Z', size: 1, settled: false }));
      queue.push(...added);
      return added;
    },
    async processQueue(opts) {
      record('processQueue', opts);
      return opts?.force ? sampleJob({ id: 'job-processed', state: 'running' }) : null;
    },
    async addNote(req: AddNoteRequest): Promise<AddNoteResult> {
      record('addNote', req);
      const notePath = `/tmp/vault/inbox/${req.title.toLowerCase().replace(/[^a-z0-9]+/g, '-')}.md`;
      return { notePath, requestID: 'req-1', queued: [notePath, ...(req.images ?? []).filter((i) => i.mode === 'keep').map((i) => i.path)] };
    },
    listJobs() {
      record('listJobs');
      return fake.jobs;
    },
    getJob(id) {
      record('getJob', id);
      return fake.jobs.find((j) => j.id === id);
    },
    async approve(id) {
      record('approve', id);
    },
    async reply(id, text) {
      record('reply', id, text);
    },
    async allow(id, rules) {
      record('allow', id, rules);
    },
    async reject(id) {
      record('reject', id);
    },
    async cancel(id) {
      record('cancel', id);
    },
    async ask(req: AskRequest): Promise<AskResponse> {
      record('ask', req);
      return {
        conversationID: req.conversationID ?? 'conv-1',
        answer: 'Brew sencha at 70-80 °C [1].',
        citations: [{ n: 1, path: 'wiki/tea/sencha.md', title: 'Sencha' }],
        gaps: ['No notes on cold brewing.'],
        selection: req.selection ?? { runnerID: 'claude-code', model: 'sonnet', effort: 'medium' },
        costUSD: 0.01,
      };
    },
    // v2 stubs: server-cli teammate fills these with recorded fakes.
    labelNote: async () => notImplemented('labelNote'),
    listLabels: async () => notImplemented('listLabels'),
    labelReview: async () => notImplemented('labelReview'),
    suggestLabelsForPages: async () => notImplemented('suggestLabelsForPages'),
    confirmLabels: async () => notImplemented('confirmLabels'),
    listConversations: async () => notImplemented('listConversations'),
    getConversation: async () => notImplemented('getConversation'),
    deleteConversation: async () => notImplemented('deleteConversation'),
    setConversationPinned: async () => notImplemented('setConversationPinned'),
    listRunners: async () => notImplemented('listRunners'),
    setRunnerSecret: async () => notImplemented('setRunnerSecret'),
    subscribe(listener) {
      record('subscribe');
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };

  function record(method: string, ...args: unknown[]) {
    fake.calls.push({ method, args });
    const err = failures.get(method);
    if (err) {
      failures.delete(method);
      throw err;
    }
  }
  return fake;
}
