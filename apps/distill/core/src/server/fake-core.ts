import { CoreError } from '../contracts.js';
import type {
  ActivityApi,
  ActivityEntry,
  TrashItem,
  CollectedFile,
  Collector,
  CollectorRun,
  ActionItem,
  ActionTypeInfo,
  ConnectionInfo,
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
import { queueStatus } from '../engine/apply-queue.js';

/**
 * In-memory DistillCore for server/CLI tests and client development. Records
 * every call; `emit` pushes a CoreEvent to subscribers. Never touches disk.
 */
export interface FakeCore extends DistillCore, EngineExtras, ActivityApi {
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
  /** v3 actions, action types and connections (in memory). */
  actions: ActionItem[];
  actionTypes: ActionTypeInfo[];
  connections: ConnectionInfo[];
  /** v4 collectors, their runs and the Folder ledger (in memory). */
  collectors: Collector[];
  collectorRuns: CollectorRun[];
  collected: CollectedFile[];
  /** v6 activity entries (newest first) and trash items. */
  activity: ActivityEntry[];
  trash: TrashItem[];
}

export function sampleCollector(overrides: Partial<Collector> = {}): Collector {
  return {
    id: 'col-1',
    kind: 'folder',
    name: 'Distill Inbox',
    vaultPath: '/tmp/vault',
    enabled: true,
    schedule: { cron: '0 * * * *', preset: 'hourly' },
    folder: { source: '/tmp/Distill Inbox', afterCollect: 'copy' },
    createdAt: '2026-10-04T08:00:00Z',
    updatedAt: '2026-10-04T08:00:00Z',
    status: { running: false, nextRunAt: '2026-10-04T10:00:00Z', lastRun: null, needsConsent: false, needsAttention: false, collectedCount: 1 },
    ...overrides,
  };
}

export function sampleCollectorRun(overrides: Partial<CollectorRun> = {}): CollectorRun {
  return {
    id: 'run-1',
    collectorId: 'col-1',
    kind: 'folder',
    vaultPath: '/tmp/vault',
    trigger: 'schedule',
    startedAt: '2026-10-04T09:00:00Z',
    endedAt: '2026-10-04T09:00:01Z',
    durationMs: 1000,
    result: 'success',
    counts: { copied: 1, moved: 0, skipped: 2, waiting: 0, errors: 0, added: 1 },
    filesAdded: ['gyokuro.md'],
    files: [
      { name: 'gyokuro.md', outcome: 'copied', queueName: 'gyokuro.md', size: 120 },
      { name: 'gyokuro copy.md', outcome: 'skipped', reason: 'already collected', size: 120 },
      { name: 'sencha.md', outcome: 'skipped', reason: 'already collected', size: 80 },
    ],
    ...overrides,
  };
}

export function sampleAction(overrides: Partial<ActionItem> = {}): ActionItem {
  return {
    id: 'act-1',
    type: 'todo',
    status: 'pending',
    title: 'Book the tasting room for Saturday',
    body: null,
    fields: { due: '2026-10-04' },
    why: 'You said you would book it',
    source: { kind: 'note', jobID: 'job-20261001-120000-abcd', notePath: 'wiki/sources/tea.md', pageTitle: 'Tea club planning', quote: 'I’ll book the tasting room' },
    vaultPath: '/tmp/vault',
    createdAt: '2026-10-01T12:00:00Z',
    updatedAt: '2026-10-01T12:00:00Z',
    events: [{ at: '2026-10-01T12:00:00Z', event: 'found', detail: 'by Sonnet' }],
    ...overrides,
  };
}

function sampleActionTypes(): ActionTypeInfo[] {
  const base = { enabled: true, draftWhen: 'onFind' as const, improveAfterEdit: true, connectionID: null };
  return [
    { ...base, id: 'todo', label: 'To-do', pluralLabel: 'To-dos', improveAfterEdit: false, fields: [{ key: 'due', label: 'Due', kind: 'date' }], handlers: [{ id: 'complete', label: 'Complete', available: true }] },
    {
      ...base,
      id: 'slack',
      label: 'Slack message',
      pluralLabel: 'Slack messages',
      fields: [{ key: 'to', label: 'To', kind: 'person', required: true }],
      handlers: [
        { id: 'copy', label: 'Copy', available: true },
        { id: 'markSent', label: 'Mark as sent', available: true },
        { id: 'send', label: 'Send in Slack', available: false, reason: 'Later' },
      ],
    },
  ];
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

export function sampleActivityEntry(over: Partial<ActivityEntry> = {}): ActivityEntry {
  return {
    id: '1791155040000-0001-a1b2c3',
    at: '2026-10-04T23:04:00.000Z',
    type: 'collector.deleted',
    source: 'app',
    object: { kind: 'collector', id: 'col-2', name: 'Meeting notes' },
    summary: 'Deleted the script collector “Meeting notes”',
    outcome: 'ok',
    details: { kind: 'script', interpreter: 'python3', scriptBytes: 2140, scriptLines: 61 },
    recovery: { kind: 'trash', trashId: 'trash-1791155040000-0a1b2c3d', expiresAt: '2026-11-03T23:04:00.000Z' },
    pid: 4242,
    ...over,
  };
}

export function sampleTrashItem(over: Partial<TrashItem> = {}): TrashItem {
  return {
    id: 'trash-1791155040000-0a1b2c3d',
    kind: 'collector',
    objectID: 'col-2',
    name: 'Meeting notes',
    deletedAt: '2026-10-04T23:04:00.000Z',
    expiresAt: '2026-11-03T23:04:00.000Z',
    source: 'app',
    sizeBytes: 2600,
    details: { kind: 'script', interpreter: 'python3', scriptBytes: 2140, scriptLines: 61 },
    ...over,
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
    actions: [sampleAction()],
    actionTypes: sampleActionTypes(),
    collectors: [sampleCollector()],
    collectorRuns: [sampleCollectorRun()],
    activity: [sampleActivityEntry()],
    trash: [sampleTrashItem()],
    collected: [
      {
        sha256: 'a'.repeat(64),
        name: 'gyokuro.md',
        sourcePath: '/tmp/Distill Inbox/gyokuro.md',
        size: 120,
        mtime: '2026-10-04T07:00:00Z',
        collectedAt: '2026-10-04T09:00:00Z',
        collectorId: 'col-1',
        queueName: 'gyokuro.md',
        outcome: 'copied',
      },
    ],
    connections: [
      { id: 'atlassian', label: 'Atlassian (Jira and Confluence)', status: 'not_connected', site: null, account: null, message: null, usedBy: ['jira', 'confluence'] },
      { id: 'slack', label: 'Slack', status: 'not_connected', site: null, account: null, message: 'Copy works without connecting', usedBy: ['slack'] },
    ],
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
        ...queueStatus(fake.jobs),
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
    async scanQueue(opts) {
      record('scanQueue', opts);
      // The fake queue doesn't change on disk: a scan finds nothing new.
      return {
        added: 0, removed: 0, changed: 0, checkedAt: '2026-10-01T12:00:00Z', trigger: opts?.trigger ?? 'manual',
        addedEntries: [], removedEntries: [], changedEntries: [], entries: queue,
      };
    },
    async processQueue(opts) {
      record('processQueue', opts);
      return opts?.force ? sampleJob({ id: 'job-processed', state: 'running' }) : null;
    },
    async rereadSources(req) {
      record('rereadSources', req);
      // The fake expands a job to its files; by count when perBatch is given, else one batch by tokens.
      const files = req.jobId ? (fake.jobs.find((j) => j.id === req.jobId)?.files ?? []).filter((f) => !f.endsWith('.distill.json')) : (req.files ?? []);
      const per = req.perBatch ?? Math.max(1, files.length);
      const groups = [];
      for (let i = 0; i < files.length; i += per) groups.push({ files: files.slice(i, i + per) });
      const reread = { id: 'reread-20261005-120000-abcd', group: 1, groups: groups.length, ...(req.jobId ? { fromJob: req.jobId } : {}) };
      const first = sampleJob({ id: 'job-reread-1', state: 'running', files: groups[0]?.files ?? [], reread });
      if (groups[0]) Object.assign(groups[0], { jobId: first.id });
      return {
        id: reread.id,
        vaultPath: req.vaultPath ?? '/tmp/vault',
        perBatch: req.perBatch ?? 0,
        ...(req.perBatch === undefined ? { tokenBudget: req.tokenBudget ?? 100_000 } : {}),
        ...(req.jobId ? { fromJob: req.jobId } : {}),
        groups,
        started: groups.length ? [first] : [],
        waiting: Math.max(0, groups.length - 1),
      };
    },
    async listHeld(vaultPath) {
      record('listHeld', vaultPath);
      return [{ file: 'inbox/bad.md', reason: 'it isn’t valid UTF-8 text from line 412', at: '2026-10-05T10:40:00Z', jobId: 'job-1', size: 1200 }];
    },
    async retryHeld(file, vaultPath) {
      record('retryHeld', file, vaultPath);
      if (file !== 'inbox/bad.md') throw new CoreError('not_found', `Not held: ${file}`);
      const job = sampleJob({ id: 'job-retry-1', state: 'running', files: [file] });
      return { id: 'reread-retry', vaultPath: vaultPath ?? '/tmp/vault', perBatch: 0, tokenBudget: 100_000, groups: [{ files: [file], jobId: job.id }], started: [job], waiting: 0 };
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
    tryRecoveryAgain(id) {
      record('tryRecoveryAgain', id);
      return fake.jobs.find((j) => j.id === id)!;
    },
    unqueue(id) {
      record('unqueue', id);
      return fake.jobs.find((j) => j.id === id)!;
    },
    async reply(id, text) {
      record('reply', id, text);
    },
    async allow(id, rules) {
      record('allow', id, rules);
    },
    async reject(id, opts) {
      if (opts) record('reject', id, opts);
      else record('reject', id);
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
    async labelQueueItem(file, labels) {
      record('labelQueueItem', file, labels);
      return fake.queue;
    },
    async retryQueueLabels(file) {
      record('retryQueueLabels', file);
      return fake.queue;
    },
    async skipQueueLabels(file) {
      record('skipQueueLabels', file);
      return fake.queue;
    },
    async removeReviewSource(jobID, page, removed) {
      record('removeReviewSource', jobID, page, removed);
      return sampleJob({ id: jobID });
    },
    async editReviewLabels(jobID, edits) {
      record('editReviewLabels', jobID, edits);
      return sampleJob({ id: jobID });
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
    async findJobActions(id) {
      record('findJobActions', id);
      const job = fake.jobs.find((j) => j.id === id);
      if (!job) throw new CoreError('not_found', `Unknown job ${id}.`);
      if (job.state !== 'completed') throw new CoreError('invalid_state', `Job ${id} has no applied changes to find actions in.`);
      job.actionsFound = { status: 'finding', found: 0, pending: 0, added: 0, byType: {} };
      return job;
    },
    async jobActions(id) {
      record('jobActions', id);
      const job = fake.jobs.find((j) => j.id === id);
      if (!job) throw new CoreError('not_found', `Unknown job ${id}.`);
      return { summary: job.actionsFound ?? null, proposals: [] };
    },
    async removeQueueEntry(p) {
      record('removeQueueEntry', p);
      const i = queue.findIndex((e) => e.path === p);
      if (i === -1) throw new CoreError('invalid_request', `${p} is not in the active queue folder.`);
      queue.splice(i, 1);
      return queue;
    },
    async listActionTypes() {
      record('listActionTypes');
      return fake.actionTypes;
    },
    async listActions(query) {
      record('listActions', query);
      return fake.actions.filter((a) => (!query?.type || a.type === query.type) && (query?.history || !['removed', 'done', 'sent', 'dismissed'].includes(a.status)));
    },
    async getAction(id) {
      record('getAction', id);
      return fake.actions.find((a) => a.id === id);
    },
    async createAction(input) {
      record('createAction', input);
      const item = sampleAction({ id: `act-${fake.actions.length + 1}`, type: input.type, title: input.title, body: input.body ?? null, fields: input.fields ?? {} });
      fake.actions.push(item);
      return item;
    },
    async updateAction(id, patch) {
      record('updateAction', id, patch);
      const item = requireAction(id);
      if (patch.title !== undefined) item.title = patch.title;
      if (patch.body !== undefined) item.body = patch.body;
      if (patch.fields) Object.assign(item.fields, patch.fields);
      if (patch.type) item.type = patch.type;
      return item;
    },
    async confirmActions(ids) {
      record('confirmActions', ids);
      return ids.map((id) => Object.assign(requireAction(id), { status: 'open' as const }));
    },
    async dismissActions(ids) {
      record('dismissActions', ids);
      for (const id of ids) requireAction(id).status = 'dismissed';
    },
    async draftAction(id, opts) {
      record('draftAction', id, opts?.signal ? 'signal' : undefined);
      return Object.assign(requireAction(id), { status: 'ready' as const, body: 'Drafted.' });
    },
    async previewActionButton(id, buttonId) {
      record('previewActionButton', id, buttonId);
      return { argv: ['python3', '/x/slack_cli.py', 'send', '--', '#general', 'Hi'], display: "python3 /x/slack_cli.py send -- '#general' Hi", problems: [], needsApproval: true, needsConsent: false, approvalHash: 'h' };
    },
    async previewButtonDraft(input) {
      record('previewButtonDraft', input.typeId);
      return { argv: ['python3', '/x/slack_cli.py', 'send'], display: 'python3 /x/slack_cli.py send', problems: [], needsApproval: true, needsConsent: false, approvalHash: 'h' };
    },
    async listSlackPeople(vaultPath) {
      record('listSlackPeople', vaultPath ?? undefined);
      return [{ vaultPath: '/v', name: 'Aditya Pradhan', target: '@aditya', savedAt: '2026-10-06T12:00:00Z' }];
    },
    async rememberSlackPerson(input) {
      record('rememberSlackPerson', input.name, input.target, input.vaultPath ?? undefined);
      return { vaultPath: input.vaultPath ?? '/v', name: input.name, target: input.target, savedAt: '2026-10-06T12:00:00Z' };
    },
    async forgetSlackPerson(input) {
      record('forgetSlackPerson', input.name, input.vaultPath ?? undefined);
      return { forgotten: true };
    },
    async slackTarget(id) {
      record('slackTarget', id);
      return { kind: 'person' as const, written: 'Aditya Pradhan', target: '@aditya', name: 'Aditya Pradhan' };
    },
    async runActionButton(id, buttonId, opts) {
      record('runActionButton', id, buttonId, opts?.approve ? 'approve' : undefined);
      const item = requireAction(id);
      return { run: { runId: 'run-1', buttonId, label: 'Send in Slack', startedAt: '2026-10-05T12:00:00Z', result: 'running' as const }, item };
    },
    async stopActionButtonRun(id) {
      record('stopActionButtonRun', id);
    },
    async summarizeAction(id, opts) {
      record('summarizeAction', id, opts?.signal ? 'signal' : undefined);
      return Object.assign(requireAction(id), { summary: 'Summarized.' });
    },
    async improveAction(id, opts) {
      record('improveAction', id, opts?.signal ? 'signal' : undefined);
      const item = requireAction(id);
      return Object.assign(item, { previousBody: item.body ?? null, body: 'Improved.' });
    },
    async undoImprove(id) {
      record('undoImprove', id);
      const item = requireAction(id);
      if (item.previousBody == null) throw new CoreError('invalid_state', 'There is no improve to undo.');
      return Object.assign(item, { body: item.previousBody, previousBody: null });
    },
    async performAction(id, handlerID) {
      record('performAction', id, handlerID);
      const item = requireAction(id);
      if (handlerID === 'create') item.error = { code: 'not_connected', message: 'Jira isn’t connected.' };
      if (handlerID === 'complete') item.status = 'done';
      if (handlerID === 'markSent') item.status = 'sent';
      return item;
    },
    async sendActionTo(id, type) {
      record('sendActionTo', id, type);
      const from = requireAction(id);
      from.status = 'sent';
      const next = sampleAction({ id: `act-${fake.actions.length + 1}`, type, title: from.title, fromActionID: id });
      fake.actions.push(next);
      return next;
    },
    async removeAction(id) {
      record('removeAction', id);
      return Object.assign(requireAction(id), { status: 'removed' as const });
    },
    async restoreAction(id) {
      record('restoreAction', id);
      return Object.assign(requireAction(id), { status: 'open' as const });
    },
    async deleteActionForever(id) {
      record('deleteActionForever', id);
      const item = requireAction(id);
      if (!['removed', 'done', 'sent'].includes(item.status)) throw new CoreError('invalid_state', 'Only items in History can be deleted forever.');
      fake.actions.splice(fake.actions.indexOf(item), 1);
    },
    async detectAskActions(conversationID, turnIndex) {
      record('detectAskActions', conversationID, turnIndex);
      if (!fake.conversations.some((c) => c.id === conversationID)) throw new CoreError('not_found', `no conversation with id "${conversationID}"`);
      return fake.actions.filter((a) => a.source.kind === 'ask' && a.source.conversationID === conversationID);
    },
    async listConnections() {
      record('listConnections');
      return fake.connections;
    },
    async connect(id, req) {
      record('connect', id, { ...req, ...(req.token ? { token: '[set]' } : {}) });
      const c = fake.connections.find((x) => x.id === id);
      if (!c) throw new CoreError('not_found', `Unknown connection ${id}.`);
      if (req.token === 'bad') throw new CoreError('invalid_request', `acme.atlassian.net didn't accept token ${req.token} for ${req.email}.`);
      Object.assign(c, { status: 'connected', site: req.site ?? c.site ?? null, account: 'Jin Liu' });
      return c;
    },
    async signInURL(id, site) {
      record('signInURL', id, site);
      if (id !== 'atlassian') throw new CoreError('invalid_request', 'Slack isn’t needed yet.');
      return { url: 'https://id.atlassian.com/manage-profile/security/api-tokens' };
    },
    async disconnect(id) {
      record('disconnect', id);
      const c = fake.connections.find((x) => x.id === id);
      if (!c) throw new CoreError('not_found', `Unknown connection ${id}.`);
      return Object.assign(c, { status: 'not_connected' as const, account: null });
    },
    async listCollectors() {
      record('listCollectors');
      return fake.collectors;
    },
    async getCollector(id) {
      record('getCollector', id);
      return fake.collectors.find((c) => c.id === id);
    },
    async createCollector(input) {
      record('createCollector', input);
      const c = sampleCollector({
        id: `col-${fake.collectors.length + 1}`,
        kind: input.kind,
        name: input.name ?? (input.kind === 'folder' ? 'Distill Inbox' : 'Script'),
        enabled: input.kind === 'folder',
        ...(input.kind === 'script' && input.script
          ? { folder: undefined, script: { source: input.script.source, interpreter: input.script.interpreter, timeoutSeconds: input.script.timeoutSeconds ?? 300 } }
          : {}),
      });
      fake.collectors.push(c);
      return c;
    },
    async updateCollector(id, patch) {
      record('updateCollector', id, patch);
      const c = requireCollector(id);
      if (patch.name !== undefined) c.name = patch.name;
      if (patch.enabled !== undefined) c.enabled = patch.enabled;
      if (patch.schedule) c.schedule = patch.schedule;
      if (patch.folder && c.folder) Object.assign(c.folder, patch.folder);
      return c;
    },
    async deleteCollector(id) {
      record('deleteCollector', id);
      fake.collectors.splice(fake.collectors.indexOf(requireCollector(id)), 1);
    },
    async runCollector(id) {
      record('runCollector', id);
      const c = requireCollector(id);
      if (c.status?.running) throw new CoreError('busy', `${c.name} is already running.`);
      // Stored as finished (a fake run ends at once); returned as it was when it started.
      const done = sampleCollectorRun({ id: `run-${fake.collectorRuns.length + 1}`, collectorId: id, kind: c.kind, trigger: 'now' });
      fake.collectorRuns.unshift(done);
      const started: CollectorRun = { ...done, result: 'running', files: [], filesAdded: [], counts: { copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 0, added: 0 } };
      delete started.endedAt;
      delete started.durationMs;
      return started;
    },
    async stopCollector(id) {
      record('stopCollector', id);
      requireCollector(id);
      const run = fake.collectorRuns.find((r) => r.collectorId === id && (r.result === 'running' || r.result === 'queued'));
      return run ? Object.assign(run, { result: 'stopped' as const }) : null;
    },
    async allowCollector(id, sha256) {
      record('allowCollector', id, sha256);
      const c = requireCollector(id);
      if (!c.script) throw new CoreError('invalid_request', 'Only script collectors need consent.');
      Object.assign(c.script, { allowedSha256: sha256, allowedAt: '2026-10-04T09:00:00Z' });
      c.enabled = true;
      return c;
    },
    async revokeCollector(id) {
      record('revokeCollector', id);
      const c = requireCollector(id);
      if (!c.script) throw new CoreError('invalid_request', 'Only script collectors have consent.');
      Object.assign(c.script, { allowedSha256: null, allowedAt: null });
      c.enabled = false;
      return c;
    },
    async listCollectorRuns(id, opts) {
      record('listCollectorRuns', id, opts);
      requireCollector(id);
      const runs = fake.collectorRuns.filter((r) => r.collectorId === id);
      return opts?.limit ? runs.slice(0, opts.limit) : runs;
    },
    async listCollected(id, query) {
      record('listCollected', id, query);
      requireCollector(id);
      return fake.collected.filter((f) => f.collectorId === id && (!query || f.name.includes(query)));
    },
    async forgetCollected(id, sha256) {
      record('forgetCollected', id, sha256);
      requireCollector(id);
      const removed = fake.collected.filter((f) => f.collectorId === id && (!sha256 || f.sha256 === sha256));
      fake.collected = fake.collected.filter((f) => !removed.includes(f));
      return removed;
    },
    async restoreCollected(id, files) {
      record('restoreCollected', id, files);
      requireCollector(id);
      fake.collected.push(...files);
      return files.length;
    },
    async createCollectorFolder(id, which) {
      record('createCollectorFolder', id, which);
      return requireCollector(id);
    },
    async checkSchedule(cron) {
      record('checkSchedule', cron);
      return cron.trim().split(/\s+/).length === 5
        ? { cron, valid: true, preset: 'custom' as const, nextRuns: ['2026-10-04T10:00:00Z'] }
        : { cron, valid: false, error: 'A schedule has 5 fields.', nextRuns: [] };
    },
    async getCollectorScript(id) {
      record('getCollectorScript', id);
      const c = requireCollector(id);
      if (!c.script) throw new CoreError('invalid_request', 'Only script collectors have a script.');
      const file = 'file' in c.script.source ? c.script.source.file : '/state/collectors/scripts/x/collector.zsh';
      return { collectorId: id, interpreter: c.script.interpreter, managed: true, path: file, dir: '/state/collectors/scripts/x', code: 'print hi', sha256: 'a'.repeat(64), manifest: null };
    },
    async writeCollectorScript(id, update) {
      record('writeCollectorScript', id, update);
      const c = requireCollector(id);
      if (!c.script) throw new CoreError('invalid_request', 'Only script collectors have a script.');
      return { collectorId: id, interpreter: c.script.interpreter, managed: true, path: '/state/collectors/scripts/x/collector.js', dir: '/state/collectors/scripts/x', code: update.code ?? 'print hi', sha256: 'b'.repeat(64), manifest: update.manifest !== undefined ? { name: 'package.json' as const, path: '/state/collectors/scripts/x/package.json', text: update.manifest, sha256: update.manifest === null ? null : 'c'.repeat(64) } : null };
    },
    async installCollectorPackages(id, opts) {
      record('installCollectorPackages', id, opts);
      requireCollector(id);
      return { id: 'ins-1', collectorId: id, trigger: 'manual' as const, startedAt: '2026-10-04T09:00:00Z', result: 'running' as const, command: 'npm install --no-audit --no-fund', manifestName: 'package.json' as const, manifestSha256: 'c'.repeat(64), ...(opts?.clean ? { clean: true } : {}) };
    },
    async stopCollectorInstall(id) {
      record('stopCollectorInstall', id);
      requireCollector(id);
      return null;
    },
    async getCollectorInstall(id) {
      record('getCollectorInstall', id);
      requireCollector(id);
      return null;
    },
    async testCollector(id) {
      record('testCollector', id);
      const c = requireCollector(id);
      return sampleCollectorRun({ id: 'run-test', collectorId: id, kind: c.kind, trigger: 'test', result: 'running', outputDir: '/state/collectors/test-runs/x' });
    },
    extractImageText: async (req: { imagePath: string; vaultPath?: string }) => {
      record('extractImageText', req);
      return { text: '', model: 'Haiku' };
    },
    searchPages: async (query: string, opts?: { vaultPath?: string; limit?: number }) => {
      record('searchPages', query, opts);
      return [{ path: 'wiki/sources/sencha.md', title: 'Sencha basics' }];
    },
    async listActivity(query = {}) {
      record('listActivity', query);
      const limit = query.limit ?? 50;
      const list = fake.activity.filter(
        (e) =>
          (!query.cursor || e.id < query.cursor) &&
          (!query.types?.length || query.types.some((t) => e.type === t || e.type.startsWith(`${t}.`))) &&
          (!query.objectID || e.object.id === query.objectID) &&
          (!query.sources?.length || query.sources.includes(e.source)) &&
          (!query.text || `${e.summary} ${e.object.name ?? ''}`.toLowerCase().includes(query.text.toLowerCase())),
      );
      const entries = list.slice(0, limit);
      return { entries, nextCursor: list.length > limit ? entries[entries.length - 1]!.id : null };
    },
    async listTrash() {
      record('listTrash');
      return fake.trash;
    },
    async restoreFromTrash(id) {
      record('restoreFromTrash', id);
      const item = fake.trash.find((t) => t.id === id);
      if (!item) throw new CoreError('not_found', `No trash item ${id} (it may have expired).`);
      fake.trash.splice(fake.trash.indexOf(item), 1);
      return { item, objectID: item.objectID, ...(item.kind === 'collector' ? { note: 'The script collector is off; review and allow its script to turn it on.' } : {}) };
    },
    subscribe(listener) {
      record('subscribe');
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };

  function requireCollector(id: string): Collector {
    const c = fake.collectors.find((x) => x.id === id);
    if (!c) throw new CoreError('not_found', `Unknown collector ${id}.`);
    return c;
  }

  function requireAction(id: string): ActionItem {
    const item = fake.actions.find((a) => a.id === id);
    if (!item) throw new CoreError('not_found', `Unknown action ${id}.`);
    return item;
  }

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
