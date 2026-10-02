import { scanPages, type LabeledPage } from '../labels/vault.js';

/** A vault page for the note picker (`[[`, ⌘K). */
export interface PageRef {
  path: string; // vault-relative, e.g. wiki/sources/sencha.md
  title: string; // frontmatter `title`, else the file name without .md
}

export const DEFAULT_PAGE_LIMIT = 8;
export const MAX_PAGE_LIMIT = 50;

export function clampPageLimit(limit: number | undefined): number {
  if (limit === undefined || !Number.isFinite(limit)) return DEFAULT_PAGE_LIMIT;
  return Math.max(1, Math.min(MAX_PAGE_LIMIT, Math.floor(limit)));
}

function fold(s: string): string {
  return s.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

/** Characters of `q` appear in order in `s`: a score that prefers tight, early matches; 0 = no match. */
function subsequenceScore(s: string, q: string): number {
  let at = -1;
  let first = -1;
  for (const ch of q) {
    at = s.indexOf(ch, at + 1);
    if (at === -1) return 0;
    if (first === -1) first = at;
  }
  const span = at - first + 1;
  return 20 * (q.length / span) - Math.min(first, 10) * 0.5;
}

/** How well `text` matches `query` (both folded); 0 = no match. */
function matchScore(text: string, query: string): number {
  if (!text) return 0;
  if (text === query) return 100;
  if (text.startsWith(query)) return 80;
  const words = text.split(/[\s\-_/.()]+/).filter(Boolean);
  if (words.some((w) => w.startsWith(query))) return 65;
  // Every query word starts some word of the text ("sen bas" → "Sencha basics").
  const qWords = query.split(/\s+/).filter(Boolean);
  if (qWords.length > 1 && qWords.every((q) => words.some((w) => w.startsWith(q)))) return 55;
  if (text.includes(query)) return 45;
  return subsequenceScore(text, query.replace(/\s+/g, ''));
}

/**
 * Rank pages for a query: exact title, title prefix, word prefix, all words,
 * substring, then in-order letters. The file name counts too (slightly less).
 * Ties go to shorter titles, then alphabetical. Empty query: alphabetical.
 */
export function rankPages(pages: PageRef[], query: string, limit?: number): PageRef[] {
  const n = clampPageLimit(limit);
  const q = fold(query.trim());
  const byTitle = (a: PageRef, b: PageRef) => a.title.length - b.title.length || a.title.localeCompare(b.title) || a.path.localeCompare(b.path);
  if (!q) return [...pages].sort((a, b) => a.title.localeCompare(b.title) || a.path.localeCompare(b.path)).slice(0, n);
  const scored: { page: PageRef; score: number }[] = [];
  for (const page of pages) {
    const base = page.path.split('/').pop()!.replace(/\.md$/i, '');
    const score = Math.max(matchScore(fold(page.title), q), matchScore(fold(base), q) * 0.9);
    if (score > 0) scored.push({ page, score });
  }
  scored.sort((a, b) => b.score - a.score || byTitle(a.page, b.page));
  return scored.slice(0, n).map((s) => s.page);
}

/** Note pages (system pages like index, log and hot excluded) for the picker. */
export function pickablePages(pages: LabeledPage[]): PageRef[] {
  return pages.filter((p) => !p.system).map((p) => ({ path: p.path, title: p.title }));
}

/** Scan `<vault>/wiki/**\/*.md` and rank the note pages for `query`. */
export async function searchVaultPages(vaultPath: string, query: string, limit?: number): Promise<PageRef[]> {
  return rankPages(pickablePages(await scanPages(vaultPath)), query, limit);
}
