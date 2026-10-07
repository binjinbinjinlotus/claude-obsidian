/**
 * Actions: to-dos and action types found in applied notes and Ask answers,
 * their drafts, handlers and connections. State: <state>/actions.json and
 * <state>/connections.json (secrets in the Keychain).
 *
 * Spec: apps/distill/docs/specs/actions.md
 */
import fs from 'node:fs';
import path from 'node:path';
import {
  CoreError,
  type ActionItem,
  type ActionPatch,
  type ActionQuery,
  type ActionSource,
  type ActionStatus,
  type ActionTypeInfo,
  type ActionButton,
  type ActionButtonInfo,
  type ActionButtonPreview,
  type ActionButtonRun,
  type Collector,
  type ScriptCommand,
  type AskConversation,
  type AskResponse,
  type ConnectionInfo,
  type ConnectRequest,
  type CoreEvent,
  type DistillCore,
  type Job,
  type JobActionProposal,
  type JobActions,
  type JobActionsSummary,
  type ActionRawRef,
  type ActionWikiRef,
  type ModelSelection,
  type NewActionInput,
  type Progress,
  type RunnerRegistry,
  type Settings,
  type SlackTarget,
  type ConfirmAs,
  type ActionPreferences,
  type HighlightItem,
  type HighlightNote,
  type RoutingPreview,
  type TrackPendingRequest,
} from '../contracts.js';
import type { ActionsOwned, ReviewReadyInfo } from '../engine/index.js';
import { makeReadingCopy } from '../coverage/copy.js';
import { ledgerRecords } from '../coverage/archive.js';
import { mapPool } from '../engine/queue-labels.js';
import { readBundle, sourcePages, wikiWrites } from '../engine/review-labels.js';
import { jobStateDirectory } from '../store/jobs.js';
import { buildWindowPrompt, loadFound, saveFound, type FoundFile, type FoundSource } from './batch.js';
import {
  bestHeading,
  clip,
  closestLines,
  coveredLines,
  excerptOf,
  headingsOf,
  locateQuote,
  matchPage,
  normalizeForMatch,
  numbered,
  originalOfPage,
  parseLines,
  readLines,
  resolveOriginal,
  sectionText,
  sha256File,
  sourceLineOf,
  plainTitle,
  titleOfPage,
  wikiRef,
  windowAround,
  windowsOf,
} from './context.js';
import type { FetchLike } from '../runners/model-api.js';
import { defaultSecretStore, type SecretStore } from '../runners/secrets.js';
import { isoDate } from '../store/json.js';
import { actionPreferences, decodeActionPreferences, defaultSelection as settingsDefaultSelection } from '../store/settings.js';
import { DRAFT_SCHEMA, FIND_SCHEMA, fieldsFrom, IMPROVE_SCHEMA, modelName, runStructured, SUMMARIZE_SCHEMA, type ActionTask } from './ai.js';
import { ActionHandlerError, API_TOKEN_URL, ATLASSIAN, AtlassianClient, ConnectionFile } from './atlassian.js';
import { approvalHash, buildArgv, commandTimeout, displayArgv, maskSecrets, parseResult, placeholdersIn, type TemplateValues } from '../collectors/commands.js';
import type { CommandRunHandle, CommandRunInput } from '../collectors/index.js';
import { buttonsFor, ButtonApprovals, normalizeButton, sampleItem, templateValues } from './buttons.js';
import { normalizeSlackTarget, resolveSlackTarget, SlackPeople } from './slack-target.js';
import { checkJiraDraft, JiraMeta } from './jira-meta.js';
import { asked, defaultsKey, extraFields, fieldKey, fromKey, fromNote, isEmptyValue, payloadValue, valueFor } from './jira-required.js';
import { buildDraftPrompt, buildFindPrompt, buildImprovePrompt, buildSummarizePrompt, DEFAULT_FIND_PROMPT, waitingBlock, type DraftContext, type FindDocument } from './prompts.js';
import {
  actionTypeDef,
  actionTypeDefs,
  effectiveType,
  handlerFn,
  resolveTypeID,
  TODO_TYPE,
  typeInfo,
  type EffectiveType,
  type PromptContext,
} from './registry.js';
import { displayName, handlesFor, matchPerson, ownerInstruction, peopleOf, routeItem, routingOn, YOU_ID } from './routing.js';
import { MAX_OTHERS_PAGES, othersLine, othersPrompt, othersSectionLines, readPageFacts, sectionMatches, type OthersLine } from './highlights.js';
import { ActionStore, event, HISTORY_STATUSES, leftAt, LIVE_STATUSES, newActionID } from './store.js';

export interface ActionsServiceOptions {
  emit: (event: CoreEvent) => void;
  getSettings: () => Settings;
  runners: RunnerRegistry;
  /** <stateDir>/actions.json */
  file: string;
  stateDir: string;
  /** Default selection for an action task when Settings has none. */
  defaultSelection?: (task: 'actionFind' | 'actionDraft' | 'actionImprove') => ModelSelection;
  /** Keychain by default; tests pass a MemorySecretStore. */
  secrets?: SecretStore;
  /** Network for Atlassian; tests pass a fake. */
  fetch?: FetchLike;
  now?: () => Date;
  /** Ask history, for detectAskActions. */
  getConversation?: (id: string) => Promise<AskConversation | undefined>;
  /** Write the job's "Found 5 actions" summary (engine.setJobActions). */
  setJobActions?: (jobID: string, summary: JobActionsSummary) => void;
  /** v11: the job as it is now (commit checks which parts applied). */
  getJob?: (id: string) => Job | undefined;
  /** Automations (action-buttons.md): runs a script's command for a button. Bound late (collectors start after actions). */
  scripts?: () => ScriptsAccess | undefined;
}

/** What action buttons need from Automations. */
export interface ScriptsAccess {
  runCommand(input: CommandRunInput): CommandRunHandle;
  scriptConsent(id: string): { sha256: string; allowed: boolean } | { problem: string };
  getCollector(id: string): Promise<Collector | undefined>;
}

export type ActionsService = Pick<DistillCore, ActionsOwned> & {
  /** After a batch is applied: the "Finding actions" step. Never throws. `retry` runs it again (Try again). */
  findInJob(job: Job, opts?: { retry?: boolean }): Promise<void>;
  /** After an Ask answer: background detection when Settings say so. Never throws. */
  afterAsk(conversationID: string, response?: AskResponse): Promise<void>;
  /** v11: a batch reached Review: look through its sources for actions (they wait in the job until apply). Never throws. */
  findForReview(job: Job, info: ReviewReadyInfo): Promise<void>;
  /** v11: a batch ended without applying: its waiting proposals are not added. Never throws. */
  jobEnded(job: Job): Promise<void>;
  /** v11: the actions a batch found, as Review shows them. */
  jobActions(jobID: string): Promise<JobActions>;
  /** actions-routing.md: what the next ingest batch adds to its prompt for this vault's Others' actions sections ('' = nothing due). */
  othersActionsPrompt(vaultPath: string): string;
  /** Drop History items older than historyDays (also runs on load and at most hourly). */
  sweepHistory(): void;
  /** Resolves when no background draft or find is running (tests). */
  whenIdle(): Promise<void>;
};

/** Steps of the batch progress once the changes are applied. */
export const FIND_STEPS = ['Moved to inbox', 'Read sources', 'Applied changes', 'Finding actions', 'Done'];

const SWEEP_INTERVAL_MS = 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_DOC_CHARS = 12_000;
const MAX_TOTAL_CHARS = 60_000;
const MAX_FOUND = 25;
/** Open Pending promises shown to the find step (the newest). */
const MAX_WAITING = 30;
/** Settings' preview line: "In the last 7 days this would have sent …". */
const PREVIEW_DAYS = 7;
/** Pages that never hold actions of their own. */
const SKIP_PAGES = [/^wiki\/(log|hot|index)\.md$/, /^wiki\/meta\//, /^\.raw\//, /^\.vault-meta\//, /(^|\/)_index\.md$/];

const clone = <T>(v: T): T => structuredClone(v);
const samePath = (a: string | null | undefined, b: string | null | undefined) => !!a && !!b && path.resolve(a) === path.resolve(b);

export function normalizeText(s: string | null | undefined): string {
  return (s ?? '')
    .toLowerCase()
    .replace(/[‘’“”"'`]/g, '')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

function sourceNotePath(s: ActionSource): string | null {
  return s.kind === 'note' ? (s.notePath ?? null) : null;
}

function sourceQuote(s: ActionSource): string | null {
  return s.kind === 'manual' ? null : (s.quote ?? null);
}

type DedupeKey = Pick<ActionItem, 'type' | 'title' | 'source'>;

/** Same source (note path, or Ask chat) and the same normalized quote. */
export function sameSourceQuote(a: DedupeKey, b: DedupeKey): boolean {
  const qa = normalizeText(sourceQuote(a.source));
  if (!qa || qa !== normalizeText(sourceQuote(b.source))) return false;
  // A long quote is the same line even when it was found through another page
  // (the source note in one batch, the wiki page that kept it in the next).
  if (a.source.kind === 'note' && b.source.kind === 'note') return sourceNotePath(a.source) === sourceNotePath(b.source) || qa.length >= 24;
  if (a.source.kind === 'ask' && b.source.kind === 'ask') return a.source.conversationID === b.source.conversationID;
  return false;
}

/** Same type and the same normalized title. */
export function sameTitle(a: DedupeKey, b: DedupeKey): boolean {
  return a.type === b.type && normalizeText(a.title) !== '' && normalizeText(a.title) === normalizeText(b.title);
}

/** Same source note + quote, or same normalized title and type. */
export function isDuplicate(a: DedupeKey, b: DedupeKey): boolean {
  return sameSourceQuote(a, b) || sameTitle(a, b);
}

function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** "3 to-dos, 1 Slack message" */
export function describeByType(byType: Record<string, number>): string {
  return Object.entries(byType)
    .filter(([, n]) => n > 0)
    .map(([id, n]) => {
      const def = actionTypeDef(id);
      const one = id === TODO_TYPE ? 'to-do' : (def?.label ?? id);
      const many = id === TODO_TYPE ? 'to-dos' : (def?.pluralLabel ?? `${id}s`);
      return plural(n, one, many);
    })
    .join(', ');
}

/** A reading copy's lines (absolute path). */
function readCopy(abs: string): string[] {
  try {
    const lines = fs.readFileSync(abs, 'utf8').split('\n');
    if (lines.at(-1) === '') lines.pop();
    return lines;
  } catch {
    return [];
  }
}

function readText(file: string, max: number): string | undefined {
  try {
    const text = fs.readFileSync(file, 'utf8');
    return text.length > max ? `${text.slice(0, max)}\n[…truncated]` : text;
  } catch {
    return undefined;
  }
}

function titleOf(text: string, file: string): string {
  return titleOfPage(text, file);
}

/** A model's summary as plain text: Markdown emphasis and bullets dropped, one paragraph, ≤ 800 characters. */
export function plainSummary(s: string): string {
  const text = s
    .split('\n')
    .map((l) => plainTitle(l.replace(/^\s*(?:[-*•]|\d+[.)])\s+/, '')))
    .filter(Boolean)
    .join(' ');
  return clip(text, 800);
}

export function createActionsService(opts: ActionsServiceOptions): ActionsService {
  const now = opts.now ?? (() => new Date());
  const store = new ActionStore(opts.file);
  const scratchRoot = path.join(opts.stateDir, 'actions', 'scratch');
  const connections = new ConnectionFile(path.join(opts.stateDir, 'connections.json'));
  const secrets = opts.secrets ?? defaultSecretStore();
  const fetchImpl: FetchLike = opts.fetch ?? ((input, init) => fetch(input, init));
  const controllers = new Map<string, AbortController>();
  const inflight = new Set<Promise<unknown>>();
  let lastSweep = Number.NEGATIVE_INFINITY;

  const atlassian = new AtlassianClient({
    fetch: fetchImpl,
    secrets,
    file: connections,
    now,
    onChange: () => emitConnection(),
  });

  function emit(e: CoreEvent): void {
    try {
      opts.emit(e);
    } catch {
      /* a listener must never break the service */
    }
  }

  function log(level: 'info' | 'warn' | 'error', message: string): void {
    emit({ type: 'log', level, message });
  }

  function track<T>(p: Promise<T>): Promise<T> {
    inflight.add(p);
    void p.finally(() => inflight.delete(p)).catch(() => undefined);
    return p;
  }

  // ───────────── state ─────────────

  let items: ActionItem[] = recover(store.load(now()));

  /** A draft or create that was running when the core quit. */
  function recover(loaded: ActionItem[]): ActionItem[] {
    let changed = false;
    for (const item of loaded) {
      if (item.status === 'drafting') {
        item.status = item.body ? 'ready' : 'open';
        item.events.push(event(now(), 'interrupted', 'Writing the draft stopped when Distill quit.'));
        changed = true;
      } else if (item.status === 'creating') {
        item.status = 'ready';
        item.error = {
          code: 'other',
          message: 'Distill quit while creating this. Check whether it exists before you retry, so it isn’t created twice.',
        };
        item.events.push(event(now(), 'interrupted', 'Creating stopped when Distill quit.'));
        changed = true;
      }
    }
    if (changed) {
      try {
        store.save(loaded);
      } catch {
        /* saved on the next change */
      }
    }
    return loaded;
  }

  function persist(): void {
    try {
      store.save(items);
    } catch (err) {
      log('error', `Could not save actions: ${(err as Error).message}`);
    }
  }

  function find(id: string): ActionItem | undefined {
    return items.find((i) => i.id === id);
  }

  function require(id: string): ActionItem {
    const item = find(id);
    if (!item) throw new CoreError('not_found', `Unknown action ${id}.`);
    return item;
  }

  /** Synchronous change → save → event. Never awaits between read and write. */
  function mutate(id: string, change: (item: ActionItem) => void): ActionItem {
    const item = require(id);
    change(item);
    item.updatedAt = isoDate(now());
    persist();
    emit({ type: 'action', action: clone(item) });
    return clone(item);
  }

  function insert(item: ActionItem): ActionItem {
    items.push(item);
    persist();
    emit({ type: 'action', action: clone(item) });
    return clone(item);
  }

  function prefs() {
    return actionPreferences(opts.getSettings());
  }

  function effective(typeID: string): EffectiveType | undefined {
    const def = actionTypeDef(typeID);
    return def ? effectiveType(def, prefs()) : undefined;
  }

  function selectionFor(task: ActionTask, override?: ModelSelection | null): ModelSelection {
    if (override) return override;
    const settings = opts.getSettings();
    const fromSettings = settings.taskDefaults[task];
    if (fromSettings) return fromSettings;
    return opts.defaultSelection ? opts.defaultSelection(task) : settingsDefaultSelection(settings, task);
  }

  // ───────────── progress ─────────────

  function progress(p: Progress): void {
    emit({ type: 'progress', progress: { ...p } });
  }

  // ───────────── History retention ─────────────

  function sweepHistory(): void {
    lastSweep = now().getTime();
    const days = prefs().historyDays;
    if (!(days > 0)) return; // forever
    const cutoff = now().getTime() - days * DAY_MS;
    const drop = items.filter(
      (i) => !LIVE_STATUSES.includes(i.status) && [...HISTORY_STATUSES, 'dismissed'].includes(i.status) && leftAt(i).getTime() < cutoff,
    );
    if (drop.length === 0) return;
    items = items.filter((i) => !drop.includes(i));
    persist();
    for (const i of drop) emit({ type: 'action', action: clone(i), deleted: true });
  }

  function maybeSweep(): void {
    if (now().getTime() - lastSweep >= SWEEP_INTERVAL_MS) sweepHistory();
  }

  sweepHistory();

  // ───────────── connections ─────────────

  function usedBy(connectionID: string): string[] {
    return actionTypeDefs()
      .filter((d) => d.connectionID === connectionID)
      .map((d) => d.id);
  }

  function slackInfo(): ConnectionInfo {
    return { id: 'slack', label: 'Slack', status: 'not_connected', site: null, account: null, message: 'Copy works without connecting', usedBy: ['slack'] };
  }

  function connectionInfo(id: string): ConnectionInfo {
    if (id === ATLASSIAN) return atlassian.info(usedBy(ATLASSIAN));
    if (id === 'slack') return slackInfo();
    throw new CoreError('not_found', `Unknown connection ${id}.`);
  }

  function emitConnection(): void {
    emit({ type: 'connection', connection: atlassian.info(usedBy(ATLASSIAN)) });
  }

  // ───────────── creating items ─────────────

  function initialStatus(typeID: string, body: string | null | undefined): ActionStatus {
    if (typeID === TODO_TYPE) return 'open';
    return body && body.trim() ? 'ready' : 'open';
  }

  /** In your lists (not Pending or Highlights). Items found before routing have no route: yours. */
  function inLists(item: ActionItem): boolean {
    return (item.route ?? 'list') === 'list';
  }

  function withDefaults(typeID: string, fields: Record<string, string | null> | undefined): Record<string, string | null> {
    const eff = effective(typeID);
    const out: Record<string, string | null> = { ...(fields ?? {}) };
    for (const [k, v] of Object.entries(eff?.fieldDefaults ?? {})) if (out[k] == null || out[k] === '') out[k] = v;
    return out;
  }

  function canDraft(item: ActionItem): boolean {
    const eff = effective(item.type);
    return !!eff && eff.enabled && !!eff.draftPrompt && item.type !== TODO_TYPE;
  }

  /** Start writing a draft in the background (drafts on finding / confirm / Send to). */
  function draftInBackground(id: string): void {
    const item = find(id);
    if (!item || !canDraft(item) || item.body?.trim() || !inLists(item)) return;
    void track(draft(id).catch((err: unknown) => log('warn', `Draft for ${id} failed: ${(err as Error).message}`)));
  }

  // ───────────── AI: draft / improve ─────────────

  function promptContext(item: ActionItem): PromptContext {
    const src = item.source;
    const notePath = src.kind === 'note' ? (src.notePath ?? null) : src.kind === 'ask' ? (src.citedPaths?.[0] ?? null) : null;
    const noteTitle = src.kind === 'note' ? (src.pageTitle ?? (notePath ? path.basename(notePath, '.md') : null)) : null;
    return { item, noteTitle, notePath, today: isoDate(now()).slice(0, 10) };
  }

  /**
   * v11 (action-context.md): what a draft is written from. The original's lines ±25 (archive, then
   * inbox; the stored excerpt when it is gone) and each wiki section; an older item without `raw`
   * gets its note's text in a window centred on its quote, never the first 12,000 characters.
   */
  function draftContextFor(item: ActionItem): DraftContext | undefined {
    const src = item.source;
    if (src.kind === 'manual' || !item.vaultPath) return undefined;
    const vault = item.vaultPath;
    const out: DraftContext = {};
    const raw = src.raw;
    if (raw && raw.match !== 'none') {
      const at = resolveOriginal(vault, raw);
      const lines = at ? readLines(vault, at) : undefined;
      if (lines && raw.lines) {
        const w = windowAround(lines, raw.lines[0], raw.lines[1], 25, MAX_DOC_CHARS);
        out.original = { path: at!, from: w.from, to: w.to, text: w.text };
      } else if (raw.excerpt && raw.lines) {
        out.original = { path: raw.path, from: raw.lines[0], to: raw.lines[1], text: raw.excerpt };
      }
    }
    const wiki: NonNullable<DraftContext['wiki']> = [];
    for (const w of (src.wiki ?? []).slice(0, 3)) {
      const lines = readLines(vault, w.path);
      const text = lines ? sectionText(lines.join('\n'), w.heading ?? null) : undefined;
      const body = text ?? w.excerpt ?? undefined;
      if (body) wiki.push({ path: w.path, heading: w.heading ?? null, text: body.length > 4000 ? `${body.slice(0, 4000)}\n[…]` : body });
    }
    if (wiki.length > 0) out.wiki = wiki;
    if (!out.original) {
      const rel = src.kind === 'note' ? src.notePath : src.citedPaths?.[0];
      const lines = rel ? readLines(vault, rel) : undefined;
      if (lines && (wiki.length === 0 || src.kind === 'note')) {
        const loc = src.quote ? locateQuote(lines, src.quote) : undefined;
        const w = loc ? windowAround(lines, loc[0], loc[1], 200, MAX_DOC_CHARS) : windowAround(lines, 1, 1, 0, MAX_DOC_CHARS);
        if (!loc) {
          // No quote to centre on: the start, up to the limit.
          let b = 1;
          let size = 0;
          while (b <= lines.length && size + lines[b - 1]!.length + 1 <= MAX_DOC_CHARS) size += lines[b++ - 1]!.length + 1;
          out.note = lines.slice(0, Math.max(1, b - 1)).join('\n') + (b <= lines.length ? '\n[…truncated]' : '');
        } else {
          out.note = `${w.from > 1 ? `[lines ${w.from}–${w.to} of ${lines.length}]\n` : ''}${w.text}`;
        }
      }
    }
    return out.original || out.wiki || out.note ? out : undefined;
  }

  async function aiPass(
    id: string,
    kind: 'draft' | 'improve',
    signal?: AbortSignal,
  ): Promise<ActionItem> {
    const item = require(id);
    const eff = effective(item.type);
    if (!eff || !eff.enabled) throw new CoreError('invalid_request', `${actionTypeDef(item.type)?.pluralLabel ?? item.type} are turned off.`);
    if (kind === 'draft' && !eff.draftPrompt) throw new CoreError('invalid_request', 'To-dos have no draft to write.');
    if (kind === 'improve') {
      if (!eff.improvePrompt) throw new CoreError('invalid_request', 'To-dos are edited by hand; there is no improve pass.');
      if (!item.body?.trim()) throw new CoreError('invalid_request', 'There is no text to improve yet.');
    }
    if (item.status === 'drafting' || item.status === 'creating') throw new CoreError('busy', `This ${eff.def.label.toLowerCase()} is busy.`);
    if (!['pending', 'open', 'ready'].includes(item.status)) {
      throw new CoreError('invalid_state', `Can't ${kind} an item that is ${item.status}.`);
    }
    const before = item.status;
    const task: ActionTask = kind === 'draft' ? 'actionDraft' : 'actionImprove';
    const selection = selectionFor(task, kind === 'draft' ? eff.draftSelection : eff.improveSelection);
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    signal?.addEventListener('abort', onAbort);
    controllers.get(id)?.abort();
    controllers.set(id, controller);
    // Synchronous: from here the item is drafting, and a second call gets busy.
    mutate(id, (i) => {
      i.status = 'drafting';
      i.error = null;
    });
    const key = `action:${id}`;
    const startedAt = isoDate(now());
    const model = modelName(opts.runners, selection);
    progress({
      key,
      kind: 'actions',
      message: kind === 'draft' ? `Writing the draft with ${model}` : `Improving with ${model}`,
      startedAt,
      runnerID: selection.runnerID,
      model: selection.model,
    });
    const snapshot = clone(item);
    try {
      const ctx = promptContext(snapshot);
      const prompt = kind === 'draft' ? buildDraftPrompt(eff, snapshot, ctx, draftContextFor(snapshot)) : buildImprovePrompt(eff, snapshot, ctx);
      const out = await runStructured({
        runners: opts.runners,
        settings: opts.getSettings(),
        task,
        selection,
        prompt,
        schema: kind === 'draft' ? DRAFT_SCHEMA : IMPROVE_SCHEMA,
        scratchRoot,
        signal: controller.signal,
      });
      const body = typeof out.value.body === 'string' ? out.value.body.trim() : '';
      if (!body) throw new Error('The AI returned an empty text.');
      if (!find(id) || find(id)!.status !== 'drafting') return clone(require(id)); // removed meanwhile
      const result = mutate(id, (i) => {
        if (kind === 'draft') {
          i.body = body;
          const title = typeof out.value.title === 'string' ? out.value.title.trim() : '';
          if (title && !i.title.trim()) i.title = title;
          // Keep every field already set; fill only the empty ones.
          for (const [k, v] of Object.entries(fieldsFrom(out.value.fields))) {
            if (eff.def.fields.some((f) => f.key === k) && (i.fields[k] == null || i.fields[k] === '')) i.fields[k] = v;
          }
          i.previousBody = null;
          i.events.push(event(now(), 'drafted', `with ${out.model}`));
        } else {
          i.previousBody = i.body ?? null;
          i.body = body;
          i.events.push(event(now(), 'improved', `with ${out.model}`));
        }
        i.draftModel = out.model;
        i.status = before === 'pending' ? 'pending' : 'ready';
      });
      progress({ key, kind: 'actions', message: kind === 'draft' ? 'Draft written' : 'Improved', startedAt, finished: true });
      if (kind === 'draft' && result.type === 'jira') return await fillJiraRequired(await alignJira(result));
      return result;
    } catch (err) {
      const cancelled = controller.signal.aborted;
      const message = cancelled ? 'Cancelled' : (err as Error).message;
      const current = find(id);
      let result: ActionItem;
      if (current && current.status === 'drafting') {
        result = mutate(id, (i) => {
          i.status = before === 'pending' ? 'pending' : i.body?.trim() ? 'ready' : 'open';
          if (!cancelled) i.error = { code: 'ai_failed', message: kind === 'draft' ? `Couldn’t write the draft: ${message}` : `Couldn’t improve it: ${message}` };
        });
      } else {
        result = current ? clone(current) : snapshot;
      }
      progress({ key, kind: 'actions', message, startedAt, finished: true, ...(cancelled ? {} : { error: message }) });
      return result;
    } finally {
      signal?.removeEventListener('abort', onAbort);
      if (controllers.get(id) === controller) controllers.delete(id);
    }
  }

  function draft(id: string, signal?: AbortSignal): Promise<ActionItem> {
    return aiPass(id, 'draft', signal);
  }

  /** action-summary.md: an older item's summary, written on first open. One run per item at a time;
   *  the status never changes. A failure leaves the summary empty with `error`, so Try again works. */
  const summarizing = new Map<string, Promise<ActionItem>>();
  function summarize(id: string, signal?: AbortSignal): Promise<ActionItem> {
    const item = require(id);
    if (item.summary?.trim()) return Promise.resolve(clone(item));
    const running = summarizing.get(id);
    if (running) return running;
    const p = (async () => {
      const selection = selectionFor('actionFind', prefs().findSelection);
      const snapshot = clone(item);
      try {
        const prompt = buildSummarizePrompt(snapshot, promptContext(snapshot), draftContextFor(snapshot));
        const out = await runStructured({
          runners: opts.runners,
          settings: opts.getSettings(),
          task: 'actionFind',
          selection,
          prompt,
          schema: SUMMARIZE_SCHEMA,
          scratchRoot,
          signal,
        });
        const summary = typeof out.value.summary === 'string' ? plainSummary(out.value.summary) : '';
        if (!summary) throw new Error('The AI returned an empty summary.');
        if (!find(id)) return snapshot;
        return mutate(id, (i) => {
          i.summary = summary;
          if (i.error?.code === 'ai_failed' && i.error.message.startsWith('Couldn’t summarize')) i.error = null;
          i.events.push(event(now(), 'summarized', `by ${out.model}`));
        });
      } catch (err) {
        if (signal?.aborted || !find(id)) return find(id) ? clone(require(id)) : snapshot;
        return mutate(id, (i) => {
          i.error = { code: 'ai_failed', message: `Couldn’t summarize: ${(err as Error).message}` };
        });
      } finally {
        summarizing.delete(id);
      }
    })();
    summarizing.set(id, p);
    track(p);
    return p;
  }

  // ───────────── finding ─────────────

  interface Found {
    type: string;
    title: string;
    body: string | null;
    fields: Record<string, string>;
    why: string;
    /** action-summary.md: what the action is about (plain text, ≤ 800 characters). */
    summary: string | null;
    quote: string;
    notePath: string | null;
    /** v11: the line numbers the model gave (window prompts); only a hint for the core's own search. */
    lines?: [number, number];
    wiki?: { path: string; heading: string }[];
    /** actions-routing.md: whose it is, as written. */
    owner?: string;
    owedTo?: string;
    what?: string;
    due?: string;
  }

  function parseFound(value: Record<string, unknown>): Found[] {
    const raw = Array.isArray(value.items) ? value.items : [];
    const out: Found[] = [];
    for (const r of raw.slice(0, MAX_FOUND)) {
      if (typeof r !== 'object' || r === null) continue;
      const o = r as Record<string, unknown>;
      const title = typeof o.title === 'string' ? o.title.trim() : '';
      if (!title) continue;
      const f: Found = {
        type: typeof o.type === 'string' ? o.type.trim() : TODO_TYPE,
        title: title.slice(0, 300),
        body: typeof o.body === 'string' && o.body.trim() ? o.body.trim() : null,
        fields: fieldsFrom(o.fields),
        why: typeof o.why === 'string' ? o.why.trim() : '',
        summary: typeof o.summary === 'string' && o.summary.trim() ? plainSummary(o.summary) : null,
        quote: typeof o.quote === 'string' ? o.quote.trim().slice(0, 600) : '',
        notePath: typeof o.notePath === 'string' && o.notePath.trim() ? o.notePath.trim() : null,
      };
      const lines = parseLines(o.lines);
      if (lines) f.lines = lines;
      for (const k of ['owner', 'owedTo', 'what', 'due'] as const) {
        const v = typeof o[k] === 'string' ? (o[k] as string).trim().slice(0, 200) : '';
        if (v) f[k] = v;
      }
      if (f.due && !/^\d{4}-\d{2}-\d{2}$/.test(f.due)) delete f.due;
      if (Array.isArray(o.wiki)) {
        f.wiki = o.wiki
          .filter((w): w is Record<string, unknown> => typeof w === 'object' && w !== null && typeof (w as Record<string, unknown>).path === 'string')
          .map((w) => ({ path: String(w.path).trim(), heading: typeof w.heading === 'string' ? w.heading.trim() : '' }))
          .slice(0, 4);
      }
      out.push(f);
    }
    return out;
  }

  function parseReceived(value: Record<string, unknown>): { id: string; quote: string }[] {
    if (!Array.isArray(value.received)) return [];
    return value.received
      .filter((r): r is Record<string, unknown> => typeof r === 'object' && r !== null && typeof (r as Record<string, unknown>).id === 'string')
      .map((r) => ({ id: String(r.id).trim(), quote: typeof r.quote === 'string' ? r.quote.trim().slice(0, 300) : '' }))
      .slice(0, 10);
  }

  /** Types the find prompt may use from this source. */
  function findTypes(source: 'notes' | 'ask', force: boolean) {
    const p = prefs();
    const sp = p.sources[source];
    const todos = sp.detectTodos || (force && !sp.detectTypes);
    const typesOn = sp.detectTypes || (force && !sp.detectTodos);
    const disabled = new Set(sp.disabledTypes ?? []);
    const allowed = actionTypeDefs()
      .filter((d) => d.id !== TODO_TYPE && typesOn && !disabled.has(d.id) && effectiveType(d, p).enabled)
      .map((d) => d.id);
    return { todos, allowed, confirm: sp.confirm };
  }

  /** A found item as it would be added (type fallback, field defaults); undefined when its type isn't wanted. */
  function buildItem(f: Found, o: { source: ActionSource; vaultPath: string | null; model: string; todos: boolean; allowed: string[]; confirm: boolean; routing?: boolean }): ActionItem | undefined {
    let type = o.allowed.includes(f.type) ? f.type : TODO_TYPE;
    if (type === TODO_TYPE && !o.todos) return undefined;
    if (!effective(type)) type = TODO_TYPE;
    const t = isoDate(now());
    const item: ActionItem = {
      id: newActionID(),
      type,
      status: o.confirm ? 'pending' : initialStatus(type, type === TODO_TYPE ? f.body : null),
      title: f.title,
      body: type === TODO_TYPE ? f.body : null,
      fields: withDefaults(type, f.fields),
      why: f.why || null,
      summary: f.summary,
      source: o.source,
      vaultPath: o.vaultPath,
      createdAt: t,
      updatedAt: t,
      draftModel: null,
      events: [event(now(), 'found', `by ${o.model}`)],
    };
    if (o.routing && routingOn(prefs())) applyRoute(item, f);
    return item;
  }

  /** actions-routing.md: record whose it is and where it goes (only new finds; nothing already listed moves). */
  function applyRoute(item: ActionItem, f: Pick<Found, 'owner' | 'owedTo' | 'what' | 'due'>): void {
    const r = routeItem({ type: item.type, owner: f.owner ?? null, owedTo: f.owedTo ?? null }, prefs());
    item.owner = f.owner ?? null;
    item.owedTo = f.owedTo ?? null;
    item.ownerID = r.ownerID;
    item.owedToID = r.owedToID;
    item.route = r.route;
    if (r.unclear) item.ownerUnclear = true;
    if (f.what) item.what = f.what;
    if (f.due) {
      item.due = f.due;
      if (actionTypeDef(item.type)?.fields.some((x) => x.key === 'due') && !item.fields.due) item.fields.due = f.due;
    }
  }

  /**
   * v11: the same content (raw sha256): an item from the same original, of the same type, on
   * overlapping lines or with the same quote. Older items without `raw` count when their note
   * still hashes to that sha256 and their quote is found in the original (`oldLines`).
   */
  function sameContent(i: DedupeKey & { vaultPath?: string | null }, candidate: DedupeKey, oldLines?: (i: DedupeKey & { vaultPath?: string | null }) => [number, number] | undefined): boolean {
    if (i.type !== candidate.type) return false;
    const cr = rawOf(candidate.source);
    if (!cr?.sha256) return false;
    const ir = rawOf(i.source);
    const quotesMatch = () => {
      const a = normalizeText(sourceQuote(i.source));
      return a !== '' && a === normalizeText(sourceQuote(candidate.source));
    };
    const overlap = (a: [number, number] | null | undefined, b: [number, number] | null | undefined) => !!a && !!b && a[0] <= b[1] && b[0] <= a[1];
    if (ir?.sha256) {
      if (ir.sha256 !== cr.sha256) return false;
      return overlap(ir.lines, cr.lines) || quotesMatch();
    }
    if (!oldLines) return false;
    return overlap(oldLines(i), cr.lines);
  }

  function rawOf(s: ActionSource): ActionRawRef | null | undefined {
    return s.kind === 'manual' ? undefined : s.raw;
  }

  /** v11: an older item (no raw) located in a new original: its quote's lines there, when its note is that content or the quote is long. */
  function oldLinesIn(sha256: string, lines: string[], sourceLines: number) {
    const cache = new Map<string, [number, number] | undefined>();
    return (i: DedupeKey & { vaultPath?: string | null }): [number, number] | undefined => {
      if (i.source.kind !== 'note' || !i.source.quote) return undefined;
      const key = i.source.quote;
      if (cache.has(key)) return cache.get(key);
      let hit: [number, number] | undefined;
      const sameFile = i.vaultPath && i.source.notePath ? sha256File(path.resolve(i.vaultPath, i.source.notePath)) === sha256 : false;
      if (sameFile || normalizeText(i.source.quote).length >= 24) {
        const loc = locateQuote(lines, i.source.quote);
        if (loc) hit = [sourceLineOf(lines, loc[0], sourceLines), sourceLineOf(lines, loc[1], sourceLines)];
      }
      cache.set(key, hit);
      return hit;
    };
  }

  /** The existing item a candidate repeats, if any (see actions.md → Duplicates, action-context.md → Dedupe). */
  function duplicateOf(
    candidate: ActionItem,
    before: ActionItem[],
    o: { conversationID?: string; oldLines?: (i: DedupeKey & { vaultPath?: string | null }) => [number, number] | undefined } = {},
  ): ActionItem | undefined {
    // Earlier items: same quote or same title. Items from this same run share
    // quotes ("book the room and tell Mei" is a to-do and a message), so only
    // the title rule applies among them.
    // Lines already handled (in any status: done, removed, sent, dismissed)
    // are never suggested again when a later batch rewrites the same page.
    // The title rule only counts live items (a recurring to-do may come back),
    // and items dismissed in this same Ask chat.
    return before.find(
      (i) =>
        sameSourceQuote(i, candidate) ||
        sameContent(i, candidate, o.oldLines) ||
        ((LIVE_STATUSES.includes(i.status) ||
          (i.status === 'dismissed' && o.conversationID && i.source.kind === 'ask' && i.source.conversationID === o.conversationID)) &&
          sameTitle(i, candidate)),
    );
  }

  /**
   * Turn model findings into items: unknown / disabled types fall back to to-do;
   * duplicates of live items (or of items dismissed in this chat) are not added
   * again — the existing item is returned instead.
   */
  function addFound(
    found: Found[],
    o: { source: (f: Found) => ActionSource; vaultPath: string | null; model: string; todos: boolean; allowed: string[]; confirm: boolean; conversationID?: string },
  ): { added: ActionItem[]; existing: ActionItem[] } {
    const added: ActionItem[] = [];
    const existing: ActionItem[] = [];
    const before = [...items];
    for (const f of found) {
      const item = buildItem(f, { ...o, source: o.source(f) });
      if (!item) continue;
      const dup = duplicateOf(item, before, o.conversationID ? { conversationID: o.conversationID } : {});
      if (dup) {
        if (LIVE_STATUSES.includes(dup.status) && !existing.includes(dup)) existing.push(dup);
        continue;
      }
      if (added.some((a) => a.type === item.type && normalizeText(a.title) === normalizeText(item.title))) continue;
      items.push(item);
      added.push(item);
    }
    if (added.length > 0) {
      persist();
      for (const i of added) emit({ type: 'action', action: clone(i) });
      if (!o.confirm) {
        for (const i of added) if (i.type !== TODO_TYPE && effective(i.type)?.draftWhen === 'onFind') draftInBackground(i.id);
      }
    }
    return { added: added.map(clone), existing: existing.map(clone) };
  }

  // ───────────── finding in a batch (v11, action-context.md) ─────────────

  /** One source of a batch to look through. */
  interface PassSource {
    /** The source file (vault-relative): inbox/…, .raw/captured/…, or a wiki page (pageOnly). */
    file: string;
    /** Where the text is read from when it isn't `file` (the archive copy of a gone inbox file). */
    readFrom?: string;
    page?: { path: string; title: string; text: string } | null;
    /** The text is the wiki page itself (the original isn't available). */
    pageOnly?: boolean;
  }

  /** Which runner looks through a batch's sources: the finding model, on the batch's own runner when it is another provider. */
  function passSelection(job: Job): ModelSelection {
    const sel = selectionFor('actionFind', prefs().findSelection);
    // Absent on old jobs means Claude Code (contracts: Job.runnerID).
    const own = job.runnerID ?? 'claude-code';
    if (!own || own === sel.runnerID) return sel;
    const runner = opts.runners.get(own);
    if (!runner) return sel;
    const model = runner.models.some((m) => m.id === sel.model) ? sel.model : job.model || runner.defaultModel;
    return { runnerID: own, model, effort: sel.effort ?? null };
  }

  function summaryOf(job: Job, f: FoundFile, model?: string | null): JobActionsSummary {
    const sources = Object.values(f.sources);
    const counted = f.proposals.filter((p) => p.state !== 'duplicate' && p.state !== 'notApplied');
    // actions-routing.md: items for other people aren't "found actions" of yours; they are counted apart.
    const live = counted.filter((p) => inLists(p.item));
    const routedAway = { waiting: counted.filter((p) => p.item.route === 'waiting').length, others: counted.filter((p) => p.item.route === 'others').length };
    const byType: Record<string, number> = {};
    for (const p of live) byType[p.item.type] = (byType[p.item.type] ?? 0) + 1;
    const addedItems = f.proposals.filter((p) => p.state === 'added').map((p) => find(p.item.id)).filter((i): i is ActionItem => !!i && inLists(i));
    // A pass that isn't running any more (Distill quit meanwhile) didn't finish: it shows as failed, with Try again.
    const active = passes.has(job.id);
    const failed = sources.filter((s) => s.status === 'failed' || (s.status === 'finding' && !active));
    const finding = active && sources.some((s) => s.status === 'finding');
    const waiting = live.filter((p) => p.state === 'waiting').length;
    const committed = f.proposals.some((p) => p.state === 'added' || p.state === 'duplicate') || (job.state === 'completed' && !!job.operationID);
    const failedText = failed
      .map((s) => {
        const file = Object.keys(f.sources).find((k) => f.sources[k] === s)!;
        return `${path.basename(file, path.extname(file))}: ${s.error ?? (s.status === 'finding' ? 'Distill stopped before it finished looking' : 'it failed')}`;
      })
      .join('; ');
    return {
      status: finding ? 'finding' : failed.length > 0 ? 'failed' : 'done',
      found: live.length,
      pending: addedItems.filter((i) => i.status === 'pending').length,
      added: addedItems.filter((i) => i.status !== 'pending').length,
      byType,
      ...(failed.length > 0 ? { error: failedText } : {}),
      model: model ?? sources.find((s) => s.model)?.model ?? null,
      stage: committed ? 'applied' : 'review',
      proposed: waiting,
      lines: sources.reduce((n, s) => n + coveredLines(s.looked), 0),
      linesOf: sources.reduce((n, s) => n + s.lines, 0),
      sources: sources.length,
      duplicates: f.proposals.filter((p) => p.state === 'duplicate').length,
      ...(routedAway.waiting > 0 ? { waiting: routedAway.waiting } : {}),
      ...(routedAway.others > 0 ? { others: routedAway.others } : {}),
    };
  }

  function setSummary(jobID: string, s: JobActionsSummary): void {
    try {
      opts.setJobActions?.(jobID, s);
    } catch {
      /* the job may be gone */
    }
  }

  /** The wiki refs of a found item: its source page first (best section), then refs the model named that exist. */
  function wikiRefsFor(f: Found, src: PassSource, written: Map<string, string>, vaultPath: string): ActionWikiRef[] {
    const out: ActionWikiRef[] = [];
    const query = `${f.title} ${f.quote} ${f.why}`;
    const textOf = (p: string): string | undefined => {
      if (written.has(p)) return written.get(p);
      const lines = readLines(vaultPath, p);
      return lines ? lines.join('\n') : undefined;
    };
    const named = (f.wiki ?? []).filter((w) => w.path.startsWith('wiki/') && w.path.endsWith('.md'));
    if (src.page) {
      const own = named.find((w) => w.path === src.page!.path && w.heading && sectionText(src.page!.text, w.heading) !== undefined);
      const heading = own?.heading || bestHeading(src.page.text, query) || null;
      const ref = wikiRef(src.page.path, src.page.text, heading);
      if (ref) out.push(ref);
    }
    for (const w of named) {
      if (out.some((r) => r.path === w.path) || out.length >= 3) continue;
      const text = textOf(w.path);
      if (text === undefined) continue;
      const ref = wikiRef(w.path, text, w.heading || null);
      if (ref) out.push(ref);
    }
    return out;
  }

  /**
   * Look through every line of `sources` (windows of planned sections) and record what was found
   * in the job's side file as proposals. Sources already looked through (same file and sha256)
   * are skipped unless `retry` and they failed.
   */
  /** One pass per job at a time (a rebuild can reach Review again while one runs); the next skips what is done. */
  const passes = new Map<string, Promise<unknown>>();

  function runPass(job: Job, sources: PassSource[], written: Map<string, string>, o: { stage: 'review' | 'applied'; retry?: boolean }): Promise<FoundFile> {
    const before = passes.get(job.id) ?? Promise.resolve();
    const next = before.catch(() => undefined).then(() => runPassNow(job, sources, written, o));
    passes.set(job.id, next);
    void next.finally(() => {
      if (passes.get(job.id) === next) passes.delete(job.id);
    }).catch(() => undefined);
    return next;
  }

  async function runPassNow(job: Job, sources: PassSource[], written: Map<string, string>, o: { stage: 'review' | 'applied'; retry?: boolean }): Promise<FoundFile> {
    const vault = path.resolve(job.vaultPath);
    const jobDir = jobStateDirectory(job);
    let f = loadFound(job) ?? { version: 1 as const, sources: {}, proposals: [], committed: [] };
    const types = findTypes('notes', false);
    const p = prefs();
    const selection = passSelection(job);
    const model = modelName(opts.runners, selection);
    const today = isoDate(now()).slice(0, 10);
    const writtenList = [...written.entries()].filter(([w]) => !SKIP_PAGES.some((re) => re.test(w))).map(([w, text]) => ({ path: w, title: titleOfPage(text, w) }));
    // actions-routing.md: whose each item is, and the open Pending promises a later note may deliver.
    const routing = routingOn(p) ? ownerInstruction(p) : undefined;
    const waitingItems = routing
      ? items.filter((i) => i.route === 'waiting' && LIVE_STATUSES.includes(i.status) && !i.received && samePath(i.vaultPath, job.vaultPath)).slice(-MAX_WAITING)
      : [];
    const waitingKeys = new Map(waitingItems.map((w, k) => [`w${k + 1}`, w]));
    const waiting = waitingBlock([...waitingKeys].map(([k, w]) => ({ id: k, text: `${w.title}${w.source.kind === 'note' && w.source.pageTitle ? ` (promised in ${w.source.pageTitle})` : ''}` })));

    interface Prepared {
      src: PassSource;
      sha256: string | null;
      lines: string[];
      sourceLines: number;
      windows: { from: number; to: number }[];
      title: string;
    }
    const prepared: Prepared[] = [];
    let n = 0;
    for (const src of sources) {
      const prev = f.sources[src.file];
      const readRel = src.readFrom ?? src.file;
      n += 1;
      let copy;
      if (src.pageOnly && src.page) {
        // The page's text in this change (it may not be in the vault yet).
        const pagesDir = path.join(jobDir, 'actions', 'pages');
        fs.mkdirSync(pagesDir, { recursive: true });
        fs.writeFileSync(path.join(pagesDir, `${n}.md`), src.page.text);
        copy = makeReadingCopy(pagesDir, `${n}.md`, path.join(jobDir, 'actions'), n);
      } else {
        copy = makeReadingCopy(vault, readRel, path.join(jobDir, 'actions'), n);
      }
      const sha = copy.sha256 || null;
      if (prev && prev.sha256 === sha && (prev.status === 'done' || (prev.status === 'failed' && !o.retry))) continue;
      if (copy.unreadable || !copy.copy) {
        // Not text (PDF, image) or unreadable: its page is looked through instead, when there is one.
        if (!src.pageOnly && src.page) {
          sources.push({ file: src.file, page: src.page, pageOnly: true });
          continue;
        }
        f.sources[src.file] = { sha256: sha, status: 'failed', lines: 0, looked: [], error: copy.unreadable ?? 'it isn’t text', at: isoDate(now()), ...(src.page ? { page: src.page.path } : {}) };
        continue;
      }
      const lines = readCopy(copy.copy);
      const windows = windowsOf(lines, copy.sections);
      // Drop this source's earlier proposals that never applied: they are found again.
      f.proposals = f.proposals.filter((x) => !(x.file === src.file && (x.state === 'waiting' || x.state === 'notApplied')));
      f.sources[src.file] = {
        sha256: sha,
        status: 'finding',
        lines: lines.length,
        looked: [],
        at: isoDate(now()),
        model,
        ...(src.page ? { page: src.page.path } : {}),
        ...(src.pageOnly ? { pageOnly: true } : {}),
      };
      prepared.push({ src, sha256: sha, lines, sourceLines: copy.sourceLines, windows, title: src.page?.title ?? titleOfPage(lines.join('\n'), src.file) });
    }
    saveFound(job, f);
    if (prepared.length === 0) return f;

    const totalLines = prepared.reduce((k, x) => k + x.lines.length, 0);
    const key = o.stage === 'review' ? `actions:job:${job.id}` : job.id;
    const startedAt = isoDate(now());
    const base =
      o.stage === 'review'
        ? { key, kind: 'actions' as const, startedAt, runnerID: selection.runnerID, model: selection.model }
        : { key, kind: 'batch' as const, steps: FIND_STEPS, startedAt, runnerID: selection.runnerID, model: selection.model, stepIndex: FIND_STEPS.indexOf('Finding actions') };
    let looked = 0;
    const lookedText = () => `${looked.toLocaleString('en-US')} of ${totalLines.toLocaleString('en-US')} lines`;
    progress({ ...base, message: `Finding actions in ${plural(prepared.length, 'source')} · ${lookedText()}` });
    setSummary(job.id, summaryOf(job, f, model));

    const tasks = prepared.flatMap((pr) => pr.windows.map((w, i) => ({ pr, w, i })));
    const results = await mapPool(tasks, 3, async ({ pr, w, i }) => {
      const prompt = buildWindowPrompt({
        instructions: p.findPrompt?.trim() ? p.findPrompt : DEFAULT_FIND_PROMPT,
        types: findTypeList(types.todos, types.allowed),
        today,
        file: pr.src.pageOnly && pr.src.page ? pr.src.page.path : pr.src.file,
        title: pr.title,
        from: w.from,
        to: w.to,
        of: pr.lines.length,
        part: i + 1,
        parts: pr.windows.length,
        text: numbered(pr.lines, w.from, w.to),
        // The source's page, at most 12,000 characters (it repeats in every window).
        page: pr.src.pageOnly || !pr.src.page ? null : { ...pr.src.page, text: clip(pr.src.page.text, MAX_DOC_CHARS) },
        written: writtenList,
        ...(routing ? { routing } : {}),
        ...(waiting ? { waiting } : {}),
      });
      let lastError = '';
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const out = await runStructured({ runners: opts.runners, settings: opts.getSettings(), task: 'actionFind', selection, prompt, schema: FIND_SCHEMA, scratchRoot });
          looked += w.to - w.from + 1;
          progress({ ...base, message: `Finding actions in ${plural(prepared.length, 'source')} · ${lookedText()}` });
          // Review's strip counts the lines as they are looked through.
          f.sources[pr.src.file]?.looked.push([w.from, w.to]);
          setSummary(job.id, summaryOf(job, f, model));
          return { pr, w, found: parseFound(out.value), received: parseReceived(out.value), model: out.model };
        } catch (err) {
          lastError = (err as Error).message;
        }
      }
      return { pr, w, error: lastError };
    });

    f = loadFound(job) ?? f;
    for (const pr of prepared) {
      const mine = results.filter((r) => r.pr === pr);
      const s = f.sources[pr.src.file]!;
      const errors = mine.filter((r) => 'error' in r) as { w: { from: number; to: number }; error: string }[];
      s.looked = mine.filter((r) => !('error' in r)).map((r) => [r.w.from, r.w.to] as [number, number]);
      s.status = errors.length > 0 ? 'failed' : 'done';
      if (errors.length > 0) s.error = `lines ${errors.map((e) => `${e.w.from}–${e.w.to}`).join(', ')} weren’t looked through: ${errors[0]!.error}`;
      else delete s.error;
      const foundModel = mine.find((r) => 'model' in r && r.model) as { model: string } | undefined;
      if (foundModel) s.model = foundModel.model;
      const found = mine.flatMap((r) => ('found' in r && r.found ? r.found.map((x) => ({ x, w: r.w })) : []));
      // A promise these lines look like delivering: suggested once this source's page applies (never closed).
      for (const r of mine.flatMap((m) => ('received' in m && m.received ? m.received : []))) {
        const w = waitingKeys.get(r.id);
        const page = pr.src.page?.path ?? pr.src.file;
        if (!w || (w.source.kind === 'note' && w.source.notePath === page)) continue;
        f.received = [...(f.received ?? []).filter((x) => x.id !== w.id), { id: w.id, quote: r.quote, file: pr.src.file, title: pr.title, ...(pr.src.page ? { page: pr.src.page.path } : {}) }];
      }
      const oldLines = pr.sha256 && !pr.src.pageOnly ? oldLinesIn(pr.sha256, pr.lines, pr.sourceLines) : undefined;
      for (const { x, w } of found) {
        const hint = x.lines ? ([Math.max(w.from, x.lines[0]), Math.min(w.to, x.lines[1])] as [number, number]) : null;
        const loc = locateQuote(pr.lines, x.quote, hint && hint[0] <= hint[1] ? hint : null);
        const srcLines = loc ? ([sourceLineOf(pr.lines, loc[0], pr.sourceLines), sourceLineOf(pr.lines, loc[1], pr.sourceLines)] as [number, number]) : undefined;
        const lines = srcLines && srcLines[0] > srcLines[1] ? ([srcLines[1], srcLines[0]] as [number, number]) : srcLines;
        const wiki = wikiRefsFor(x, pr.src, written, vault);
        let source: ActionSource;
        if (pr.src.pageOnly) {
          source = {
            kind: 'note',
            jobID: job.id,
            notePath: pr.src.page?.path ?? pr.src.file,
            pageTitle: pr.title,
            quote: x.quote || null,
            ...(wiki.length > 0 ? { wiki } : {}),
            contextNote: 'Found in the wiki page: the original isn’t available.',
          };
        } else {
          const raw: ActionRawRef = {
            path: pr.src.readFrom ?? pr.src.file,
            ...(pr.src.readFrom && pr.src.readFrom !== pr.src.file ? { inboxPath: pr.src.file } : pr.src.file.startsWith('.raw/') ? {} : { inboxPath: pr.src.file }),
            ...(pr.sha256 ? { sha256: pr.sha256 } : {}),
            match: lines ? 'quote' : 'none',
          };
          if (lines && loc) {
            raw.lines = lines;
            raw.excerpt = excerptOf(pr.lines, loc[0], loc[1]);
          }
          source = {
            kind: 'note',
            jobID: job.id,
            notePath: pr.src.page?.path ?? pr.src.file,
            pageTitle: pr.src.page?.title ?? pr.title,
            quote: x.quote || null,
            raw,
            ...(wiki.length > 0 ? { wiki } : {}),
          };
        }
        const item = buildItem(x, { source, vaultPath: job.vaultPath, model: s.model ?? model, todos: types.todos, allowed: types.allowed, confirm: true, routing: true });
        if (!item) continue;
        item.status = 'pending';
        // Within one pass only the title rule applies (one sentence can hold two actions).
        if (f.proposals.some((q) => q.file === pr.src.file && q.item.type === item.type && normalizeText(q.item.title) === normalizeText(item.title))) continue;
        const dup = duplicateOf(item, items, oldLines ? { oldLines } : {});
        f.proposals.push({
          item,
          file: pr.src.file,
          ...(pr.src.page ? { page: pr.src.page.path } : {}),
          state: dup ? 'duplicate' : 'waiting',
          ...(dup ? { existingID: dup.id } : {}),
        });
      }
    }
    saveFound(job, f);
    const summary = summaryOf(job, f, model);
    setSummary(job.id, summary);
    const what = describeByType(summary.byType);
    const message = summary.status === 'failed'
      ? 'Couldn’t look through every line'
      : summary.found === 0
        ? `No actions found · ${lookedText()}`
        : `Found ${plural(summary.found, 'action')}${what ? `: ${what}` : ''}`;
    progress({ ...base, message, finished: true, ...(summary.status === 'failed' ? { error: summary.error ?? 'failed' } : {}), ...(o.stage === 'applied' ? { stepIndex: FIND_STEPS.length - 1 } : {}) });
    return f;
  }

  /** Which of a job's proposals may be added now: their source page applied (a part), or the whole change applied. */
  function appliedCheck(job: Job, assumeApplied = false): (p: JobActionProposal) => boolean {
    const parts = job.parts ?? [];
    const pages = new Set(parts.flatMap((x) => x.pages));
    const applied = assumeApplied || (job.state === 'completed' && (!!job.operationID || job.changedPaths.length > 0)) || parts.length > 0;
    return (p) => {
      if (!applied) return false;
      if (parts.length === 0) return true;
      if (p.page) return pages.has(p.page);
      return true;
    };
  }

  /**
   * Add the proposals whose source's pages applied (idempotent: runs on every apply and when a pass
   * finishes after one). Duplicates are not added; a source left out never adds.
   */
  function commitJob(jobIn: Job, o: { applied?: boolean } = {}): FoundFile | undefined {
    const job = opts.getJob?.(jobIn.id) ?? jobIn;
    const f = loadFound(job);
    if (!f) return undefined;
    const ok = appliedCheck(job, !!o.applied);
    const ended = ['rejected', 'cancelled'].includes(job.state) || (job.state === 'completed' && !job.pendingPart);
    const types = findTypes('notes', false);
    const added: ActionItem[] = [];
    // Items from this same batch share quotes ("book the room and tell Mei"): among them only the title rule applies.
    const before = items.filter((i) => !(f.committed ?? []).includes(i.id));
    let changed = false;
    for (const p of f.proposals) {
      if (p.state !== 'waiting' && p.state !== 'notApplied') continue;
      if (!ok(p)) {
        if (ended && p.state === 'waiting') {
          p.state = 'notApplied';
          changed = true;
        }
        continue;
      }
      if (f.committed?.includes(p.item.id) || find(p.item.id)) {
        p.state = 'added';
        changed = true;
        continue;
      }
      const candidate: ActionItem = clone(p.item);
      // A type turned off since it was found comes in as a to-do (or is dropped when to-dos are off).
      if (candidate.type !== TODO_TYPE && !types.allowed.includes(candidate.type)) {
        candidate.type = TODO_TYPE;
        candidate.fields = withDefaults(TODO_TYPE, candidate.fields);
      }
      if (candidate.type === TODO_TYPE && !types.todos) {
        p.state = 'notApplied';
        changed = true;
        continue;
      }
      const dup = duplicateOf(candidate, before) ?? added.find((a) => a.type === candidate.type && normalizeText(a.title) === normalizeText(candidate.title));
      if (dup) {
        p.state = 'duplicate';
        p.existingID = dup.id;
        changed = true;
        continue;
      }
      // The original moves into the archive with the batch.
      if (candidate.source.kind === 'note' && candidate.source.raw) {
        const at = resolveOriginal(job.vaultPath, candidate.source.raw);
        if (at && at !== candidate.source.raw.path) {
          if (!candidate.source.raw.inboxPath && !candidate.source.raw.path.startsWith('.raw/')) candidate.source.raw.inboxPath = candidate.source.raw.path;
          candidate.source.raw.path = at;
        }
      }
      const t = isoDate(now());
      // actions-routing.md: Pending and Highlights items are never To confirm; an unclear owner always asks.
      candidate.status = !inLists(candidate)
        ? 'open'
        : types.confirm || candidate.ownerUnclear
          ? 'pending'
          : initialStatus(candidate.type, candidate.type === TODO_TYPE ? candidate.body : null);
      candidate.updatedAt = t;
      items.push(candidate);
      added.push(candidate);
      p.item = clone(candidate);
      p.state = 'added';
      f.committed = [...(f.committed ?? []), candidate.id];
      changed = true;
    }
    if (added.length > 0) {
      persist();
      for (const i of added) emit({ type: 'action', action: clone(i) });
      if (!types.confirm) {
        for (const i of added) if (i.status !== 'pending' && i.type !== TODO_TYPE && effective(i.type)?.draftWhen === 'onFind') draftInBackground(i.id);
      }
      const yours = added.filter(inLists);
      const what = describeByType(Object.fromEntries(Object.entries(yours.reduce<Record<string, number>>((m, i) => ((m[i.type] = (m[i.type] ?? 0) + 1), m), {}))));
      if (yours.length > 0) log('info', `${types.confirm ? `Found ${plural(yours.length, 'action')} to confirm` : `Added ${plural(yours.length, 'action')}`} from ${job.id}${what ? ` (${what})` : ''}.`);
      const routed = added.filter((i) => i.route !== undefined);
      if (routed.length > 0) {
        emit({
          type: 'actions.routed',
          jobID: job.id,
          lists: routed.filter((i) => i.route === 'list' && !i.ownerUnclear).length,
          waiting: routed.filter((i) => i.route === 'waiting').length,
          others: routed.filter((i) => i.route === 'others').length,
          unclear: routed.filter((i) => i.ownerUnclear).length,
        });
      }
    }
    // A later note that looks like a promise was delivered: a suggestion on the Pending item, once its page applied.
    for (const r of [...(f.received ?? [])]) {
      if (!ok({ item: {} as ActionItem, file: r.file, state: 'waiting', ...(r.page ? { page: r.page } : {}) })) continue;
      const w = find(r.id);
      if (w && w.route === 'waiting' && LIVE_STATUSES.includes(w.status) && !w.received) {
        mutate(w.id, (i) => {
          i.received = { notePath: r.page ?? r.file, pageTitle: r.title, quote: r.quote || null, at: isoDate(now()) };
          i.events.push(event(now(), 'looks-received', r.page ?? r.file));
        });
      }
      f.received = (f.received ?? []).filter((x) => x !== r);
      changed = true;
    }
    if (changed) saveFound(job, f);
    const summary = summaryOf(job, f);
    if (Object.keys(f.sources).length > 0) setSummary(job.id, summary);
    return f;
  }

  /** The sources of an applied batch without a side file (older jobs, Try again): originals, else their pages. */
  function sourcesOfApplied(job: Job): { sources: PassSource[]; written: Map<string, string> } {
    const vault = path.resolve(job.vaultPath);
    const written = new Map<string, string>();
    for (const rel of job.changedPaths) {
      if (!rel.endsWith('.md') || !rel.startsWith('wiki/')) continue;
      const lines = readLines(vault, rel);
      if (lines) written.set(rel, lines.join('\n'));
    }
    let records: ReturnType<typeof ledgerRecords>;
    try {
      records = ledgerRecords(vault);
    } catch {
      records = [];
    }
    const pages = [...written]
      .filter(([p]) => !SKIP_PAGES.some((re) => re.test(p)))
      .map(([p, text]) => {
        const sp = /^source_path:\s*["']?(.+?)["']?\s*$/m.exec(text.split('\n').slice(0, 40).join('\n'))?.[1];
        return { page: p, ...(sp ? { source: sp } : {}), text };
      });
    const pageFor = (file: string): PassSource['page'] => {
      const m = matchPage(file, pages, vault, records);
      return m ? { path: m.page, title: titleOfPage(m.text, m.page), text: m.text } : null;
    };
    const sources: PassSource[] = [];
    for (const file of job.files) {
      if (file.endsWith('.distill.json')) continue;
      if (!/\.(md|txt|markdown|text|vtt|srt|csv|html?)$/i.test(file)) continue;
      const page = pageFor(file);
      // Part of a batch: a source whose page didn't apply (removed, or left for later) isn't looked through here.
      if (!page && (job.parts?.length ?? 0) > 0) {
        log('info', `Finding actions in ${job.id}: ${file} has no applied page in this batch; not looked through.`);
        continue;
      }
      const abs = path.resolve(vault, file);
      if (abs.startsWith(vault + path.sep) && fs.existsSync(abs)) {
        sources.push({ file, page });
        continue;
      }
      // Gone from the inbox: its archived copy, through the ledger.
      const rec = records.find((r) => r.locator === file && r.sha256);
      const at = rec?.sha256 ? resolveOriginal(vault, { path: file, sha256: rec.sha256 }) : undefined;
      if (at) sources.push({ file, readFrom: at, page });
      else if (page) sources.push({ file: page.path, page, pageOnly: true, readFrom: page.path });
    }
    if (sources.length === 0) {
      // No text sources: the changed pages are what there is.
      for (const [p, text] of written) {
        if (SKIP_PAGES.some((re) => re.test(p))) continue;
        sources.push({ file: p, page: { path: p, title: titleOfPage(text, p), text }, pageOnly: true, readFrom: p });
      }
    }
    return { sources, written };
  }

  /** The last change each job showed in Review (Try again in Review reuses it). */
  const reviewInfo = new Map<string, ReviewReadyInfo>();

  /** The change a batch in Review shows, read from its bundle (Try again after a restart). */
  function reviewInfoFromBundle(job: Job): ReviewReadyInfo | undefined {
    const bundlePath = job.approval?.bundlePath;
    const b = bundlePath ? readBundle(bundlePath) : undefined;
    if (!b) return undefined;
    return {
      pages: sourcePages(b).map((p) => ({ page: p.page, ...(p.source ? { source: p.source } : {}), title: p.title, text: p.text })),
      written: wikiWrites(b),
    };
  }

  function reviewSourcesOf(job: Job, info: ReviewReadyInfo): PassSource[] {
    // Not part of this change: a hard stop (Review shows it), or sources a fresh session reads next (their own part).
    const out = new Set<string>([...(job.stopped ?? []).map((s) => s.file), ...(job.pendingPart?.unread ?? [])]);
    const files = job.files.filter((f) => !f.endsWith('.distill.json') && !out.has(f));
    let records: ReturnType<typeof ledgerRecords>;
    try {
      records = ledgerRecords(job.vaultPath);
    } catch {
      records = [];
    }
    const sources: PassSource[] = [];
    const claimed = new Set<string>();
    for (const file of files) {
      // A re-read or repair reads `.raw/captured/<sha>.md`, while its page keeps the inbox path: matched by content.
      const page = matchPage(file, info.pages, job.vaultPath, records);
      if (page) claimed.add(page.page);
      sources.push({ file, page: page ? { path: page.page, title: page.title, text: page.text } : null });
    }
    // One source and one page left over: they belong together.
    const loose = sources.filter((s) => !s.page);
    const free = info.pages.filter((p) => !claimed.has(p.page));
    if (loose.length === 1 && free.length === 1) loose[0]!.page = { path: free[0]!.page, title: free[0]!.title, text: free[0]!.text };
    return sources;
  }

  async function findForReview(job: Job, info: ReviewReadyInfo, o: { retry?: boolean } = {}): Promise<void> {
    reviewInfo.set(job.id, info);
    const sp = prefs().sources.notes;
    if (!sp.detectTodos && !sp.detectTypes) {
      setSummary(job.id, { status: 'skipped', found: 0, pending: 0, added: 0, byType: {}, stage: 'review' });
      return;
    }
    const written = new Map(info.written.map((w) => [w.path, w.text]));
    const sources = reviewSourcesOf(job, info);
    if (sources.length === 0) return;
    try {
      await runPass(job, sources, written, { stage: 'review', retry: !!o.retry });
    } catch (err) {
      log('warn', `Finding actions for ${job.id} failed: ${(err as Error).message}`);
    }
    // Approved meanwhile: add what applied.
    commitJob(job);
  }

  async function findInJob(job: Job, o: { retry?: boolean } = {}): Promise<void> {
    const existing = loadFound(job);
    // Try again while the batch is in Review: the sources that failed, from the change it shows.
    if (o.retry && job.state !== 'completed') {
      // After a restart the change is read again from the bundle Review shows.
      const info = reviewInfo.get(job.id) ?? reviewInfoFromBundle(job);
      if (info) await findForReview(job, info, { retry: true });
      else {
        const f = loadFound(job);
        setSummary(job.id, {
          ...(f ? summaryOf(job, f) : { found: 0, pending: 0, added: 0, byType: {}, stage: 'review' as const }),
          status: 'failed',
          error: 'Distill couldn’t read this batch’s change to look through it again.',
        });
      }
      return;
    }
    if (existing && !o.retry) {
      // A pass still running adds what applied when it ends.
      if (passes.has(job.id)) return;
      // Looked through in Review (or after an earlier apply): add what applied now.
      if (Object.values(existing.sources).every((s) => s.status === 'done')) {
        commitJob(job, { applied: true });
        return;
      }
      // A source not looked through in full (a window failed, or Distill quit meanwhile): once more,
      // by itself, now that the batch applied. Nothing is missed silently.
      o = { retry: true };
    }
    if (!existing) {
      if (o.retry) store.processedJobs = store.processedJobs.filter((id) => id !== job.id);
      if (store.processedJobs.includes(job.id)) return;
    }
    const sp = prefs().sources.notes;
    const markProcessed = () => {
      if (!store.processedJobs.includes(job.id)) store.processedJobs.push(job.id);
      persist();
    };
    if (!sp.detectTodos && !sp.detectTypes) {
      markProcessed();
      setSummary(job.id, { status: 'skipped', found: 0, pending: 0, added: 0, byType: {} });
      return;
    }
    const { sources, written } = existing && o.retry
      ? (() => {
          // Try again: the sources that failed, read as before.
          const all = sourcesOfApplied(job);
          const failed = new Set(Object.entries(existing.sources).filter(([, s]) => s.status !== 'done').map(([k]) => k));
          return { sources: all.sources.filter((s) => failed.has(s.file)), written: all.written };
        })()
      : sourcesOfApplied(job);
    if (sources.length === 0) {
      markProcessed();
      if (!existing) setSummary(job.id, { status: 'skipped', found: 0, pending: 0, added: 0, byType: {} });
      else commitJob(job, { applied: true });
      return;
    }
    // Recorded before the run so a restart never finds the same batch twice.
    markProcessed();
    try {
      await runPass(job, sources, written, { stage: 'applied', retry: !!o.retry });
    } catch (err) {
      const message = (err as Error).message;
      setSummary(job.id, { status: 'failed', found: 0, pending: 0, added: 0, byType: {}, error: message });
      log('warn', `Finding actions for ${job.id} failed: ${message}`);
      return;
    }
    commitJob(job, { applied: true });
  }

  async function jobEnded(job: Job): Promise<void> {
    if (loadFound(job)) commitJob(job);
  }

  async function jobActions(jobID: string): Promise<JobActions> {
    const job = opts.getJob?.(jobID);
    if (!job) throw new CoreError('not_found', `Unknown job ${jobID}.`);
    const f = loadFound(job);
    if (!f) return { summary: job.actionsFound ?? null, proposals: [] };
    // The item as it is now in Actions, for proposals already added.
    const proposals = f.proposals.map((p) => {
      const now = p.state === 'added' ? find(p.item.id) : undefined;
      return clone(now ? { ...p, item: now } : p);
    });
    return { summary: summaryOf(job, f), proposals };
  }

  // ───────────── Ask: raw context for found items (v11) ─────────────

  /** The cited pages' archived original and its closest lines; else wiki only. */
  function askContext(vaultPath: string, cited: string[], f: Found): Pick<Extract<ActionSource, { kind: 'ask' }>, 'raw' | 'wiki' | 'contextNote'> {
    const query = `${f.title} ${f.quote} ${f.why}`;
    const wiki: ActionWikiRef[] = [];
    let raw: ActionRawRef | undefined;
    let records: ReturnType<typeof ledgerRecords> | undefined;
    try {
      records = ledgerRecords(vaultPath);
    } catch {
      records = [];
    }
    let anyOriginal = false;
    for (const page of cited.slice(0, 3)) {
      const lines = readLines(vaultPath, page);
      if (lines && wiki.length < 2) {
        const text = lines.join('\n');
        const ref = wikiRef(page, text, bestHeading(text, query) ?? null);
        if (ref) wiki.push(ref);
      }
      if (raw?.lines) continue;
      const orig = originalOfPage(vaultPath, page, records);
      if (!orig) continue;
      anyOriginal = true;
      const olines = readLines(vaultPath, orig.path);
      if (!olines) continue;
      const hit = closestLines(olines, query);
      if (hit) {
        raw = {
          path: orig.path,
          ...(orig.inboxPath ? { inboxPath: orig.inboxPath } : {}),
          ...(orig.sha256 ? { sha256: orig.sha256 } : {}),
          lines: [hit.from, hit.to],
          excerpt: excerptOf(olines, hit.from, hit.to),
          match: 'closest',
        };
      } else if (!raw) {
        raw = { path: orig.path, ...(orig.inboxPath ? { inboxPath: orig.inboxPath } : {}), ...(orig.sha256 ? { sha256: orig.sha256 } : {}), match: 'none' };
      }
    }
    const out: Pick<Extract<ActionSource, { kind: 'ask' }>, 'raw' | 'wiki' | 'contextNote'> = {};
    if (raw) out.raw = raw;
    if (wiki.length > 0) out.wiki = wiki;
    if (!raw?.lines) {
      out.contextNote = anyOriginal
        ? 'No lines in the original match it closely; the wiki sections are its context.'
        : cited.length === 0
          ? 'The answer cites no pages.'
          : 'The cited pages have no archived original; the wiki sections are its context.';
    }
    return out;
  }

  function findTypeList(todos: boolean, allowed: string[]) {
    const ids = [...(todos ? [TODO_TYPE] : []), ...allowed];
    return ids.map((id) => {
      const def = actionTypeDef(id)!;
      return { id, label: def.label, recognizes: def.recognizes, fields: def.fields.map((f) => f.key) };
    });
  }

  async function detectAsk(conversationID: string, turnIndex: number | undefined, force: boolean, response?: AskResponse): Promise<ActionItem[]> {
    if (!opts.getConversation) throw new CoreError('not_implemented', 'detectAskActions: no Ask history');
    const conv = await opts.getConversation(conversationID);
    if (!conv) throw new CoreError('not_found', `Unknown conversation ${conversationID}.`);
    // The turn of this answer, even when a quick follow-up was saved meanwhile.
    let index = turnIndex ?? conv.turns.length - 1;
    if (turnIndex === undefined && response) {
      for (let k = conv.turns.length - 1; k >= 0; k--) {
        if (conv.turns[k]!.response.answer === response.answer) {
          index = k;
          break;
        }
      }
    }
    const turn = conv.turns[index];
    if (!turn) throw new CoreError('invalid_request', `Conversation ${conversationID} has no turn ${index}.`);
    const types = findTypes('ask', force);
    if (!types.todos && types.allowed.length === 0) return [];
    const p = prefs();
    const selection = selectionFor('actionFind', p.findSelection);
    const key = `actions:${conversationID}`;
    const startedAt = isoDate(now());
    const model = modelName(opts.runners, selection);
    progress({ key, kind: 'actions', message: 'Looking for actions in this answer…', startedAt, runnerID: selection.runnerID, model: selection.model });
    try {
      const cited = turn.response.citations.map((c) => c.path);
      const docs: FindDocument[] = [{ path: `ask:${conversationID}`, title: turn.request.question, text: `Question: ${turn.request.question}\n\nAnswer:\n${turn.response.answer}` }];
      let total = docs[0]!.text.length;
      for (const c of turn.response.citations.slice(0, 3)) {
        const abs = path.resolve(conv.vaultPath, c.path);
        if (!abs.startsWith(path.resolve(conv.vaultPath) + path.sep)) continue;
        const text = readText(abs, 4000);
        if (!text || total + text.length > MAX_TOTAL_CHARS) continue;
        total += text.length;
        docs.push({ path: c.path, title: c.title, text });
      }
      const out = await runStructured({
        runners: opts.runners,
        settings: opts.getSettings(),
        task: 'actionFind',
        selection,
        prompt: buildFindPrompt({
          instructions: p.findPrompt?.trim() ? p.findPrompt : DEFAULT_FIND_PROMPT,
          types: findTypeList(types.todos, types.allowed),
          documents: docs,
          today: isoDate(now()).slice(0, 10),
          extra: `Find actions in the Ask answer (the first document). The cited pages are context only: take an action from them only when the answer mentions it.`,
        }),
        schema: FIND_SCHEMA,
        scratchRoot,
      });
      const { added, existing } = addFound(parseFound(out.value), {
        source: (f) => ({
          kind: 'ask', conversationID, question: turn.request.question, quote: f.quote || null, citedPaths: cited,
          turnIndex: index, gap: fromGap(f, turn.response?.gaps),
          // v11: the cited pages' archived original (closest lines), else wiki only.
          ...askContext(conv.vaultPath, cited, f),
        }),
        vaultPath: conv.vaultPath,
        model: out.model,
        todos: types.todos,
        allowed: types.allowed,
        confirm: types.confirm,
        conversationID,
      });
      const results = [...added, ...existing.filter((e) => e.status !== 'dismissed')];
      const message = results.length === 0 ? 'No actions in this answer' : `Found ${plural(results.length, 'action')} · ${model}`;
      progress({ key, kind: 'actions', message, startedAt, finished: true });
      return results;
    } catch (err) {
      const message = (err as Error).message;
      progress({ key, kind: 'actions', message: 'Couldn’t look for actions', startedAt, finished: true, error: message });
      throw err;
    }
  }

  // ───────────── public API ─────────────

  // ───────────── buttons (action-buttons.md) ─────────────

  const approvals = new ButtonApprovals(path.join(opts.stateDir, 'actions', 'button-approvals.json'));
  const jiraMeta = new JiraMeta(atlassian, now);
  const people = new SlackPeople(path.join(opts.stateDir, 'actions', 'slack-people.json'));

  /** The vault whose remembered names apply: the item's, else the active one. */
  function peopleVault(vaultPath?: string | null): string | null {
    return vaultPath ?? opts.getSettings().activeVaultPath ?? null;
  }

  function slackTargetOf(item: ActionItem): SlackTarget {
    const vault = peopleVault(item.vaultPath);
    return resolveSlackTarget(item.fields.to, item.fields.thread, (n) => people.lookup(vault, n));
  }

  /**
   * A Slack message's `{fields.to}` is where it goes (a remembered name becomes its @handle) and
   * `{fields.thread}` the ts to reply under. A plain name, a group or a thread the button can't
   * reach refuses the run here, in plain words, before any argument is built.
   */
  function slackProblem(item: ActionItem, button: ActionButton, values: TemplateValues): string | undefined {
    const t = slackTargetOf(item);
    const uses = (key: string) => Object.values(button.bindings).some((b) => placeholdersIn(b).includes(key));
    values['fields.thread'] = t.threadTs ?? '';
    // A thread the item names but Distill can't read is never left out: that would post at the top level.
    if (uses('fields.thread') && t.kind === 'thread' && !t.threadTs) return t.problem;
    if (!uses('fields.to') && !uses('recipient')) return undefined;
    if (t.problem) return t.problem;
    values['fields.to'] = values.recipient = t.target ?? '';
    if (t.kind === 'thread' && !uses('fields.thread')) {
      return `This message replies in a thread, but ${button.label} doesn’t fill in a thread. Edit the button and set thread to {fields.thread}.`;
    }
    return undefined;
  }
  const buttonRuns = new Map<string, { stop(): void }>();

  interface ResolvedButton {
    collector?: Collector;
    command?: ScriptCommand;
    problem?: string;
  }

  async function resolveScript(button: ActionButton): Promise<ResolvedButton> {
    const scripts = opts.scripts?.();
    if (!scripts) return { problem: 'Automations aren’t running' };
    let collector: Collector | undefined;
    try {
      collector = await scripts.getCollector(button.scriptId);
    } catch {
      return { problem: 'Script missing' };
    }
    if (!collector) return { problem: 'Script missing' };
    if (collector.kind !== 'script' || !collector.script) return { collector, problem: `${collector.name} isn’t a script` };
    const command = (collector.script.commands ?? []).find((c) => c.id === button.commandId);
    if (!command) return { collector, problem: `${collector.name} has no command ${button.commandId}` };
    return { collector, command };
  }

  function buttonOf(typeId: string, buttonId: string): ActionButton {
    const b = buttonsFor(prefs(), typeId).find((x) => x.id === buttonId);
    if (!b) throw new CoreError('not_found', `No button ${buttonId} on ${typeId}.`);
    return b;
  }

  async function previewFor(item: ActionItem, button: ActionButton): Promise<ActionButtonPreview & { resolved: ResolvedButton }> {
    const resolved = await resolveScript(button);
    const out: ActionButtonPreview = { argv: [], display: '', problems: [], needsApproval: true, needsConsent: false, approvalHash: '' };
    if (resolved.problem || !resolved.collector?.script || !resolved.command) {
      out.problems.push(resolved.problem ?? 'Script missing');
      return { ...out, resolved };
    }
    const script = resolved.collector.script;
    const def = actionTypeDef(item.type);
    const ctx = promptContext(item);
    const values = templateValues(item, { fieldKeys: (def?.fields ?? []).map((f) => f.key), noteTitle: ctx.noteTitle, notePath: ctx.notePath, now: now() });
    const where = item.type === 'slack' ? slackProblem(item, button, values) : undefined;
    if (where) {
      out.problems.push(where);
      return { ...out, resolved };
    }
    const built = buildArgv(resolved.command, button.bindings, values);
    out.problems.push(...built.problems);
    const scriptPath = 'file' in script.source ? script.source.file : `(${resolved.collector.name}, kept by Distill)`;
    out.argv = [script.interpreter, scriptPath, ...built.args];
    out.display = displayArgv(out.argv);
    const consent = opts.scripts?.()?.scriptConsent(resolved.collector.id);
    if (!consent || 'problem' in consent) {
      out.problems.push(consent && 'problem' in consent ? consent.problem : 'Script missing');
      return { ...out, resolved };
    }
    out.needsConsent = !consent.allowed;
    out.approvalHash = approvalHash(consent.sha256, resolved.command, button);
    out.needsApproval = !approvals.approved(button.id, out.approvalHash);
    return { ...out, resolved };
  }

  async function buttonInfos(typeId: string): Promise<ActionButtonInfo[]> {
    const out: ActionButtonInfo[] = [];
    for (const b of buttonsFor(prefs(), typeId)) {
      const r = await resolveScript(b);
      let reason = r.problem ?? null;
      if (!reason && r.collector) {
        const consent = opts.scripts?.()?.scriptConsent(r.collector.id);
        if (consent && 'problem' in consent) reason = consent.problem;
        else if (consent && !consent.allowed) reason = `${r.collector.name} needs your OK`;
      }
      out.push({ ...b, available: b.enabled && !reason, reason, scriptName: r.collector?.name ?? null, commandLabel: r.command?.label ?? null });
    }
    return out;
  }

  async function runButton(id: string, buttonId: string, o: { approve?: boolean } = {}): Promise<{ run: ActionButtonRun; item: ActionItem; approved?: boolean }> {
    const item = require(id);
    const button = buttonOf(item.type, buttonId);
    if (!button.enabled) throw new CoreError('invalid_state', `${button.label} is turned off.`);
    if (item.activeRun || buttonRuns.has(id)) throw new CoreError('busy', 'A button is already running for this item.');
    const p = await previewFor(item, button);
    if (p.problems.length > 0) throw new CoreError('invalid_request', p.problems.join('; '), { problems: p.problems });
    if (p.needsConsent) throw new CoreError('invalid_state', `${p.resolved.collector!.name} needs your OK before its commands run.`, { needsConsent: true });
    if (p.needsApproval || button.confirm) {
      if (!o.approve) {
        const { resolved: _r, ...preview } = p;
        throw new CoreError('invalid_state', 'Check the command, then press Run.', { needsApproval: true, preview });
      }
      approvals.approve(button.id, p.approvalHash, now());
    }
    const approvedNow = p.needsApproval;
    const scripts = opts.scripts?.();
    if (!scripts) throw new CoreError('invalid_state', 'Automations aren’t running.');
    const command = p.resolved.command!;
    const handle = scripts.runCommand({
      collectorId: p.resolved.collector!.id,
      commandId: command.id,
      args: p.argv.slice(2),
      timeoutSeconds: commandTimeout(command),
      buttonId: button.id,
      actionId: id,
      actionType: item.type,
      itemJson: JSON.stringify(item),
    });
    buttonRuns.set(id, handle);
    const started: ActionButtonRun = { runId: handle.run.id, buttonId: button.id, label: button.label, startedAt: handle.run.startedAt, result: 'running' };
    const updated = mutate(id, (i) => {
      i.activeRun = { runId: handle.run.id, buttonId: button.id };
      i.runs = [started, ...(i.runs ?? [])].slice(0, 10);
      if (i.error?.code === 'other' && i.error.message.startsWith(`${button.label} `)) i.error = null;
    });
    track(
      handle.done.then((run) => {
        buttonRuns.delete(id);
        if (!find(id)) return;
        const parsed = run.result === 'success' ? parseResult(run.stdoutTail ?? '', command.result) : {};
        const tail = (t?: string) => (t ? maskSecrets(t).slice(-2048) : undefined);
        const result: ActionButtonRun = {
          ...started,
          endedAt: run.endedAt,
          durationMs: run.durationMs,
          result: run.result === 'success' ? 'success' : run.result === 'timedout' ? 'timedout' : run.result === 'stopped' ? 'stopped' : run.result === 'notTrusted' ? 'notTrusted' : 'failed',
          exitCode: run.exitCode ?? null,
          ...(tail(run.stdoutTail) ? { stdoutTail: tail(run.stdoutTail) } : {}),
          ...(tail(run.stderrTail) ? { stderrTail: tail(run.stderrTail) } : {}),
          ...(parsed.key || parsed.url ? { external: { key: parsed.key ?? null, url: parsed.url ?? null } } : {}),
          message: parsed.message ?? run.error?.message ?? null,
        };
        mutate(id, (i) => {
          i.activeRun = null;
          i.runs = [result, ...(i.runs ?? []).filter((r) => r.runId !== result.runId)].slice(0, 10);
          if (result.result === 'success') {
            if (button.storeResult && (parsed.key || parsed.url)) {
              i.external = { ...(i.external ?? {}), ...(parsed.key ? { key: parsed.key } : {}), ...(parsed.url ? { url: parsed.url } : {}), ...(parsed.status ? { status: parsed.status } : {}) };
            }
            if (button.onSuccess === 'markSent' && i.status !== 'sent') {
              i.events.push(event(now(), 'status', `${i.status} → sent`));
              i.status = 'sent';
            } else if (button.onSuccess === 'complete' && i.status !== 'done') {
              i.events.push(event(now(), 'done', i.status));
              i.status = 'done';
            }
            i.error = null;
            i.events.push(event(now(), 'ran', `${button.label}${result.message ? ` · ${result.message.slice(0, 200)}` : ''}`));
          } else {
            const why = result.result === 'timedout' ? 'timed out' : result.result === 'stopped' ? 'was stopped' : `failed${result.exitCode != null ? ` (exit ${result.exitCode})` : ''}`;
            i.error = { code: 'other', message: `${button.label} ${why}${run.error?.message && result.result !== 'stopped' ? `: ${run.error.message}` : ''}` };
            i.events.push(event(now(), 'run-failed', `${button.label} · ${why}`));
          }
        });
      }),
    );
    return { run: started, item: updated, ...(approvedNow ? { approved: true } : {}) };
  }

  /**
   * Add as (actions.md): a pending item comes in as `as.type`, in place (same id, its source, line,
   * wiki refs, why and labels kept), with an event `type` "todo → slack" and `confirmed` "as slack".
   */
  function confirmAs(id: string, as: ConfirmAs): ActionItem {
    const item = require(id);
    if (item.status !== 'pending') throw new CoreError('invalid_state', 'Only an item waiting for you to confirm can be added as another type.');
    const def = actionTypeDef(as.type);
    if (!def || !effectiveType(def, prefs()).enabled) throw new CoreError('invalid_request', `Can’t add it as ${as.type}: that type isn’t on.`);
    const fields = mappedFields(item, def.fields.map((f) => f.key));
    // A carried-over choice the new type doesn't have (a ticket's "Highest" for a to-do) is left out, never stored.
    for (const f of def.fields) if (f.kind === 'choice' && f.choices && fields[f.key] && !f.choices.includes(fields[f.key]!)) fields[f.key] = null;
    for (const [k, v] of Object.entries(as.fields ?? {})) {
      const spec = def.fields.find((f) => f.key === k);
      if (!spec) throw new CoreError('invalid_request', `${def.pluralLabel} have no field ${k}.`);
      const value = typeof v === 'string' && v.trim() ? v.trim() : null;
      if (value && spec.kind === 'choice' && spec.choices && !spec.choices.includes(value)) {
        throw new CoreError('invalid_request', `${spec.label} is one of ${spec.choices.join(', ')}.`);
      }
      fields[k] = value;
    }
    Object.assign(fields, withDefaults(def.id, fields));
    const missing = def.fields.filter((f) => f.required && !fields[f.key]?.trim()).map((f) => f.label);
    if (missing.length > 0) throw new CoreError('invalid_request', `Fill in ${missing.join(' and ')} first.`, { missing });
    const title = as.title?.trim() || item.title;
    const body = as.body !== undefined ? (as.body?.trim() ? as.body : null) : (item.body?.trim() || item.summary?.trim() || null);
    const from = item.type;
    const confirmed = mutate(id, (i) => {
      if (def.id !== i.type) i.events.push(event(now(), 'type', `${i.type} → ${def.id}`));
      i.type = def.id;
      i.title = title;
      i.body = body;
      i.fields = withDefaults(def.id, fields);
      i.status = initialStatus(i.type, i.body);
      i.events.push(event(now(), 'confirmed', from === def.id ? undefined : `as ${def.id} (found as ${from})`));
    });
    if (confirmed.type !== TODO_TYPE && !confirmed.body && effective(confirmed.type)?.draftWhen === 'onFind') draftInBackground(id);
    return confirmed;
  }

  /**
   * actions.md, Jira pickers: a drafted ticket's Priority in the project's own spelling ("medium" →
   * "Medium"); one the project doesn't have is left empty and the field marked. Best effort: not
   * connected or unreachable changes nothing.
   */
  async function alignJira(item: ActionItem): Promise<ActionItem> {
    const priority = item.fields.priority?.trim();
    if (item.type !== 'jira' || !priority || !item.fields.project?.trim() || !atlassian.isConnected()) return item;
    let check;
    try {
      check = await checkJiraDraft(jiraMeta, item.fields);
    } catch {
      return item;
    }
    if (!find(item.id)) return item;
    if (check.priority && check.priority !== priority) return mutate(item.id, (i) => (i.fields.priority = check.priority!));
    if (check.problem?.field === 'priority') {
      return mutate(item.id, (i) => {
        i.fields.priority = null;
        i.error = { code: 'refused', message: `${priority} isn’t a priority in ${check.project}, so it was left empty. Pick one.`, field: 'priority' };
        i.events.push(event(now(), 'edited', 'fields.priority'));
      });
    }
    return item;
  }

  /**
   * actions.md, Jira required fields: after a draft, an empty field the project + type asks for gets a
   * value the note names exactly (tagged "from the note"). Best effort. A saved value wins, but is never
   * copied onto the item: it applies at Create for this project + type only (a ticket moved to another
   * project with the same field doesn't carry it).
   */
  async function fillJiraRequired(item: ActionItem): Promise<ActionItem> {
    if (item.type !== 'jira' || !item.fields.project?.trim() || !atlassian.isConnected()) return item;
    let check;
    try {
      check = await checkJiraDraft(jiraMeta, item.fields);
    } catch {
      return item;
    }
    if (!check.fields || !check.project || !check.issueType || !find(item.id)) return item;
    const saved = prefs().types.jira?.requiredDefaults?.[defaultsKey(check.project, check.issueType)];
    const text = [item.title, item.body ?? '', item.summary ?? '', sourceQuote(item.source) ?? ''].join('\n');
    const patch: Record<string, string> = {};
    for (const f of extraFields(check.fields)) {
      if (!asked(f) && !saved?.[f.id]) continue;
      if (!isEmptyValue(item.fields[fieldKey(f.id)])) continue;
      if (saved?.[f.id]) continue;
      const v = fromNote(f, text);
      if (v) {
        patch[fieldKey(f.id)] = v;
        // Several choices: the names the note gave, so a chip added later isn't tagged.
        patch[fromKey(f.id)] = f.kind === 'options' ? v : 'note';
      }
    }
    if (Object.keys(patch).length === 0) return item;
    return mutate(item.id, (i) => Object.assign(i.fields, patch));
  }

  /** Jira's create page with the project, type, summary, description, priority and the fields Distill can fill. */
  async function jiraCreatePage(item: ActionItem): Promise<string> {
    const rec = atlassian.record();
    if (!rec) throw new CoreError('invalid_state', 'Jira isn’t connected.', { jira: 'not_connected' });
    const check = await checkJiraDraft(jiraMeta, item.fields);
    const q = new URLSearchParams();
    if (check.projectId) q.set('pid', check.projectId);
    if (check.typeId) q.set('issuetype', check.typeId);
    q.set('summary', item.title);
    if (item.body?.trim()) q.set('description', item.body);
    const prio = check.fields?.find((f) => f.id === 'priority')?.options?.find((o) => o.name === (check.priority ?? item.fields.priority));
    if (prio) q.set('priority', prio.id);
    if (check.fields && check.project && check.issueType) {
      const saved = prefs().types.jira?.requiredDefaults?.[defaultsKey(check.project, check.issueType)];
      for (const f of extraFields(check.fields)) {
        const raw = valueFor(f, item.fields, saved);
        if (raw === undefined) continue;
        const r = payloadValue(f, raw);
        if (!('value' in r)) continue;
        const v = r.value as { id?: string; child?: { id: string } } | { id: string }[] | string | number;
        if (Array.isArray(v)) for (const o of v) q.append(f.id, o.id);
        else if (typeof v === 'object' && v && 'id' in v && v.id) {
          q.set(f.id, v.id);
          if (v.child) q.set(`${f.id}:1`, v.child.id);
        } else if (typeof v === 'string' || typeof v === 'number') q.set(f.id, String(v));
      }
    }
    return `${rec.site.replace(/\/$/, '')}/secure/CreateIssueDetails!init.jspa?${q.toString()}`;
  }

  /** The found item's fields for another type: same keys kept; people become a message's To, and back. */
  function mappedFields(item: ActionItem, keys: string[]): Record<string, string | null> {
    const has = new Set(keys);
    const out: Record<string, string | null> = {};
    for (const [k, v] of Object.entries(item.fields)) if (has.has(k)) out[k] = v;
    const person = item.fields.person ?? item.fields.assignee ?? null;
    if (has.has('to') && !out.to && person) out.to = person;
    if (has.has('assignee') && !out.assignee && (item.fields.person ?? item.fields.to)) out.assignee = item.fields.person ?? item.fields.to ?? null;
    if (has.has('person') && !out.person && (item.fields.to ?? item.fields.assignee)) out.person = item.fields.to ?? item.fields.assignee ?? null;
    return out;
  }

  // ───────────── whose items: Pending and Highlights (actions-routing.md) ─────────────

  function requireRoute(id: string, route: 'waiting' | 'others', what: string): ActionItem {
    const item = require(id);
    if (item.route !== route || !LIVE_STATUSES.includes(item.status)) throw new CoreError('invalid_state', `${what}`);
    return item;
  }

  function peopleNow() {
    return peopleOf(prefs());
  }

  function ownerName(item: ActionItem): string {
    return displayName(item.ownerID, item.owner, peopleNow());
  }

  function notePathOf(item: ActionItem): string | null {
    return item.source.kind === 'note' ? (item.source.notePath ?? null) : null;
  }

  /** Others' actions of each page, as the page's section should list them. */
  function othersByPage(vaultPath: string | null): Map<string, { vault: string; lines: OthersLine[]; ids: string[] }> {
    const out = new Map<string, { vault: string; lines: OthersLine[]; ids: string[] }>();
    for (const i of items) {
      const page = notePathOf(i);
      if (!page || !i.vaultPath || !page.startsWith('wiki/') || !page.endsWith('.md')) continue;
      if (vaultPath && !samePath(i.vaultPath, vaultPath)) continue;
      // Every routed item of the page counts (an empty list removes a section that is there).
      if (i.route === undefined) continue;
      const key = `${path.resolve(i.vaultPath)}\n${page}`;
      const entry = out.get(key) ?? { vault: i.vaultPath, lines: [], ids: [] };
      if (i.route === 'others' && LIVE_STATUSES.includes(i.status)) {
        entry.lines.push({ person: ownerName(i), title: i.title, due: i.due ?? null });
        entry.ids.push(i.id);
      }
      out.set(key, entry);
    }
    return out;
  }

  /**
   * The pages whose Others' actions section differs from what the page holds now (compared, never
   * tracked: a batch that skipped one, or a rejected batch, leaves it due for the next).
   */
  function othersDue(vaultPath: string): { path: string; lines: string[] }[] {
    const due: { path: string; lines: string[] }[] = [];
    for (const [key, e] of othersByPage(vaultPath)) {
      const page = key.split('\n')[1]!;
      const facts = readPageFacts(e.vault, page, page);
      if (!facts) continue; // the page is gone
      const lines = othersSectionLines(e.lines);
      if (lines.length === 0 && facts.others === undefined) continue;
      if (sectionMatches(facts.others, lines)) continue;
      due.push({ path: page, lines });
    }
    return due.slice(0, MAX_OTHERS_PAGES);
  }

  function highlightOf(vaultPath: string, page: string, all: ActionItem[]): HighlightNote {
    const people = peopleNow();
    const fromNote = all.filter((i) => samePath(i.vaultPath, vaultPath) && notePathOf(i) === page && i.status !== 'dismissed');
    const first = fromNote.find((i) => i.source.kind === 'note' && i.source.pageTitle);
    const fallback = (first?.source.kind === 'note' ? first.source.pageTitle : null) ?? path.basename(page, '.md');
    // Only a wiki page is read (an item whose page wasn't matched points at its original: no wiki block).
    const facts = page.startsWith('wiki/') ? readPageFacts(vaultPath, page, fallback) : undefined;
    const live = fromNote.filter((i) => LIVE_STATUSES.includes(i.status));
    const others = live.filter((i) => i.route === 'others');
    const waiting = live.filter((i) => i.route === 'waiting');
    const lists = live.filter((i) => inLists(i));
    const onPage = new Set((facts?.others ?? []).map((l) => l.trim()));
    const byPerson = new Map<string, { person: string; personID: string | null; items: HighlightItem[] }>();
    for (const i of others) {
      const person = ownerName(i);
      const key = i.ownerID ?? `name:${person.toLowerCase()}`;
      const g = byPerson.get(key) ?? { person, personID: i.ownerID ?? null, items: [] };
      const line = i.source.kind === 'note' ? (i.source.raw?.lines?.[0] ?? null) : null;
      g.items.push({ id: i.id, title: i.title, due: i.due ?? null, line, onPage: onPage.has(othersLine({ person, title: i.title, due: i.due ?? null })) });
      byPerson.set(key, g);
    }
    const order = (id: string | null) => {
      const k = id ? people.findIndex((x) => x.id === id) : -1;
      return k < 0 ? people.length : k;
    };
    // People-list entries first, in list order; then others in the order they first appear in the note.
    const firstSeen = (g: { items: HighlightItem[] }): [string, number] => g.items
      .map((i): [string, number] => [find(i.id)?.createdAt ?? '9999', i.line ?? Number.MAX_SAFE_INTEGER])
      .reduce((m, x) => (x[0] < m[0] || (x[0] === m[0] && x[1] < m[1]) ? x : m), ['9999', Number.MAX_SAFE_INTEGER]);
    const seen = (a: { items: HighlightItem[] }, b: { items: HighlightItem[] }) => {
      const [x, y] = [firstSeen(a), firstSeen(b)];
      return x[0] !== y[0] ? (x[0] < y[0] ? -1 : 1) : x[1] - y[1];
    };
    const groups = [...byPerson.values()].sort((a, b) => order(a.personID) - order(b.personID) || seen(a, b) || a.person.localeCompare(b.person));
    const names: string[] = [];
    const you = people[0]!;
    if (fromNote.some((i) => i.ownerID === YOU_ID || i.owedToID === YOU_ID || inLists(i))) names.push(you.name.trim() || 'You');
    for (const i of fromNote) {
      // Whose it is, who it's for, and who a message goes to.
      const to = i.fields.to ?? i.fields.person ?? null;
      const named: [string | null | undefined, string | null | undefined][] = [[i.ownerID, i.owner], [i.owedToID, i.owedTo], [to ? matchPerson(to, people) : null, to]];
      for (const [id, written] of named) {
        if (id === YOU_ID || !(written ?? '').trim()) continue;
        const n = displayName(id, written, people);
        if (!names.includes(n)) names.push(n);
      }
    }
    const typeCounts: Record<string, number> = {};
    for (const i of lists) typeCounts[i.type] = (typeCounts[i.type] ?? 0) + 1;
    const foundAt = fromNote.reduce((m, i) => (i.createdAt > m ? i.createdAt : m), '');
    const date = facts?.date ?? /^\d{4}-\d{2}-\d{2}/.exec(facts?.title ?? fallback)?.[0] ?? foundAt.slice(0, 10);
    return {
      notePath: page,
      title: facts?.title ?? fallback,
      date,
      kind: facts?.meeting ? 'meeting' : 'note',
      ...(facts?.duration ? { duration: facts.duration } : {}),
      people: names,
      wiki: facts ? { path: page, title: facts.title, ...(facts.summary ? { summary: facts.summary } : {}), keyPoints: facts.keyPoints, decisions: facts.decisions } : null,
      others: groups,
      yours: { lists: typeCounts, waiting: waiting.map((i) => ({ id: i.id, person: ownerName(i), what: i.what ?? i.title })) },
      counts: { others: others.length, decisions: facts?.decisions.length ?? 0, lists: lists.length, waiting: waiting.length },
      foundAt,
    };
  }

  /** Notes with routed items (vault, page), newest first. */
  function highlightNotes(): { vault: string; page: string }[] {
    const seen = new Map<string, { vault: string; page: string; at: string }>();
    for (const i of items) {
      const page = notePathOf(i);
      if (!page || !i.vaultPath || i.route === undefined || i.status === 'dismissed') continue;
      const key = `${path.resolve(i.vaultPath)}\n${page}`;
      const at = seen.get(key)?.at ?? '';
      seen.set(key, { vault: i.vaultPath, page, at: i.createdAt > at ? i.createdAt : at });
    }
    return [...seen.values()].sort((a, b) => b.at.localeCompare(a.at));
  }

  const service: ActionsService = {
    async listActionTypes(): Promise<ActionTypeInfo[]> {
      const p = prefs();
      const conn = { connected: (id: string) => (id === ATLASSIAN ? atlassian.isConnected() : false) };
      const out: ActionTypeInfo[] = [];
      for (const d of actionTypeDefs()) {
        const info = typeInfo(d, p, conn);
        const buttons = await buttonInfos(d.id);
        if (buttons.length > 0) {
          info.buttons = buttons;
          // A button in the Send slot takes the reserved "Send in Slack" place.
          if (buttons.some((b) => b.slot === 'send')) info.handlers = info.handlers.filter((h) => h.id !== 'send');
        }
        out.push(info);
      }
      return out;
    },

    async previewActionButton(id, buttonId) {
      const item = require(id);
      const { resolved: _r, ...p } = await previewFor(item, buttonOf(item.type, buttonId));
      return p;
    },

    async previewButtonDraft(input) {
      const button = normalizeButton(input.button);
      if (!button) throw new CoreError('invalid_request', 'A button needs an id, a script and a command.');
      const def = actionTypeDef(input.typeId);
      if (!def) throw new CoreError('not_found', `Unknown action type ${input.typeId}.`);
      const item = input.itemId ? require(input.itemId) : sampleItem(def.id, def.fields.map((f) => f.key));
      const { resolved: _r, ...p } = await previewFor(item, button);
      return p;
    },

    runActionButton(id, buttonId, o) {
      return runButton(id, buttonId, o);
    },

    jiraProjects(o) {
      return jiraMeta.projects(o);
    },

    jiraIssueTypes(project, o) {
      return jiraMeta.issueTypes(project, o);
    },

    jiraFields(project, typeId, o) {
      return jiraMeta.fields(project, typeId, o);
    },

    jiraUsers(project, query) {
      return jiraMeta.users(project, query);
    },

    async jiraCreateURL(id) {
      const item = require(id);
      if (item.type !== 'jira') throw new CoreError('not_found', `${id} isn’t a Jira ticket.`);
      return { url: await jiraCreatePage(item) };
    },

    async listSlackPeople(vaultPath) {
      return people.list(vaultPath ?? null);
    },

    async rememberSlackPerson(input) {
      const name = (input.name ?? '').trim();
      if (!name) throw new CoreError('invalid_request', 'Which name is this?');
      const vault = peopleVault(input.vaultPath);
      if (!vault) throw new CoreError('invalid_state', 'Pick a vault first: names are remembered per vault.');
      const person = people.remember(vault, name, normalizeSlackTarget(input.target ?? ''), now());
      return person;
    },

    async forgetSlackPerson(input) {
      const vault = peopleVault(input.vaultPath);
      const forgotten = vault ? people.forget(vault, input.name ?? '') : false;
      return { forgotten };
    },

    async slackTarget(id) {
      const item = require(id);
      if (item.type !== 'slack') throw new CoreError('not_found', `${id} isn’t a Slack message.`);
      return slackTargetOf(item);
    },

    async stopActionButtonRun(id) {
      buttonRuns.get(id)?.stop();
    },

    async listActions(query: ActionQuery = {}): Promise<ActionItem[]> {
      maybeSweep();
      const text = query.text?.trim().toLowerCase();
      return items
        .filter((i) => {
          if (query.status && query.status.length > 0) {
            if (!query.status.includes(i.status)) return false;
          } else if (i.status === 'dismissed' || (!query.history && HISTORY_STATUSES.includes(i.status))) {
            return false;
          }
          if (query.type && i.type !== query.type) return false;
          // actions-routing.md: live items list by route (default your lists); History holds every route.
          const route = query.route ?? 'list';
          if (route !== 'all' && LIVE_STATUSES.includes(i.status) && (i.route ?? 'list') !== route) return false;
          if (query.vaultPath && i.vaultPath && path.resolve(i.vaultPath) !== path.resolve(query.vaultPath)) return false;
          if (text) {
            const hay = [i.title, i.body, i.why, sourceQuote(i.source), sourceNotePath(i.source), ...Object.values(i.fields)]
              .filter(Boolean)
              .join('\n')
              .toLowerCase();
            if (!hay.includes(text)) return false;
          }
          return true;
        })
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
        .map(clone);
    },

    async getAction(id: string): Promise<ActionItem | undefined> {
      const item = find(id);
      return item ? clone(item) : undefined;
    },

    async createAction(input: NewActionInput): Promise<ActionItem> {
      const title = (input.title ?? '').trim();
      if (!title) throw new CoreError('invalid_request', 'An action needs a title.');
      const def = actionTypeDef(input.type ?? TODO_TYPE);
      if (!def) throw new CoreError('invalid_request', `Unknown action type ${input.type}.`);
      if (!effectiveType(def, prefs()).enabled) throw new CoreError('invalid_request', `${def.pluralLabel} are turned off.`);
      const t = isoDate(now());
      const body = input.body?.trim() ? input.body : null;
      const source: ActionSource = input.source ?? { kind: 'manual' };
      const item: ActionItem = {
        id: newActionID(),
        type: def.id,
        status: initialStatus(def.id, body),
        title,
        body,
        fields: withDefaults(def.id, input.fields),
        why: input.why ?? null,
        source,
        ...(input.labels ? { labels: cleanLabels(input.labels) } : {}),
        vaultPath: input.vaultPath ?? opts.getSettings().activeVaultPath ?? null,
        createdAt: t,
        updatedAt: t,
        events: [event(now(), 'added', source.kind === 'ask' ? 'from Ask' : source.kind === 'manual' && source.by === 'agent' ? 'by an agent' : 'by you')],
      };
      const created = insert(item);
      if (!body && effective(def.id)?.draftWhen === 'onFind') draftInBackground(item.id);
      return created;
    },

    async updateAction(id: string, patch: ActionPatch): Promise<ActionItem> {
      const item = require(id);
      if (item.status === 'drafting' || item.status === 'creating') throw new CoreError('busy', 'Wait until it finishes, then edit.');
      const editable: ActionStatus[] = ['pending', 'open', 'ready', 'created'];
      if (!editable.includes(item.status)) throw new CoreError('invalid_state', `Can't edit an item that is ${item.status}.`);
      if (patch.type !== undefined && patch.type !== item.type) {
        if (!['pending', 'open', 'ready'].includes(item.status)) throw new CoreError('invalid_state', 'Only drafts and open items can change type.');
        const def = actionTypeDef(patch.type);
        if (!def || !effectiveType(def, prefs()).enabled) throw new CoreError('invalid_request', `Can't move it to ${patch.type}.`);
      }
      if (patch.title !== undefined && !patch.title.trim()) throw new CoreError('invalid_request', 'The title can’t be empty.');
      return mutate(id, (i) => {
        const changes: string[] = [];
        if (patch.title !== undefined && patch.title !== i.title) {
          i.title = patch.title.trim();
          changes.push('title');
        }
        if (patch.body !== undefined && patch.body !== i.body) {
          i.body = patch.body;
          i.previousBody = null; // Undo improve no longer applies after your edit
          changes.push('text');
        }
        if (patch.fields) {
          for (const [k, v] of Object.entries(patch.fields)) i.fields[k] = v;
          changes.push('fields');
        }
        if (patch.labels) {
          i.labels = cleanLabels(patch.labels);
          changes.push('labels');
        }
        if (patch.type !== undefined && patch.type !== i.type) {
          const from = i.type;
          i.type = patch.type;
          i.fields = withDefaults(i.type, i.fields);
          if (i.status !== 'pending') i.status = initialStatus(i.type, i.body);
          i.events.push(event(now(), 'type', `${from} → ${i.type}`));
        } else if (i.status === 'open' && i.type !== TODO_TYPE && i.body?.trim()) {
          i.status = 'ready';
        }
        i.error = null;
        if (changes.length > 0) i.events.push(event(now(), 'edited', changes.join(', ')));
      });
    },

    async confirmActions(ids: string[], o: { as?: ConfirmAs } = {}): Promise<ActionItem[]> {
      const out: ActionItem[] = [];
      for (const id of ids) require(id);
      if (o.as) {
        if (ids.length !== 1) throw new CoreError('invalid_request', 'Add as takes one item at a time.');
        return [confirmAs(ids[0]!, o.as)];
      }
      for (const id of ids) {
        const item = require(id);
        if (item.status !== 'pending') {
          out.push(clone(item));
          continue;
        }
        // A type turned off since it was found comes in as a to-do.
        const type = resolveTypeID(item.type, prefs());
        const confirmed = mutate(id, (i) => {
          if (type !== i.type) {
            i.events.push(event(now(), 'type', `${i.type} → ${type}`));
            i.type = type;
          }
          // action-summary.md: a to-do confirmed without a note takes its summary as the note.
          if (i.type === TODO_TYPE && !i.body?.trim() && i.summary?.trim()) i.body = i.summary;
          i.status = initialStatus(i.type, i.body);
          i.events.push(event(now(), 'confirmed'));
        });
        out.push(confirmed);
        if (confirmed.type !== TODO_TYPE && !confirmed.body && effective(confirmed.type)?.draftWhen === 'onFind') draftInBackground(id);
      }
      return out;
    },

    async dismissActions(ids: string[]): Promise<void> {
      for (const id of ids) {
        const item = require(id);
        const untouched =
          (['open', 'ready', 'drafting'] as ActionStatus[]).includes(item.status) &&
          item.events.every(
            (e, n, all) =>
              ['found', 'drafted', 'interrupted', 'confirmed'].includes(e.event) ||
              // Track as Pending, undone at once
              (e.event === 'pending' && all[n + 1]?.event === 'restored') ||
              (e.event === 'restored' && all[n - 1]?.event === 'pending') ||
              // confirm's to-do fallback for a type turned off since it was found
              (e.event === 'type' && all[n + 1]?.event === 'confirmed'),
          );
        if (item.status !== 'pending' && item.status !== 'dismissed' && !untouched) {
          throw new CoreError('invalid_state', `Only found items can be dismissed; remove this one instead.`);
        }
      }
      for (const id of ids) {
        if (require(id).status === 'dismissed') continue;
        controllers.get(id)?.abort();
        const prior = require(id).status;
        mutate(id, (i) => {
          i.status = 'dismissed';
          // Where it was, for Undo (restoreAction).
          i.events.push(event(now(), 'dismissed', prior === 'drafting' ? (i.body?.trim() ? 'ready' : 'open') : prior));
        });
      }
    },

    draftAction(id, o) {
      return draft(id, o?.signal);
    },

    summarizeAction(id, o) {
      return summarize(id, o?.signal);
    },

    improveAction(id, o) {
      return aiPass(id, 'improve', o?.signal);
    },

    async undoImprove(id: string): Promise<ActionItem> {
      const item = require(id);
      if (item.previousBody == null) throw new CoreError('invalid_state', 'There is no improve to undo.');
      if (item.status === 'drafting' || item.status === 'creating') throw new CoreError('busy', 'Wait until it finishes.');
      return mutate(id, (i) => {
        i.body = i.previousBody ?? null;
        i.previousBody = null;
        i.events.push(event(now(), 'improve-undone'));
      });
    },

    async performAction(id: string, handlerID: string): Promise<ActionItem> {
      const item = require(id);
      const def = actionTypeDef(item.type);
      const spec = def?.handlers.find((h) => h.id === handlerID);
      if (!def || !spec) throw new CoreError('invalid_request', `${def?.label ?? item.type} has no handler ${handlerID}.`);
      if (spec.reserved) throw new CoreError('invalid_request', `${spec.label} isn’t available yet.`);
      const fn = handlerFn(item.type, handlerID);
      if (!fn) throw new CoreError('not_implemented', `${spec.label}: not implemented`);
      if (item.status === 'drafting' || item.status === 'creating') throw new CoreError('busy', `This ${def.label.toLowerCase()} is busy.`);
      const allowed: Record<string, ActionStatus[]> = {
        copy: ['open', 'ready'],
        markSent: ['open', 'ready'],
        // Complete works from every live, non-busy state, and from sent (Mark as sent): pending (confirm or
        // dismiss it), removed, dismissed and done are refused.
        complete: ['open', 'ready', 'created', 'sent'],
        create: ['open', 'ready'],
        refresh: ['created'],
      };
      const ok = allowed[handlerID] ?? ['open', 'ready', 'created'];
      if (!ok.includes(item.status)) throw new CoreError('invalid_state', `Can't ${spec.label.toLowerCase()} an item that is ${item.status}.`);
      if (handlerID === 'complete' && item.status === 'sent' && [...item.events].reverse().find((e) => e.event === 'sent' || e.event.startsWith('sent-to:'))?.event.startsWith('sent-to:')) {
        // A to-do sent to another type lives on as that item; complete it there.
        throw new CoreError('invalid_state', 'It lives on as the item it was sent to; complete that one instead.');
      }
      if (handlerID === 'copy' && !item.body?.trim()) {
        throw new CoreError('invalid_state', 'There is no text to copy yet; write the draft first.');
      }
      const before = item.status;
      if (handlerID === 'create') {
        // Locked while it runs; a second press gets busy.
        mutate(id, (i) => {
          i.status = 'creating';
          i.error = null;
        });
      }
      try {
        const result = await fn({ item: clone(require(id)), settings: opts.getSettings(), now: now(), services: { atlassian, jiraMeta } });
        return mutate(id, (i) => {
          if (result.status) i.status = result.status;
          else if (i.status === 'creating') i.status = before;
          if (result.external !== undefined) i.external = result.external;
          i.error = null;
          i.events.push(event(now(), result.event, result.detail ?? null));
        });
      } catch (err) {
        const error =
          err instanceof ActionHandlerError ? err.error : { code: 'other' as const, message: (err as Error).message || 'It didn’t work.' };
        if (!(err instanceof ActionHandlerError) && err instanceof CoreError) {
          if (find(id)?.status === 'creating') mutate(id, (i) => (i.status = before));
          throw err;
        }
        return mutate(id, (i) => {
          if (i.status === 'creating') i.status = before;
          i.error = error;
          i.events.push(event(now(), 'failed', `${spec.label}: ${error.message}`));
        });
      }
    },

    async sendActionTo(id: string, typeID: string): Promise<ActionItem> {
      const item = require(id);
      if (!['pending', 'open', 'ready'].includes(item.status)) throw new CoreError('invalid_state', `Can't send an item that is ${item.status}.`);
      if (typeID === item.type) throw new CoreError('invalid_request', 'It is already that type.');
      const def = actionTypeDef(typeID);
      if (!def || !effectiveType(def, prefs()).enabled) throw new CoreError('invalid_request', `Can't send it to ${typeID}.`);
      const fields: Record<string, string | null> = {};
      const keys = new Set(def.fields.map((f) => f.key));
      for (const [k, v] of Object.entries(item.fields)) if (keys.has(k)) fields[k] = v;
      // A to-do's person is a message's recipient.
      if (keys.has('to') && !fields.to && item.fields.person) fields.to = item.fields.person;
      if (keys.has('person') && !fields.person && item.fields.to) fields.person = item.fields.to;
      const t = isoDate(now());
      const fromLabel = actionTypeDef(item.type)?.label ?? item.type;
      const next: ActionItem = {
        id: newActionID(),
        type: def.id,
        status: 'open',
        title: item.title,
        body: def.id === TODO_TYPE ? (item.body ?? null) : null,
        fields: withDefaults(def.id, fields),
        why: item.why ?? null,
        summary: item.summary ?? null,
        source: clone(item.source),
        vaultPath: item.vaultPath ?? null,
        createdAt: t,
        updatedAt: t,
        fromActionID: item.id,
        events: [event(now(), 'added', `sent from ${fromLabel}`)],
      };
      if (item.labels) next.labels = [...item.labels];
      mutate(id, (i) => {
        i.status = 'sent';
        i.events.push(event(now(), `sent-to:${def.id}`, next.id));
      });
      const created = insert(next);
      // "Send to" writes the draft right away.
      if (def.id !== TODO_TYPE) draftInBackground(next.id);
      return created;
    },

    async assignActionOwner(id: string, owner: string | null): Promise<ActionItem> {
      const item = require(id);
      if (item.status !== 'pending' || !inLists(item)) throw new CoreError('invalid_state', 'Only an item waiting for you to confirm can be assigned.');
      const people = peopleNow();
      const written = typeof owner === 'string' ? owner.trim() : '';
      if (owner !== null && !written) throw new CoreError('invalid_request', 'Whose is it? Give a person, or null for Not mine.');
      const byID = people.find((p) => p.id === written);
      const name = byID ? byID.name || (byID.id === YOU_ID ? 'me' : '') : written;
      return mutate(id, (i) => {
        if (owner === null) {
          // Not mine: someone else's, to the note's Highlights.
          i.route = 'others';
          i.ownerID = null;
          i.status = 'open';
          i.events.push(event(now(), 'routed', 'not mine → Highlights'));
        } else {
          const r = routeItem({ type: i.type, owner: byID?.id === YOU_ID ? 'me' : name, owedTo: i.owedTo ?? null }, prefs());
          i.owner = byID?.id === YOU_ID ? 'me' : name;
          i.ownerID = byID?.id ?? r.ownerID;
          i.route = byID && handlesFor(prefs(), i.type).includes(byID.id) ? 'list' : r.unclear ? 'list' : r.route;
          if (i.route !== 'list') i.status = 'open';
          i.events.push(event(now(), 'routed', `${displayName(i.ownerID, i.owner, people)} → ${i.route === 'list' ? 'your list' : i.route === 'waiting' ? 'Pending' : 'Highlights'}`));
        }
        delete i.ownerUnclear;
      });
    },

    async trackAsPending(id: string, req?: TrackPendingRequest): Promise<ActionItem> {
      const item = require(id);
      const by = req?.by == null ? null : String(req.by).trim() || null;
      if (by !== null && !/^\d{4}-\d{2}-\d{2}$/.test(by)) throw new CoreError('invalid_request', `“${by}” isn’t a date; use YYYY-MM-DD.`);
      const written = typeof req?.waitingOn === 'string' ? req.waitingOn.trim() : '';
      // Who: a People id, else a People name or alias, else the name as written.
      const people = peopleNow();
      const personID = people.find((p) => p.id === written)?.id ?? matchPerson(written, people) ?? null;
      if (written && personID === YOU_ID) throw new CoreError('invalid_request', 'You can’t wait on yourself; add it to your list instead.');
      const name = written ? displayName(personID, written, people) : '';
      if (item.route === 'others') {
        // Highlights: an Others' action already has its person.
        requireRoute(id, 'others', 'Only another person’s action can be tracked as Pending.');
        return mutate(id, (i) => {
          i.route = 'waiting';
          i.owedTo = 'me';
          i.owedToID = YOU_ID;
          i.what = i.what ?? null;
          if (written) {
            i.owner = name;
            i.ownerID = personID;
          }
          if (req?.by !== undefined) i.due = by;
          i.events.push(event(now(), 'routed', 'tracked as Pending'));
        });
      }
      // To confirm (any type) or an open to-do: the same item, now something you wait for.
      if (item.route === 'waiting') throw new CoreError('invalid_state', 'It is already in Pending.');
      const fromConfirm = item.status === 'pending';
      if (!fromConfirm && !LIVE_STATUSES.includes(item.status)) {
        throw new CoreError('invalid_state', `Only an item to confirm or an open to-do can go to Pending; this one is ${item.status}.`);
      }
      if (!fromConfirm && item.type !== TODO_TYPE) {
        const label = actionTypeDef(item.type)?.label ?? item.type;
        throw new CoreError('invalid_request', `Only a to-do can move to Pending; a ${label.toLowerCase()} you added is something you do.`);
      }
      if (item.status === 'drafting' || item.status === 'creating') throw new CoreError('busy', 'Wait until it finishes.');
      if (!written) throw new CoreError('invalid_request', 'Fill in who you’re waiting on.', { missing: ['Waiting on'] });
      const how = fromConfirm ? `found as ${item.type === TODO_TYPE ? 'to-do' : (actionTypeDef(item.type)?.label ?? item.type)}` : 'moved from To do';
      return mutate(id, (i) => {
        i.trackedFrom = {
          route: i.route ?? null,
          status: i.status,
          owner: i.owner ?? null,
          ownerID: i.ownerID ?? null,
          owedTo: i.owedTo ?? null,
          owedToID: i.owedToID ?? null,
          due: i.due ?? null,
          ownerUnclear: i.ownerUnclear === true,
        };
        i.route = 'waiting';
        i.status = 'open';
        i.owner = name;
        i.ownerID = personID;
        i.owedTo = 'me';
        i.owedToID = YOU_ID;
        i.due = by;
        delete i.ownerUnclear;
        i.events.push(event(now(), 'pending', `waiting on ${name} (${how})`));
      });
    },

    async claimAction(id: string): Promise<ActionItem> {
      requireRoute(id, 'others', 'Only another person’s action can be claimed.');
      const claimed = mutate(id, (i) => {
        i.route = 'list';
        i.owner = 'me';
        i.ownerID = YOU_ID;
        i.status = initialStatus(i.type, i.type === TODO_TYPE ? i.body : null);
        i.events.push(event(now(), 'claimed', 'it’s mine'));
      });
      if (claimed.type !== TODO_TYPE && effective(claimed.type)?.draftWhen === 'onFind') draftInBackground(id);
      return claimed;
    },

    async markReceived(id: string): Promise<ActionItem> {
      const item = requireRoute(id, 'waiting', 'Only something you are waiting for can be marked received.');
      return mutate(id, (i) => {
        i.status = 'done';
        i.events.push(event(now(), 'received', i.received ? `in ${i.received.pageTitle ?? i.received.notePath}` : null));
        i.events.push(event(now(), 'done', item.status));
      });
    },

    async stopWaiting(id: string): Promise<ActionItem> {
      const item = requireRoute(id, 'waiting', 'Only something you are waiting for can be stopped.');
      return mutate(id, (i) => {
        i.status = 'removed';
        i.events.push(event(now(), 'not-waiting'));
        i.events.push(event(now(), 'removed', item.status));
      });
    },

    async nudgeAction(id: string, message: { to: string; text: string }): Promise<{ item: ActionItem; message: ActionItem }> {
      const item = requireRoute(id, 'waiting', 'Only something you are waiting for can be nudged.');
      const to = (message?.to ?? '').trim();
      const text = (message?.text ?? '').trim();
      if (!to) throw new CoreError('invalid_request', 'Fill in who it goes to first.', { missing: ['To'] });
      if (!text) throw new CoreError('invalid_request', 'Write the message first.');
      const def = actionTypeDef('slack');
      if (!def || !effectiveType(def, prefs()).enabled) throw new CoreError('invalid_request', 'Slack messages are turned off.');
      const t = isoDate(now());
      const next: ActionItem = {
        id: newActionID(),
        type: 'slack',
        status: 'ready',
        title: `Nudge ${ownerName(item).split(/\s+/)[0]} about ${item.what ?? item.title}`,
        body: text,
        fields: withDefaults('slack', { to }),
        why: `You are waiting on ${ownerName(item)}: ${item.title}.`,
        source: clone(item.source),
        vaultPath: item.vaultPath ?? null,
        fromActionID: item.id,
        createdAt: t,
        updatedAt: t,
        events: [event(now(), 'added', 'nudge from Pending')],
      };
      const created = insert(next);
      const waiting = mutate(id, (i) => i.events.push(event(now(), 'nudged', next.id)));
      return { item: waiting, message: created };
    },

    async routingPreview(draft?: Pick<ActionPreferences, 'people' | 'types'>): Promise<RoutingPreview> {
      const saved = prefs();
      // The draft is read like Settings reads it (it comes over HTTP as plain JSON).
      const d = draft ? decodeActionPreferences({ ...(draft.people ? { people: draft.people } : {}), ...(draft.types ? { types: draft.types } : {}) }) : undefined;
      const p = { people: d?.people ?? saved.people ?? [], types: { ...saved.types, ...(d?.types ?? {}) } } as Pick<ActionPreferences, 'people' | 'types'>;
      const since = now().getTime() - PREVIEW_DAYS * DAY_MS;
      const out: RoutingPreview = { days: PREVIEW_DAYS, lists: 0, waiting: 0, others: 0, beforeRouting: 0 };
      for (const i of items) {
        if (i.source.kind !== 'note' || new Date(i.createdAt).getTime() < since) continue;
        // Only items the find step read an owner for (found while routing was on); the rest are named, not counted.
        if (i.route === undefined) {
          out.beforeRouting += 1;
          continue;
        }
        const r = routeItem({ type: i.type, owner: i.owner ?? null, owedTo: i.owedTo ?? null }, p);
        if (r.route === 'waiting') out.waiting += 1;
        else if (r.route === 'others') out.others += 1;
        else out.lists += 1;
      }
      return out;
    },

    async listHighlights(): Promise<HighlightNote[]> {
      return highlightNotes().map((n) => highlightOf(n.vault, n.page, items));
    },

    async getHighlight(notePath: string): Promise<HighlightNote> {
      const hit = highlightNotes().find((n) => n.page === notePath);
      if (!hit) throw new CoreError('not_found', `No Highlights for ${notePath}.`);
      return highlightOf(hit.vault, hit.page, items);
    },

    async removeAction(id: string): Promise<ActionItem> {
      const item = require(id);
      if (item.status === 'creating') throw new CoreError('busy', 'Wait until creating finishes.');
      if (item.status === 'removed' || item.status === 'dismissed') return clone(item);
      if (HISTORY_STATUSES.includes(item.status)) throw new CoreError('invalid_state', 'It is already in History.');
      controllers.get(id)?.abort();
      const prior = item.status === 'drafting' ? (item.body?.trim() ? 'ready' : 'open') : item.status;
      return mutate(id, (i) => {
        i.status = 'removed';
        i.events.push(event(now(), 'removed', prior));
      });
    },

    async restoreAction(id: string): Promise<ActionItem> {
      const item = require(id);
      if (item.route === 'waiting' && item.trackedFrom && LIVE_STATUSES.includes(item.status)) {
        // Undo of Track as Pending: back where it was, with the same status and fields, while nothing has
        // happened to it in Pending since.
        if (item.events.at(-1)?.event !== 'pending') throw new CoreError('invalid_state', 'It has changed in Pending since; it stays there.');
        const from = item.trackedFrom;
        return mutate(id, (i) => {
          if (from.route) i.route = from.route;
          else delete i.route;
          i.status = from.status;
          // Absent stays absent, so the item reads exactly as before.
          for (const k of ['owner', 'ownerID', 'owedTo', 'owedToID', 'due'] as const) {
            if (from[k] === null) delete i[k];
            else i[k] = from[k];
          }
          if (from.ownerUnclear) i.ownerUnclear = true;
          delete i.trackedFrom;
          i.events.push(event(now(), 'restored', 'from Pending'));
        });
      }
      const back = (x: string | null | undefined, fallback: ActionStatus): ActionStatus =>
        (['pending', 'open', 'ready', 'created'] as ActionStatus[]).includes(x as ActionStatus) ? (x as ActionStatus) : fallback;
      const lastEvent = (pred: (name: string) => boolean) => [...item.events].reverse().find((e) => pred(e.event));
      let status: ActionStatus;
      /** Undo of "Send to": the untouched item it became goes away. */
      let dropID: string | undefined;
      switch (item.status) {
        case 'removed':
          status = back(lastEvent((n) => n === 'removed')?.detail, 'open');
          break;
        case 'done': {
          // Complete records the status it left; an automatic Done (Jira / Confluence) doesn't, so a
          // created item goes back to created and anything else to its first live status.
          const left = lastEvent((n) => n === 'done')?.detail;
          status = (['open', 'ready', 'created', 'sent'] as ActionStatus[]).includes(left as ActionStatus)
            ? (left as ActionStatus)
            : item.external?.key ? 'created' : initialStatus(item.type, item.body);
          if (status === 'created' && !item.external?.key) status = initialStatus(item.type, item.body);
          break;
        }
        case 'dismissed':
          // Undo of Dismiss: back to "to confirm" (or where an auto-added item was).
          status = back(lastEvent((n) => n === 'dismissed')?.detail, 'pending');
          break;
        case 'sent': {
          const last = lastEvent((n) => n === 'sent' || n.startsWith('sent-to:'));
          if (last?.event.startsWith('sent-to:')) {
            const next = last.detail ? find(last.detail) : undefined;
            if (next) {
              const untouched =
                (['pending', 'open', 'ready', 'drafting'] as ActionStatus[]).includes(next.status) &&
                next.events.every((e) => ['added', 'drafted', 'interrupted'].includes(e.event));
              if (!untouched) {
                const where = actionTypeDef(next.type)?.pluralLabel ?? next.type;
                throw new CoreError('invalid_state', `It lives on in ${where}; remove it there instead.`);
              }
              dropID = next.id;
            }
          }
          // Undo of Mark as sent / Send to.
          status = item.type === TODO_TYPE ? 'open' : initialStatus(item.type, item.body);
          break;
        }
        default:
          throw new CoreError('invalid_state', 'Only removed, completed, sent or dismissed items can be restored.');
      }
      const type = resolveTypeID(item.type, prefs());
      const changedType = type !== item.type;
      if (dropID) {
        controllers.get(dropID)?.abort();
        const dropped = find(dropID)!;
        items = items.filter((i) => i.id !== dropID);
        persist();
        emit({ type: 'action', action: clone(dropped), deleted: true });
      }
      return mutate(id, (i) => {
        if (changedType) {
          i.events.push(event(now(), 'type', `${i.type} → ${type}`));
          i.type = type;
          if (status === 'ready' || status === 'created') status = 'open';
        }
        i.status = status;
        i.events.push(event(now(), 'restored', changedType ? 'as a to-do' : null));
      });
    },

    async deleteActionForever(id: string): Promise<void> {
      const item = require(id);
      if (![...HISTORY_STATUSES, 'dismissed'].includes(item.status)) {
        throw new CoreError('invalid_state', 'Only items in History can be deleted forever; remove it first.');
      }
      items = items.filter((i) => i.id !== id);
      persist();
      emit({ type: 'action', action: clone(item), deleted: true });
    },

    detectAskActions(conversationID: string, turnIndex?: number) {
      return detectAsk(conversationID, turnIndex, true);
    },

    async listConnections(): Promise<ConnectionInfo[]> {
      return [atlassian.info(usedBy(ATLASSIAN)), slackInfo()];
    },

    async connect(id: string, req: ConnectRequest): Promise<ConnectionInfo> {
      if (id === 'slack') throw new CoreError('invalid_request', 'Slack isn’t needed yet: Copy works without connecting.');
      if (id !== ATLASSIAN) throw new CoreError('not_found', `Unknown connection ${id}.`);
      await atlassian.connect(req.site, req.email, req.token);
      return connectionInfo(id);
    },

    async signInURL(id: string, _site?: string): Promise<{ url: string }> {
      if (id === ATLASSIAN) return { url: API_TOKEN_URL };
      if (id === 'slack') throw new CoreError('invalid_request', 'Slack isn’t needed yet: Copy works without connecting.');
      throw new CoreError('not_found', `Unknown connection ${id}.`);
    },

    async disconnect(id: string): Promise<ConnectionInfo> {
      if (id === 'slack') return slackInfo();
      if (id !== ATLASSIAN) throw new CoreError('not_found', `Unknown connection ${id}.`);
      await atlassian.disconnect();
      return connectionInfo(id);
    },

    findInJob: (job, o) =>
      track(findInJob(job, o).catch((err: unknown) => log('warn', `Finding actions for ${job.id} failed: ${(err as Error).message}`))),

    afterAsk: (conversationID, response) =>
      track(
        (async () => {
          const sp = prefs().sources.ask;
          if (!sp.detectTodos && !sp.detectTypes) return;
          await detectAsk(conversationID, undefined, false, response);
        })().catch((err: unknown) => log('warn', `Finding actions in an answer failed: ${(err as Error).message}`)),
      ),

    findForReview: (job, info) =>
      track(findForReview(job, info).catch((err: unknown) => log('warn', `Finding actions for ${job.id} failed: ${(err as Error).message}`))),

    jobEnded: (job) => track(jobEnded(job).catch((err: unknown) => log('warn', `Actions of ${job.id}: ${(err as Error).message}`))),

    jobActions,

    othersActionsPrompt: (vaultPath) => othersPrompt(othersDue(vaultPath)),

    sweepHistory,

    async whenIdle() {
      while (inflight.size > 0) await Promise.allSettled([...inflight]);
    },
  };
  return service;
}

/** True when a found item restates one of the answer's gaps (so clients drop that Gap callout). */
export function fromGap(f: { title?: string | null; quote?: string | null }, gaps: unknown): boolean {
  if (!Array.isArray(gaps)) return false;
  const norm = (t: unknown) => (typeof t === 'string' ? t.toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim() : '');
  const words = (t: string) => new Set(t.split(' ').filter((w) => w.length > 3));
  const mine = words(`${norm(f.title)} ${norm(f.quote)}`);
  return gaps.some((g) => {
    const gw = words(norm(g));
    if (gw.size === 0) return false;
    let shared = 0;
    for (const w of gw) if (mine.has(w)) shared++;
    return shared / gw.size >= 0.5;
  });
}

/** Labels as stored: trimmed, without a leading #, no blanks, no duplicates (case-insensitive), in order. */
export function cleanLabels(labels: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of labels) {
    const l = String(raw).trim().replace(/^#+/, '').trim();
    if (!l || seen.has(l.toLowerCase())) continue;
    seen.add(l.toLowerCase());
    out.push(l);
  }
  return out;
}
