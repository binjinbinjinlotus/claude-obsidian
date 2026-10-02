import { existsSync, promises as fs } from 'node:fs';
import path from 'node:path';
import {
  runnerSupports,
  type AskCitation,
  type AskRequest,
  type AskResponse,
  type ModelSelection,
  type RunRequest,
  type RunnerRegistry,
  type Settings,
} from '../contracts.js';
import { ConversationStore, KeyedMutex, type ConversationRecord } from './conversations.js';
import { filterPages, hasFilter, readRule, scanVaultPages, type VaultPage } from './filters.js';
import { ASK_OUTPUT_SCHEMA_TEXT, ASK_READ_ONLY_TOOLS, ASK_SYSTEM_PROMPT, buildAskPrompt } from './prompt.js';
import { DEFAULT_SOURCE_TAXONOMY, type SourceTaxonomy } from './taxonomy.js';

export interface AskDeps {
  getSettings(): Settings;
  runners: RunnerRegistry;
  /** Directory for Ask conversation state (sessions), e.g. <stateDir>/ask. */
  stateDir: string;
  /** Source taxonomy for group expansion; default DEFAULT_SOURCE_TAXONOMY. */
  taxonomy?: SourceTaxonomy;
  /** Clock, for tests. */
  now?: () => Date;
}

export interface AskService {
  ask(req: AskRequest): Promise<AskResponse>;
}

export { DEFAULT_SOURCE_TAXONOMY } from './taxonomy.js';

const DEFAULT_RUNNER = 'claude-code';

export function createAskService(deps: AskDeps): AskService {
  const store = new ConversationStore(deps.stateDir);
  const mutex = new KeyedMutex();
  const now = () => (deps.now ? deps.now() : new Date()).toISOString();

  async function ask(req: AskRequest): Promise<AskResponse> {
    const question = (req.question ?? '').trim();
    if (!question) throw new Error('ask: question is empty');
    const conversationID = req.conversationID ?? store.newID();
    return mutex.run(conversationID, () => askLocked(req, question, conversationID));
  }

  async function askLocked(req: AskRequest, question: string, conversationID: string): Promise<AskResponse> {
    const settings = deps.getSettings();
    const record = req.conversationID ? await store.load(conversationID) : undefined;
    if (req.conversationID && !record) throw new Error(`ask: unknown conversation ${conversationID}`);

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

    // Session: resume unless there is none yet, or the runner or vault changed.
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
      } else if (record.workingDirectory !== undefined && record.workingDirectory !== workspace) {
        notices.push('Started a new session: the Ask workspace moved, so earlier turns are not in context.');
        sessionID = null;
      }
    }

    // Filters.
    const labels = (req.labels ?? []).filter((l) => l.trim());
    const sources = (req.sources ?? []).filter((s) => s.trim());
    const filtered = hasFilter({ labels, sources });
    let allowedPages: VaultPage[] | undefined;
    if (filtered) {
      const pages = await scanVaultPages(vaultPath);
      allowedPages = filterPages(pages, { labels, sources }, deps.taxonomy ?? DEFAULT_SOURCE_TAXONOMY);
      if (allowedPages.length === 0) {
        const describe = [labels.length ? `labels ${labels.join(', ')}` : '', sources.length ? `sources ${sources.join(', ')}` : '']
          .filter(Boolean)
          .join(' and ');
        const answer = `No notes in the vault match ${describe}, so there is nothing to answer from. Remove or change the filters to search all notes.`;
        await store.save(nextRecord(record, { conversationID, sessionID, selection, vaultPath, workspace, cost: 0, ran: false }));
        return {
          conversationID,
          answer: withNotices(notices, answer),
          citations: [],
          gaps: [`No notes match ${describe}.`],
          selection,
          costUSD: 0,
        };
      }
    }

    const isNewSession = sessionID === null;
    const runSessionID = sessionID ?? store.newID();
    const request: RunRequest = {
      // Not the vault: Claude Code auto-approves reads inside its working
      // directories, which would bypass the per-page Read rules (verified).
      workingDirectory: workspace,
      prompt: buildAskPrompt(question, { vaultPath, labels, sources, allowedPages }),
      session: isNewSession ? { start: runSessionID } : { resume: runSessionID },
      selection,
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
    const answer = mapped?.answer ?? result.resultText;
    const allowed = allowedPages ? new Set(allowedPages.map((p) => p.path)) : undefined;
    const citations = mapped ? await validateCitations(mapped.citations, vaultPath, allowed, allowedPages) : [];
    const costUSD = Number.isFinite(result.costUSD) ? result.costUSD : 0;

    await store.save(
      nextRecord(record, {
        conversationID,
        sessionID: result.sessionID || runSessionID,
        selection,
        vaultPath,
        workspace,
        cost: costUSD,
        ran: true,
      }),
    );

    return {
      conversationID,
      answer: withNotices(notices, answer),
      citations,
      gaps: mapped?.gaps ?? [],
      selection,
      costUSD,
    };
  }

  function nextRecord(
    previous: ConversationRecord | undefined,
    next: {
      conversationID: string;
      sessionID: string | null;
      selection: ModelSelection;
      vaultPath: string;
      workspace: string;
      cost: number;
      ran: boolean;
    },
  ): ConversationRecord {
    const stamp = now();
    return {
      conversationID: next.conversationID,
      sessionID: next.sessionID,
      selection: next.selection,
      vaultPath: next.vaultPath,
      workingDirectory: next.workspace,
      createdAt: previous?.createdAt ?? stamp,
      updatedAt: stamp,
      turns: (previous?.turns ?? 0) + (next.ran ? 1 : 0),
      costUSD: (previous?.costUSD ?? 0) + next.cost,
    };
  }

  return { ask };
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

function withNotices(notices: string[], answer: string): string {
  if (!notices.length) return answer;
  return `${notices.map((n) => `> [!note] ${n}`).join('\n>\n')}\n\n${answer}`;
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
