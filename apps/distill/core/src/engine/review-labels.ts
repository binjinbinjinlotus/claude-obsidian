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

function pageNeedsRevision(p: SourcePage, overrides?: Map<string, string[]>): boolean {
  return p.unconfirmed || p.origin !== undefined || (overrides?.has(p.page) ?? false);
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
export function writeRevision(b: LoadedBundle, pages: SourcePage[], overrides?: Map<string, string[]>): Revision | undefined {
  const n = nextRevision(b.dir);
  const draftDir = path.join(b.dir, `labels-${n}`);
  const byWrite = new Map(pages.map((p) => [p.write, p]));
  const changed: string[] = [];
  const writes = b.writes.map((w, i) => {
    const p = byWrite.get(w);
    if (!p || !pageNeedsRevision(p, overrides)) return w;
    const next = confirmedText(p, overrides?.get(p.page));
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
