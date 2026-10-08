import { promises as fsp } from 'node:fs';
import path from 'node:path';
import type { LabelCount, LabelOrigin, LabelReview, LabelReviewItem } from '../contracts.js';
import { listValue, parseFrontmatter, scalarValue } from './frontmatter.js';

/** Max labels an AI suggestion returns. User-chosen labels are not capped. */
export const MAX_SUGGESTED_LABELS = 5;

/**
 * A label as stored in `tags`: lower case, no '#', whitespace → '-', only
 * letters, digits, `_`, `-` and `/` (Obsidian tag characters). Purely numeric
 * values are not valid Obsidian tags → undefined.
 */
export function normalizeLabel(raw: string): string | undefined {
  const s = raw
    .normalize('NFC')
    .trim()
    .replace(/^#+/, '')
    .toLowerCase()
    .replace(/\s+/g, '-')
    .replace(/[^\p{L}\p{N}_\-/]/gu, '')
    .replace(/-{2,}/g, '-')
    .replace(/\/{2,}/g, '/')
    .replace(/^[-/]+|[-/]+$/g, '');
  if (!s || /^[\d_\-/]+$/.test(s)) return undefined;
  return s;
}

/** Normalize, drop invalid, dedupe (first wins), optionally cap. */
export function normalizeLabels(raw: readonly string[], max?: number): string[] {
  const out: string[] = [];
  for (const r of raw) {
    const n = normalizeLabel(r);
    if (n && !out.includes(n)) out.push(n);
    if (max !== undefined && out.length >= max) break;
  }
  return out;
}

/**
 * Labels a caller chose (addNote, labelNote, confirmLabels): trimmed, no
 * leading '#', no whitespace inside (rejected, as the server does), then
 * normalized like every stored label and deduped. Not capped. Throws on the
 * first invalid label.
 */
export function userLabels(raw: readonly unknown[]): string[] {
  const out: string[] = [];
  for (const r of raw) {
    if (typeof r !== 'string') throw new Error('Labels must be strings.');
    const trimmed = r.trim().replace(/^#+/, '');
    if (/\s/.test(trimmed)) throw new Error(`Label "${r}" contains whitespace.`);
    const n = normalizeLabel(trimmed);
    if (!n) throw new Error(`"${r}" is not a valid label.`);
    if (!out.includes(n)) out.push(n);
  }
  return out;
}

/** How Ask reads a stored tag (split legacy `a, b` scalars; lower case; no '#'). */
function readTags(values: string[]): string[] {
  const out: string[] = [];
  for (const v of values.flatMap((t) => t.split(/[,\s]+/))) {
    const t = v.trim().replace(/^#+/, '').toLowerCase().replace(/^\/+|\/+$/g, '');
    if (t && !out.includes(t)) out.push(t);
  }
  return out;
}

/** A page's labels as Ask reads them. */
export function pageTags(text: string): string[] {
  return readTags(listValue(parseFrontmatter(text), 'tags'));
}

/** Bootstrap/navigation pages that are not notes (mirrors the linter's orphan exclusions). */
const SYSTEM_PAGE_NAMES = new Set([
  '_index.md',
  'index.md',
  'log.md',
  'hot.md',
  'overview.md',
  'dashboard.md',
  'wiki map.md',
  'getting-started.md',
]);

export function isSystemPage(relPath: string, type?: string): boolean {
  if (relPath.startsWith('wiki/meta/')) return true;
  if (SYSTEM_PAGE_NAMES.has(path.posix.basename(relPath).toLowerCase())) return true;
  return type === 'meta';
}

export interface LabeledPage {
  path: string; // vault-relative
  title: string;
  tags: string[];
  /** labels_reviewed: false */
  unconfirmed: boolean;
  origin?: LabelOrigin;
  labelsBy?: string;
  system: boolean;
}

const HEAD_BYTES = 64 * 1024;
const ORIGINS: LabelOrigin[] = ['queue-folder', 'cli', 'suggest'];

async function readHead(file: string): Promise<string> {
  const handle = await fsp.open(file, 'r');
  try {
    const buffer = Buffer.alloc(HEAD_BYTES);
    const { bytesRead } = await handle.read(buffer, 0, HEAD_BYTES, 0);
    return buffer.subarray(0, bytesRead).toString('utf8');
  } finally {
    await handle.close();
  }
}

async function markdownFiles(dir: string, rel: string, out: string[]): Promise<void> {
  let entries: import('node:fs').Dirent[];
  try {
    entries = await fsp.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    const childRel = `${rel}/${e.name}`;
    if (e.isDirectory()) await markdownFiles(path.join(dir, e.name), childRel, out);
    else if (e.isFile() && e.name.toLowerCase().endsWith('.md')) out.push(childRel);
  }
}

/** Every Markdown page under `<vault>/wiki/` (no symlinks, no hidden folders), sorted. */
export async function scanPages(vaultPath: string): Promise<LabeledPage[]> {
  const files: string[] = [];
  await markdownFiles(path.join(vaultPath, 'wiki'), 'wiki', files);
  files.sort();
  const pages: LabeledPage[] = [];
  for (const rel of files) {
    let head: string;
    try {
      head = await readHead(path.join(vaultPath, rel));
    } catch {
      continue;
    }
    const fm = parseFrontmatter(head);
    const origin = scalarValue(fm, 'labels_origin') as LabelOrigin | undefined;
    const page: LabeledPage = {
      path: rel,
      title: scalarValue(fm, 'title') ?? path.posix.basename(rel, '.md'),
      tags: readTags(listValue(fm, 'tags')),
      unconfirmed: scalarValue(fm, 'labels_reviewed')?.toLowerCase() === 'false',
      system: isSystemPage(rel, scalarValue(fm, 'type')),
    };
    if (origin && ORIGINS.includes(origin)) page.origin = origin;
    const by = scalarValue(fm, 'labels_by');
    if (by) page.labelsBy = by;
    pages.push(page);
  }
  return pages;
}

/** Label counts over note pages (system pages excluded), most used first. */
export function countLabels(pages: LabeledPage[]): LabelCount[] {
  const counts = new Map<string, LabelCount>();
  for (const p of pages) {
    if (p.system) continue;
    for (const tag of p.tags) {
      const c = counts.get(tag) ?? { name: tag, count: 0, unconfirmed: 0 };
      c.count += 1;
      if (p.unconfirmed) c.unconfirmed += 1;
      counts.set(tag, c);
    }
  }
  return [...counts.values()].sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
}

export function reviewLabels(pages: LabeledPage[]): LabelReview {
  const toReview: LabelReviewItem[] = [];
  const unlabeled: { path: string; title: string }[] = [];
  for (const p of pages) {
    if (p.system) continue;
    if (p.unconfirmed) {
      toReview.push({ path: p.path, title: p.title, labels: p.tags, origin: p.origin ?? null });
    } else if (p.tags.length === 0) {
      unlabeled.push({ path: p.path, title: p.title });
    }
  }
  return { toReview, unlabeled };
}

/** Labels already used in the vault, most used first (what suggestions should reuse). */
export async function existingLabels(vaultPath: string): Promise<string[]> {
  return countLabels(await scanPages(vaultPath)).map((c) => c.name);
}
