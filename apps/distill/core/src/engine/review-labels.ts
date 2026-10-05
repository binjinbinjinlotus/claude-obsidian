import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { ReviewSource } from '../contracts.js';
import { isObject, writeFileAtomic } from '../store/json.js';
import { listValue, parseFrontmatter, scalarValue, setLabelProperties } from '../labels/frontmatter.js';
import { pageTags } from '../labels/vault.js';

/**
 * Labels in Review (approval-and-review.md, "Labels in Review").
 *
 * A batch's bundle writes one source page per input, with the labels the queue or the batch
 * suggested (`labels_by: ai`, `labels_reviewed: false`). Review shows them, and approving
 * confirms exactly what was shown (decision 2026-10-05). The bundle is never rewritten at approve
 * time: before Approve is offered, the core writes a label *revision* (a new bundle next to the
 * original, with new draft files for the source pages only) and inspects it; only a revision that
 * inspects cleanly replaces the job's bundle and plan, so the approval hash always matches what
 * is shown. The original bundle and drafts are never modified.
 */

const sha256 = (data: string | Uint8Array) => createHash('sha256').update(data).digest('hex');

interface BundleWrite {
  path: string;
  content_file?: string;
  content?: string;
  sha256?: string;
  [key: string]: unknown;
}

export interface LoadedBundle {
  path: string;
  dir: string;
  raw: Record<string, unknown>;
  writes: BundleWrite[];
}

export function readBundle(bundlePath: string): LoadedBundle | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(bundlePath, 'utf8'));
  } catch {
    return undefined;
  }
  if (!isObject(raw) || !Array.isArray(raw.writes)) return undefined;
  const writes = raw.writes.filter((w): w is BundleWrite => isObject(w) && typeof w.path === 'string');
  return { path: bundlePath, dir: path.dirname(bundlePath), raw, writes };
}

function contentAbs(b: LoadedBundle, w: BundleWrite): string | undefined {
  if (typeof w.content_file !== 'string') return undefined;
  return path.isAbsolute(w.content_file) ? w.content_file : path.resolve(b.dir, w.content_file);
}

function contentOf(b: LoadedBundle, w: BundleWrite): string | undefined {
  if (typeof w.content === 'string') return w.content;
  const abs = contentAbs(b, w);
  if (!abs) return undefined;
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch {
    return undefined;
  }
}

/** v11 (action-context.md): every Markdown page under wiki/ the bundle writes, with its text. */
export function wikiWrites(b: LoadedBundle): { path: string; text: string }[] {
  const out: { path: string; text: string }[] = [];
  for (const w of b.writes) {
    if (!w.path.startsWith('wiki/') || !w.path.toLowerCase().endsWith('.md')) continue;
    const text = contentOf(b, w);
    if (text !== undefined) out.push({ path: w.path, text });
  }
  return out;
}

/** A page of the bundle that carries an input's labels. */
export interface SourcePage {
  write: BundleWrite;
  page: string;
  text: string;
  title: string;
  source?: string;
  labels: string[];
  by: 'ai' | 'user' | 'none';
  /** `labels_reviewed: false` in the draft. */
  unconfirmed: boolean;
  origin?: string;
}

/**
 * Source pages: Markdown writes under wiki/ whose front matter has label properties
 * (`labels_by`) or `type: source`. Concept and entity pages' tags are the agent's, not label
 * suggestions, and are left alone.
 */
export function sourcePages(b: LoadedBundle): SourcePage[] {
  const out: SourcePage[] = [];
  for (const w of b.writes) {
    if (!w.path.startsWith('wiki/') || !w.path.toLowerCase().endsWith('.md')) continue;
    const text = contentOf(b, w);
    if (text === undefined) continue;
    const fm = parseFrontmatter(text);
    const labelsBy = scalarValue(fm, 'labels_by');
    const type = scalarValue(fm, 'type');
    if (labelsBy === undefined && type !== 'source') continue;
    const labels = pageTags(text);
    const source = scalarValue(fm, 'source_path') ?? listValue(fm, 'sources')[0];
    const entry: SourcePage = {
      write: w,
      page: w.path,
      text,
      title: scalarValue(fm, 'title') ?? path.posix.basename(w.path, '.md'),
      labels,
      by: labelsBy === 'ai' ? 'ai' : labelsBy === 'user' || labels.length > 0 ? 'user' : 'none',
      unconfirmed: scalarValue(fm, 'labels_reviewed') === 'false',
    };
    if (source) entry.source = source;
    const origin = scalarValue(fm, 'labels_origin');
    if (origin) entry.origin = origin;
    out.push(entry);
  }
  return out;
}

export function reviewSources(pages: SourcePage[]): ReviewSource[] {
  return pages.map((p) => {
    const s: ReviewSource = { page: p.page, title: p.title, labels: [...p.labels], by: p.by };
    if (p.source) s.source = p.source;
    return s;
  });
}

/** True when the revision would change something: an unconfirmed page, or an override. */
export function needsRevision(pages: SourcePage[], overrides?: Map<string, string[]>): boolean {
  return pages.some((p) => pageNeedsRevision(p, overrides));
}

function pageNeedsRevision(p: SourcePage, overrides?: Map<string, string[]>, mode: RevisionMode = 'confirm'): boolean {
  if (overrides?.has(p.page)) return true;
  return mode === 'confirm' && (p.unconfirmed || p.origin !== undefined);
}

/**
 * confirm = every source page's labels confirmed (Approve); keep = only the user's edits confirmed, the rest as the
 * batch wrote them (Approve, review labels later); suggest = the overrides written as the AI's suggestions
 * (`labels_by: ai`, `labels_reviewed: false`), the rest untouched (the unconfirmed version of a batch whose labels
 * were suggested after it was built).
 */
export type RevisionMode = 'confirm' | 'keep' | 'suggest';

/** The text a source page gets as an AI suggestion left to review (Labels → To review). */
export function suggestedText(p: SourcePage, labels: string[]): string {
  return setLabelProperties(p.text, { tags: labels, labels_by: 'ai', labels_reviewed: false });
}

/** The text a source page gets in a revision: the given (or current) tags, confirmed by the user. */
export function confirmedText(p: SourcePage, labels: string[] | undefined): string {
  const tags = labels ?? p.labels;
  return setLabelProperties(p.text, tags.length > 0 ? { tags, labels_by: 'user' } : { tags: [], labels_by: 'user' });
}

/** Next free revision number in the job directory (`bundle-labels-<n>.json`). */
function nextRevision(dir: string): number {
  let n = 1;
  while (fs.existsSync(path.join(dir, `bundle-labels-${n}.json`))) n += 1;
  return n;
}

export interface Revision {
  bundlePath: string;
  revision: number;
  /** Pages whose content changed. */
  changed: string[];
}

/**
 * Write a label revision of `b` into its directory: `labels-<n>/` holds the new source-page
 * drafts, `bundle-labels-<n>.json` is the bundle with those writes repointed (and their sha256
 * updated). Everything else in the bundle is copied as is. Returns undefined when nothing changes.
 */
export function writeRevision(
  b: LoadedBundle,
  pages: SourcePage[],
  overrides?: Map<string, string[]>,
  mode: RevisionMode = 'confirm',
): Revision | undefined {
  const n = nextRevision(b.dir);
  const draftDir = path.join(b.dir, `labels-${n}`);
  const byWrite = new Map(pages.map((p) => [p.write, p]));
  const changed: string[] = [];
  const writes = b.writes.map((w, i) => {
    const p = byWrite.get(w);
    if (!p || !pageNeedsRevision(p, overrides, mode)) return w;
    const given = overrides?.get(p.page);
    const next = mode === 'suggest' && given ? suggestedText(p, given) : confirmedText(p, given);
    if (next === p.text) return w;
    changed.push(p.page);
    const out: BundleWrite = { ...w };
    if (typeof w.content === 'string') {
      out.content = next;
    } else {
      const base = typeof w.content_file === 'string' ? path.basename(w.content_file) : `page-${i + 1}.md`;
      fs.mkdirSync(draftDir, { recursive: true });
      const file = path.join(draftDir, base);
      writeFileAtomic(file, next);
      out.content_file = path.relative(b.dir, file).split(path.sep).join('/');
    }
    if (typeof w.sha256 === 'string') out.sha256 = sha256(next);
    return out;
  });
  if (changed.length === 0) return undefined;
  // Keep any write entries that were not objects with a path (none in practice) in place.
  const rawWrites = Array.isArray(b.raw.writes) ? b.raw.writes : [];
  let k = 0;
  const mergedWrites = rawWrites.map((w) => (isObject(w) && typeof w.path === 'string' ? writes[k++] : w));
  const bundlePath = path.join(b.dir, `bundle-labels-${n}.json`);
  writeFileAtomic(bundlePath, JSON.stringify({ ...b.raw, writes: mergedWrites }, null, 2) + '\n');
  return { bundlePath, revision: n, changed };
}

/** A short reason from `transaction inspect` output: the `ERR CODE: message` line when there is one. */
export function inspectReason(error: string): string {
  const err = /ERR ([A-Z_]+): ([^\n]+)/.exec(error);
  if (err) return `${err[2]!.trim()} (${err[1]})`;
  const line = error.split('\n').map((l) => l.trim()).find((l) => l.length > 0) ?? error;
  return line.length > 300 ? line.slice(0, 300) + '…' : line;
}

/** sha256 of each page's content in a bundle, by page. */
export function pageShas(b: LoadedBundle): Map<string, string> {
  const out = new Map<string, string>();
  for (const w of b.writes) {
    const text = contentOf(b, w);
    if (text !== undefined) out.set(w.path, sha256(text));
  }
  return out;
}

/** The absolute content file of a page in a bundle (written out first when the write is inline). */
export function contentFileFor(b: LoadedBundle, page: string, scratchDir: string): string | undefined {
  const w = b.writes.find((x) => x.path === page);
  if (!w) return undefined;
  const abs = contentAbs(b, w);
  if (abs) return abs;
  if (typeof w.content !== 'string') return undefined;
  fs.mkdirSync(scratchDir, { recursive: true });
  const file = path.join(scratchDir, path.posix.basename(page));
  writeFileAtomic(file, w.content);
  return file;
}

/**
 * What the user approved against a rebuilt change: every expected source page is in it with the
 * exact content they saw, and no page of an excluded source (not picked, removed) is in it.
 * Returns the problems; [] = it matches.
 */
export function verifyRebuilt(
  b: LoadedBundle,
  expected: Record<string, string>,
  excluded: string[],
  excludedSources: string[] = [],
  /** v10 (full reads): content sha256 of sources that must have no source ledger record in it. */
  excludedShas: string[] = [],
  /** v10: the vault's source ledger as it is now (records it already holds unchanged are fine). */
  currentLedger?: unknown,
): string[] {
  const problems: string[] = [...ledgerProblems(b, excludedSources, excludedShas, currentLedger)];
  const shas = pageShas(b);
  for (const [page, sha] of Object.entries(expected)) {
    const got = shas.get(page);
    if (got === undefined) problems.push(`${page} is missing`);
    else if (got !== sha) problems.push(`${page} is not the page you approved`);
  }
  const written = new Set(b.writes.map((w) => w.path));
  for (const page of excluded) if (written.has(page)) problems.push(`${page} should not be in it`);
  if (excludedSources.length > 0) {
    const out = new Set(excludedSources);
    for (const p of sourcePages(b)) {
      if (p.source && out.has(p.source) && !(p.page in expected)) problems.push(`${p.page} (from ${p.source}) should not be in it`);
    }
  }
  return problems;
}

/**
 * v10: a source left out of a change must have no source ledger record in it either: none whose
 * `origin.locator` is the source (or its archive path) or whose `content_sha256` is its content.
 * Only the bundle's own write of the ledger is checked, and only records it adds or changes.
 */
export function ledgerProblems(b: LoadedBundle, files: string[], shas: string[], current?: unknown): string[] {
  if (files.length === 0 && shas.length === 0) return [];
  const w = b.writes.find((x) => x.path === 'wiki/meta/ledgers/source-ledger.json');
  if (!w) return [];
  const text = contentOf(b, w);
  if (text === undefined) return ['its source ledger could not be read'];
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    return ['its source ledger is not valid JSON'];
  }
  const sources = isObject(v) && isObject(v.sources) ? v.sources : {};
  const outFiles = new Set(files.map((f) => f.normalize('NFC')));
  const outShas = new Set(shas.map((s) => s.toLowerCase()));
  const problems: string[] = [];
  const before = isObject(current) && isObject(current.sources) ? current.sources : {};
  for (const [id, rec] of Object.entries(sources)) {
    if (!isObject(rec)) continue;
    // A record the vault already holds, unchanged, is not this change adding the source.
    if (id in before && JSON.stringify(before[id]) === JSON.stringify(rec)) continue;
    const locator = isObject(rec.origin) && typeof rec.origin.locator === 'string' ? rec.origin.locator.normalize('NFC') : '';
    const sha = typeof rec.content_sha256 === 'string' ? rec.content_sha256.toLowerCase() : '';
    if (outFiles.has(locator) || (sha && outShas.has(sha))) problems.push(`source ledger record ${id} (${locator || sha}) should not be in it`);
  }
  return problems;
}

export interface PartPromptInput {
  reason: 'partial' | 'remaining' | 'stale';
  bundlePath: string;
  keep: { page: string; source?: string | null; contentFile: string; sha256: string }[];
  leaveOut: { page: string; source?: string | null }[];
  removed: { page: string; source?: string | null }[];
  appliedOperation?: string;
}

/** The turn that asks the batch's own session for a change holding exactly the approved sources. */
export function partPrompt(o: PartPromptInput): string {
  const why = {
    partial: 'The user approved only some of the sources in this batch.',
    remaining: `The part the user approved was applied${o.appliedOperation ? ` (operation ${o.appliedOperation})` : ''}. Now build the change for the sources that are left.`,
    stale: 'The vault changed after the user reviewed this batch (another change was applied first), so the reviewed bundle no longer applies.',
  }[o.reason];
  const item = (x: { page: string; source?: string | null }) => `- ${x.page}${x.source ? ` (from ${x.source})` : ''}`;
  const lines = [
    why,
    '',
    `Build a NEW transaction bundle at \`${o.bundlePath}\` (leave every earlier bundle as it is), for the vault as it is now.`,
    '',
    'It must create these source pages, each byte for byte the file given: use a `content_file` pointing at that exact file and its sha256; do not rewrite, reformat or relabel them:',
    ...o.keep.map((k) => `- ${k.page}${k.source ? ` (from ${k.source})` : ''}: ${k.contentFile} (sha256 ${k.sha256})`),
  ];
  if (o.leaveOut.length > 0) lines.push('', 'Leave these sources out entirely (no page for them; they stay for a later approval):', ...o.leaveOut.map(item));
  if (o.removed.length > 0) lines.push('', 'The user removed these sources; never write a page for them:', ...o.removed.map(item));
  lines.push(
    '',
    'Write the index, log, hot cache, overview, ledgers, and any concept or entity pages again so they cover only the sources above plus what is already in the vault.',
    'Run `transaction inspect` on the new bundle and finish with `needs_approval` and its `bundle_path`. Distill checks that the source pages are exactly the files given before the user sees it.',
  );
  return lines.join('\n');
}
