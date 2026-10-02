/**
 * Shared contract for every Distill layer (core engine, Ask, server, CLI,
 * clients). Owned by the lead: change it only by agreement, and keep the
 * persisted shapes byte-compatible with what the Swift app writes today
 * (~/Library/Application Support/Distill/settings.json and jobs.json).
 *
 * Specs: apps/distill/docs/specs/architecture.md, ai-runners.md,
 * approval-and-review.md, queue-and-batching.md, notes-composer.md, ask.md.
 */

// ───────────────────────────── Settings (settings.json) ─────────────────────────────

export interface VaultProfile {
  path: string;
  queueDirectory: string;
}

export type AITask = 'ingest' | 'ask' | 'labelSuggest' | 'imageText';

export interface ModelSelection {
  runnerID: string;
  model: string;
  /** undefined/null = the runner's default */
  effort?: string | null;
}

/** Field names and defaults mirror Swift `WorkerSettings`. Unknown keys must be preserved on write. */
export interface Settings {
  vaults: VaultProfile[];
  activeVaultPath?: string | null;
  batchIntervalMinutes: number; // default 10, min 1
  settleSeconds: number; // default 10
  model: string; // legacy default model for ingest/ask, default "sonnet"
  claudePath: string; // default ~/.local/bin/claude
  pythonPath: string; // default /usr/bin/python3
  productRoot: string; // claude-obsidian checkout (contains scripts/claude-obsidian.py)
  extraAllowedTools: string[];
  autoProcessEnabled: boolean; // default true
  enabledRunners: string[]; // default ["claude-code"]
  taskDefaults: Partial<Record<AITask, ModelSelection>>;
  /** New in the TS core; absent in Swift-written files. Path to node for spawning bridges. */
  nodePath?: string | null;
}

// ───────────────────────────── Jobs (jobs.json) ─────────────────────────────

export type JobState = 'running' | 'awaitingApproval' | 'completed' | 'failed' | 'rejected' | 'cancelled';

export interface TransactionPlan {
  operation_id: string;
  operation_type: string;
  valid: boolean;
  changed_paths: string[];
  approval_sha256: string;
}

export interface PermissionDenial {
  toolName: string;
  input: Record<string, unknown>;
}

export interface ApprovalRequest {
  summary: string;
  questions: string[];
  bundlePath?: string | null;
  plan?: TransactionPlan | null;
  planError?: string | null;
  denials: PermissionDenial[];
  skipped: string[];
}

export interface TurnRecord {
  id: string; // UUID
  date: string; // ISO-8601, e.g. 2026-10-01T15:42:00Z
  author: 'worker' | 'user' | 'app';
  text: string;
  costUSD: number;
}

/** Field names mirror Swift `Job` (note `sessionID`, `operationID`, `costUSD`). */
export interface Job {
  id: string; // job-yyyyMMdd-HHmmss-xxxx
  kind: string; // JobKind id, e.g. "ingest"
  vaultPath: string;
  files: string[]; // vault-relative inputs, e.g. inbox/foo.md
  sessionID: string;
  runnerID?: string | null; // absent in old jobs = "claude-code"
  model: string;
  effort?: string | null;
  state: JobState;
  createdAt: string;
  updatedAt: string;
  approval?: ApprovalRequest | null;
  turns: TurnRecord[];
  grantedTools: string[];
  operationID?: string | null;
  changedPaths: string[];
  error?: string | null;
}

/** Structured status every agent turn must end with (JSON schema in WorkerProtocol). */
export interface WorkerStatus {
  status: 'needs_approval' | 'needs_input' | 'done' | 'nothing_to_do' | 'failed';
  summary: string;
  bundle_path?: string;
  questions?: string[];
  operation_id?: string;
  changed_paths?: string[];
  skipped?: string[];
}

// ───────────────────────────── Runners ─────────────────────────────

export type RunnerCapability =
  | 'agentTools'
  | 'toolPermissions'
  | 'sandboxedWrites'
  | 'sessionResume'
  | 'structuredOutput'
  | 'effort'
  | 'vision';

export interface ModelOption {
  id: string;
  label: string;
  note?: string;
}

export type RunSession = { start: string } | { resume: string };

export interface RunRequest {
  workingDirectory: string;
  prompt: string;
  session: RunSession;
  selection: ModelSelection;
  /** Claude Code permission-rule syntax: Read, Bash(cmd:*), Edit(//abs/**). */
  allowedTools: string[];
  readableDirectories: string[];
  pluginDirectory?: string;
  outputSchema?: string; // JSON Schema text
  systemPrompt?: string;
  environment?: Record<string, string>;
  /** Absolute paths of images to attach (vision runners). */
  images?: string[];
  signal?: AbortSignal;
}

export interface RunResult {
  sessionID?: string;
  resultText: string;
  isError: boolean;
  costUSD: number;
  structured?: unknown;
  denials: PermissionDenial[];
  raw: string;
}

export interface SetupProblem {
  code: string; // e.g. "missingClaude", "noVault"
  message: string;
}

export interface AgentRunner {
  readonly id: string;
  readonly displayName: string;
  readonly capabilities: ReadonlySet<RunnerCapability>;
  readonly models: ModelOption[];
  readonly effortLevels: string[];
  readonly defaultModel: string;
  problems(settings: Settings): SetupProblem[];
  run(request: RunRequest, settings: Settings): Promise<RunResult>;
  /** argv that reopens a session interactively, if supported. */
  resumeCommand?(sessionID: string, model: string, settings: Settings): string[] | undefined;
}

export interface RunnerRegistry {
  all(): AgentRunner[];
  get(id: string): AgentRunner | undefined;
  /** Enabled runners whose capabilities satisfy the task. */
  candidates(task: AITask, settings: Settings): AgentRunner[];
}

export function runnerSupports(runner: AgentRunner, task: AITask): boolean {
  return TASK_REQUIREMENTS[task].some((need) => need.every((c) => runner.capabilities.has(c)));
}

/** What each task requires (mirror of Swift `AITask.requiredCapabilities`). */
export const TASK_REQUIREMENTS: Record<AITask, RunnerCapability[][]> = {
  // any one inner list satisfies the task
  ingest: [
    ['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput'],
    ['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput'],
  ],
  ask: [['agentTools', 'toolPermissions', 'sessionResume']],
  labelSuggest: [['structuredOutput']],
  imageText: [['vision']],
};

// ───────────────────────────── Queue & notes ─────────────────────────────

export interface QueueEntry {
  path: string; // absolute
  name: string;
  modified: string; // ISO-8601
  size: number;
  settled: boolean;
}

export interface NoteImage {
  /** Absolute path of an image file to include. */
  path: string;
  /** keep = store as attachment (default); extract = read text, do not store. */
  mode: 'keep' | 'extract';
}

export interface AddNoteRequest {
  title: string;
  text: string;
  images?: NoteImage[];
  /** Source id from the settings taxonomy, e.g. "slack", "meeting", "in-person". */
  source?: string;
  /** Free text: link, channel or person, e.g. "#tea-club · with Mei". */
  sourceRef?: string;
  vaultPath?: string; // default: active vault
}

export interface AddNoteResult {
  /** Files written into the queue folder (note .md, images, manifest). */
  queued: string[];
  notePath: string;
}

// ───────────────────────────── Ask ─────────────────────────────

export interface AskRequest {
  question: string;
  /** Continue a previous Ask conversation (same runner session). */
  conversationID?: string;
  selection?: ModelSelection; // default: settings task default for "ask"
  /** Default: all notes. Filters only when given. */
  labels?: string[];
  sources?: string[];
  vaultPath?: string;
}

export interface AskCitation {
  n: number;
  path: string; // vault-relative page
  title: string;
}

export interface AskResponse {
  conversationID: string;
  answer: string; // markdown with [n] markers
  citations: AskCitation[];
  gaps: string[];
  selection: ModelSelection;
  costUSD: number;
}

// ───────────────────────────── Events ─────────────────────────────

export type CoreEvent =
  | { type: 'queue'; entries: QueueEntry[] }
  | { type: 'job'; job: Job }
  | { type: 'settings'; settings: Settings }
  | { type: 'log'; level: 'info' | 'warn' | 'error'; message: string };

// ───────────────────────────── The core facade ─────────────────────────────

export interface StatusResponse {
  version: string;
  activeVault?: VaultProfile | null;
  problems: SetupProblem[];
  queueCount: number;
  pendingApprovals: number;
  runningJobs: number;
  nextBatchAt?: string | null;
  runners: { id: string; displayName: string; enabled: boolean; problems: SetupProblem[] }[];
}

/**
 * Everything the server exposes. Implemented by `createCore()` in index.ts
 * (engine + Ask). The server and CLI depend only on this interface.
 */
export interface DistillCore {
  start(): Promise<void>; // start scheduler
  stop(): Promise<void>;

  status(): Promise<StatusResponse>;
  getSettings(): Settings;
  updateSettings(patch: Partial<Settings>): Promise<Settings>;

  listQueue(): QueueEntry[];
  addQueueFiles(paths: string[]): Promise<QueueEntry[]>; // copies; originals untouched
  processQueue(opts?: { force?: boolean }): Promise<Job | null>;
  addNote(req: AddNoteRequest): Promise<AddNoteResult>;

  listJobs(): Job[];
  getJob(id: string): Job | undefined;
  approve(id: string): Promise<void>;
  reply(id: string, text: string): Promise<void>;
  allow(id: string, rules: string[]): Promise<void>;
  reject(id: string): Promise<void>;
  cancel(id: string): Promise<void>;

  ask(req: AskRequest): Promise<AskResponse>;

  subscribe(listener: (event: CoreEvent) => void): () => void;
}

// ───────────────────────────── Paths ─────────────────────────────

/** Where the core keeps state. Overridable via DISTILL_STATE_DIR (tests, headless runs). */
export interface StatePaths {
  dir: string; // ~/Library/Application Support/Distill
  settings: string; // <dir>/settings.json
  jobs: string; // <dir>/jobs.json
  serverLock: string; // <dir>/server.json  {pid, port, startedAt}
  token: string; // <dir>/token  (mode 0600)
}
