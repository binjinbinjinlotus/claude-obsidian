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
  type AskConversation,
  type ConnectionInfo,
  type ConnectRequest,
  type CoreEvent,
  type DistillCore,
  type Job,
  type JobActionsSummary,
  type ModelSelection,
  type NewActionInput,
  type Progress,
  type RunnerRegistry,
  type Settings,
} from '../contracts.js';
import type { ActionsOwned } from '../engine/index.js';
import type { FetchLike } from '../runners/model-api.js';
import { defaultSecretStore, type SecretStore } from '../runners/secrets.js';
import { isoDate } from '../store/json.js';
import { actionPreferences, defaultSelection as settingsDefaultSelection } from '../store/settings.js';
import { DRAFT_SCHEMA, FIND_SCHEMA, fieldsFrom, IMPROVE_SCHEMA, modelName, runStructured, type ActionTask } from './ai.js';
import { ActionHandlerError, API_TOKEN_URL, ATLASSIAN, AtlassianClient, ConnectionFile } from './atlassian.js';
import { buildDraftPrompt, buildFindPrompt, buildImprovePrompt, DEFAULT_FIND_PROMPT, type FindDocument } from './prompts.js';
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
}

export type ActionsService = Pick<DistillCore, ActionsOwned> & {
  /** After a batch is applied: the "Finding actions" step. Never throws. */
  findInJob(job: Job): Promise<void>;
  /** After an Ask answer: background detection when Settings say so. Never throws. */
  afterAsk(conversationID: string): Promise<void>;
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
/** Pages that never hold actions of their own. */
const SKIP_PAGES = [/^wiki\/(log|hot|index)\.md$/, /^wiki\/meta\//, /^\.raw\//, /^\.vault-meta\//, /(^|\/)_index\.md$/];

const clone = <T>(v: T): T => structuredClone(v);

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

/** Same source note + quote, or same normalized title and type. */
export function isDuplicate(a: Pick<ActionItem, 'type' | 'title' | 'source'>, b: Pick<ActionItem, 'type' | 'title' | 'source'>): boolean {
  const qa = normalizeText(sourceQuote(a.source));
  const qb = normalizeText(sourceQuote(b.source));
  if (qa && qa === qb) {
    if (a.source.kind === 'note' && b.source.kind === 'note' && sourceNotePath(a.source) === sourceNotePath(b.source)) return true;
    if (a.source.kind === 'ask' && b.source.kind === 'ask' && a.source.conversationID === b.source.conversationID) return true;
  }
  return a.type === b.type && normalizeText(a.title) !== '' && normalizeText(a.title) === normalizeText(b.title);
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

function readText(file: string, max: number): string | undefined {
  try {
    const text = fs.readFileSync(file, 'utf8');
    return text.length > max ? `${text.slice(0, max)}\n[…truncated]` : text;
  } catch {
    return undefined;
  }
}

function titleOf(text: string, file: string): string {
  const fm = /^---\n(?:[\s\S]*?\n)?title:\s*["']?(.+?)["']?\s*\n[\s\S]*?---/.exec(text);
  if (fm?.[1]) return fm[1];
  const h = /^#\s+(.+)$/m.exec(text);
  return h?.[1]?.trim() ?? path.basename(file, path.extname(file));
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
    if (!item || !canDraft(item) || item.body?.trim()) return;
    void track(draft(id).catch((err: unknown) => log('warn', `Draft for ${id} failed: ${(err as Error).message}`)));
  }

  // ───────────── AI: draft / improve ─────────────

  function promptContext(item: ActionItem): PromptContext {
    const src = item.source;
    const notePath = src.kind === 'note' ? (src.notePath ?? null) : src.kind === 'ask' ? (src.citedPaths?.[0] ?? null) : null;
    const noteTitle = src.kind === 'note' ? (src.pageTitle ?? (notePath ? path.basename(notePath, '.md') : null)) : null;
    return { item, noteTitle, notePath, today: isoDate(now()).slice(0, 10) };
  }

  function noteTextFor(item: ActionItem): string | undefined {
    const src = item.source;
    const rel = src.kind === 'note' ? src.notePath : src.kind === 'ask' ? src.citedPaths?.[0] : undefined;
    if (!rel || !item.vaultPath) return undefined;
    const abs = path.resolve(item.vaultPath, rel);
    if (!abs.startsWith(path.resolve(item.vaultPath) + path.sep)) return undefined;
    return readText(abs, MAX_DOC_CHARS);
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
      const prompt = kind === 'draft' ? buildDraftPrompt(eff, snapshot, ctx, noteTextFor(snapshot)) : buildImprovePrompt(eff, snapshot, ctx);
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

  // ───────────── finding ─────────────

  interface Found {
    type: string;
    title: string;
    body: string | null;
    fields: Record<string, string>;
    why: string;
    quote: string;
    notePath: string | null;
  }

  function parseFound(value: Record<string, unknown>): Found[] {
    const raw = Array.isArray(value.items) ? value.items : [];
    const out: Found[] = [];
    for (const r of raw.slice(0, MAX_FOUND)) {
      if (typeof r !== 'object' || r === null) continue;
      const o = r as Record<string, unknown>;
      const title = typeof o.title === 'string' ? o.title.trim() : '';
      if (!title) continue;
      out.push({
        type: typeof o.type === 'string' ? o.type.trim() : TODO_TYPE,
        title: title.slice(0, 300),
        body: typeof o.body === 'string' && o.body.trim() ? o.body.trim() : null,
        fields: fieldsFrom(o.fields),
        why: typeof o.why === 'string' ? o.why.trim() : '',
        quote: typeof o.quote === 'string' ? o.quote.trim().slice(0, 600) : '',
        notePath: typeof o.notePath === 'string' && o.notePath.trim() ? o.notePath.trim() : null,
      });
    }
    return out;
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
    for (const f of found) {
      let type = o.allowed.includes(f.type) ? f.type : TODO_TYPE;
      if (type === TODO_TYPE && !o.todos) continue;
      const source = o.source(f);
      const candidate = { type, title: f.title, source };
      const dup = items.find(
        (i) =>
          (LIVE_STATUSES.includes(i.status) ||
            (i.status === 'dismissed' && o.conversationID && i.source.kind === 'ask' && i.source.conversationID === o.conversationID)) &&
          isDuplicate(i, candidate),
      );
      if (dup) {
        if (!existing.includes(dup)) existing.push(dup);
        continue;
      }
      if (added.some((a) => isDuplicate(a, candidate))) continue;
      const eff = effective(type);
      if (!eff) type = TODO_TYPE;
      const fields = withDefaults(type, f.fields);
      const t = isoDate(now());
      const item: ActionItem = {
        id: newActionID(),
        type,
        status: o.confirm ? 'pending' : initialStatus(type, type === TODO_TYPE ? f.body : null),
        title: f.title,
        body: type === TODO_TYPE ? f.body : null,
        fields,
        why: f.why || null,
        source,
        vaultPath: o.vaultPath,
        createdAt: t,
        updatedAt: t,
        draftModel: null,
        events: [event(now(), 'found', `by ${o.model}`)],
      };
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

  function summarize(added: ActionItem[], confirm: boolean, model: string): JobActionsSummary {
    const byType: Record<string, number> = {};
    for (const i of added) byType[i.type] = (byType[i.type] ?? 0) + 1;
    return { status: 'done', found: added.length, pending: confirm ? added.length : 0, added: confirm ? 0 : added.length, byType, model };
  }

  function documentsForJob(job: Job): FindDocument[] {
    const vault = path.resolve(job.vaultPath);
    const rels = [
      ...job.changedPaths.filter((p) => p.endsWith('.md') && !SKIP_PAGES.some((re) => re.test(p))),
      ...job.files.filter((p) => /\.(md|txt|markdown)$/i.test(p)),
    ];
    const docs: FindDocument[] = [];
    let total = 0;
    for (const rel of [...new Set(rels)]) {
      const abs = path.resolve(vault, rel);
      if (!abs.startsWith(vault + path.sep)) continue;
      const text = readText(abs, MAX_DOC_CHARS);
      if (!text?.trim()) continue;
      if (total + text.length > MAX_TOTAL_CHARS) break;
      total += text.length;
      docs.push({ path: rel, title: titleOf(text, rel), text });
    }
    return docs;
  }

  async function findInJob(job: Job): Promise<void> {
    if (store.processedJobs.includes(job.id)) return;
    const setSummary = (s: JobActionsSummary) => {
      try {
        opts.setJobActions?.(job.id, s);
      } catch {
        /* the job may be gone */
      }
    };
    const types = findTypes('notes', false);
    const sp = prefs().sources.notes;
    const markProcessed = () => {
      store.processedJobs.push(job.id);
      persist();
    };
    if (!sp.detectTodos && !sp.detectTypes) {
      markProcessed();
      setSummary({ status: 'skipped', found: 0, pending: 0, added: 0, byType: {} });
      return;
    }
    const docs = documentsForJob(job);
    if (docs.length === 0) {
      markProcessed();
      setSummary({ status: 'skipped', found: 0, pending: 0, added: 0, byType: {} });
      return;
    }
    const p = prefs();
    const selection = selectionFor('actionFind', p.findSelection);
    const model = modelName(opts.runners, selection);
    const startedAt = isoDate(now());
    const base = { key: job.id, kind: 'batch' as const, steps: FIND_STEPS, startedAt, runnerID: selection.runnerID, model: selection.model };
    progress({ ...base, message: `Finding actions in ${plural(docs.length, 'note')}`, stepIndex: FIND_STEPS.indexOf('Finding actions') });
    setSummary({ status: 'finding', found: 0, pending: 0, added: 0, byType: {}, model });
    // Recorded before the run so a restart never finds the same batch twice.
    markProcessed();
    try {
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
        }),
        schema: FIND_SCHEMA,
        scratchRoot,
      });
      const titles = new Map(docs.map((d) => [d.path, d.title ?? null]));
      const sourceNote = job.files[0] ?? docs[0]!.path;
      const { added } = addFound(parseFound(out.value), {
        source: (f) => {
          const notePath = f.notePath && titles.has(f.notePath) ? f.notePath : sourceNote;
          return { kind: 'note', jobID: job.id, notePath, pageTitle: titles.get(notePath) ?? null, quote: f.quote || null };
        },
        vaultPath: job.vaultPath,
        model: out.model,
        todos: types.todos,
        allowed: types.allowed,
        confirm: types.confirm,
      });
      const summary = summarize(added, types.confirm, out.model);
      setSummary(summary);
      const what = describeByType(summary.byType);
      const message =
        added.length === 0
          ? 'No actions found'
          : types.confirm
            ? `Found ${plural(added.length, 'action')} to confirm`
            : `Added ${plural(added.length, 'action')}`;
      progress({ ...base, message: what ? `${message}: ${what}` : message, stepIndex: FIND_STEPS.length - 1, finished: true });
      if (added.length > 0) log('info', `${message} from ${job.id}${what ? ` (${what})` : ''}.`);
    } catch (err) {
      const message = (err as Error).message;
      setSummary({ status: 'failed', found: 0, pending: 0, added: 0, byType: {}, error: message, model });
      progress({ ...base, message: 'Couldn’t find actions', stepIndex: FIND_STEPS.indexOf('Finding actions'), finished: true, error: message });
      log('warn', `Finding actions for ${job.id} failed: ${message}`);
    }
  }

  function findTypeList(todos: boolean, allowed: string[]) {
    const ids = [...(todos ? [TODO_TYPE] : []), ...allowed];
    return ids.map((id) => {
      const def = actionTypeDef(id)!;
      return { id, label: def.label, recognizes: def.recognizes, fields: def.fields.map((f) => f.key) };
    });
  }

  async function detectAsk(conversationID: string, turnIndex: number | undefined, force: boolean): Promise<ActionItem[]> {
    if (!opts.getConversation) throw new CoreError('not_implemented', 'detectAskActions: no Ask history');
    const conv = await opts.getConversation(conversationID);
    if (!conv) throw new CoreError('not_found', `Unknown conversation ${conversationID}.`);
    const index = turnIndex ?? conv.turns.length - 1;
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
        source: (f) => ({ kind: 'ask', conversationID, question: turn.request.question, quote: f.quote || null, citedPaths: cited }),
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

  const service: ActionsService = {
    async listActionTypes(): Promise<ActionTypeInfo[]> {
      const p = prefs();
      const conn = { connected: (id: string) => (id === ATLASSIAN ? atlassian.isConnected() : false) };
      return actionTypeDefs().map((d) => typeInfo(d, p, conn));
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
        vaultPath: input.vaultPath ?? opts.getSettings().activeVaultPath ?? null,
        createdAt: t,
        updatedAt: t,
        events: [event(now(), 'added', source.kind === 'ask' ? 'from Ask' : 'by you')],
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

    async confirmActions(ids: string[]): Promise<ActionItem[]> {
      const out: ActionItem[] = [];
      for (const id of ids) require(id);
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
          item.events.every((e) => ['found', 'drafted', 'interrupted'].includes(e.event));
        if (item.status !== 'pending' && item.status !== 'dismissed' && !untouched) {
          throw new CoreError('invalid_state', `Only found items can be dismissed; remove this one instead.`);
        }
      }
      for (const id of ids) {
        if (require(id).status === 'dismissed') continue;
        controllers.get(id)?.abort();
        mutate(id, (i) => {
          i.status = 'dismissed';
          i.events.push(event(now(), 'dismissed'));
        });
      }
    },

    draftAction(id, o) {
      return draft(id, o?.signal);
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
        complete: ['open', 'ready', 'created'],
        create: ['open', 'ready'],
        refresh: ['created'],
      };
      const ok = allowed[handlerID] ?? ['open', 'ready', 'created'];
      if (!ok.includes(item.status)) throw new CoreError('invalid_state', `Can't ${spec.label.toLowerCase()} an item that is ${item.status}.`);
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
        const result = await fn({ item: clone(require(id)), settings: opts.getSettings(), now: now(), services: { atlassian } });
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
      if (item.status !== 'removed' && item.status !== 'done') {
        throw new CoreError('invalid_state', item.status === 'sent' ? 'A sent item lives on where it was sent; it can’t be restored.' : 'Only removed or completed items can be restored.');
      }
      const lastRemoved = [...item.events].reverse().find((e) => e.event === 'removed');
      let status: ActionStatus;
      if (item.status === 'removed') {
        const prior = (lastRemoved?.detail ?? '') as ActionStatus;
        status = (['pending', 'open', 'ready', 'created'] as ActionStatus[]).includes(prior) ? prior : 'open';
      } else {
        status = item.external?.key ? 'created' : initialStatus(item.type, item.body);
      }
      const type = resolveTypeID(item.type, prefs());
      const changedType = type !== item.type;
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

    findInJob: (job) =>
      track(findInJob(job).catch((err: unknown) => log('warn', `Finding actions for ${job.id} failed: ${(err as Error).message}`))),

    afterAsk: (conversationID) =>
      track(
        (async () => {
          const sp = prefs().sources.ask;
          if (!sp.detectTodos && !sp.detectTypes) return;
          await detectAsk(conversationID, undefined, false);
        })().catch((err: unknown) => log('warn', `Finding actions in an answer failed: ${(err as Error).message}`)),
      ),

    sweepHistory,

    async whenIdle() {
      while (inflight.size > 0) await Promise.allSettled([...inflight]);
    },
  };
  return service;
}
