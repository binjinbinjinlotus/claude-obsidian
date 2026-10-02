import { CoreError } from '../contracts.js';
import type {
  AddNoteRequest,
  AddNoteResult,
  AskConversation,
  AskRequest,
  AskResponse,
  CoreEvent,
  LabelCount,
  LabelReview,
  LabelSuggestion,
  DistillCore,
  Job,
  Progress,
  QueueEntry,
  RunnerInfo,
  Settings,
  StatusResponse,
} from '../contracts.js';
import type { EngineExtras } from '../engine/index.js';

/**
 * In-memory DistillCore for server/CLI tests and client development. Records
 * every call; `emit` pushes a CoreEvent to subscribers. Never touches disk.
 */
export interface FakeCore extends DistillCore, EngineExtras {
  calls: { method: string; args: unknown[] }[];
  jobs: Job[];
  emit(event: CoreEvent): void;
  listenerCount(): number;
  /** Make the next call of `method` throw this error. */
  failNext(method: keyof DistillCore | keyof EngineExtras, error: Error): void;
  /** What listProgress returns. */
  progress: Progress[];
  /** Queue entries (removeQueueEntry removes by path). */
  queue: QueueEntry[];
  /** Queued notes by request ID (labels = confirmed labels, if any). */
  notes: Map<string, { notePath: string; labels?: string[] }>;
  conversations: AskConversation[];
  runners: RunnerInfo[];
  /** When set, addNote with suggest "wait" returns this as suggestError instead of suggestions. */
  suggestError?: string;
}

/** What the fake suggests for every note: one existing label and one new one. */
export const FAKE_SUGGESTIONS: LabelSuggestion[] = [
  { name: 'tea', existing: true },
  { name: 'gyokuro', existing: false },
];

export function sampleConversation(overrides: Partial<AskConversation> = {}): AskConversation {
  return {
    id: 'conv-1',
    title: 'How hot for sencha?',
    vaultPath: '/tmp/vault',
    createdAt: '2026-10-01T12:00:00Z',
    updatedAt: '2026-10-01T12:05:00Z',
    pinned: false,
    turnCount: 1,
    turns: [
      {
        askedAt: '2026-10-01T12:00:00Z',
        request: { question: 'How hot for sencha?' },
        response: {
          conversationID: 'conv-1',
          answer: 'Brew sencha at 70-80 °C [1].',
          citations: [{ n: 1, path: 'wiki/tea/sencha.md', title: 'Sencha' }],
          gaps: [],
          selection: { runnerID: 'claude-code', model: 'sonnet', effort: 'medium' },
          costUSD: 0.01,
        },
      },
    ],
    ...overrides,
  };
}

function sampleRunners(): RunnerInfo[] {
  return [
    {
      id: 'claude-code',
      displayName: 'Claude Code',
      kind: 'agent',
      enabled: true,
      capabilities: ['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput', 'effort'],
      tasks: ['ingest', 'ask', 'labelSuggest'],
      models: [{ id: 'sonnet', label: 'Sonnet' }],
      effortLevels: ['low', 'medium', 'high', 'xhigh', 'max'],
      defaultModel: 'sonnet',
      problems: [],
      secrets: [],
    },
    {
      id: 'openrouter',
      displayName: 'OpenRouter',
      kind: 'modelAPI',
      enabled: false,
      capabilities: ['structuredOutput'],
      tasks: ['labelSuggest'],
      models: [{ id: 'anthropic/claude-haiku', label: 'Claude Haiku' }],
      effortLevels: [],
      defaultModel: 'anthropic/claude-haiku',
      problems: [{ code: 'missingSecret', message: 'Add an OpenRouter API key.' }],
      secrets: [{ name: 'apiKey', label: 'API key', isSet: false }],
    },
  ];
}

const summary = ({ turns: _turns, ...rest }: AskConversation) => rest;

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
  let nextRequest = 1;
  const fake: FakeCore = {
    calls: [],
    progress: [],
    queue,
    jobs: init.jobs ?? [sampleJob()],
    notes: new Map(),
    conversations: [sampleConversation()],
    runners: sampleRunners(),
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
      const requestID = `req-${nextRequest++}`;
      fake.notes.set(requestID, { notePath, ...(req.labels ? { labels: req.labels } : {}) });
      const result: AddNoteResult = {
        notePath,
        requestID,
        queued: [notePath, ...(req.images ?? []).filter((i) => i.mode === 'keep').map((i) => i.path)],
      };
      if (!req.labels && req.suggest === 'wait') {
        if (fake.suggestError) result.suggestError = fake.suggestError;
        else result.suggestedLabels = FAKE_SUGGESTIONS.map((l) => ({ ...l }));
      }
      return result;
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
    async labelNote(requestID, labels) {
      record('labelNote', requestID, labels);
      const note = fake.notes.get(requestID);
      if (!note) throw new CoreError('not_found', `no queued note with request ID "${requestID}"`);
      note.labels = labels;
      return { notePath: note.notePath, labels };
    },
    async listLabels(vaultPath): Promise<LabelCount[]> {
      record('listLabels', vaultPath);
      return [
        { name: 'tea', count: 3, unconfirmed: 1 },
        { name: 'green', count: 1, unconfirmed: 0 },
      ];
    },
    async labelReview(vaultPath): Promise<LabelReview> {
      record('labelReview', vaultPath);
      return {
        toReview: [{ path: 'wiki/tea/sencha.md', title: 'Sencha', labels: ['tea'], origin: 'cli' }],
        unlabeled: [{ path: 'wiki/tea/matcha.md', title: 'Matcha' }],
      };
    },
    async suggestLabelsForPages(paths, opts) {
      record('suggestLabelsForPages', paths, opts);
      return sampleJob({ id: 'job-label-suggest', kind: 'labelSuggest', files: paths, state: 'running' });
    },
    async confirmLabels(items, vaultPath) {
      record('confirmLabels', items, vaultPath);
      return sampleJob({ id: 'job-label-confirm', kind: 'labelConfirm', files: items.map((i) => i.path) });
    },
    async listConversations() {
      record('listConversations');
      return fake.conversations.map(summary);
    },
    async getConversation(id) {
      record('getConversation', id);
      return fake.conversations.find((c) => c.id === id);
    },
    async deleteConversation(id) {
      record('deleteConversation', id);
      const i = fake.conversations.findIndex((c) => c.id === id);
      if (i === -1) throw new CoreError('not_found', `no conversation with id "${id}"`);
      fake.conversations.splice(i, 1);
    },
    async setConversationPinned(id, pinned) {
      record('setConversationPinned', id, pinned);
      const c = fake.conversations.find((x) => x.id === id);
      if (!c) throw new CoreError('not_found', `no conversation with id "${id}"`);
      c.pinned = pinned;
      return summary(c);
    },
    async listRunners() {
      record('listRunners');
      return fake.runners;
    },
    async setRunnerSecret(runnerID, name, value) {
      record('setRunnerSecret', runnerID, name, value);
      const secret = fake.runners.find((r) => r.id === runnerID)?.secrets.find((s) => s.name === name);
      if (!secret) throw new CoreError('not_found', `runner "${runnerID}" has no secret "${name}"`);
      secret.isSet = value !== null;
    },
    async cancelAsk(id: string) {
      record('cancelAsk', id);
    },
    async listProgress() {
      record('listProgress');
      return fake.progress;
    },
    async deleteJob(id) {
      record('deleteJob', id);
      const i = fake.jobs.findIndex((j) => j.id === id);
      if (i === -1) throw new CoreError('not_found', `Unknown job ${id}.`);
      const state = fake.jobs[i]!.state;
      if (state === 'running' || state === 'awaitingApproval') {
        throw new CoreError('invalid_state', `Job ${id} is ${state}; only finished jobs can be deleted.`);
      }
      fake.jobs.splice(i, 1);
    },
    async jobResumeCommand(id) {
      record('jobResumeCommand', id);
      const job = fake.jobs.find((j) => j.id === id);
      if (!job) throw new CoreError('not_found', `Unknown job ${id}.`);
      return job.kind === 'labels' ? null : ['claude', '--resume', job.sessionID, '--model', job.model];
    },
    async removeQueueEntry(p) {
      record('removeQueueEntry', p);
      const i = queue.findIndex((e) => e.path === p);
      if (i === -1) throw new CoreError('invalid_request', `${p} is not in the active queue folder.`);
      queue.splice(i, 1);
      return queue;
    },
    extractImageText: async (req: { imagePath: string; vaultPath?: string }) => {
      record('extractImageText', req);
      return { text: '', model: 'Haiku' };
    },
    searchPages: async (query: string, opts?: { vaultPath?: string; limit?: number }) => {
      record('searchPages', query, opts);
      return [{ path: 'wiki/sources/sencha.md', title: 'Sencha basics' }];
    },
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
