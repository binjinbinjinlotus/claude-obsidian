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

export type AITask = 'ingest' | 'ask' | 'labelSuggest' | 'imageText' | 'actionFind' | 'actionDraft' | 'actionImprove' | 'recovery';

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
  /** review-queue.md: self-recovery for batches (absent = DEFAULT_RECOVERY_PREFERENCES). */
  recovery?: Partial<RecoveryPreferences>;
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
  /**
   * v10 (full reads): how much source text one batch takes, in estimated tokens. Absent/null =
   * Automatic (30% of the ingest model's context window, at most 100K). Clamped to 10K–300K and
   * to half the model's window.
   */
  batchSourceTokens?: number | null;
  /** v10: how much of each source goes into its page, per source type. Absent = DEFAULT_DETAIL_LEVELS. */
  detailLevel?: Partial<Record<DetailSourceType, DetailLevel>> | null;
}

/** v10: Settings → Batching → "How much of each source goes into its page". */
export type DetailLevel = 'highlights' | 'detailed' | 'nearComplete';
export type DetailSourceType = 'meeting' | 'conversation' | 'research' | 'other';
export const DEFAULT_DETAIL_LEVELS: Record<DetailSourceType, DetailLevel> = {
  meeting: 'detailed',
  conversation: 'detailed',
  research: 'highlights',
  other: 'highlights',
};

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
  /** review-queue.md: a rebuilt plan the owner had approved: what differs from the approved one. */
  sinceApproved?: SinceApproved | null;
  summary: string;
  questions: string[];
  bundlePath?: string | null;
  plan?: TransactionPlan | null;
  planError?: string | null;
  denials: PermissionDenial[];
  skipped: string[];
  /** v6 (2026-10-05): each source page the bundle creates, with its labels (Review shows and edits them). */
  sources?: ReviewSource[];
  /** v6: where the labels shown in Review stand; Approve is refused while `state` is suggesting or confirming. */
  labels?: ReviewLabels | null;
  /** v6: the same change with labels left unconfirmed (Approve, review labels later); the user's own edits are kept confirmed. */
  unconfirmed?: { bundlePath: string; plan: TransactionPlan } | null;
  /**
   * v6: this plan was rebuilt in the batch's session (part of the batch, what is left, or after the vault changed) and checked
   * against what the user approved: approve it once more. `pages` = the source pages it holds, unchanged byte for byte.
   */
  rebuilt?: { reason: 'partial' | 'remaining' | 'stale' | 'covered'; pages: string[]; labels: 'confirm' | 'later' } | null;
  /**
   * v6: these sources of the batch have no change to approve yet: the user discarded the rebuilt change for them (what
   * is left after a part applied, or the change rebuilt after the vault changed), or the session that would rebuild it
   * was gone. Nothing was applied and the sources stay in this batch. There is no plan: Approve asks the batch's
   * session to rebuild their change (`pendingPart.prompt`); "Reject batch" ends the batch.
   */
  needsRebuild?: boolean | null;
}

/** One input's source page in a pending batch (approval-and-review.md, "Labels in Review"). */
export interface ReviewSource {
  page: string; // vault-relative page the bundle writes, e.g. wiki/sources/Foo.md
  title: string;
  /** The input it was made from (`source_path`), e.g. inbox/foo.md. */
  source?: string | null;
  labels: string[];
  /** ai = suggested by the AI (shown dashed); user = confirmed in the queue, edited in Review, or the file's own tags; none = no labels. */
  by: 'ai' | 'user' | 'none';
  /** Only while labels are attached to a batch that reached Review without them. */
  state?: 'waiting' | 'suggesting' | 'failed' | null;
  /** v6: taken out of the batch (never added to the vault; its inbox file stays). Undo while the batch is in Review. */
  removed?: boolean;
}

export interface ReviewLabels {
  /**
   * suggesting = labels are being suggested for a batch that reached Review without them (3 at a time);
   * confirming = the core is writing them into the change and checking it again;
   * confirmed = the change holds them confirmed, so approving confirms what is shown;
   * unconfirmed = the change could not be revised (`message` says why): approving applies them unconfirmed.
   */
  state: 'suggesting' | 'confirming' | 'confirmed' | 'unconfirmed';
  message?: string | null;
  done?: number;
  total?: number;
  /** The `bundle-labels-<n>.json` the plan now uses. */
  revision?: number;
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
  /** v6: parts of this batch already applied (approving only some sources); newest last. */
  parts?: JobPart[];
  /** v6: the part being rebuilt in the batch's session (what the user approved, by page), until its change comes back. */
  pendingPart?: PendingPart | null;
  /**
   * v6: the batch's AI session was found gone when a turn tried to resume it (session continuity).
   * The job was put back as it was; the app shows SessionReplaceConfirm. Cleared by the next turn.
   */
  sessionUnavailable?: SessionUnavailable | null;
  /**
   * v8 (2026-10-05): what the user approved, recorded when Approve starts the apply (Review after Approve).
   * Counts come from the checked plan and the vault before the apply: new pages by folder, existing ones as updated.
   */
  approvedChange?: ApprovedChange | null;
  /** v8: the user pressed Done on this batch in Review after it was approved; it is then only in History. */
  reviewDoneAt?: string | null;
  /** v9 (2026-10-05): this batch re-reads sources already ingested (POST /v1/batches/reread); absent on other batches. */
  reread?: JobReread | null;
  /** v10 (full reads): what this batch's session read, counted by the core from the tool results. */
  coverage?: CoverageSummary | null;
  /** v10: sources that couldn't be read in full: left out of the change, never approvable. */
  stopped?: StoppedSource[];
  /** v10: this batch is one of several the queue was split into by size ("Batch 1 of 3"). */
  batchOf?: { index: number; total: number; tokens: number } | null;
  /** review-queue.md: approved and waiting for the vault's apply queue (or rebuilt and waiting for the owner). */
  queuedApply?: QueuedApply | null;
  /** review-queue.md: the plan is being rebuilt against the vault as it is now. */
  refresh?: RefreshState | null;
  /** review-queue.md: bounded self-recovery for a batch that can't make progress on its own. */
  recovery?: RecoveryState | null;
}

/** review-queue.md: self-recovery bounds, in Settings → Recovery. */
export interface RecoveryPreferences {
  /** Recover automatically (default on). */
  automatic: boolean;
  /** Agent attempts per batch and problem (1–5, default 2). */
  maxAttempts: number;
  /** Spend at most this on recovery per batch (default $1.00). */
  maxCostUSD: number;
}

export const DEFAULT_RECOVERY_PREFERENCES: RecoveryPreferences = { automatic: true, maxAttempts: 2, maxCostUSD: 1 };

/** review-queue.md: an approval waiting for its turn to apply in the vault. */
export interface QueuedApply {
  /** When the owner approved (ISO). */
  at: string;
  /** Queue position: the first approve's time in ms; a re-approval keeps it. */
  order: number;
  /** approval_sha256 of the plan approved. Present = waiting to apply; absent = rebuilt, needs the owner's OK again. */
  planSha256?: string | null;
  /** The exact bundle approved. */
  bundlePath: string;
  labels: 'confirm' | 'later';
  carries: 'confirm' | 'later';
}

/** review-queue.md: the approved bundle against the rebuilt one (source pages are proven the same). */
export interface SinceApproved {
  sources: 'same';
  content: string[];
  added: string[];
  dropped: string[];
  bookkeeping: string[];
}

/** review-queue.md: a plan being rebuilt because the vault changed under it. */
export interface RefreshState {
  since: string;
  reason: 'stale';
  stalePaths: string[];
  /** The owner had approved it (it keeps its queue place and asks once more). */
  approved: boolean;
  attempt: number;
}

export type RecoverySignature =
  | 'stale-again'
  | 'lock'
  | 'plan-error'
  | 'not-recorded'
  | 'full-read-stop'
  | 'session-gone'
  | 'runner-failed'
  | 'denial';

export type RecoveryFix =
  | 'rebuild_in_session'
  | 'reinspect_same_bundle'
  | 'wait_then_retry'
  | 'split_batch'
  | 'discard_stale_part'
  | 'answer_denial'
  | 'new_session'
  | 'give_up';

export interface RecoveryAttempt {
  at: string;
  by: 'rule' | 'agent';
  runnerID?: string;
  model?: string;
  fix: RecoveryFix | 'lock_wait' | 'refresh' | 'journal';
  diagnosis?: string;
  result: 'fixed' | 'failed' | 'running';
  error?: string;
  costUSD: number;
}

export interface RecoveryState {
  state: 'running' | 'waiting' | 'gaveUp' | 'fixed';
  signature: RecoverySignature;
  attempts: RecoveryAttempt[];
  /** Blocked commands Distill answered itself (at most 2 per batch). */
  denialAnswers?: number;
  /** The owner's sentence when recovery gave up ("Claude wanted to compare …"). */
  summary?: string;
  /** A waiting attempt runs again at this time (ISO). */
  waitUntil?: string;
  /**
   * Recovery suggested something only the owner may do: continue in a new session, rebuild one group of the
   * sources first (`groups[0]`, the rest wait), or discard the rebuilt part. The card asks; nothing changes until
   * the owner confirms.
   */
  proposal?: 'new_session' | 'split_batch' | 'discard_stale_part' | null;
  /** split_batch: the sources (their pages) in groups; the first is rebuilt on the owner's OK. */
  groups?: string[][];
  /**
   * The approval hash the owner gave this batch's queued apply. reinspect_same_bundle and wait_then_retry put
   * the batch back in the queue only under this exact hash, and the pump's inspect proves the bytes first.
   */
  approvedSha256?: string;
  /** What a `waiting` recovery does when its time comes: ask the agent (default) or retry the queued apply. */
  wake?: 'agent' | 'retry';
}

/** v10: one source's coverage as clients show it ("647 lines · read in full"). */
export interface CoverageSourceSummary {
  file: string;
  /** Lines that had to be read (image placeholder lines left out); 1 for a PDF or image. */
  lines: number;
  read: number;
  state: 'full' | 'partial' | 'unreadable' | 'stopped' | 'later';
  reason?: string;
  /** Embedded images in it (not text, not read). */
  images?: number;
  /** Automatic continuations that asked for lines of this source; absent when the first pass read it all. */
  rounds?: number;
  /** Not read to the end: the last line read without a gap from line 1 (0 = none). */
  readTo?: number;
}

/** v10: a batch's coverage (full-read.md). Information for the owner, never a decision. */
export interface CoverageSummary {
  sources: CoverageSourceSummary[];
  /** Sources read in full, of the readable ones. */
  full: number;
  of: number;
  lines: number;
  /** Automatic continuations sent in this session (all kinds: lines, partial wording, detail, archive). */
  rounds: number;
  /** Sources that needed at least one more round of reading ("2 needed a second round"). */
  continued: number;
  /** reading = still being read; complete = every source in the change read in full; split = some go to a fresh session next; stopped = some couldn't be read. */
  state: 'reading' | 'complete' | 'split' | 'stopped';
  /** The detail pass: what the pages missed and was added before Review, and what was left (information). */
  detail?: { checked: number; added: number; left: number; note?: string } | null;
  /** Pages that still say they are partial although every line was read (information). */
  partialWording?: string[];
  /** Sources taken out of this change to be read next in a fresh session. */
  later?: string[];
  /** Originals archived in .raw/captured/ by this change. */
  archived?: number;
}

/** v10: a source that couldn't be read in full (the hard stop). */
export interface StoppedSource {
  file: string;
  sha256?: string;
  /** Plain words: "it isn’t valid UTF-8 text from line 412". */
  reason: string;
  at: string;
}

/** v10: a stopped source still in inbox/, not read in full by any later batch ("Held in inbox/"). */
export interface HeldSource extends StoppedSource {
  jobId: string;
  size?: number;
}

/** v9: which re-read a batch belongs to: group `group` of `groups` (1-based). */
export interface JobReread {
  id: string; // reread-yyyyMMdd-HHmmss-xxxx
  group: number;
  groups: number;
  /** The batch whose sources are read again, when the request named one. */
  fromJob?: string | null;
  /** Extra words from the user for every group's prompt. */
  instruction?: string | null;
  /** v10: why it runs: the owner or CLI asked, the automatic repair, or Try again on a held source. */
  reason?: 'manual' | 'repair' | 'retry' | null;
}

/**
 * v9: re-read sources already in inbox/ (queue-and-batching.md, "Re-read sources"). Give `files`
 * (vault-relative inbox paths) or `jobId` (that batch's sources: its files minus note manifests,
 * each folder one item). Files are read in place: nothing is moved, copied or written into inbox/.
 */
export interface RereadRequest {
  vaultPath?: string;
  files?: string[];
  jobId?: string;
  /** Sources per batch (1-10). When given, groups hold this many sources. Each batch is its own job with a fresh AI session. */
  perBatch?: number;
  /** v10: pack groups by estimated tokens instead (default: the batch size, Settings → Batching). */
  tokenBudget?: number;
  instruction?: string;
  /** v10: why it runs (default manual). */
  reason?: 'manual' | 'repair' | 'retry';
}

export interface RereadGroup {
  files: string[];
  folders?: string[];
  /** The batch this group became, once it started. */
  jobId?: string | null;
}

export interface RereadResult {
  id: string;
  vaultPath: string;
  /** Sources per group when grouped by count; 0 when packed by tokens. */
  perBatch: number;
  /** v10: the token budget the groups were packed by, when packed by tokens. */
  tokenBudget?: number;
  fromJob?: string | null;
  groups: RereadGroup[];
  /** Batches started by this call (at most one: one runs at a time per vault). */
  started: Job[];
  /** Groups still waiting for the vault to be free. */
  waiting: number;
  /** Sources left out (note manifests), with why. */
  skipped?: { path: string; reason: string }[];
}

/** v8: the approved change (plan counts, never the model's words). */
export interface ApprovedChange {
  at: string; // ISO-8601, when the user approved
  operationID: string;
  /** All paths the plan changes. */
  changes: number;
  /** New pages under wiki/sources/, wiki/concepts/, wiki/entities/, and any other new page under wiki/. */
  sources: number;
  concepts: number;
  entities: number;
  otherPages: number;
  /** Pages under wiki/ that existed before the apply. */
  updated: number;
  /** Source pages in this approval (a part of a batch approves some). */
  sourcesApproved?: number;
  /** The approved plan's `approval_sha256`: Review tells a rebuilt plan from the one approved. */
  approvalSha256?: string;
  /** Set when the vault's journal showed the plan applied outside Distill (in Terminal). */
  appliedOutside?: boolean;
}

// ───────────────────────────── Session continuity ─────────────────────────────
//
// System-wide rule (2026-10-05): Distill never resumes into a session that is gone and never
// swaps sessions silently. A resume that can't happen is a typed `session_unavailable` error;
// the same call again with `newSession: true` continues in a new, seeded session.

/** Where the session belonged. */
export type SessionPlace = 'batch' | 'conversation' | 'terminal';
/** Why it is unavailable: the runner said not found, its transcript is gone, it never started, or its runner is gone. */
export type SessionUnavailableReason = 'notFound' | 'missing' | 'neverStarted' | 'runnerGone';
/** The call that hit it, so the client can repeat it with newSession. */
export type SessionAction = 'approve' | 'reply' | 'allow' | 'ask' | 'resume';

export interface SessionUnavailable {
  place: SessionPlace;
  reason: SessionUnavailableReason;
  /** Plain sentence for people. */
  message: string;
  /** The technical reason (runner stderr line, missing path); never content. */
  detail: string;
  action?: SessionAction;
  /** Reply text / allow rules to send again (batch only). */
  text?: string;
  rules?: string[];
  /** Approve options to send again (batch only): approve-later, or the sources picked for part of a batch. */
  labels?: 'confirm' | 'later';
  pages?: string[];
  at?: string;
}

/** Options for a call that may resume a session. */
export interface SessionOptions {
  /** Continue in a new session (the user confirmed SessionReplaceConfirm). */
  newSession?: boolean;
}

export interface JobPart {
  operationID: string;
  /** Source pages applied in this part. */
  pages: string[];
  /** confirm = labels confirmed; later = left unconfirmed for Labels → To review. */
  labels: 'confirm' | 'later';
  at: string; // ISO-8601
}

export interface PendingPart {
  /**
   * partial = the user approved some sources; remaining = what is left after a part applied; stale = the vault changed after review;
   * v10: covered = the sources read in full, split from those one session couldn't finish (the gate skips it);
   * unread = those sources, read again in a fresh session.
   */
  reason: 'partial' | 'remaining' | 'stale' | 'covered' | 'unread';
  /** v10 (covered): the sources left out to be read next in a fresh session, after this part applies. */
  unread?: string[];
  /** Source pages the rebuilt change must hold, with the sha256 of the content the user saw. */
  expected: Record<string, string>;
  /** Source pages that must not be in it (not picked, removed). */
  excluded: string[];
  labels: 'confirm' | 'later';
  /** Sources the user did not pick (they stay for later), with the sha256 of their page as shown; rebuilt after this part applies. */
  rest?: ReviewSource[];
  restExpected?: Record<string, string>;
  /** The content file of each rest page as shown (the rebuild of what is left reuses it byte for byte). */
  restFiles?: Record<string, string>;
  /** The sources the rebuilt change holds, as Review showed them (with who chose their labels). */
  shown?: ReviewSource[];
  /** Sources the user removed (kept for History). */
  removed?: ReviewSource[];
  /** partial: the batch's Review as it was before the user approved part of it; rejecting the rebuilt part restores it. */
  before?: ApprovalRequest;
  /** The request sent to the session for this part; Approve after a discarded rebuild sends it again (to a new bundle path). */
  prompt?: string;
  bundlePath?: string;
}

/** v6: Reject options. A rebuilt part: `part` (default) discards only that rebuilt change; `batch` rejects the whole batch. */
export interface RejectOptions {
  scope?: 'part' | 'batch';
}

/** v6: Approve options (approval-and-review.md). */
export interface ApproveOptions {
  /** confirm (default) = approving confirms the labels shown; later = apply with labels unconfirmed (Labels → To review). */
  labels?: 'confirm' | 'later';
  /** Source pages to approve; omitted = every source not removed. A subset makes the batch's session rebuild the change first. */
  pages?: string[];
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
  /**
   * v11 (action-context.md): review = found in the batch before Review (they wait in the job until
   * their source's pages apply: `proposed`); applied = added to Actions. Absent = an older job (found after apply).
   */
  stage?: 'review' | 'applied';
  /** v11: found before apply, not added yet (their source's pages haven't applied). */
  proposed?: number;
  /** v11: lines looked through for actions, and lines in the sources (all of them, by construction). */
  lines?: number;
  linesOf?: number;
  /** v11: sources looked through. */
  sources?: number;
  /** v11: found again by a re-read or repair and already in Actions (not added twice). */
  duplicates?: number;
}

/** v11: one action found in a batch, as Review shows it (GET /v1/jobs/:id/actions). */
export interface JobActionProposal {
  /** The item as it will be added (status pending; `id` is kept when it is added). */
  item: ActionItem;
  /** The source file (vault-relative) and its source page in the change. */
  file: string;
  page?: string | null;
  /**
   * waiting   = in Review; added after its source's page applies;
   * added     = in Actions (`item.id`);
   * duplicate = already in Actions (`existingID`), not added again;
   * notApplied = its source was removed from the batch or the batch was rejected.
   */
  state: 'waiting' | 'added' | 'duplicate' | 'notApplied';
  existingID?: string | null;
}

export interface JobActions {
  summary: JobActionsSummary | null;
  proposals: JobActionProposal[];
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
  | 'vision'
  /** v10: its tool results say which lines each read returned (full reads can be checked). */
  | 'readCoverage';

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
  /**
   * v7 (live log): called for each step the agent takes while it runs (a tool it calls, a tool that
   * finished, a status message). Claude Code then streams (`stream-json`); the result is unchanged.
   * Runners without a tool loop never call it.
   */
  onStep?: (step: RunnerStep) => void;
}

/** v7: one thing an agent did, as the runner saw it (Claude Code stream-json, Codex --json). */
export type RunnerStep =
  | { kind: 'tool'; id?: string; tool: string; input: Record<string, unknown> }
  | { kind: 'toolDone'; id: string; isError?: boolean }
  | { kind: 'message'; text: string };

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
  /** argv that opens a NEW interactive session primed with `prompt` (session continuity), if supported. */
  newSessionCommand?(prompt: string, model: string, settings: Settings): string[] | undefined;
  /**
   * Whether the runner's own store still holds this session: 'missing' only on positive evidence
   * (the store is readable and has no file for it); 'unknown' whenever that can't be told.
   */
  sessionStatus?(sessionID: string, environment?: Record<string, string | undefined>): SessionStoreStatus;
}

export type SessionStoreStatus = 'present' | 'missing' | 'unknown';

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
  // v10 (owner decision 2026-10-05): batches run only on runners whose reads can be verified
  // (`readCoverage`); the engine routes ingest there (engine `ingestSelection`). Codex is deferred.
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
  // review-queue.md: one structured call, no tools, no session.
  recovery: [['structuredOutput']],
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
  /**
   * v6 (2026-10-05), text files that are not notes: their labels, suggested in the background at most 3 files at a
   * time and kept in Distill's state (never in the file). Absent for notes (their manifest has them), folders,
   * Google Docs, binary files, or when labeling.autoLabelQueueFolder is off.
   */
  labels?: QueueLabels | null;
  /** v6: the label gate: a text file whose labels are not in yet stays for the next batch. */
  heldForLabels?: boolean;
}

export interface QueueLabels {
  /** waiting = behind the 3 running; own = the .md's own tags (no AI call); skipped = the user sent it without labels. */
  state: 'waiting' | 'suggesting' | 'suggested' | 'confirmed' | 'own' | 'failed' | 'skipped';
  labels: LabelSuggestion[];
  error?: string | null;
  /** Failed suggestions so far; Distill retries by itself until 3, then waits for the user. */
  attempts?: number;
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
  /** Continue in a new session seeded with the conversation so far (after session_unavailable). */
  newSession?: boolean;
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
  /**
   * v6: the file a per-file progress is about (label suggestions run 3 files at a time: one `labelSuggest` progress
   * per file, key `label:<file sha256>` in the queue or `label:<jobID>:<file>` in a batch; `group` = the batch's job id).
   */
  item?: string;
  group?: string;
  startedAt: string; // ISO-8601, for the elapsed timer
  runnerID?: string;
  model?: string;
  finished?: boolean;
  error?: string;
  /** v7, batches: the file being worked on now, e.g. the file whose labels are being suggested. */
  current?: string;
}

// ───────────────────────────── Live log (job steps) ─────────────────────────────

/**
 * v7: one line of a job's live log (spec live-log.md). Plain words for people, plus a short raw
 * `detail` (tool and target only). Never file contents, tool results, a draft's text or secrets.
 * A step is sent again when it changes (running → done); `id` is stable.
 */
export interface JobStep {
  id: string;
  at: string; // ISO-8601, when it started
  endedAt?: string;
  /** Where it belongs: getting ready, the AI's steps, the core's check, your review, applying. */
  phase: 'prepare' | 'agent' | 'check' | 'review' | 'apply';
  /** note = the AI's own short status message. */
  kind: 'step' | 'note';
  state: 'done' | 'running' | 'waiting' | 'review' | 'failed';
  /**
   * What sort of step, so clients can fold repeats ("Read 22 sources"): move, labels, label, read,
   * readPage, readRef, search, command, write, edit, skill, plan, web, agent, tool, note, check, review,
   * answer, apply, actions, done, error.
   */
  verb: string;
  text: string;
  detail?: string;
  /** A short trailing count or fact: "3 labels", "31 changes". */
  count?: string;
  /** The file or page it was about (a name, never a path outside the vault). */
  file?: string;
  /** A step inside another (a file inside "Suggesting labels"). */
  parent?: string;
  /** v8: what to do next, in plain words, on a failed apply step ("Nothing was changed. Approve again to try again."). */
  hint?: string;
}

export interface JobStepsPage {
  jobId: string;
  steps: JobStep[];
  /** False when the job ran before steps were kept (or its log was removed). */
  kept: boolean;
  /** True when the job had more steps than are kept (2,000). */
  truncated?: boolean;
}

// ───────────────────────────── Errors ─────────────────────────────

/** HTTP mapping: not_found→404, invalid_request→400, invalid_state/busy/no_vault→409, not_implemented→501. */
export type CoreErrorCode =
  | 'not_found'
  | 'invalid_request'
  | 'invalid_state'
  | 'busy'
  | 'no_vault'
  | 'not_implemented'
  | 'conflict'
  /** The AI session a call would resume is gone; `details` is a SessionUnavailable. */
  | 'session_unavailable';

export class CoreError extends Error {
  constructor(
    readonly code: CoreErrorCode,
    message: string,
    /** Extra fields for the API error body (additive), e.g. a SessionUnavailable. */
    readonly details?: Record<string, unknown>,
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

/**
 * v11 (action-context.md): where in the ORIGINAL source an action comes from. The lines are located by the
 * core in the original's text (never taken from the model's report).
 */
export interface ActionRawRef {
  /** Vault-relative: `.raw/captured/<sha>.<ext>` once archived, else where the source was (inbox/…). */
  path: string;
  /** Where the source was when the action was found (inbox/…), when that differs from `path`. */
  inboxPath?: string | null;
  sha256?: string | null;
  /** Lines in the original, 1-based and inclusive: [from, to]. Absent when `match` is none. */
  lines?: [number, number] | null;
  /** The text of those lines, at most 1,500 characters. */
  excerpt?: string | null;
  /**
   * quote   = the action's quoted words were found on these lines;
   * closest = the lines that share the most words with the action (Ask actions; shown as "closest lines");
   * none    = the original is known but no lines match.
   */
  match?: 'quote' | 'closest' | 'none';
}

/** v11: a wiki page (and section) an action relates to. */
export interface ActionWikiRef {
  /** Vault-relative page path (wiki/…). */
  path: string;
  title?: string | null;
  /** The section's heading, without #'s; absent = the page as a whole. */
  heading?: string | null;
  /** A few lines of that section, at most 800 characters. */
  excerpt?: string | null;
}

export type ActionSource =
  | {
      kind: 'note'; jobID?: string | null; notePath?: string | null; pageTitle?: string | null; quote?: string | null;
      /** v11: the original's lines (raw source) and the wiki pages the action relates to. */
      raw?: ActionRawRef | null;
      wiki?: ActionWikiRef[];
      /** v11: why there is no `raw` (plain words), e.g. "found before originals were archived". */
      contextNote?: string | null;
    }
  | {
      kind: 'ask'; conversationID: string; question?: string | null; quote?: string | null; citedPaths?: string[];
      /** Which turn of the chat it came from (0-based). */
      turnIndex?: number | null;
      /** It came from the answer's gap (what the vault didn't cover): clients then hide that Gap callout. */
      gap?: boolean;
      /** v11: the cited pages' archived original, closest lines (match "closest"); absent = wiki only. */
      raw?: ActionRawRef | null;
      wiki?: ActionWikiRef[];
      /** v11: why there is no `raw`, e.g. "the cited pages have no archived original". */
      contextNote?: string | null;
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
  /** 2–4 plain sentences on what the action is about: context, who, what was asked, by when.
   *  Written at finding time from the original plus the wiki; older items get it on first open
   *  (action-summary.md). Not editable; separate from `body`. */
  summary?: string | null;
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
  /** Button runs, newest first, at most 10 (action-buttons.md). */
  runs?: ActionButtonRun[];
  /** A button running for this item now. */
  activeRun?: { runId: string; buttonId: string } | null;
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
  /** Buttons that run an automation's command, with whether each can run now. */
  buttons?: ActionButtonInfo[];
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
  /** Buttons that run an automation's command (action-buttons.md). */
  buttons?: ActionButton[];
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
/**
 * The script's language. v6: 'typescript' runs on the login shell's node with its built-in type stripping
 * (Node 22.6+; tsx when the script's folder has it installed). An old client keeps it as a raw string.
 */
export type CollectorInterpreter = 'zsh' | 'python3' | 'node' | 'typescript';
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

/**
 * v6: `{file, managed: true}` is a script Distill keeps as a real file in its own folder,
 * <state>/collectors/scripts/<collector-id>/collector.<ext>, next to its package manifest. `{file}` alone is
 * the user's own file. `{inline}` is accepted on input (and still decoded from an old collectors.json):
 * the core writes the code to the managed file, so collectors.json only holds the reference.
 */
export type ScriptSource = { file: string; managed?: boolean } | { inline: string };

export interface ScriptCollectorSettings {
  source: ScriptSource;
  interpreter: CollectorInterpreter;
  /** Default 300 (5 minutes), 1…3600. */
  timeoutSeconds: number;
  /** The script sha256 the user allowed (consent). A run starts only while the script hashes to this. */
  allowedSha256?: string | null;
  allowedAt?: string | null;
  /** v6: the sha256 of each file the consent covered, so the app can say what changed since ("package.json"). */
  allowedFiles?: { script: string; manifest: string | null } | null;
  /**
   * v6, a script Distill keeps: the sha256 of the script and its manifest as the core last wrote or saw
   * them. Files that hash differently were edited outside Distill (an editor opened with "Open in
   * editor"); the core logs that once (`collector.script.changed_outside`) and moves this on. Internal.
   */
  knownFiles?: { script: string | null; manifest: string | null } | null;
  /**
   * Automations (action-buttons.md): whether this script collects on a schedule / Run now. Absent = true
   * (every collector made before). A commands-only script (the Slack CLI) has `collects: false`.
   */
  collects?: boolean;
  /** Ways an action button may call this script with arguments, declared by the owner. */
  commands?: ScriptCommand[];
}

/** One way to call a script with arguments (action-buttons.md). */
export interface ScriptCommand {
  /** A slug, unique within the script: "send". */
  id: string;
  label: string;
  description?: string;
  /** In argv order. */
  args: ScriptCommandArg[];
  /** Put "--" before the first positional. Default true, so text starting with "-" stays text. */
  endOptions?: boolean;
  /** Default 60, 1…3600. */
  timeoutSeconds?: number;
  /** How to read a key or URL from stdout; absent = nothing is read. */
  result?: ScriptResultParse;
}

export interface ScriptCommandArg {
  /** What a button binds to: "target", "text", "thread". */
  name: string;
  /** word = a fixed word ("send"); flag = "--thread VALUE", left out when empty; switch = "--all" when on; positional = one element. */
  kind: 'word' | 'flag' | 'switch' | 'positional';
  flag?: string;
  /** word: the word itself. */
  value?: string;
  /** positional default true, flag default false. */
  required?: boolean;
  /** A regular expression the final value must match. */
  pattern?: string;
  /** Plain words for the pattern: "#channel, @handle or an ID". */
  hint?: string;
}

export interface ScriptResultParse {
  /** The last stdout line that parses as a JSON object: {key?, url?, status?, message?}. */
  json?: boolean;
  /** A regular expression on stdout; group 1 (or a group named key) becomes external.key. */
  keyPattern?: string;
  urlPattern?: string;
}

/** A button on an action type that runs an automation's command (action-buttons.md). */
export interface ActionButton {
  id: string; // btn-<uuid>
  label: string;
  icon?: string | null;
  enabled: boolean;
  /** The automation (col-…). */
  scriptId: string;
  commandId: string;
  /** Argument name → template, e.g. {text: "{body}"}. Words are never bound. */
  bindings: Record<string, string>;
  /** Show the run sheet and wait for Run. The first run and the first after any change always ask. */
  confirm: boolean;
  onSuccess: 'none' | 'markSent' | 'complete';
  /** Store the key or URL read from the output in item.external. */
  storeResult: boolean;
  /** Item statuses that show it. Default ['open', 'ready']. */
  when?: ActionStatus[];
  /** send = takes the reserved "Send in Slack" slot; primary; or more (the ⋯ menu). */
  slot: 'send' | 'primary' | 'more';
}

export interface ActionButtonInfo extends ActionButton {
  available: boolean;
  /** Why it can't run now: "Slack CLI needs your OK", "Script missing", "Command removed". */
  reason?: string | null;
  scriptName?: string | null;
  commandLabel?: string | null;
}

/** The exact command a button would run for an item. */
export interface ActionButtonPreview {
  /** Interpreter, script path, then the arguments, one element each (exactly what runs). */
  argv: string[];
  /** For reading only: shell-quoted. */
  display: string;
  problems: string[];
  /** The run sheet must open (first run, or anything changed since the last approved run). */
  needsApproval: boolean;
  /** The script itself needs consent first. */
  needsConsent: boolean;
  approvalHash: string;
}

/**
 * Where a Slack message goes (action-buttons.md, "Where to send"): the To row resolved against the
 * names remembered for the item's vault. `target` is what a button's `{fields.to}` becomes; null
 * while a plain name is unknown, and then `problem` says why nothing can be sent.
 */
export interface SlackTarget {
  kind: 'channel' | 'person' | 'thread';
  /** The item's `to` field as written ("Aditya Pradhan", "#general", "@mei"). */
  written: string;
  /** #channel, @handle or an ID; for a thread, the channel (or person) it is in. */
  target: string | null;
  /** The written name, when a remembered name resolved it ("Aditya Pradhan" → @aditya). */
  name?: string;
  /** Thread: the ts to reply under (`{fields.thread}`). */
  threadTs?: string;
  /** An unknown name: "Who is Aditya Pradhan in Slack?" */
  ask?: string;
  /** Why a button can't send it, in plain words. */
  problem?: string;
}

/** A remembered name → Slack target, per vault (`<state>/actions/slack-people.json`). */
export interface SlackPerson {
  vaultPath: string;
  name: string;
  /** @handle, a user ID, or a #channel. */
  target: string;
  savedAt: string;
}

/** One button run kept on an item (newest 10). */
export interface ActionButtonRun {
  runId: string;
  buttonId: string;
  label: string;
  startedAt: string;
  endedAt?: string;
  durationMs?: number;
  result: 'running' | 'success' | 'failed' | 'timedout' | 'stopped' | 'notTrusted';
  exitCode?: number | null;
  stdoutTail?: string;
  stderrTail?: string;
  external?: { key?: string | null; url?: string | null } | null;
  message?: string | null;
}

/** v6: a kept script's files changed outside Distill (seen at a read, a tick or before consent and runs). */
export interface CollectorOutsideChange {
  collectorId: string;
  name: string;
  interpreter: CollectorInterpreter;
  /** Which files changed. */
  changes: ('script' | 'manifest')[];
  /** The script now: null when it is gone. Sizes and hashes only, never the text. */
  script: { path: string; bytes: number; lines: number; sha256: string; modifiedAt: string } | null;
  /** The manifest now (requirements.txt / package.json), when one changed: null when it is gone. */
  manifest?: { name: string; bytes: number; sha256: string; modifiedAt: string } | null;
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
  /** v6, script: where the script lives and its packages. */
  script?: CollectorScriptStatus;
  /** The sidebar count: the last run failed or timed out, or the script needs consent. */
  needsAttention: boolean;
}

/** v6: package manifest of a Distill-managed script: package.json (node, typescript) or requirements.txt (python3). zsh has none. */
export type CollectorManifestName = 'package.json' | 'requirements.txt';

export interface CollectorManifestStatus {
  name: CollectorManifestName;
  /** Absolute path (in the script's folder), whether the file exists or not. */
  path: string;
  exists: boolean;
  /** The manifest lists at least one package (an empty one needs no install). */
  hasDependencies: boolean;
  /** How many packages it lists (package.json: dependencies + devDependencies + optionalDependencies; requirements.txt: requirement lines). */
  packageCount: number;
  /** sha256 of the manifest's bytes (null when it doesn't exist). */
  sha256: string | null;
  /** The manifest sha256 of the last successful install. */
  installedSha256: string | null;
  /** It has packages and they weren't installed for this version (or node_modules / .venv is missing). The next run installs first. */
  needsInstall: boolean;
  installing: boolean;
  /** The newest install (output left out; see getCollectorInstall). */
  lastInstall: CollectorInstall | null;
  /**
   * v6, one word for the app: none (no packages), ready (installed for this version), installing, failed
   * (the last install of this version failed: Install again), needsInstall (not installed yet).
   */
  state: 'none' | 'ready' | 'installing' | 'failed' | 'needsInstall';
}

/** v6: computed on every read. */
export interface CollectorScriptStatus {
  /** The script file that runs (absolute). For an old inline record that couldn't be moved to a file: "". */
  path: string;
  /** The collector's own folder (managed scripts), else null. */
  dir: string | null;
  managed: boolean;
  /** Managed scripts only; null for zsh and for the user's own file. */
  manifest: CollectorManifestStatus | null;
  /** Needs consent after an allowed version: which files changed since. Absent when never allowed or unknown (allowed before v6). */
  changes?: ('script' | 'manifest')[];
  /** v6: the newest test run (without files and output tails), and its scratch folder. */
  lastTestRun?: CollectorRun | null;
}

/**
 * v6: one package install in a managed script's folder: `npm install` (node, typescript) or
 * `python3 -m venv .venv` + `.venv/bin/python3 -m pip install -r requirements.txt` (python3).
 * Kept at <state>/collectors/installs/<collector-id>.json (the newest only).
 */
export interface CollectorInstall {
  id: string; // ins-<uuid>
  collectorId: string;
  /**
   * manual = Install (API); allow = the user allowed a version whose packages weren't installed (adding a
   * script, or OK after a manifest change), so it installs at once; beforeRun = the safety net: packages
   * went missing (node_modules deleted), so a run installed first.
   */
  trigger: 'manual' | 'allow' | 'beforeRun';
  startedAt: string;
  endedAt?: string;
  durationMs?: number;
  result: 'running' | 'success' | 'failed' | 'timedout' | 'stopped';
  /** What ran, for display ("npm install --no-audit --no-fund"). */
  command: string;
  manifestName: CollectorManifestName;
  manifestSha256: string;
  /** node_modules / .venv was removed first. */
  clean?: boolean;
  /** package.json: the Node whose npm ran the install (Distill's own Node). */
  runtime?: CollectorRuntime;
  exitCode?: number | null;
  signal?: string | null;
  error?: { code: CollectorErrorCode; message: string };
  /** stdout and stderr interleaved, the last 64 KB, with credentials in URLs and auth tokens masked. */
  outputTail?: string;
}

/** v6: GET /v1/collectors/:id/script. */
export interface CollectorScriptFiles {
  collectorId: string;
  interpreter: CollectorInterpreter;
  managed: boolean;
  /** The script file (absolute). */
  path: string;
  dir: string | null;
  /** The script's text; null when it can't be read (problem says why). */
  code: string | null;
  /** sha256 of the script's bytes alone (send it back as baseSha256 when saving). */
  sha256: string | null;
  problem?: string;
  /** Managed scripts with a manifest kind (not zsh): its text, or null when there is none yet. */
  manifest: { name: CollectorManifestName; path: string; text: string | null; sha256: string | null } | null;
}

/**
 * v6: PUT /v1/collectors/:id/script. Managed scripts only. A changed script or manifest needs consent again,
 * like any script change. baseSha256 / baseManifestSha256 (from CollectorScriptFiles) refuse the save
 * (invalid_state) when the file changed on disk since it was loaded (e.g. in an external editor).
 */
export interface CollectorScriptUpdate {
  code?: string;
  /** The manifest's new text; null removes it. */
  manifest?: string | null;
  baseSha256?: string;
  /** null = it didn't exist when loaded. */
  baseManifestSha256?: string | null;
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
  /**
   * v6: `manifest` is the package manifest's text for a managed script (package.json / requirements.txt).
   * Automations: `collects: false` for a script that only offers commands (Add's "Commands for buttons").
   */
  script?: { source: ScriptSource; interpreter: CollectorInterpreter; timeoutSeconds?: number; manifest?: string; collects?: boolean };
}

export interface CollectorPatch {
  name?: string;
  vaultPath?: string;
  /** Turning a script on needs a current consent (else invalid_state). */
  enabled?: boolean;
  schedule?: CollectorSchedule;
  folder?: Partial<FolderCollectorSettings>;
  /** A new source or interpreter changes the hash: the script needs consent again. */
  script?: Partial<{ source: ScriptSource; interpreter: CollectorInterpreter; timeoutSeconds: number; collects: boolean; commands: ScriptCommand[] }>;
}

/**
 * v6: 'test' = Test run: the script runs exactly like a real run, but $2 / DISTILL_QUEUE_DIR is a scratch
 * folder Distill owns (`outputDir`), so nothing reaches the queue. Not a scheduled run: it never changes
 * status.lastRun, the sidebar count or the schedule. Kept in run history.
 */
export type CollectorTrigger = 'schedule' | 'now' | 'catchup' | 'test' | 'action';

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
  | 'installFailed' // v6: the install before the run failed (installId)
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
  /** While queued: what it waits for. v6: 'install' = the packages being installed for this collector. */
  waiting?: 'slot' | 'batch' | 'install';
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
  /** v7: both streams in the order they were printed, the last 64 KB, consecutive output of one stream merged. */
  outputLog?: CollectorOutputChunk[];
  /** v6: the install this run did first (the manifest changed since the last install). */
  installId?: string;
  /** v6, test runs: the scratch folder that stood in for the queue folder (filesAdded are its names). Kept until the next test run, at most 7 days. */
  outputDir?: string;
  /** Script: what ran it (JavaScript and TypeScript run on Distill's own Node, never the login shell's node). */
  runtime?: CollectorRuntime;
  /** Automations: a command run from an action button (trigger 'action'). argv is masked like output. */
  command?: { id: string; buttonId: string; actionId: string; argv: string[] };
}

/** v7: a piece of script output and when it came. */
export interface CollectorOutputChunk {
  stream: 'stdout' | 'stderr';
  text: string;
  at: string; // ISO-8601
}

/** What ran a script or an npm install: label "Node 22.22.1", "Node 22.22.1 with tsx", "python3 (.venv)", "python3", "zsh". */
export interface CollectorRuntime {
  label: string;
  /** The interpreter's absolute path. */
  path: string;
  /** Node's version (Node only). */
  version?: string;
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
  /** chat: turnCount; collector: kind, interpreter, scriptFile, scriptBytes, scriptLines, vault. Never the script. */
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
  // v6: package installs of managed scripts
  | { type: 'collector.install.started'; install: CollectorInstall }
  | { type: 'collector.install.output'; collectorId: string; installId: string; text: string }
  | { type: 'collector.install.finished'; install: CollectorInstall }
  /** A kept script or its manifest was edited outside Distill (older Mac builds decode it as `.unknown`). */
  | { type: 'collector.script.changed_outside'; change: CollectorOutsideChange }
  // v5: a queue scan finished (Refresh, window, periodic). A `queue` event precedes it when the list changed.
  | { type: 'queue.scanned'; result: QueueScanResult }
  // v6: a line was added to the activity log (older Mac builds decode unknown events as `.unknown`).
  | { type: 'activity'; entry: ActivityEntry }
  /** v6: an AI session that was gone was replaced by a new one after the user's OK (never content). */
  | { type: 'session.replaced'; place: SessionPlace; reason?: SessionUnavailableReason; objectID: string; name?: string }
  // v7: a step of a job's live log, new or changed (older Mac builds decode it as `.unknown`).
  | { type: 'job.step'; jobId: string; step: JobStep }
  // v10: the automatic repair queued re-reads of sources never read in full (full-read.md, section 6).
  | { type: 'repair.queued'; vaultPath: string; rereadId: string; sources: number; batches: number; files: string[]; missing?: string[] };

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
  /** v10: the batch size in force (tokens), the model's context window it comes from, and whether it is Automatic. */
  batchBudget?: { tokens: number; contextWindow: number; model: string; automatic: boolean } | null;
  /** v10: sources held in inbox/ because they couldn't be read in full. */
  heldCount?: number;
  /** review-queue.md: approved batches waiting their turn to apply, per vault, `position` 1 = next. */
  applyQueue?: { id: string; name: string; vaultPath: string; position: number }[];
  /** review-queue.md: batches recovery is working on, waiting to try again (`waitUntil`), or gave up on. */
  recovering?: { id: string; name: string; signature: RecoverySignature; state: RecoveryState['state']; waitUntil?: string }[];
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
  approve(id: string, opts?: ApproveOptions & SessionOptions): Promise<void>;
  reply(id: string, text: string, opts?: SessionOptions): Promise<void>;
  allow(id: string, rules: string[], opts?: SessionOptions): Promise<void>;
  /** A rebuilt part of a batch: discards only that part unless `scope: 'batch'` (approval-and-review.md). */
  reject(id: string, opts?: RejectOptions): Promise<void>;
  /** review-queue.md: Don't apply yet: out of the vault's apply queue, back to Ready with its plan. */
  unqueue(id: string): Job;
  /** review-queue.md: Let recovery try again (attempts start over). */
  tryRecoveryAgain(id: string): Job;
  cancel(id: string): Promise<void>;
  /** Finished jobs only (completed/failed/rejected/cancelled); else invalid_state. */
  deleteJob(id: string): Promise<void>;
  /** argv that reopens the job's session interactively; null when the runner has none. */
  jobResumeCommand(id: string, opts?: SessionOptions): Promise<string[] | null>;
  /** v7: the job's live log, as kept (GET /v1/jobs/:id/steps); not_found for an unknown job. */
  listJobSteps?(id: string): Promise<JobStepsPage>;
  /** v8: Review after Approve: the user is done looking at an approved batch (it stays in History). */
  finishReview?(id: string): Promise<Job>;
  /**
   * v8: Clean up inbox (inbox-cleanup.md). What could move to the Trash now, and what stays and why.
   * `jobId` limits it to the files that batch used; otherwise every file in the vault's inbox/. Read-only.
   */
  previewInboxCleanup?(opts?: { jobId?: string; vaultPath?: string }): Promise<InboxCleanupPreview>;
  /** v8: move these items (paths from a preview) to the Trash, each checked again first. Never automatic. */
  cleanUpInbox?(req: InboxCleanupRequest): Promise<InboxCleanupResult>;
  /**
   * v9: read sources already ingested again, completely, in groups of `perBatch` (one batch and one
   * fresh session each, one after another). Updates the existing pages through Review as usual.
   */
  rereadSources?(req: RereadRequest): Promise<RereadResult>;
  /** v10: sources held in inbox/ because they couldn't be read in full (GET /v1/held). */
  listHeld?(vaultPath?: string): Promise<HeldSource[]>;
  /** v10: Try again on a held source: re-checks its bytes, then reads it in a batch of its own (POST /v1/held/retry). */
  retryHeld?(file: string, vaultPath?: string): Promise<RereadResult>;
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
  /** v6: confirm labels for a text file in the queue ([] = no labels). Kept in Distill's state; the batch uses them. */
  labelQueueItem(path: string, labels: string[]): Promise<QueueEntry[]>;
  /** v6: ask again for a queue file whose suggestion failed (it joins the 3-at-a-time line). */
  retryQueueLabels(path: string): Promise<QueueEntry[]>;
  /** v6: let a queue file whose labels failed go in the next batch without labels. */
  skipQueueLabels(path: string): Promise<QueueEntry[]>;
  /** v6: take a source out of a pending batch (removed = true) or put it back (false). Nothing is written to the vault or inbox/. */
  removeReviewSource(jobID: string, page: string, removed: boolean): Promise<Job>;
  /**
   * v6: change the labels of source pages in a batch awaiting approval. The core writes a new label revision of the
   * bundle and inspects it; only a clean inspect replaces the plan (new approval hash). Otherwise `conflict` and
   * nothing changes. Refused while another label revision is running.
   */
  editReviewLabels(jobID: string, edits: { page: string; labels: string[] }[]): Promise<Job>;

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
  /** Write the summary of an item that has none (older items), from its original and wiki context. */
  summarizeAction(id: string, opts?: { signal?: AbortSignal }): Promise<ActionItem>;
  /** The exact command a button would run for an item (action-buttons.md). */
  previewActionButton(id: string, buttonId: string): Promise<ActionButtonPreview>;
  /** Remembered Slack names (all vaults, or one), sorted by name. */
  listSlackPeople(vaultPath?: string | null): Promise<SlackPerson[]>;
  /**
   * Remember who a name is in Slack for a vault (the item's, else the active one). `target` is an
   * @handle, an ID or a #channel; a bare lower-case handle gets its @. Anything else is invalid_request.
   */
  rememberSlackPerson(input: { name: string; target: string; vaultPath?: string | null }): Promise<SlackPerson>;
  /** Forget a remembered name; false when there was none. */
  forgetSlackPerson(input: { name: string; vaultPath?: string | null }): Promise<{ forgotten: boolean }>;
  /** Where a Slack message would go now: its To row resolved (not_found for another type). */
  slackTarget(id: string): Promise<SlackTarget>;
  /** The preview for a button being edited (Settings), on an item or a built-in sample. */
  previewButtonDraft(input: { typeId: string; button: ActionButton; itemId?: string | null }): Promise<ActionButtonPreview>;
  /**
   * Run a button for an item. `approve` records the approval of this exact command (the run sheet's Run);
   * `approved` is true when this run approved it (a first run, or a changed command), for the activity log.
   */
  runActionButton(id: string, buttonId: string, opts?: { approve?: boolean }): Promise<{ run: ActionButtonRun; item: ActionItem; approved?: boolean }>;
  stopActionButtonRun(id: string): Promise<void>;
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
  /** v6: the script's text and its package manifest. */
  getCollectorScript(id: string): Promise<CollectorScriptFiles>;
  /** v6: save a managed script's code and/or manifest (consent again when they change). Returns the files as saved. */
  writeCollectorScript(id: string, update: CollectorScriptUpdate): Promise<CollectorScriptFiles>;
  /** v6: install the manifest's packages (needs a current consent; busy while a run or install is going). Resolves when it started. */
  installCollectorPackages(id: string, opts?: { clean?: boolean }): Promise<CollectorInstall>;
  /** v6: stop a running install. Null when none runs. */
  stopCollectorInstall(id: string): Promise<CollectorInstall | null>;
  /** v6: the newest install with its output; null when there was none. */
  getCollectorInstall(id: string): Promise<CollectorInstall | null>;
  /** v6: Test run (scripts): like Run now, into a scratch folder instead of the queue. Same consent; busy like Run now. */
  testCollector(id: string): Promise<CollectorRun>;

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

// ───────────────────────────── Inbox clean-up (v8) ─────────────────────────────

/** Why a file stays in inbox/. */
export type InboxStayReason = 'notAdded' | 'changed' | 'pageMissing' | 'inReview' | 'inQueue' | 'unreadable' | 'notReadInFull' | 'notArchived' | 'held';

/** One thing that can go to the Trash: a file, a note (with its manifest and images), or a folder item as one. */
export interface InboxCleanupItem {
  /** Vault-relative, e.g. inbox/foo.md or inbox/2026-10-04/Tea tasting trip. */
  path: string;
  kind: 'file' | 'note' | 'folder';
  /** Other paths that go with it (a note's .distill.json and images); a folder moves whole. */
  members?: string[];
  /** Files it holds (1 for a file; a note's files; a folder's files). */
  fileCount: number;
  size: number;
  /** The batch that used it, when known. */
  jobId?: string;
  jobTitle?: string;
  /** When the ledger says it was added (YYYY-MM-DD). */
  addedAt?: string;
  /** The pages made from it. */
  pages: string[];
}

export interface InboxCleanupStay {
  path: string;
  kind: 'file' | 'note' | 'folder';
  reason: InboxStayReason;
  /** "3 of 12 files not added yet", the missing page, … (names only). */
  detail?: string;
  fileCount: number;
}

export interface InboxCleanupPreview {
  vaultPath: string;
  jobId?: string;
  items: InboxCleanupItem[];
  stays: InboxCleanupStay[];
  checkedAt: string;
}

export interface InboxCleanupRequest {
  paths: string[];
  jobId?: string;
  vaultPath?: string;
}

export interface InboxCleanupResult {
  moved: { path: string; fileCount: number }[];
  /** Not moved: failed a check when it was checked again, or was not offered. */
  stayed: InboxCleanupStay[];
  failed: { path: string; error: string }[];
  /** finder = moved by Finder (Put Back works); rename = moved into ~/.Trash. */
  method: 'finder' | 'rename' | 'none';
}
