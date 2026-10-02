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
}

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
  /** note = written by addNote (complete when queued, skips the wait); file = anything else. */
  kind?: 'note' | 'file';
  /** Why the core can't use this file (unreadable, too large, ...). */
  problem?: string | null;
  /** True when the file changed after the core first saw it (its ready time moved). Shown as "still changing". */
  changing?: boolean;
  /** For a note row: the paths of the files that travel with it (its .distill.json and images). Clients show one row; removing the note removes them all. */
  members?: string[];
  /** For a note row: its source summary and whether its labels are confirmed, from the manifest. */
  note?: { source?: string | null; labelsConfirmed?: boolean; imageCount?: number } | null;
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
export type CoreErrorCode = 'not_found' | 'invalid_request' | 'invalid_state' | 'busy' | 'no_vault' | 'not_implemented';

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
 * done      – completed (to-do checked, or Jira says Done / you marked it done)
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
  /** e.g. found, confirmed, drafted, edited, improved, improve-undone, copied, sent-to:<type>, created, status, done, removed, restored */
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
  /** copy | markSent | create | complete | refresh | send … */
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
}

export interface ActionPatch {
  title?: string;
  body?: string | null;
  fields?: Record<string, string | null>;
  /** Change where it goes (only while pending/open/ready). */
  type?: ActionTypeID;
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
  | { type: 'connection'; connection: ConnectionInfo };

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
   * an item still untouched since it was found (only found/drafted events) → dismissed, no History entry.
   */
  dismissActions(ids: string[]): Promise<void>;
  /** Write the draft now ("Create message"). progress key: action:<id>. */
  draftAction(id: string, opts?: { signal?: AbortSignal }): Promise<ActionItem>;
  /** Improve the draft after your edit (improve prompt + model); keeps previousBody for Undo. */
  improveAction(id: string, opts?: { signal?: AbortSignal }): Promise<ActionItem>;
  /** Put previousBody back. */
  undoImprove(id: string): Promise<ActionItem>;
  /** Run a handler: copy (records the event), markSent, create, complete, refresh, … */
  performAction(id: string, handlerID: string): Promise<ActionItem>;
  /** A to-do (or an item of another type) goes to a type's list; the new item keeps fromActionID; the old one leaves its list. */
  sendActionTo(id: string, type: ActionTypeID): Promise<ActionItem>;
  removeAction(id: string): Promise<ActionItem>;
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
}
