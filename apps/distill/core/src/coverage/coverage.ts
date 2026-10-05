import fs from 'node:fs';
import path from 'node:path';
import type { CoverageSummary } from '../contracts.js';
import { isObject, readJSON, writeFileAtomic } from '../store/json.js';
import type { ReadingCopy, Section, SourceKind } from './copy.js';
import type { StreamEvent } from './stream.js';

/**
 * Coverage of one batch session (full-read.md, section 3), kept in `<job dir>/coverage.json`
 * (numbers and paths only). It accumulates across the turns of ONE session and is reset when the
 * batch moves to a new one. The job carries a short summary (`job.coverage`) for clients.
 */

export type Range = [number, number];

export interface CoverageSourceRecord {
  file: string;
  kind: SourceKind;
  sha256: string;
  /** Absolute path of the reading copy (text sources). */
  copy?: string;
  /** Lines the copy has (text), pages (PDF), 1 (image/other). */
  lines: number;
  sourceLines: number;
  /** Copy lines that are image placeholders: never required. */
  imageLines: number[];
  sections: Section[];
  unreadable?: string;
  estTokens: number;
  /** Continuations that asked for lines of this source (0 or absent: read in the first pass). */
  rounds?: number;
}

export interface CoverageRecord {
  version: 1;
  sessionID: string;
  seq: number;
  lastContext: number;
  sources: CoverageSourceRecord[];
  events: StreamEvent[];
  /** Automatic continuations sent in this session (all kinds count toward MAX_CONTINUATIONS). */
  rounds: number;
  /** Lines credited when the last continuation was sent (stop early when a round adds none). */
  creditedAtLastRound: number;
  /** sha256 of each source's page draft when a continuation asked for new lines to be read. */
  pageShaAtRound?: Record<string, string>;
  /** The detail pass ran (once per session) and what it found. */
  detail?: { ran: boolean; missing: number; left?: number };
}

export const MAX_CONTINUATIONS = 3;

export function coverageFile(jobDir: string): string {
  return path.join(jobDir, 'coverage.json');
}

export function newRecord(sessionID: string, copies: ReadingCopy[]): CoverageRecord {
  return {
    version: 1,
    sessionID,
    seq: 0,
    lastContext: 0,
    sources: copies.map(sourceRecord),
    events: [],
    rounds: 0,
    creditedAtLastRound: 0,
  };
}

export function sourceRecord(c: ReadingCopy): CoverageSourceRecord {
  const imageLines: number[] = [];
  if (c.copy && c.imageLines > 0) {
    try {
      const lines = fs.readFileSync(c.copy, 'utf8').split('\n');
      lines.forEach((l, i) => {
        if (i < c.sourceLines && /^\[[^\]]*: embedded [A-Z0-9.+-]+, \d+ KB, not text\]$/.test(l)) imageLines.push(i + 1);
      });
    } catch {
      /* no placeholders known: they are then simply required */
    }
  }
  const r: CoverageSourceRecord = {
    file: c.file,
    kind: c.kind,
    sha256: c.sha256,
    lines: c.lines,
    sourceLines: c.sourceLines,
    imageLines,
    sections: c.sections,
    estTokens: c.estTokens,
  };
  if (c.copy) r.copy = c.copy;
  if (c.unreadable) r.unreadable = c.unreadable;
  return r;
}

export function loadRecord(jobDir: string): CoverageRecord | undefined {
  try {
    const v = readJSON(coverageFile(jobDir));
    if (!isObject(v) || v.version !== 1 || !Array.isArray(v.sources) || !Array.isArray(v.events)) return undefined;
    return v as unknown as CoverageRecord;
  } catch {
    return undefined;
  }
}

export function saveRecord(jobDir: string, r: CoverageRecord): void {
  fs.mkdirSync(jobDir, { recursive: true });
  writeFileAtomic(coverageFile(jobDir), JSON.stringify(r), 0o600);
}

// ───────────── ranges ─────────────

export function mergeRanges(rs: Range[]): Range[] {
  const s = rs.filter((r) => r[1] >= r[0]).sort((a, b) => a[0] - b[0]);
  const out: Range[] = [];
  for (const r of s) {
    const last = out.at(-1);
    if (last && r[0] <= last[1] + 1) last[1] = Math.max(last[1], r[1]);
    else out.push([r[0], r[1]]);
  }
  return out;
}

export function rangesLength(rs: Range[]): number {
  return rs.reduce((n, r) => n + (r[1] - r[0] + 1), 0);
}

/** `required` minus `have`. */
export function subtractRanges(required: Range[], have: Range[]): Range[] {
  const out: Range[] = [];
  const h = mergeRanges(have);
  for (const [a, b] of mergeRanges(required)) {
    let start = a;
    for (const [c, d] of h) {
      if (d < start || c > b) continue;
      if (c > start) out.push([start, Math.min(b, c - 1)]);
      start = Math.max(start, d + 1);
      if (start > b) break;
    }
    if (start <= b) out.push([start, b]);
  }
  return out;
}

export function requiredRanges(s: CoverageSourceRecord): Range[] {
  if (s.unreadable || s.lines <= 0) return [];
  if (s.kind !== 'text') return [[1, 1]];
  const skip = new Set(s.imageLines);
  const out: Range[] = [];
  let start = 0;
  for (let i = 1; i <= s.lines; i++) {
    if (skip.has(i)) {
      if (start) out.push([start, i - 1]);
      start = 0;
    } else if (!start) start = i;
  }
  if (start) out.push([start, s.lines]);
  return out;
}

// ───────────── matching reads to sources ─────────────

function norm(p: string): string {
  let abs = path.resolve(p).normalize('NFC');
  try {
    abs = fs.realpathSync(abs).normalize('NFC');
  } catch {
    /* not on disk any more: compare the resolved path */
  }
  return abs;
}

export interface MatchContext {
  vaultPath: string;
  /** Draft file → source file, from the final bundle (content_file of a source page; bundle.json for inline pages). */
  drafts?: Map<string, string>;
}

/** Each source's credited ranges, and how many lines a source still lacks. */
export interface SourceCoverage {
  file: string;
  required: number;
  read: number;
  missing: Range[];
  full: boolean;
  unreadable?: string;
}

export function computeCoverage(r: CoverageRecord, m: MatchContext): SourceCoverage[] {
  const byPath = new Map<string, { s: CoverageSourceRecord; copy: boolean }>();
  for (const s of r.sources) {
    byPath.set(norm(path.join(m.vaultPath, s.file)), { s, copy: false });
    if (s.copy) byPath.set(norm(s.copy), { s, copy: true });
  }
  const lastCompact = Math.max(0, ...r.events.filter((e) => e.t === 'compact').map((e) => e.seq));
  const writes = r.events.filter((e): e is Extract<StreamEvent, { t: 'write' }> => e.t === 'write').map((e) => ({ seq: e.seq, path: norm(path.isAbsolute(e.path) ? e.path : path.join(m.vaultPath, e.path)) }));
  const draftsOf = new Map<string, Set<string>>();
  for (const [draft, file] of m.drafts ?? []) {
    const set = draftsOf.get(file) ?? new Set<string>();
    set.add(norm(draft));
    draftsOf.set(file, set);
  }
  const credit = new Map<string, Range[]>();
  for (const e of r.events) {
    if (e.t !== 'read') continue;
    const hit = byPath.get(norm(path.isAbsolute(e.path) ? e.path : path.join(m.vaultPath, e.path)));
    if (!hit) continue;
    const s = hit.s;
    // Reads before a compaction count only when a later write of the source's page draft follows them.
    if (e.seq < lastCompact) {
      const drafts = draftsOf.get(s.file);
      if (!drafts || !writes.some((w) => w.seq > e.seq && drafts.has(w.path))) continue;
    }
    const list = credit.get(s.file) ?? [];
    if (s.kind !== 'text') {
      list.push([1, 1]);
    } else if (!e.whole) {
      // A read of the original (not the copy) can't credit the split pieces after its last line.
      const max = hit.copy ? s.lines : s.sourceLines;
      const from = Math.max(1, e.from);
      const to = Math.min(max, e.to);
      if (to >= from) list.push([from, to]);
    }
    credit.set(s.file, list);
  }
  return r.sources.map((s) => {
    const req = requiredRanges(s);
    const have = credit.get(s.file) ?? [];
    const missing = subtractRanges(req, have);
    const required = rangesLength(req);
    const out: SourceCoverage = { file: s.file, required, read: required - rangesLength(missing), missing, full: !s.unreadable && missing.length === 0 };
    if (s.unreadable) out.unreadable = s.unreadable;
    return out;
  });
}

export function creditedLines(cov: SourceCoverage[]): number {
  return cov.reduce((n, c) => n + c.read, 0);
}

export function summarize(cov: SourceCoverage[], r: CoverageRecord, state: CoverageSummary['state']): CoverageSummary {
  const readable = cov.filter((c) => !c.unreadable);
  return {
    sources: cov.map((c) => ({
      file: c.file,
      lines: c.required,
      read: c.read,
      state: c.unreadable ? 'unreadable' : c.full ? 'full' : 'partial',
      ...(c.unreadable ? { reason: c.unreadable } : {}),
      ...(r.sources.find((s) => s.file === c.file)?.imageLines.length ? { images: r.sources.find((s) => s.file === c.file)!.imageLines.length } : {}),
      ...(r.sources.find((s) => s.file === c.file)?.rounds ? { rounds: r.sources.find((s) => s.file === c.file)!.rounds! } : {}),
    })),
    full: readable.filter((c) => c.full).length,
    of: readable.length,
    lines: readable.reduce((n, c) => n + c.required, 0),
    rounds: r.rounds,
    continued: r.sources.filter((s) => (s.rounds ?? 0) > 0).length,
    state,
  };
}

// ───────────── what to ask for ─────────────

/** Missing ranges cut at the source's planned section boundaries, as Read offset/limit pairs. */
export function readsFor(missing: Range[], sections: Section[]): Range[] {
  const out: Range[] = [];
  for (const [a, b] of missing) {
    let start = a;
    const cuts = sections.map((s) => s.to).filter((t) => t >= a && t < b);
    for (const c of cuts) {
      out.push([start, c]);
      start = c + 1;
    }
    out.push([start, b]);
  }
  // Keep each read at most 400 lines even without a section plan.
  return out.flatMap(([a, b]) => {
    const parts: Range[] = [];
    for (let s = a; s <= b; s += 400) parts.push([s, Math.min(b, s + 399)]);
    return parts;
  });
}

export function rangeText(rs: Range[]): string {
  return rs.map(([a, b]) => (a === b ? `line ${a}` : `lines ${a}–${b}`)).join(', ');
}

export function continuationPrompt(r: CoverageRecord, cov: SourceCoverage[], bundlePath: string, vaultPath: string): string {
  const lines = [
    'These parts of the batch were NOT read. Distill counts the lines each Read returned, and these lines never came back.',
    'Read each one with the Read tool exactly as given (a Read can return fewer lines than asked: continue from the last line it returned), then update that source’s page draft from what you read, rebuild the bundle at the same path, inspect it, and finish with `needs_approval`.',
    '',
  ];
  for (const c of cov) {
    if (c.full || c.unreadable) continue;
    const s = r.sources.find((x) => x.file === c.file)!;
    if (s.kind !== 'text') {
      lines.push(`- ${c.file}: read it with the Read tool (it was never read successfully).`);
      continue;
    }
    const reads = readsFor(c.missing, s.sections);
    const target = s.copy ? path.relative(vaultPath, s.copy) : c.file;
    lines.push(
      `- ${c.file} (read the copy ${target}): ${rangeText(c.missing)} — ` +
        reads.map(([a, b]) => `Read offset ${a} limit ${b - a + 1}`).join('; '),
    );
  }
  lines.push('', `The bundle: ${bundlePath}. Keep \`source_path\` on each source page as the source’s path above, never the copy’s path.`);
  return lines.join('\n');
}

// ───────────── what the pages say ─────────────

/**
 * Wording that says a source was not fully read (tuned on the owner's 13 pages: "so this page is
 * partial", "partial on transcript detail", "were not read", "only read for its first minutes").
 * Kept narrow so "a partial payment" in a meeting is not taken for it.
 */
export const PARTIAL_WORDING: RegExp[] = [
  /\b(?:page|source|summary|ingest|this) (?:is|was|remains) partial\b/i,
  /\bpartial on\b/i,
  /\bpartial(?:ly)? (?:read|ingested|covered|page|source|coverage)\b/i,
  /\bmarked partial\b/i,
  /\bnot (?:been )?(?:fully |completely )?read\b/i,
  /\bread only (?:up to|the first|part)\b/i,
  /\bonly read (?:for|the|up to)\b/i,
  /\bfirst \d+ (?:lines|minutes)\b/i,
  /\btranche\b/i,
];

/** The first sentence-ish snippet of `text` that says the source was not fully read, or undefined. */
export function partialWording(text: string): string | undefined {
  const body = text.replace(/^---\n[\s\S]*?\n---\n/, '');
  for (const re of PARTIAL_WORDING) {
    const m = re.exec(body);
    if (m) {
      const start = Math.max(0, body.lastIndexOf('\n', m.index) + 1);
      const end = body.indexOf('\n', m.index);
      return body.slice(start, end < 0 ? undefined : end).trim().slice(0, 160);
    }
  }
  return undefined;
}

export function partialPrompt(found: { page: string; file: string; snippet: string }[], bundlePath: string): string {
  return [
    'Every line of these sources was read (Distill counted the lines each Read returned), but the change still says they were read only in part:',
    ...found.map((f) => `- ${f.page} (from ${f.file}): “${f.snippet}”`),
    '',
    `Drop that wording, update the pages (and the log and hot cache entries) from the whole source, rebuild the bundle at ${bundlePath}, inspect it, and finish with \`needs_approval\`.`,
  ].join('\n');
}

export function unchangedPagePrompt(found: { page: string; file: string; ranges: string }[], bundlePath: string): string {
  return [
    'You read more of these sources, but their pages did not change. Update each page from what the newly read lines say:',
    ...found.map((f) => `- ${f.page} (from ${f.file}): ${f.ranges}`),
    '',
    `Rebuild the bundle at ${bundlePath}, inspect it, and finish with \`needs_approval\`.`,
  ].join('\n');
}
