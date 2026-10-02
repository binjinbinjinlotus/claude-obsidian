import { notImplemented } from '../contracts.js';
import { existsSync, promises as fs } from 'node:fs';
import path from 'node:path';
import type { AskOwned } from '../engine/index.js';
import {
  CoreError,
  DEFAULT_ASK_PREFERENCES,
  runnerSupports,
  type AskCitation,
  type AskConversation,
  type AskConversationSummary,
  type AskPreferences,
  type AskRequest,
  type AskResponse,
  type AskTurn,
  type CoreEvent,
  type DistillCore,
  type LabelMatch,
  type ModelSelection,
  type RunRequest,
  type RunnerRegistry,
  type Settings,
} from '../contracts.js';
import { ConversationStore, KeyedMutex, conversationOf, summaryOf, titleFrom, type ConversationRecord } from './conversations.js';
import { filterPages, hasFilter, normalizeTag, readRule, scanVaultPages, type VaultPage } from './filters.js';
import { ASK_OUTPUT_SCHEMA_TEXT, ASK_READ_ONLY_TOOLS, ASK_SYSTEM_PROMPT, buildAskPrompt } from './prompt.js';
import { expandSources, taxonomyFrom, type SourceTaxonomy } from './taxonomy.js';

export interface AskDeps {
  getSettings(): Settings;
  runners: RunnerRegistry;
  /** Directory for Ask conversation state (sessions, history), e.g. <stateDir>/ask. */
  stateDir: string;
  /** Receives `conversation` events (saved, pinned, deleted) and `log` warnings. */
  emit?: (event: CoreEvent) => void;
  /** Clock, for tests. */
  now?: () => Date;
}

export type AskService = Pick<DistillCore, AskOwned> & {
  /** Run the retention sweep now (it also runs on creation and at most hourly on ask/list). */
  sweepHistory(): Promise<void>;
};

export { DEFAULT_SOURCE_TAXONOMY } from './taxonomy.js';

const DEFAULT_RUNNER = 'claude-code';
const SWEEP_INTERVAL_MS = 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Settings askPreferences merged over the defaults, with usable values. */
export function askPreferences(settings: Settings): AskPreferences {
  const prefs = { ...DEFAULT_ASK_PREFERENCES, ...(settings.askPreferences ?? {}) };
  if (prefs.labelMatch !== 'any' && prefs.labelMatch !== 'all') prefs.labelMatch = DEFAULT_ASK_PREFERENCES.labelMatch;
  if (typeof prefs.includeUnconfirmed !== 'boolean') prefs.includeUnconfirmed = DEFAULT_ASK_PREFERENCES.includeUnconfirmed;
  if (typeof prefs.keepHistory !== 'boolean') prefs.keepHistory = DEFAULT_ASK_PREFERENCES.keepHistory;
  if (typeof prefs.historyDays !== 'number' || !Number.isFinite(prefs.historyDays) || prefs.historyDays <= 0) {
    prefs.historyDays = DEFAULT_ASK_PREFERENCES.historyDays;
  }
  return prefs;
}

interface SessionState {
  conversationID: string;
  sessionID: string | null;
  selection: ModelSelection;
  vaultPath: string;
  workspace: string;
  scope: string;
  cost: number;
  ran: boolean;
}

export function createAskService(deps: AskDeps): AskService {
  const store = new ConversationStore(deps.stateDir);
  const mutex = new KeyedMutex();
  const clock = () => (deps.now ? deps.now() : new Date());
  const now = () => clock().toISOString();

  function emit(event: CoreEvent): void {
    try {
      deps.emit?.(event);
    } catch {
      // A listener must never fail an Ask call.
    }
  }

  function warn(message: string): void {
    emit({ type: 'log', level: 'warn', message });
  }

  async function loadQuietly(id: string): Promise<ConversationRecord | undefined> {
    try {
      return await store.load(id);
    } catch (error) {
      warn(`Skipping Ask conversation ${id}: ${(error as Error).message}`);
      return undefined;
    }
  }

  // ── retention ──

  let lastSweep = Number.NEGATIVE_INFINITY;
  let sweeping: Promise<void> | undefined;

  /** Delete non-pinned conversations whose last message is older than historyDays (Keep history on). */
  function sweepHistory(): Promise<void> {
    if (sweeping) return sweeping;
    lastSweep = clock().getTime();
    sweeping = sweep().finally(() => {
      sweeping = undefined;
    });
    return sweeping;
  }

  /** Sweep when none ran in the last hour; never throws. */
  function maybeSweep(): Promise<void> {
    if (!sweeping && clock().getTime() - lastSweep < SWEEP_INTERVAL_MS) return Promise.resolve();
    return sweepHistory().catch((error) => warn(`Ask history sweep failed: ${(error as Error).message}`));
  }

  async function sweep(): Promise<void> {
    const prefs = askPreferences(deps.getSettings());
    if (!prefs.keepHistory) return; // clients delete each chat when it is closed
    const cutoff = clock().getTime() - prefs.historyDays * DAY_MS;
    for (const id of await store.ids()) {
      // A chat with a turn in flight is about to get a fresh updatedAt; waiting
      // for it would stall History and every other Ask behind a runner turn.
      if (mutex.busy(id)) continue;
      // Under the conversation's lock, re-read: a follow-up may just have landed.
      await mutex.run(id, async () => {
        const record = await loadQuietly(id);
        if (!record || record.pinned) return;
        const updated = Date.parse(record.updatedAt);
        if (!Number.isFinite(updated) || updated >= cutoff) return;
        if (await store.delete(id)) emit({ type: 'conversation', conversation: summaryOf(record), deleted: true });
      });
    }
  }

  void maybeSweep(); // on creation; failures only log

  // ── history ──

  async function listConversations(): Promise<AskConversationSummary[]> {
    await maybeSweep();
    const out: AskConversationSummary[] = [];
    for (const id of await store.ids()) {
      const record = await loadQuietly(id);
      if (record) out.push(summaryOf(record));
    }
    return out.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id));
  }

  async function getConversation(id: string): Promise<AskConversation | undefined> {
    const record = await store.load(id);
    return record ? conversationOf(record) : undefined;
  }

  async function deleteConversation(id: string): Promise<void> {
    await mutex.run(id, async () => {
      const record = await store.load(id);
      if (!record) throw new CoreError('not_found', `ask: unknown conversation ${id}`);
      await store.delete(id);
      emit({ type: 'conversation', conversation: summaryOf(record), deleted: true });
    });
  }

  async function setConversationPinned(id: string, pinned: boolean): Promise<AskConversationSummary> {
    return mutex.run(id, async () => {
      const record = await store.load(id);
      if (!record) throw new CoreError('not_found', `ask: unknown conversation ${id}`);
      // updatedAt is the last message: pinning must not extend retention.
      const next: ConversationRecord = { ...record, pinned: pinned === true };
      await store.save(next);
      const summary = summaryOf(next);
      emit({ type: 'conversation', conversation: summary });
      return summary;
    });
  }

  // ── ask ──

  async function ask(req: AskRequest): Promise<AskResponse> {
    const question = (req.question ?? '').trim();
    if (!question) throw new CoreError('invalid_request', 'ask: question is empty');
    await maybeSweep();
    const conversationID = req.conversationID ?? store.newID();
    return mutex.run(conversationID, () => askLocked(req, question, conversationID));
  }

  async function askLocked(req: AskRequest, question: string, conversationID: string): Promise<AskResponse> {
    const askedAt = now();
    const settings = deps.getSettings();
    const prefs = askPreferences(settings);
    const taxonomy = taxonomyFrom(settings);
    const record = req.conversationID ? await store.load(conversationID) : undefined;
    if (req.conversationID && !record) throw new CoreError('not_found', `ask: unknown conversation ${conversationID}`);

    const vaultPath = await resolveVault(req, record, settings);
    const notices: string[] = [];

    // Selection: request > conversation > task default > legacy model.
    const base: ModelSelection = record?.selection ??
      settings.taskDefaults?.ask ?? { runnerID: DEFAULT_RUNNER, model: settings.model };
    const selection: ModelSelection = req.selection
      ? { ...req.selection, runnerID: req.selection.runnerID || base.runnerID, model: req.selection.model || base.model }
      : { ...base };
    const runner = deps.runners.get(selection.runnerID);
    if (!runner) throw new Error(`ask: unknown runner "${selection.runnerID}"`);
    if (!settings.enabledRunners.includes(runner.id)) {
      throw new Error(`ask: runner "${runner.displayName}" is not enabled (Settings → AI runners)`);
    }
    if (!runnerSupports(runner, 'ask')) {
      throw new Error(
        `ask: runner "${runner.displayName}" cannot answer from the vault (Ask needs agent tools, tool permissions and session resume)`,
      );
    }
    const problems = runner.problems(settings);
    if (problems.length) {
      throw new Error(`ask: runner "${runner.displayName}" is not ready: ${problems.map((p) => p.message).join('; ')}`);
    }
    const productRoot = settings.productRoot;
    const workspace = await askWorkspace(deps.stateDir, vaultPath);
    if (!productRoot || !existsSync(path.join(productRoot, 'skills', 'wiki-query', 'SKILL.md'))) {
      throw new Error(`ask: productRoot "${productRoot}" is not a claude-obsidian checkout (skills/wiki-query/SKILL.md missing)`);
    }

    // Filters: request, else the settings defaults.
    const labels = (req.labels ?? []).filter((l) => l.trim());
    const sources = (req.sources ?? []).filter((s) => s.trim());
    const labelMatch: LabelMatch = req.labelMatch === 'all' || req.labelMatch === 'any' ? req.labelMatch : prefs.labelMatch;
    const includeUnconfirmed = typeof req.includeUnconfirmed === 'boolean' ? req.includeUnconfirmed : prefs.includeUnconfirmed;
    const filter = { labels, sources, labelMatch, includeUnconfirmed };
    const filtered = hasFilter(filter);
    const scope = scopeKey(filter, taxonomy);

    // The request as applied (defaults resolved), so a client can restore the chips.
    const appliedRequest: AskRequest = {
      question,
      ...(req.conversationID ? { conversationID: req.conversationID } : {}),
      selection,
      vaultPath,
      labels,
      sources,
      labelMatch,
      includeUnconfirmed,
    };

    // Session: resume unless there is none yet, or the runner, vault or scope changed.
    // A session never crosses filter scopes: earlier turns' page text stays in
    // context, so resuming would let a narrower filter see unfiltered pages.
    let sessionID = record?.sessionID ?? null;
    if (record && sessionID) {
      if (record.selection.runnerID !== selection.runnerID) {
        notices.push(
          `Started a new session: the runner changed from ${record.selection.runnerID} to ${selection.runnerID}, so earlier turns are not in context.`,
        );
        sessionID = null;
      } else if (record.vaultPath !== vaultPath) {
        notices.push('Started a new session: the vault changed, so earlier turns are not in context.');
        sessionID = null;
      } else if ((record.scope ?? '') !== scope) {
        notices.push(
          `Started a new session: the label/source filter changed, so earlier turns are not in context (a filter only limits a fresh session).`,
        );
        sessionID = null;
      } else if (record.workingDirectory !== undefined && record.workingDirectory !== workspace) {
        notices.push('Started a new session: the Ask workspace moved, so earlier turns are not in context.');
        sessionID = null;
      }
    }

    let allowedPages: VaultPage[] | undefined;
    if (filtered) {
      const pages = await scanVaultPages(vaultPath);
      allowedPages = filterPages(pages, filter, taxonomy);
      const labelled = labels.some((l) => normalizeTag(l));
      // Pages that match only when unconfirmed labels count.
      const leftOut =
        labelled && !includeUnconfirmed
          ? filterPages(pages, { ...filter, includeUnconfirmed: true }, taxonomy).length - allowedPages.length
          : 0;
      const unconfirmed = labelled && includeUnconfirmed ? allowedPages.filter((p) => p.labelsUnconfirmed).length : 0;

      if (allowedPages.length === 0) {
        const describe = [
          labels.length ? `${labelMatch === 'all' && labels.length > 1 ? 'all of labels' : 'labels'} ${labels.join(', ')}` : '',
          sources.length ? `sources ${sources.join(', ')}` : '',
        ]
          .filter(Boolean)
          .join(' and ');
        if (leftOut) {
          notices.push(`${countPages(leftOut)} would match with unconfirmed labels; Include unconfirmed is off.`);
        }
        const response: AskResponse = {
          conversationID,
          answer: `No notes in the vault match ${describe}, so there is nothing to answer from. Remove or change the filters to search all notes.`,
          citations: [],
          gaps: [`No notes match ${describe}.`],
          selection,
          costUSD: 0,
          notices,
        };
        await saveTurn(
          record,
          { conversationID, sessionID, selection, vaultPath, workspace, scope, cost: 0, ran: false },
          { askedAt, request: appliedRequest, response },
        );
        return response;
      }

      notices.push(
        `Limited to ${countPages(allowedPages.length)}${unconfirmed ? ` (${unconfirmed} unconfirmed)` : ''}.` +
          (leftOut ? ` Left out ${countPages(leftOut)} whose labels are not confirmed yet.` : ''),
      );
    }

    const isNewSession = sessionID === null;
    const runSessionID = sessionID ?? store.newID();
    const request: RunRequest = {
      // Not the vault: Claude Code auto-approves reads inside its working
      // directories, which would bypass the per-page Read rules (verified).
      workingDirectory: workspace,
      prompt: buildAskPrompt(question, { vaultPath, labels, sources, labelMatch, allowedPages }),
      session: isNewSession ? { start: runSessionID } : { resume: runSessionID },
      selection,
      availableTools: allowedPages ? ['Skill', 'Read'] : [...ASK_READ_ONLY_TOOLS],
      allowedTools: allowedPages ? ['Skill', ...allowedPages.map((p) => readRule(p.absPath))] : [...ASK_READ_ONLY_TOOLS],
      readableDirectories: allowedPages
        ? isInside(vaultPath, await realOr(productRoot))
          ? []
          : [productRoot]
        : [vaultPath, productRoot],
      pluginDirectory: productRoot,
      outputSchema: ASK_OUTPUT_SCHEMA_TEXT,
      systemPrompt: ASK_SYSTEM_PROMPT,
      environment: { CLAUDE_OBSIDIAN_VAULT: vaultPath },
    };

    const result = await runner.run(request, settings);
    if (result.isError) {
      throw new Error(`ask: ${runner.displayName} failed: ${result.resultText || 'no result text'}`);
    }

    const mapped = mapStructured(result.structured);
    const allowed = allowedPages ? new Set(allowedPages.map((p) => p.path)) : undefined;
    const citations = mapped ? await validateCitations(mapped.citations, vaultPath, allowed, allowedPages) : [];
    const costUSD = Number.isFinite(result.costUSD) ? result.costUSD : 0;
    const response: AskResponse = {
      conversationID,
      answer: mapped?.answer ?? result.resultText,
      citations,
      gaps: mapped?.gaps ?? [],
      selection,
      costUSD,
      notices,
    };
    await saveTurn(
      record,
      { conversationID, sessionID: result.sessionID || runSessionID, selection, vaultPath, workspace, scope, cost: costUSD, ran: true },
      { askedAt, request: appliedRequest, response },
    );
    return response;
  }

  /** Persist the conversation with this turn appended, and announce it. */
  async function saveTurn(previous: ConversationRecord | undefined, next: SessionState, turn: AskTurn): Promise<void> {
    const stamp = now();
    const record: ConversationRecord = {
      conversationID: next.conversationID,
      sessionID: next.sessionID,
      selection: next.selection,
      vaultPath: next.vaultPath,
      workingDirectory: next.workspace,
      scope: next.scope,
      createdAt: previous?.createdAt ?? stamp,
      updatedAt: stamp,
      turns: (previous?.turns ?? 0) + (next.ran ? 1 : 0),
      costUSD: (previous?.costUSD ?? 0) + next.cost,
      title: previous?.title || titleFrom(turn.request.question),
      pinned: previous?.pinned === true,
      history: [...(previous?.history ?? []), turn],
    };
    await store.save(record);
    emit({ type: 'conversation', conversation: summaryOf(record) });
  }

  return { ask, listConversations, getConversation, deleteConversation, setConversationPinned, sweepHistory, cancelAsk: async () => notImplemented('cancelAsk') };
}

function countPages(n: number): string {
  return `${n} ${n === 1 ? 'page' : 'pages'}`;
}

/**
 * Canonical filter scope: sorted normalized labels and expanded sources; '' when
 * unfiltered. `match` and `unconfirmed` appear only when they differ from v1
 * behaviour (any, include), so v1 scopes stay byte-identical and still resume.
 */
function scopeKey(
  filter: { labels: string[]; sources: string[]; labelMatch: LabelMatch; includeUnconfirmed: boolean },
  taxonomy: SourceTaxonomy,
): string {
  if (!hasFilter(filter)) return '';
  const l = [...new Set(filter.labels.map(normalizeTag).filter(Boolean))].sort();
  const s = filter.sources.some((x) => x.trim()) ? [...expandSources(filter.sources, taxonomy)].sort() : [];
  const key: Record<string, unknown> = { labels: l, sources: s };
  if (filter.labelMatch === 'all' && l.length > 1) key.match = 'all';
  if (!filter.includeUnconfirmed && l.length > 0) key.unconfirmed = false;
  return JSON.stringify(key);
}

function isInside(child: string, parent: string): boolean {
  const rel = path.relative(parent, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

async function realOr(p: string): Promise<string> {
  return fs.realpath(p).catch(() => path.resolve(p));
}

/**
 * The empty directory every Ask turn runs in (sessions are keyed by cwd, so it
 * is stable). It must not be inside the vault, or filtered reads would leak.
 */
async function askWorkspace(stateDir: string, vaultPath: string): Promise<string> {
  const dir = path.join(stateDir, 'workspace');
  await fs.mkdir(dir, { recursive: true });
  const real = await fs.realpath(dir);
  if (isInside(real, vaultPath)) throw new Error(`ask: state directory ${stateDir} must not be inside the vault`);
  return real;
}

/** Fail closed: request, then the conversation's vault, then the active vault, then the only vault. */
async function resolveVault(req: AskRequest, record: ConversationRecord | undefined, settings: Settings): Promise<string> {
  const candidate =
    req.vaultPath ||
    record?.vaultPath ||
    settings.activeVaultPath ||
    (settings.vaults.length === 1 ? settings.vaults[0]?.path : undefined);
  if (!candidate) {
    throw new Error(
      settings.vaults.length > 1
        ? 'ask: several vaults are configured and none is active; pass vaultPath'
        : 'ask: no vault is configured',
    );
  }
  let real: string;
  try {
    real = await fs.realpath(candidate);
  } catch {
    throw new Error(`ask: vault ${candidate} does not exist`);
  }
  const wiki = await fs.stat(path.join(real, 'wiki')).catch(() => undefined);
  if (!wiki?.isDirectory()) throw new Error(`ask: ${candidate} is not a claude-obsidian vault (no wiki/ directory)`);
  return real;
}

interface StructuredAnswer {
  answer: string;
  citations: { n: number; path: string; title: string }[];
  gaps: string[];
}

/** Accept the structured output as an object or JSON text; undefined when it is not an Ask answer. */
export function mapStructured(value: unknown): StructuredAnswer | undefined {
  let data = value;
  if (typeof data === 'string') {
    try {
      data = JSON.parse(data);
    } catch {
      return undefined;
    }
  }
  if (!data || typeof data !== 'object') return undefined;
  const obj = data as Record<string, unknown>;
  if (typeof obj.answer !== 'string') return undefined;
  const citations = Array.isArray(obj.citations)
    ? obj.citations.flatMap((c) => {
        if (!c || typeof c !== 'object') return [];
        const { n, path: p, title } = c as Record<string, unknown>;
        const num = typeof n === 'number' ? n : typeof n === 'string' ? Number.parseInt(n, 10) : NaN;
        if (!Number.isInteger(num) || typeof p !== 'string' || !p.trim()) return [];
        return [{ n: num, path: p, title: typeof title === 'string' ? title : '' }];
      })
    : [];
  const gaps = Array.isArray(obj.gaps) ? obj.gaps.filter((g): g is string => typeof g === 'string' && g.trim() !== '') : [];
  return { answer: obj.answer, citations, gaps };
}

/**
 * Keep citations that point at an existing file inside the vault (and inside the
 * allowed set when filtered). Paths are normalized to vault-relative POSIX form.
 */
export async function validateCitations(
  citations: { n: number; path: string; title: string }[],
  vaultRealPath: string,
  allowed?: Set<string>,
  knownPages?: VaultPage[],
): Promise<AskCitation[]> {
  let pages = knownPages;
  const out: AskCitation[] = [];
  for (const citation of citations) {
    let rel = await resolveInVault(citation.path, vaultRealPath);
    if (!rel) {
      // Bare page name or wikilink: resolve by unique basename/title.
      pages ??= await scanVaultPages(vaultRealPath);
      rel = resolveByName(citation.path, pages);
    }
    if (!rel) continue;
    if (allowed && !allowed.has(rel)) continue;
    const page = pages?.find((p) => p.path === rel);
    const title = citation.title.trim() || page?.title || path.posix.basename(rel, '.md');
    out.push({ n: citation.n, path: rel, title });
  }
  return out;
}

function cleanLink(raw: string): string {
  let s = raw.trim();
  const link = /^\[\[([^\]]+)\]\]$/.exec(s);
  if (link) s = link[1]!.split('|')[0]!.split('#')[0]!.trim();
  return s.replace(/\\/g, '/');
}

async function resolveInVault(raw: string, vaultRealPath: string): Promise<string | undefined> {
  const cleaned = cleanLink(raw);
  if (!cleaned) return undefined;
  let rel: string;
  if (path.isAbsolute(cleaned)) {
    const real = await fs.realpath(cleaned).catch(() => undefined);
    if (!real) return undefined;
    rel = path.relative(vaultRealPath, real).split(path.sep).join('/');
  } else {
    rel = path.posix.normalize(cleaned.replace(/^\.\//, '').replace(/^\/+/, ''));
  }
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return undefined;
  for (const candidate of rel.toLowerCase().endsWith('.md') ? [rel] : [rel, `${rel}.md`]) {
    const abs = path.join(vaultRealPath, candidate);
    const real = await fs.realpath(abs).catch(() => undefined);
    if (!real) continue;
    const back = path.relative(vaultRealPath, real);
    if (back.startsWith('..') || path.isAbsolute(back)) continue;
    const stat = await fs.stat(real).catch(() => undefined);
    if (stat?.isFile()) return candidate;
  }
  return undefined;
}

function resolveByName(raw: string, pages: VaultPage[]): string | undefined {
  const name = path.posix.basename(cleanLink(raw)).replace(/\.md$/i, '').toLowerCase();
  if (!name) return undefined;
  const matches = pages.filter(
    (p) => path.posix.basename(p.path, '.md').toLowerCase() === name || p.title.toLowerCase() === name,
  );
  return matches.length === 1 ? matches[0]!.path : undefined;
}
