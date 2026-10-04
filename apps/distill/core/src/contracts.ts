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

export type AITask = 'ingest' | 'ask' | 'labelSuggest' | 'imageText' | 'actionFind' | 'actionDraft' | 'actionImprove';

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
  settleSeconds: number; // default 600 (10 min); a file must be unchanged this long before a batch takes it
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

  // ── v2 (all optional; absent = the DEFAULT_* below) ──
  /** Editable source groups (Settings → Sources). Default DEFAULT_SOURCE_TAXONOMY. */
  sourceTaxonomy?: SourceGroup[];
  /** Defaults for new Ask chats and Ask history retention. */
  askPreferences?: Partial<AskPreferences>;
  /** How notes that don't come from the Distill UI get labels. */
  labeling?: Partial<LabelingPreferences>;
  /** Global shortcuts; no defaults (null = off). Stored as e.g. "ctrl+opt+space". */
  shortcuts?: { ask?: string | null; addNote?: string | null };
  /** Non-secret per-runner options, e.g. {"openrouter": {"baseURL": "..."}}. Secrets live in the Keychain. */
  runnerOptions?: Record<string, Record<string, string>>;
  /** v3: Actions (to-dos and action types). Absent = DEFAULT_ACTION_PREFERENCES. */
  actionPreferences?: Partial<ActionPreferences>;
  /**
   * v5: the queue check. Every this many minutes the core rescans the queue folder in full (folders
   * walked again, files removed by hand dropped). Absent = DEFAULT_QUEUE_SCAN_MINUTES (5); 0 = Off
   * (Refresh, the window-active scan and batches still scan). Clients offer 1, 5, 15, 60 and Off.
   */
  queueScanMinutes?: number | null;
}

/** Settings → Batching → "Check the queue folder for changes": every 5 minutes. */
export const DEFAULT_QUEUE_SCAN_MINUTES = 5;

export interface SourceDefinition {
  id: string; // stored in a note's `source_type`, e.g. "slack"
  label: string;
}

export interface SourceGroup {
  id: string; // e.g. "discussion"; picking a group in Ask includes all its sources
  label: string;
  sources: SourceDefinition[];
}

export const DEFAULT_SOURCE_TAXONOMY: SourceGroup[] = [
  {
    id: 'discussion',
    label: 'Discussion',
    sources: [
      { id: 'slack', label: 'Slack' },
      { id: 'meeting', label: 'Meeting' },
      { id: 'github-review', label: 'GitHub review' },
      { id: 'jira-comment', label: 'Jira comment' },
      { id: 'email', label: 'Email' },
      { id: 'in-person', label: 'In person' },
    ],
  },
  {
    id: 'reference',
    label: 'Reference',
    sources: [
      { id: 'web-page', label: 'Web page' },
      { id: 'document', label: 'Document' },
      { id: 'paper', label: 'Paper' },
    ],
  },
  {
    id: 'personal',
    label: 'Personal',
    sources: [
      { id: 'remember-this', label: 'Remember this' },
      { id: 'idea', label: 'Idea' },
    ],
  },
];

/** any = a note with at least one of the labels; all = a note with every label. */
export type LabelMatch = 'any' | 'all';

export interface AskPreferences {
  labelMatch: LabelMatch;
  /** Count AI labels not yet confirmed (labels_reviewed: false) when filtering. */
  includeUnconfirmed: boolean;
  keepHistory: boolean;
  /** Delete chats whose last message is older than this; pinned chats are kept. */
  historyDays: number;
}

export const DEFAULT_ASK_PREFERENCES: AskPreferences = {
  labelMatch: 'any',
  includeUnconfirmed: true,
  keepHistory: true,
  historyDays: 10,
};

export interface LabelingPreferences {
  /** Files dropped straight into the queue folder get AI labels at batch time (unconfirmed). */
  autoLabelQueueFolder: boolean;
  /** CLI notes with no labels sent back before the batch runs get the AI labels (unconfirmed). */
  cliFallbackToAI: boolean;
}

export const DEFAULT_LABELING_PREFERENCES: LabelingPreferences = {
  autoLabelQueueFolder: true,
  cliFallbackToAI: true,
};

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
  /** API responses only (not stored): the allow rule a client can offer, null for compound commands. */
  suggestedRule?: string | null;
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
  /** v3: actions found after the batch was applied ("Found 5 actions to confirm"). */
  actionsFound?: JobActionsSummary | null;
  /** v5: folder items in this batch (vault-relative, e.g. inbox/2026-10-04/Tea tasting trip). Their source files are in `files`. */
  folders?: string[];
}

export interface JobActionsSummary {
  status: 'finding' | 'done' | 'failed' | 'skipped';
  found: number;
  /** Waiting for you to confirm. */
  pending: number;
  /** Added without confirmation (confirm off). */
  added: number;
  byType: Record<string, number>;
  error?: string | null;
  model?: string | null;
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
  /**
   * The complete set of tools the run may see (Claude Code `--tools`). Runners
   * also ignore the user's own settings and MCP servers, so personal allow
   * rules never widen a Distill permission gate. Omit to keep the runner default.
   */
  availableTools?: string[];
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
  /** Default "agent". */
  readonly kind?: 'agent' | 'modelAPI';
  /** Keychain secrets the runner reads, e.g. [{name: "apiKey", label: "API key"}]. */
  readonly secrets?: { name: string; label: string }[];
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
  actionFind: [['structuredOutput']],
  actionDraft: [['structuredOutput']],
  actionImprove: [['structuredOutput']],
};

// ───────────────────────────── Queue & notes ─────────────────────────────

export interface QueueEntry {
  path: string; // absolute
  name: string;
  modified: string; // ISO-8601
  size: number;
  settled: boolean;
  /** When the settle wait ends (modified + settleSeconds); absent when already ready. Clients show it as a clock time. */
  readyAt?: string | null;
  /**
   * note = written by addNote (complete when queued, skips the wait); folder = a folder in the queue folder
   * (one item; v5); gdoc = a Google Drive `.gdoc` shortcut (v5); file = anything else.
   * Clients must treat an unknown kind as `file`.
   */
  kind?: 'note' | 'file' | 'folder' | 'gdoc';
  /** Why the core can't use this file (unreadable, too large, ...). */
  problem?: string | null;
  /** True when the file changed after the core first saw it (its ready time moved). Shown as "still changing". */
  changing?: boolean;
  /** For a note row: the paths of the files that travel with it (its .distill.json and images). Clients show one row; removing the note removes them all. */
  members?: string[];
  /** For a note row: its source summary and whether its labels are confirmed, from the manifest. */
  note?: { source?: string | null; labelsConfirmed?: boolean; imageCount?: number } | null;
  /** v5, folder rows: files inside (hidden files, partial downloads and the folder manifest not counted). `size` is their total; `modified` the newest change inside. */
  fileCount?: number;
  /** v5, folder rows: subfolders at any level. */
  folderCount?: number;
  /** v5, folder rows: the read-only tree, sorted by path, at most QUEUE_FOLDER_LIMITS.maxTreeEntries entries. */
  tree?: QueueTreeEntry[];
  /** v5: true when `tree` was cut at maxTreeEntries. */
  treeTruncated?: boolean;
  /** v5, gdoc rows: the document's title (the file name without .gdoc) and link. Never the account email in the file. */
  gdoc?: GoogleDocLink | null;
  /**
   * v5: the item stays in the queue and no batch takes it (Process now included), though nothing is wrong
   * with it. 'google-drive' = a .gdoc (or a folder holding only .gdoc files): Distill can't read Google Drive yet.
   */
  waiting?: 'google-drive' | string | null;
}

/** One entry of a folder item's tree. */
export interface QueueTreeEntry {
  /** Relative to the folder item, "/"-separated, e.g. "notes/day1-uji.md". */
  path: string;
  /** Bytes; a dir: the total of its files. */
  size: number;
  kind: 'file' | 'dir' | 'gdoc';
  /** Collected before (Folder collector manifest): listed for context, not given to the AI as a source. Absent = false. */
  seenBefore?: boolean;
}

/**
 * Limits for a folder queue item. Over maxFiles/maxBytes (files the AI would read) → problem 'too big';
 * a file deeper than maxDepth levels → problem 'too deep'. Either way the folder stays out of batches,
 * Process now included. The Folder collector applies maxFiles/maxBytes to a subfolder's new files.
 */
export const QUEUE_FOLDER_LIMITS = {
  maxFiles: 200,
  maxBytes: 500 * 1024 * 1024,
  /** Levels below the folder: folder/a/b/c.md is at level 3. */
  maxDepth: 8,
  maxTreeEntries: 500,
} as const;

export interface GoogleDocLink {
  /** The .gdoc file name without its extension. */
  title: string;
  /** https on docs.google.com or drive.google.com (from the file's `url`, or built from its `doc_id`). */
  url: string;
  docId?: string | null;
}

/** What a queue scan found, compared with the list the core had before it. */
export interface QueueScanResult {
  added: number;
  removed: number;
  changed: number;
  checkedAt: string; // ISO-8601
  /** manual = Refresh (POST /v1/queue/scan); window = the app window became active; periodic = the queue check. */
  trigger: 'manual' | 'window' | 'periodic';
  /** Set when the queue folder can't be read ("Can't read the queue folder"). */
  problem?: string | null;
  addedEntries: QueueEntry[];
  /** As they were last listed. */
  removedEntries: QueueEntry[];
  /** Same path, different contents (size, modified time, counts, tree, problem, kind…). */
  changedEntries: QueueEntry[];
  /** The whole list after the scan. */
  entries: QueueEntry[];
}

export interface NoteImage {
  /** Absolute path of an image file to include. */
  path: string;
  /**
   * keep = store as attachment (default; the note text embeds it as ![[file name]] where it was pasted);
   * extract = read text at batch time, do not store (legacy: the app now extracts on demand via extractImageText).
   */
  mode: 'keep' | 'extract';
}

export interface ExtractImageTextRequest {
  /** Absolute path of a local image file (png, jpg, gif, webp, heic). */
  imagePath: string;
  vaultPath?: string; // default: active vault (for runner context only; nothing is written)
}

export interface ExtractImageTextResult {
  /** Markdown read from the image; '' when no text was found. */
  text: string;
  /** Model label shown to the user, e.g. "Haiku". */
  model: string;
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
  /** Labels chosen by the caller. They count as confirmed; no suggestion is made. */
  labels?: string[];
  /**
   * When to suggest labels (labelSuggest task) if `labels` is absent:
   * wait = include them in the result (CLI); background = emit a `labelSuggestions` event (app, default);
   * none = don't suggest.
   */
  suggest?: 'wait' | 'background' | 'none';
  /** Who added the note; decides the fallback when no labels are confirmed before the batch. Default "app". */
  origin?: 'app' | 'cli';
}

export interface AddNoteResult {
  /** Files written into the queue folder (note .md, images, manifest). */
  queued: string[];
  notePath: string;
  /** Pass to labelNote() to confirm labels until the batch picks the note up. */
  requestID: string;
  /** Present when suggest = "wait" and the suggestion succeeded. */
  suggestedLabels?: LabelSuggestion[];
  /** Why suggestions are missing with suggest = "wait" (e.g. no runner for labelSuggest). */
  suggestError?: string;
  /** Cost of the suggestion call, when one ran. */
  costUSD?: number;
}

// ───────────────────────────── Labels ─────────────────────────────
//
// Labels are a note's `tags` property in the vault, which is the only record of
// whether they are confirmed:
//   labels_by: ai | user        who chose them
//   labels_reviewed: false      AI labels not yet confirmed (absent or true = confirmed)
//   labels_origin: queue-folder | cli | suggest   where unconfirmed AI labels came from
// Every vault change (applying AI labels to existing pages, confirming) is a
// transaction the user approves in Review.

export type LabelOrigin = 'queue-folder' | 'cli' | 'suggest';

export interface LabelSuggestion {
  name: string; // without '#'
  /** true = already used in the vault; false = new label. */
  existing: boolean;
}

export interface LabelCount {
  name: string;
  count: number; // pages with this label
  unconfirmed: number; // of which labels_reviewed: false
}

export interface LabelReviewItem {
  path: string; // vault-relative page
  title: string;
  labels: string[];
  origin?: LabelOrigin | null;
}

export interface LabelReview {
  /** Pages with labels_reviewed: false. */
  toReview: LabelReviewItem[];
  /** Pages under wiki/ (excluding meta/system pages) with no tags. */
  unlabeled: { path: string; title: string }[];
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
  /** Default: settings askPreferences.labelMatch ("any"). */
  labelMatch?: LabelMatch;
  /** Default: settings askPreferences.includeUnconfirmed (true). */
  includeUnconfirmed?: boolean;
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
  /** Things the user should know, e.g. "Started a new session because the filter changed." */
  notices?: string[];
}

export interface AskTurn {
  askedAt: string; // ISO-8601
  request: AskRequest;
  response: AskResponse;
}

export interface AskConversationSummary {
  id: string;
  title: string; // first question, trimmed
  vaultPath: string;
  createdAt: string;
  updatedAt: string; // last message; retention counts from here
  pinned: boolean;
  turnCount: number;
}

export interface AskConversation extends AskConversationSummary {
  turns: AskTurn[];
}

// ───────────────────────────── Runner admin ─────────────────────────────

export interface RunnerInfo {
  id: string;
  displayName: string;
  /** agent = reads files and runs tools (ingest, ask); modelAPI = plain model calls. */
  kind: 'agent' | 'modelAPI';
  enabled: boolean;
  capabilities: RunnerCapability[];
  /** Tasks this runner can do (runnerSupports). */
  tasks: AITask[];
  models: ModelOption[];
  effortLevels: string[];
  defaultModel: string;
  problems: SetupProblem[];
  /** Secrets the runner needs (stored in the macOS Keychain, never in settings.json). */
  secrets: { name: string; label: string; isSet: boolean }[];
}

// ───────────────────────────── Progress (loading states) ─────────────────────────────

/**
 * Live progress for long AI work, so clients can show what is happening.
 * One event per change; the last one for a key has `finished: true`.
 */
export interface Progress {
  /** Stable key: a job id, "ask:<conversationID>", or "note:<requestID>". */
  key: string;
  kind: 'batch' | 'labelSuggest' | 'labelPages' | 'ask' | 'apply' | 'actions';
  /** Short present-tense text, e.g. "Reading 3 sources", "Suggesting labels". */
  message: string;
  /** Ordered steps for batches: ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"]. */
  steps?: string[];
  stepIndex?: number;
  done?: number;
  total?: number;
  startedAt: string; // ISO-8601, for the elapsed timer
  runnerID?: string;
  model?: string;
  finished?: boolean;
  error?: string;
}

// ───────────────────────────── Errors ─────────────────────────────

/** HTTP mapping: not_found→404, invalid_request→400, invalid_state/busy/no_vault→409, not_implemented→501. */
export type CoreErrorCode = 'not_found' | 'invalid_request' | 'invalid_state' | 'busy' | 'no_vault' | 'not_implemented' | 'conflict';

export class CoreError extends Error {
  constructor(
    readonly code: CoreErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'CoreError';
  }
}

export function notImplemented(what: string): never {
  throw new CoreError('not_implemented', `${what}: not implemented`);
}


// ───────────────────────────── Actions (actions.json) ─────────────────────────────
//
// Things to do that Distill finds in processed notes and Ask answers. Every item
// has a TYPE. "todo" is the catch-all; other types (slack, jira, confluence, later
// email, …) are things Distill can do for you through HANDLERS (copy, mark sent,
// create in Jira, send, …). Types and handlers are data in a registry
// (core/src/actions/registry.ts): adding one never changes this contract.

/** Built-in action types. Others may appear later; clients must render unknown ids generically. */
export const BUILTIN_ACTION_TYPES = ['todo', 'slack', 'jira', 'confluence'] as const;
export type ActionTypeID = string;

/**
 * pending   – found, waiting for you to confirm (Ask me to confirm is on)
 * open      – in its list (a to-do, or a type item whose draft isn't written yet)
 * drafting  – AI is writing the draft (or improving it after your edit)
 * ready     – draft written; ready to copy / create
 * creating  – a handler is running (e.g. creating in Jira)
 * created   – exists outside Distill (external key/url/status); stays listed until done
 * done      – completed: you pressed Complete (any type, from open / ready / created / sent; the
 *             external status is left as it is), or Jira / Confluence reports Done on refresh
 * sent      – you marked a message as sent (or a future Send handler sent it)
 * removed   – you removed it; in History until historyDays, restorable
 * dismissed – you dismissed a found item before it was added (not shown in lists)
 */
export type ActionStatus = 'pending' | 'open' | 'drafting' | 'ready' | 'creating' | 'created' | 'done' | 'sent' | 'removed' | 'dismissed';

export type ActionSource =
  | { kind: 'note'; jobID?: string | null; notePath?: string | null; pageTitle?: string | null; quote?: string | null }
  | {
      kind: 'ask'; conversationID: string; question?: string | null; quote?: string | null; citedPaths?: string[];
      /** Which turn of the chat it came from (0-based). */
      turnIndex?: number | null;
      /** It came from the answer's gap (what the vault didn't cover): clients then hide that Gap callout. */
      gap?: boolean;
    }
  | { kind: 'manual'; /** Who added it: the user in the app (default) or an agent through the CLI/API. */ by?: 'user' | 'agent' };

export interface ActionError {
  /** not_connected / auth_expired → show "Sign in"; refused → `field` is the bad field; unreachable; ai_failed. */
  code: 'not_connected' | 'auth_expired' | 'refused' | 'unreachable' | 'ai_failed' | 'other';
  message: string;
  field?: string | null;
}

export interface ActionEvent {
  at: string; // ISO-8601
  /**
   * e.g. found, confirmed, drafted, edited, improved, improve-undone, copied, sent-to:<type>, created, status, done, removed, restored.
   * `done` from Complete has detail = the status it left (open | ready | created | sent), which restoreAction
   * returns it to; an automatic Done from a refresh has a description ("in Jira (Done)") instead.
   */
  event: string;
  detail?: string | null;
}

export interface ActionItem {
  id: string;
  type: ActionTypeID;
  status: ActionStatus;
  /** One line: the to-do, the message's purpose, the ticket summary, the page title. */
  title: string;
  /** Markdown: to-do notes, the Slack message, the ticket description, the page body. */
  body?: string | null;
  /** Type-specific fields by key (see ActionTypeInfo.fields), e.g. to, due, priority, person, project, issueType, space, parent. */
  fields: Record<string, string | null>;
  /** Why it needs doing (shown as "Why:"). */
  why?: string | null;
  source: ActionSource;
  vaultPath?: string | null;
  labels?: string[];
  createdAt: string;
  updatedAt: string;
  /** Model label that wrote / last improved the draft, e.g. "Sonnet". */
  draftModel?: string | null;
  /** The text before the last AI improve, for Undo. Cleared on the next edit. */
  previousBody?: string | null;
  /** Created outside Distill (Jira key, Confluence page). */
  external?: { key?: string | null; url?: string | null; status?: string | null; checkedAt?: string | null } | null;
  error?: ActionError | null;
  /** The item this one came from (a to-do sent to Slack keeps the to-do's id here). */
  fromActionID?: string | null;
  /** Timeline, oldest first. */
  events: ActionEvent[];
}

export interface ActionFieldSpec {
  key: string;
  label: string;
  kind: 'text' | 'person' | 'date' | 'choice' | 'markdown';
  choices?: string[];
  required?: boolean;
}

export interface ActionHandlerInfo {
  /** copy | markSent | create | complete ("Complete", every handler type) | refresh | send … */
  id: string;
  label: string;
  /** false = shown disabled (reserved for later, or a connection is missing). */
  available: boolean;
  reason?: string | null;
}

export interface ActionTypeInfo {
  id: ActionTypeID;
  label: string; // "Slack message"
  pluralLabel: string; // "Slack messages"
  /** Off in Settings: no tab, and its items fall back to to-dos. Reserved types (email) are listed but disabled. */
  enabled: boolean;
  reserved?: boolean;
  fields: ActionFieldSpec[];
  handlers: ActionHandlerInfo[];
  /** Connection this type needs (e.g. "atlassian"), if any. */
  connectionID?: string | null;
  /** When the draft is written: on note processing / Ask detection, or only when you click. */
  draftWhen: 'onFind' | 'onRequest';
  /** Run the improve prompt after you finish editing. */
  improveAfterEdit: boolean;
  /** Built-in prompts, shown in Settings as the Default and restored by Reset to default. */
  defaultDraftPrompt?: string | null;
  defaultImprovePrompt?: string | null;
  /** Placeholders a prompt may use (Settings → Insert field), e.g. "{title}", "{excerpt}", "{recipient}". */
  placeholders?: string[];
}

export interface ActionSourcePreferences {
  detectTodos: boolean; // default true
  detectTypes: boolean; // default true (Slack, Jira, Confluence…)
  /** Types not detected from this source even though detectTypes is on. */
  disabledTypes?: string[];
  /** Ask me to confirm before adding. Default true. */
  confirm: boolean;
}

export interface ActionTypePreferences {
  enabled: boolean;
  draftWhen: 'onFind' | 'onRequest';
  improveAfterEdit: boolean;
  /** Model for writing the draft; default Claude Code · Sonnet. */
  draftSelection?: ModelSelection | null;
  /** Model for improving after your edit; default Claude Code · Sonnet. */
  improveSelection?: ModelSelection | null;
  /** null/absent = the built-in default prompt (Reset to default sets null). */
  draftPrompt?: string | null;
  improvePrompt?: string | null;
  /** Default field values, e.g. {project: "PX", issueType: "Task"} or {space: "ENG"}. */
  fieldDefaults?: Record<string, string>;
}

export interface ActionPreferences {
  sources: { notes: ActionSourcePreferences; ask: ActionSourcePreferences };
  /** By type id. Missing keys use each type's built-in defaults. */
  types: Record<string, Partial<ActionTypePreferences>>;
  /** Model that finds actions in notes and answers; default Claude Code · Sonnet. */
  findSelection?: ModelSelection | null;
  /** Prompt for finding actions; null = default. */
  findPrompt?: string | null;
  todo: { defaultSort: 'due' | 'created' | 'priority' | 'note'; defaultGroup: 'due' | 'note' | 'none'; remindOverdue: boolean };
  /** Removed / done / sent items stay in History this many days. Default 90; 0 or less = forever. */
  historyDays: number;
}

export const DEFAULT_ACTION_PREFERENCES: ActionPreferences = {
  sources: {
    notes: { detectTodos: true, detectTypes: true, confirm: true },
    ask: { detectTodos: true, detectTypes: true, confirm: true },
  },
  types: {},
  todo: { defaultSort: 'due', defaultGroup: 'due', remindOverdue: false },
  historyDays: 90,
};

export interface ActionQuery {
  type?: ActionTypeID;
  status?: ActionStatus[];
  /** Include removed/done/sent (History). Default false. */
  history?: boolean;
  vaultPath?: string;
  text?: string;
}

export interface NewActionInput {
  type: ActionTypeID;
  title: string;
  body?: string | null;
  fields?: Record<string, string | null>;
  why?: string | null;
  source?: ActionSource; // default manual
  vaultPath?: string | null;
  /** Labels to set (trimmed, leading # dropped, deduped). */
  labels?: string[];
}

export interface ActionPatch {
  title?: string;
  body?: string | null;
  fields?: Record<string, string | null>;
  /** Change where it goes (only while pending/open/ready). */
  type?: ActionTypeID;
  /** Replaces the item's labels (trimmed, leading # dropped, deduped). */
  labels?: string[];
}

// ───────────────────────────── Connections ─────────────────────────────

export interface ConnectionInfo {
  /** "atlassian" (Jira + Confluence on one site), later "slack", … */
  id: string;
  label: string;
  status: 'connected' | 'not_connected' | 'expired' | 'signing_in' | 'error';
  site?: string | null;
  account?: string | null;
  message?: string | null;
  /** Types that use this connection. */
  usedBy: ActionTypeID[];
}

/** Credentials go to the Keychain; never to settings.json or logs. */
export interface ConnectRequest {
  site?: string; // e.g. https://acme.atlassian.net
  email?: string;
  token?: string;
}

// ───────────────────────────── Collectors (collectors.json) ─────────────────────────────
//
// Collectors fill a vault's queue folder on a schedule; what they bring is batched,
// reviewed and applied like a dropped file. One list for all vaults; each collector
// has a target vault. State: <state>/collectors.json, <state>/collectors/ledger-<vault-id>.jsonl
// (Folder dedupe by sha256), <state>/collectors/runs/<collector-id>.jsonl (run history).
// Spec: apps/distill/docs/specs/collectors.md

export type CollectorKind = 'folder' | 'script';
export type CollectorInterpreter = 'zsh' | 'python3' | 'node';
/** Presets are shorthands for the cron: every15 = "*\/15 * * * *", hourly = "0 * * * *", daily = "M H * * *", weekdays = "M H * * 1-5". */
export type SchedulePreset = 'every15' | 'hourly' | 'daily' | 'weekdays' | 'custom';

export interface CollectorSchedule {
  /** 5-field cron (minute hour day-of-month month day-of-week) in local time; "@hourly" and "@daily" are accepted. */
  cron: string;
  preset?: SchedulePreset;
}

export interface FolderCollectorSettings {
  /** Absolute source folder (a leading "~" is expanded on save). Default "~/Distill Inbox", created on save. */
  source: string;
  /** copy (default) keeps the original; move takes it out of the source folder. */
  afterCollect: 'copy' | 'move';
  /**
   * v5: also collect each top-level subfolder as one folder item. New collectors: true. A collector saved
   * before v5 (field absent) reads as false, so it keeps doing what the user set up.
   * Dedupe stays per file: a subfolder is collected when any file in it is new or changed.
   */
  includeSubfolders?: boolean;
}

export type ScriptSource = { file: string } | { inline: string };

export interface ScriptCollectorSettings {
  source: ScriptSource;
  interpreter: CollectorInterpreter;
  /** Default 300 (5 minutes), 1…3600. */
  timeoutSeconds: number;
  /** The script sha256 the user allowed (consent). A run starts only while the script hashes to this. */
  allowedSha256?: string | null;
  allowedAt?: string | null;
}

/** Computed by the core on every read; ignored on input. */
export interface CollectorStatus {
  /** A run is queued or running. */
  running: boolean;
  /** Next scheduled run (ISO-8601); null when off or the schedule never runs. */
  nextRunAt?: string | null;
  /** The newest run (files and output tails left out; see listCollectorRuns). */
  lastRun?: CollectorRun | null;
  /** Script: the script's current sha256, or null when it can't be read (scriptProblem says why). */
  currentSha256?: string | null;
  scriptProblem?: string | null;
  /** Script: never allowed, or changed since it was allowed. */
  needsConsent: boolean;
  /** Folder: ledger entries whose source is this collector's folder ("Already collected: 128 files"). */
  collectedCount?: number;
  /** The sidebar count: the last run failed or timed out, or the script needs consent. */
  needsAttention: boolean;
}

export interface Collector {
  id: string; // col-<uuid>
  kind: CollectorKind;
  name: string;
  /** Target vault (a configured vault profile); its queue folder receives the files. */
  vaultPath: string;
  enabled: boolean;
  schedule: CollectorSchedule;
  folder?: FolderCollectorSettings; // kind folder
  script?: ScriptCollectorSettings; // kind script
  createdAt: string;
  updatedAt: string;
  status?: CollectorStatus;
}

export interface NewCollectorInput {
  kind: CollectorKind;
  /** Default "Distill Inbox" (folder) / "Script" (script). */
  name?: string;
  /** Default: the active vault. */
  vaultPath?: string;
  /** Folder default true. A script is always created off (it needs consent first). */
  enabled?: boolean;
  /** Default every hour. */
  schedule?: CollectorSchedule;
  folder?: Partial<FolderCollectorSettings>;
  script?: { source: ScriptSource; interpreter: CollectorInterpreter; timeoutSeconds?: number };
}

export interface CollectorPatch {
  name?: string;
  vaultPath?: string;
  /** Turning a script on needs a current consent (else invalid_state). */
  enabled?: boolean;
  schedule?: CollectorSchedule;
  folder?: Partial<FolderCollectorSettings>;
  /** A new source or interpreter changes the hash: the script needs consent again. */
  script?: Partial<{ source: ScriptSource; interpreter: CollectorInterpreter; timeoutSeconds: number }>;
}

export type CollectorTrigger = 'schedule' | 'now' | 'catchup';

/**
 * queued    – waiting for a free slot (at most 2 collectors run at once) or, for a script,
 *             for a batch to finish applying to the same vault (`waiting`)
 * success   – copied / moved files (Folder) or added files to the queue (script, exit 0)
 * nothing   – nothing new
 * skipped   – a scheduled tick while this collector was still running (`skipReason`)
 * notTrusted – a script that isn't allowed yet or changed since (error.code notAllowed | scriptChanged)
 * stopped   – the user pressed Stop
 */
export type CollectorRunResult = 'queued' | 'running' | 'success' | 'nothing' | 'failed' | 'timedout' | 'skipped' | 'notTrusted' | 'stopped';

export type CollectorErrorCode =
  | 'sourceMissing'
  | 'noPermission'
  | 'queueMissing'
  | 'vaultMissing'
  | 'scriptMissing'
  | 'interpreterMissing'
  | 'scriptFailed'
  | 'notAllowed'
  | 'scriptChanged'
  | 'interrupted'
  | 'other';

export interface CollectorRunFile {
  /** Name in the source folder. */
  name: string;
  /** v5: 'folder' for a subfolder collected as one item ("Tea tasting trip/ (folder · 5 new of 12 files)"). Absent = a file. */
  kind?: 'file' | 'folder';
  /** Folder: files inside it. */
  fileCount?: number;
  /** Folder: files that were new or changed (copied, or the AI's sources after a move). */
  newCount?: number;
  /** copied / moved; skipped = already collected; waiting = still changing; error = this file failed (the run went on). */
  outcome: 'copied' | 'moved' | 'skipped' | 'waiting' | 'error';
  reason?: string;
  /** Name it got in the queue folder ("tea 2.md" after a clash). */
  queueName?: string;
  size?: number;
}

export interface CollectorRun {
  id: string; // run-<uuid>
  collectorId: string;
  kind: CollectorKind;
  vaultPath: string;
  trigger: CollectorTrigger;
  /** When the run started (when it was queued, until it starts). */
  startedAt: string;
  endedAt?: string;
  durationMs?: number;
  result: CollectorRunResult;
  /** While queued: what it waits for. */
  waiting?: 'slot' | 'batch';
  /** Skipped: why, e.g. "the 6:00 AM run was still going". */
  skipReason?: string;
  error?: { code: CollectorErrorCode; message: string };
  /** Folder: per-file outcomes. */
  files?: CollectorRunFile[];
  counts: { copied: number; moved: number; skipped: number; waiting: number; errors: number; added: number };
  /** Names that appeared in the queue folder during the run (script), or that the run put there (Folder). */
  filesAdded: string[];
  /** Script. */
  exitCode?: number | null;
  signal?: string | null;
  sha256?: string;
  /** Script: the last 64 KB of each stream. */
  stdoutTail?: string;
  stderrTail?: string;
}

/** One entry of a vault's ledger: a file a Folder collector took (name, size, times, hash; never content). */
export interface CollectedFile {
  sha256: string;
  name: string;
  sourcePath: string;
  size: number;
  /** The file's mtime when collected (ISO-8601). */
  mtime: string;
  collectedAt: string;
  collectorId: string;
  queueName: string;
  outcome: 'copied' | 'moved';
}

export interface ScheduleCheck {
  cron: string;
  valid: boolean;
  error?: string;
  /** The preset this cron matches, if any ("custom" otherwise). */
  preset?: SchedulePreset;
  /** The next runs from now (up to 3, ISO-8601). */
  nextRuns: string[];
}

// ───────────────────────────── Activity log (v6; spec activity-log.md) ─────────────────────────────

/**
 * Who asked for a change. Requests say who they are with the `X-Distill-Client` header
 * (app, cli, agent); the Mac app is also recognised by its URLSession User-Agent.
 *  app       – the Mac app
 *  cli       – the `distill` CLI typed by a person
 *  agent     – the CLI run by an AI agent (the plugin skills; Claude Code or Codex)
 *  scheduler – Distill on its own: scheduled batches and collector runs, history retention
 *  api       – an HTTP request that didn't say who it is
 *  core      – in-process calls with no request (tests, dev scripts)
 */
export type ActivitySource = 'app' | 'cli' | 'agent' | 'scheduler' | 'api' | 'core';

export type ActivityObjectKind =
  | 'chat'
  | 'collector'
  | 'action'
  | 'batch'
  | 'queue'
  | 'note'
  | 'connection'
  | 'settings'
  | 'runner'
  | 'labels'
  | 'core';

export interface ActivityObject {
  kind: ActivityObjectKind;
  /** Stable id (chat id, col-…, act-…, job-…, a queue file path). Absent for settings and the core. */
  id?: string;
  /** Human name at the time of the change (chat title, collector name, file name, …). */
  name?: string;
}

/** Where a deleted thing can be got back from. */
export type ActivityRecovery =
  | { kind: 'trash'; trashId: string; expiresAt: string }
  | { kind: 'macosTrash'; path: string }
  | { kind: 'none'; reason: string };

/** One line of `<state>/activity/activity.jsonl`. Never holds secrets or script bodies. */
export interface ActivityEntry {
  /** Time-sortable: "<13-digit ms>-<seq>-<random>". Also the pagination cursor. */
  id: string;
  /** ISO-8601. */
  at: string;
  /** Stable event type, "<family>.<verb>", e.g. "collector.deleted", "batch.applied". */
  type: string;
  source: ActivitySource;
  object: ActivityObject;
  /** One short sentence, e.g. "Deleted the script collector “Meeting notes”". */
  summary: string;
  outcome: 'ok' | 'failed';
  /** Failed: the error, redacted and shortened. */
  error?: string;
  /** Small, flat, redacted facts (counts, sizes, paths, changed keys). */
  details?: Record<string, string | number | boolean | null | string[]>;
  /** Deletes: where to get it back. */
  recovery?: ActivityRecovery;
  /** Process that wrote the line (the server, or another process sharing the state dir). */
  pid: number;
}

export interface ActivityQuery {
  /** Exact types or families: "collector" matches "collector.*". */
  types?: string[];
  objectKind?: ActivityObjectKind;
  objectID?: string;
  sources?: ActivitySource[];
  /** ISO-8601, inclusive. */
  since?: string;
  /** ISO-8601, exclusive. */
  until?: string;
  /** Case-insensitive text in the summary, type, object name/id and details. */
  text?: string;
  outcome?: 'ok' | 'failed';
  /** Default 50, max 500. */
  limit?: number;
  /** nextCursor of the previous page: entries older than it. */
  cursor?: string;
}

export interface ActivityPage {
  /** Newest first. */
  entries: ActivityEntry[];
  /** Pass as `cursor` for the next (older) page; null at the end. */
  nextCursor: string | null;
}

export type TrashItemKind = 'chat' | 'collector';

/** A deleted chat or collector kept for a while so it can be restored. The payload stays on disk. */
export interface TrashItem {
  id: string; // trash-<…>
  kind: TrashItemKind;
  objectID: string;
  name: string;
  deletedAt: string;
  /** When retention removes it (30 days after deletedAt by default). */
  expiresAt: string;
  source: ActivitySource;
  /** Size of the kept copy in bytes. */
  sizeBytes: number;
  /** chat: turnCount; collector: kind, interpreter, scriptBytes, scriptLines, vaultPath. Never the script. */
  details: Record<string, string | number | boolean | null>;
}

export interface RestoreResult {
  item: TrashItem;
  /** The restored chat id or collector id (a collector gets a new id when its old one is taken). */
  objectID: string;
  /** A restored script collector comes back off and needs consent again. */
  note?: string;
}

/** The activity log and trash API (composed in index.ts; the server answers 501 without it). */
export interface ActivityApi {
  listActivity(query?: ActivityQuery): Promise<ActivityPage>;
  listTrash(): Promise<TrashItem[]>;
  restoreFromTrash(id: string): Promise<RestoreResult>;
}

// ───────────────────────────── Events ─────────────────────────────

export type CoreEvent =
  | { type: 'queue'; entries: QueueEntry[] }
  | { type: 'job'; job: Job; deleted?: true }
  | { type: 'settings'; settings: Settings }
  | { type: 'log'; level: 'info' | 'warn' | 'error'; message: string }
  | { type: 'labelSuggestions'; requestID: string; notePath: string; labels: LabelSuggestion[]; error?: string; costUSD?: number }
  | { type: 'progress'; progress: Progress }
  | { type: 'conversation'; conversation: AskConversationSummary; deleted?: boolean }
  | { type: 'action'; action: ActionItem; deleted?: true }
  | { type: 'connection'; connection: ConnectionInfo }
  // v4: collectors (dotted names as in the collectors spec)
  | { type: 'collector.changed'; collector: Collector; deleted?: true }
  | { type: 'collector.run.started'; run: CollectorRun }
  /** Throttled script output: the text added since the last event. */
  | { type: 'collector.run.output'; collectorId: string; runId: string; stream: 'stdout' | 'stderr'; text: string }
  | { type: 'collector.run.finished'; run: CollectorRun }
  // v5: a queue scan finished (Refresh, window, periodic). A `queue` event precedes it when the list changed.
  | { type: 'queue.scanned'; result: QueueScanResult }
  // v6: a line was added to the activity log (older Mac builds decode unknown events as `.unknown`).
  | { type: 'activity'; entry: ActivityEntry };

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
  /** v5: the last full queue scan of any kind ("checked at 3:41 AM"), and the next queue check (null when Off). */
  lastQueueScanAt?: string | null;
  nextQueueScanAt?: string | null;
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
  /** Finished jobs only (completed/failed/rejected/cancelled); else invalid_state. */
  deleteJob(id: string): Promise<void>;
  /** argv that reopens the job's session interactively; null when the runner has none. */
  jobResumeCommand(id: string): Promise<string[] | null>;
  /** Vault pages for the note picker (`[[`), best matches first. */
  searchPages(query: string, opts?: { vaultPath?: string; limit?: number }): Promise<{ path: string; title: string }[]>;
  /**
   * Read the text in one image now (imageText task; Settings default Claude Code · Haiku · Low),
   * for "Extract content" in the editors. Returns Markdown; empty text means none was found.
   * Aborting the signal (HTTP: the client closes the request) stops the runner.
   */
  extractImageText(req: ExtractImageTextRequest, opts?: { signal?: AbortSignal }): Promise<ExtractImageTextResult>;
  /** Move a file in the active queue folder to the Trash (with its note manifest). */
  removeQueueEntry(path: string): Promise<QueueEntry[]>;
  /** v5: rescan the queue folder now (folders walked again, files removed by hand dropped); returns what changed. */
  scanQueue(opts?: { trigger?: 'manual' | 'window' }): Promise<QueueScanResult>;

  ask(req: AskRequest): Promise<AskResponse>;

  // ── v2: labels (owner: core-labels) ──
  /** Confirm labels for a queued note until the batch picks it up; afterwards → invalid_state. */
  labelNote(requestID: string, labels: string[]): Promise<{ notePath: string; labels: string[] }>;
  listLabels(vaultPath?: string): Promise<LabelCount[]>;
  labelReview(vaultPath?: string): Promise<LabelReview>;
  /**
   * AI-label existing UNLABELED pages (pages that already have tags are skipped) and write
   * labels_reviewed: false. Returns the job at once in `running`; `progress` events count pages; the
   * job moves to awaitingApproval when done. cancel() keeps finished pages.
   */
  suggestLabelsForPages(paths: string[], opts?: { vaultPath?: string; selection?: ModelSelection }): Promise<Job>;
  /** Write confirmed labels (clears the unconfirmed marks). Returns a job awaiting approval. */
  confirmLabels(items: { path: string; labels: string[] }[], vaultPath?: string): Promise<Job>;

  // ── v2: Ask history (owner: core-ask) ──
  listConversations(): Promise<AskConversationSummary[]>;
  getConversation(id: string): Promise<AskConversation | undefined>;
  deleteConversation(id: string): Promise<void>;
  setConversationPinned(id: string, pinned: boolean): Promise<AskConversationSummary>;
  /** Stop the in-flight turn of this conversation (Stop button). The question is not stored. No-op if idle. */
  cancelAsk(conversationID: string): Promise<void>;
  /** Progress currently in flight (for clients that connect mid-run). */
  listProgress(): Promise<Progress[]>;

  // ── v2: runners (owner: runners) ──
  listRunners(): Promise<RunnerInfo[]>;
  /** null clears the secret. */
  setRunnerSecret(runnerID: string, name: string, value: string | null): Promise<void>;

  // ── v3: actions (owner: core-actions) ──
  listActionTypes(): Promise<ActionTypeInfo[]>;
  listActions(query?: ActionQuery): Promise<ActionItem[]>;
  getAction(id: string): Promise<ActionItem | undefined>;
  /** Add by hand (or from a selection in Ask). Lands as open (to-do) or ready/open (type). */
  createAction(input: NewActionInput): Promise<ActionItem>;
  /** Edit. A body edit on a type with improveAfterEdit does NOT improve by itself: the client calls improveAction when you click Done. */
  updateAction(id: string, patch: ActionPatch): Promise<ActionItem>;
  /** Confirm found items (pending → open/ready, writing drafts if draftWhen is onFind). */
  confirmActions(ids: string[]): Promise<ActionItem[]>;
  /**
   * Dismiss found items (pending → dismissed). Also Undo for items added without confirmation:
   * an item still untouched since it was found (only found/drafted/confirmed events, plus confirm's
   * to-do fallback) → dismissed, no History entry. This is also the Undo of "Add all".
   */
  dismissActions(ids: string[]): Promise<void>;
  /** Write the draft now ("Create message"). progress key: action:<id>. */
  draftAction(id: string, opts?: { signal?: AbortSignal }): Promise<ActionItem>;
  /** Improve the draft after your edit (improve prompt + model); keeps previousBody for Undo. */
  improveAction(id: string, opts?: { signal?: AbortSignal }): Promise<ActionItem>;
  /** Put previousBody back. */
  undoImprove(id: string): Promise<ActionItem>;
  /**
   * Run a handler: copy (records the event), markSent, create, refresh, … complete: from open, ready, created
   * or sent (not pending, removed, dismissed, done, busy, or a to-do already sent to another type) → done,
   * whatever the external status says; event `done`, detail = the status it left.
   */
  performAction(id: string, handlerID: string): Promise<ActionItem>;
  /** A to-do (or an item of another type) goes to a type's list; the new item keeps fromActionID; the old one leaves its list. */
  sendActionTo(id: string, type: ActionTypeID): Promise<ActionItem>;
  removeAction(id: string): Promise<ActionItem>;
  /** Every Undo. done → the status Complete recorded (else created with an external key, else open/ready). */
  restoreAction(id: string): Promise<ActionItem>;
  /** From History only; cannot be undone. */
  deleteActionForever(id: string): Promise<void>;
  /** Find actions in one Ask turn (also runs by itself after each answer when Settings say so). Returns the found items. */
  detectAskActions(conversationID: string, turnIndex?: number): Promise<ActionItem[]>;

  // ── v3: connections (owner: core-actions) ──
  listConnections(): Promise<ConnectionInfo[]>;
  connect(id: string, req: ConnectRequest): Promise<ConnectionInfo>;
  /** URL to open in the browser to sign in or create a token for this connection. */
  signInURL(id: string, site?: string): Promise<{ url: string }>;
  disconnect(id: string): Promise<ConnectionInfo>;

  // ── v4: collectors (owner: core-collectors; spec collectors.md) ──
  listCollectors(): Promise<Collector[]>;
  getCollector(id: string): Promise<Collector | undefined>;
  /** A script collector is saved off and needs allowCollector before it can run. */
  createCollector(input: NewCollectorInput): Promise<Collector>;
  updateCollector(id: string, patch: CollectorPatch): Promise<Collector>;
  /** Refused (busy) while a run is queued or running. The ledger is kept. */
  deleteCollector(id: string): Promise<void>;
  /** Run now (does not move the schedule). Returns the run (queued or running); busy when one is already queued or running. */
  runCollector(id: string): Promise<CollectorRun>;
  /** Stop the queued or running run (scripts: SIGTERM, SIGKILL 10 s later). Null when idle. */
  stopCollector(id: string): Promise<CollectorRun | null>;
  /** Consent: `sha256` must equal the script's current hash (else invalid_state). Also turns it on. */
  allowCollector(id: string, sha256: string): Promise<Collector>;
  /** Clears the consent and turns the collector off. */
  revokeCollector(id: string): Promise<Collector>;
  /** Newest first. */
  listCollectorRuns(id: string, opts?: { limit?: number }): Promise<CollectorRun[]>;
  /** Folder: Already collected, newest first; `query` filters by name. */
  listCollected(id: string, query?: string): Promise<CollectedFile[]>;
  /** Folder: Forget one (every entry with that sha256 in the vault's ledger) or, without sha256, all entries from this folder. Returns what was removed (for Undo). */
  forgetCollected(id: string, sha256?: string): Promise<CollectedFile[]>;
  /** Folder: Undo of Forget: put entries back. */
  restoreCollected(id: string, files: CollectedFile[]): Promise<number>;
  /** Create a missing source folder (Folder) or the target vault's queue folder. */
  createCollectorFolder(id: string, which: 'source' | 'queue'): Promise<Collector>;
  checkSchedule(cron: string): Promise<ScheduleCheck>;

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
  actions?: string; // <dir>/actions.json (v3)
  collectors?: string; // <dir>/collectors.json (v4); ledgers and runs in <dir>/collectors/
}
