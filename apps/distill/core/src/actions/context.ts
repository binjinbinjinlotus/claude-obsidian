/**
 * Action context (action-context.md): where in the ORIGINAL an action comes from, and which wiki
 * page and section it relates to. Everything here is deterministic: the lines are located by the
 * core in the original's text, never taken from the model's report.
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { ActionRawRef, ActionWikiRef } from '../contracts.js';
import { archivedCopy, ledgerRecords, type LedgerRecord } from '../coverage/archive.js';
import { BYTES_PER_TOKEN, type Section } from '../coverage/copy.js';

export const EXCERPT_CHARS = 1500;
export const WIKI_EXCERPT_CHARS = 800;
/** One find window: consecutive planned sections up to this many tokens (about 62 KB of text). */
export const WINDOW_TOKENS = 24_000;
/** Ask: the closest lines count only when this share of the action's words is on them. */
export const CLOSEST_MIN = 0.4;
const CLOSEST_WINDOW = 8;

/** Lower case, quotes and punctuation as spaces, spaces collapsed. */
export function normalizeForMatch(s: string): string {
  return s
    .normalize('NFC')
    .toLowerCase()
    .replace(/[‘’“”"'`]/g, '')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

/** Copy line n → source line: an appendix line `L<n>↪ …` belongs to source line n. */
export function sourceLineOf(copyLines: string[], n: number, sourceLines: number): number {
  if (n <= sourceLines) return n;
  const m = /^L(\d+)↪/.exec(copyLines[n - 1] ?? '');
  return m ? Number(m[1]) : sourceLines;
}

function searchRange(norm: string[], needle: string, from: number, to: number, span = 14): [number, number] | undefined {
  for (let i = Math.max(1, from); i <= Math.min(norm.length, to); i++) {
    let joined = '';
    for (let j = i; j <= Math.min(norm.length, i + span - 1); j++) {
      const piece = norm[j - 1]!;
      if (piece) joined = joined ? `${joined} ${piece}` : piece;
      if (joined.includes(needle)) {
        // Shrink from the start: the last start line from which [start, j] still holds the needle.
        let start = i;
        while (start < j && norm.slice(start, j).filter(Boolean).join(' ').includes(needle)) start++;
        return [start, j];
      }
      if (joined.length > needle.length * 3 + 2000) break;
    }
  }
  return undefined;
}

/**
 * The copy lines (1-based, inclusive) holding `quote`, searched first around `hint` (±3 lines),
 * then in the whole copy. A long quote that isn't found whole is tried by its first and last 60
 * characters, which must be found within 14 lines of each other.
 */
export function locateQuote(copyLines: string[], quote: string | null | undefined, hint?: [number, number] | null): [number, number] | undefined {
  const needle = normalizeForMatch(quote ?? '');
  if (needle.length < 8) return undefined;
  const norm = copyLines.map(normalizeForMatch);
  const tries: [number, number][] = [];
  if (hint) tries.push([hint[0] - 3, hint[1] + 3]);
  tries.push([1, norm.length]);
  for (const [a, b] of tries) {
    const hit = searchRange(norm, needle, a, b);
    if (hit) return hit;
  }
  if (needle.length > 90) {
    const head = needle.slice(0, 60).trim();
    const tail = needle.slice(-60).trim();
    for (const [a, b] of tries) {
      const h = searchRange(norm, head, a, b);
      if (!h) continue;
      const t = searchRange(norm, tail, h[0], h[0] + 14);
      if (t) return [h[0], Math.max(h[1], t[1])];
    }
  }
  return undefined;
}

/** "210-214", "210–214", "L210", "210" → [210, 214]; undefined when it isn't lines. */
export function parseLines(s: unknown): [number, number] | undefined {
  if (typeof s !== 'string') return undefined;
  const m = /(\d+)\s*(?:[-–—]|to|\.\.)\s*L?(\d+)/.exec(s) ?? /(\d+)/.exec(s);
  if (!m) return undefined;
  const a = Number(m[1]);
  const b = m[2] !== undefined ? Number(m[2]) : a;
  if (!(a > 0) || !(b > 0)) return undefined;
  return a <= b ? [a, b] : [b, a];
}

export function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text;
}

/** The text of source lines [from, to] from the copy, at most EXCERPT_CHARS. */
export function excerptOf(copyLines: string[], from: number, to: number): string {
  return clip(copyLines.slice(from - 1, to).join('\n').trim(), EXCERPT_CHARS);
}

// ───────────── windows ─────────────

export interface FindWindow {
  from: number;
  to: number;
}

/** Consecutive planned sections grouped into windows of at most `maxTokens`; together they cover every line. */
export function windowsOf(lines: string[], sections: Section[], maxTokens = WINDOW_TOKENS): FindWindow[] {
  const secs = sections.length > 0 ? sections : lines.length > 0 ? [{ from: 1, to: lines.length }] : [];
  const tokens = (s: Section) => {
    let bytes = 0;
    for (let i = s.from; i <= s.to; i++) bytes += Buffer.byteLength(lines[i - 1] ?? '', 'utf8') + 1;
    return bytes / BYTES_PER_TOKEN;
  };
  const out: FindWindow[] = [];
  let cur: FindWindow | undefined;
  let t = 0;
  for (const s of secs) {
    const n = tokens(s);
    if (cur && t + n <= maxTokens) {
      cur.to = s.to;
      t += n;
    } else {
      if (cur) out.push(cur);
      cur = { from: s.from, to: s.to };
      t = n;
    }
  }
  if (cur) out.push(cur);
  return out;
}

/** Ranges merged; the number of lines they cover. */
export function coveredLines(ranges: [number, number][]): number {
  const sorted = [...ranges].sort((a, b) => a[0] - b[0]);
  let n = 0;
  let end = 0;
  for (const [a, b] of sorted) {
    if (b <= end) continue;
    n += b - Math.max(a, end + 1) + 1;
    end = b;
  }
  return n;
}

export function numbered(lines: string[], from: number, to: number): string {
  const out: string[] = [];
  for (let i = from; i <= to; i++) out.push(`${i}\t${lines[i - 1] ?? ''}`);
  return out.join('\n');
}

// ───────────── wiki pages ─────────────

export interface Heading {
  level: number;
  text: string;
  line: number;
}

/** Headings outside the front matter and code fences. */
export function headingsOf(text: string): Heading[] {
  const lines = text.split('\n');
  const out: Heading[] = [];
  let i = 0;
  if (lines[0]?.trim() === '---') {
    i = 1;
    while (i < lines.length && lines[i]!.trim() !== '---') i++;
    i++;
  }
  let fence = false;
  for (; i < lines.length; i++) {
    const l = lines[i]!;
    if (/^\s*(```|~~~)/.test(l)) fence = !fence;
    if (fence) continue;
    const m = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(l);
    if (m) out.push({ level: m[1]!.length, text: m[2]!.trim(), line: i + 1 });
  }
  return out;
}

/** The section under `heading` (to the next heading of the same or a higher level); the body without front matter when absent. */
export function sectionText(text: string, heading?: string | null): string | undefined {
  const lines = text.split('\n');
  const hs = headingsOf(text);
  if (!heading) {
    let start = 0;
    if (lines[0]?.trim() === '---') {
      start = 1;
      while (start < lines.length && lines[start]!.trim() !== '---') start++;
      start++;
    }
    return lines.slice(start).join('\n').trim();
  }
  const want = normalizeForMatch(heading);
  const h = hs.find((x) => normalizeForMatch(x.text) === want);
  if (!h) return undefined;
  const next = hs.find((x) => x.line > h.line && x.level <= h.level);
  return lines.slice(h.line - 1, next ? next.line - 1 : lines.length).join('\n').trim();
}

function wordsOf(s: string): Set<string> {
  return new Set(normalizeForMatch(s).split(' ').filter((w) => w.length >= 4));
}

/** The heading whose section shares the most of `query`'s words (undefined: none share any). */
export function bestHeading(text: string, query: string): string | undefined {
  const want = wordsOf(query);
  if (want.size === 0) return undefined;
  let best: { heading: string; score: number } | undefined;
  for (const h of headingsOf(text)) {
    if (h.level === 1) continue;
    const body = sectionText(text, h.text) ?? '';
    const have = wordsOf(body);
    let score = 0;
    for (const w of want) if (have.has(w)) score++;
    if (score > 0 && (!best || score > best.score)) best = { heading: h.text, score };
  }
  return best?.heading;
}

export function titleOfPage(text: string, file: string): string {
  const fm = /^---\n(?:[\s\S]*?\n)?title:\s*["']?(.+?)["']?\s*\n[\s\S]*?---/.exec(text);
  if (fm?.[1]) return fm[1];
  const h = /^#\s+(.+)$/m.exec(text);
  return h?.[1]?.trim() ?? path.basename(file, path.extname(file));
}

/** A wiki ref with its section's excerpt; undefined when the heading isn't on the page. */
export function wikiRef(pagePath: string, text: string, heading?: string | null): ActionWikiRef | undefined {
  const body = sectionText(text, heading);
  if (body === undefined) return undefined;
  const ref: ActionWikiRef = { path: pagePath, title: titleOfPage(text, pagePath) };
  if (heading) ref.heading = headingsOf(text).find((h) => normalizeForMatch(h.text) === normalizeForMatch(heading))?.text ?? heading;
  const lines = body.split('\n');
  const content = (heading ? lines.slice(1) : lines).join('\n').trim();
  if (content) ref.excerpt = clip(content, WIKI_EXCERPT_CHARS);
  return ref;
}

// ───────────── originals ─────────────

export function sha256File(abs: string): string | undefined {
  try {
    return createHash('sha256').update(fs.readFileSync(abs)).digest('hex');
  } catch {
    return undefined;
  }
}

function inside(vaultPath: string, rel: string): string | undefined {
  const vault = path.resolve(vaultPath);
  const abs = path.resolve(vault, rel);
  return abs.startsWith(vault + path.sep) ? abs : undefined;
}

/**
 * Where an original is now (vault-relative): the archive copy of its content, else `raw.path`, else
 * `raw.inboxPath` when it still hashes the same (or has no hash to check). Undefined: gone.
 */
export function resolveOriginal(vaultPath: string, raw: Pick<ActionRawRef, 'path' | 'inboxPath' | 'sha256'>): string | undefined {
  if (raw.sha256) {
    const archived = archivedCopy(vaultPath, raw.sha256);
    if (archived) return archived;
  }
  for (const rel of [raw.path, raw.inboxPath]) {
    if (!rel) continue;
    const abs = inside(vaultPath, rel);
    if (!abs || !fs.existsSync(abs)) continue;
    if (raw.sha256 && sha256File(abs) !== raw.sha256) continue;
    return rel;
  }
  return undefined;
}

/** Text lines of a vault file (CR stripped), or undefined. */
export function readLines(vaultPath: string, rel: string): string[] | undefined {
  const abs = inside(vaultPath, rel);
  if (!abs) return undefined;
  try {
    let text = fs.readFileSync(abs, 'utf8');
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    const lines = text.split('\n').map((l) => (l.endsWith('\r') ? l.slice(0, -1) : l));
    if (lines.at(-1) === '') lines.pop();
    return lines;
  } catch {
    return undefined;
  }
}

/** A window of `lines` centred on [from, to], at most `maxChars`, with its first line number. */
export function windowAround(lines: string[], from: number, to: number, pad = 25, maxChars = 12_000): { from: number; to: number; text: string } {
  let a = Math.max(1, from - pad);
  let b = Math.min(lines.length, to + pad);
  const size = () => lines.slice(a - 1, b).reduce((n, l) => n + l.length + 1, 0);
  while (size() > maxChars && (a < from || b > to)) {
    if (from - a >= b - to && a < from) a++;
    else if (b > to) b--;
    else a++;
  }
  let text = lines.slice(a - 1, b).join('\n');
  if (text.length > maxChars) text = text.slice(0, maxChars);
  return { from: a, to: b, text };
}

/** Ask: the 8-line window that shares the most distinct 4+-letter words with `query`, when at least CLOSEST_MIN of them. */
export function closestLines(lines: string[], query: string, minShare = CLOSEST_MIN): { from: number; to: number; share: number } | undefined {
  const want = wordsOf(query);
  if (want.size < 2 || lines.length === 0) return undefined;
  const per = lines.map((l) => wordsOf(l));
  let best: { from: number; to: number; share: number } | undefined;
  for (let i = 0; i < lines.length; i++) {
    const seen = new Set<string>();
    let first = -1;
    let last = -1;
    for (let j = i; j < Math.min(lines.length, i + CLOSEST_WINDOW); j++) {
      let hit = false;
      for (const w of per[j]!) {
        if (want.has(w) && !seen.has(w)) {
          seen.add(w);
          hit = true;
        }
      }
      if (hit) {
        if (first < 0) first = j;
        last = j;
      }
    }
    const share = seen.size / want.size;
    if (first >= 0 && (!best || share > best.share)) best = { from: first + 1, to: last + 1, share };
  }
  return best && best.share >= minShare ? best : undefined;
}

/** The archived (or still matching) original of a wiki page, through the source ledger or its `source_path`. */
export function originalOfPage(vaultPath: string, page: string, records?: LedgerRecord[]): { path: string; sha256?: string; inboxPath?: string } | undefined {
  let recs: LedgerRecord[];
  try {
    recs = records ?? ledgerRecords(vaultPath);
  } catch {
    recs = [];
  }
  const candidates: { sha256?: string; locator?: string }[] = recs.filter((r) => r.pages.includes(page)).map((r) => ({ ...(r.sha256 ? { sha256: r.sha256 } : {}), locator: r.locator }));
  const text = readLines(vaultPath, page)?.slice(0, 40).join('\n') ?? '';
  const sp = /^source_path:\s*["']?(.+?)["']?\s*$/m.exec(text)?.[1];
  if (sp) candidates.push({ locator: sp });
  for (const c of candidates) {
    const sha = c.sha256 ?? (c.locator ? (inside(vaultPath, c.locator) ? sha256File(inside(vaultPath, c.locator)!) : undefined) : undefined);
    const at = resolveOriginal(vaultPath, { path: c.locator ?? '', inboxPath: null, sha256: sha ?? null });
    if (at) return { path: at, ...(sha ? { sha256: sha } : {}), ...(c.locator && c.locator !== at ? { inboxPath: c.locator } : {}) };
  }
  return undefined;
}
