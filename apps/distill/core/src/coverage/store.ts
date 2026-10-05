import fs from 'node:fs';
import path from 'node:path';
import { encodeJSON, isObject, readJSON, writeFileAtomic } from '../store/json.js';

/**
 * Distill's own records about full reads, in `<state>/coverage/` (full-read.md):
 *
 * - `sources.json`: per source sha256, whether a batch whose pages APPLIED read it in full. This is
 *   what Clean up inbox and the repair use; "partial" is data from the core, never page prose.
 * - `repair.json`: which sources the automatic repair already re-read (never twice).
 * - `models.json`: each model's context window, as the runner reported it.
 */

export interface SourceCoverageEntry {
  full: boolean;
  /** The vault-relative file it was read from. */
  file: string;
  lines: number;
  jobId: string;
  at: string;
  pages?: string[];
  /** Recorded from a past job's saved stream at start, not live. */
  backfilled?: boolean;
}

function load(file: string): Record<string, unknown> {
  try {
    const v = readJSON(file);
    return isObject(v) ? v : {};
  } catch {
    return {};
  }
}

function save(file: string, value: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  writeFileAtomic(file, encodeJSON(value), 0o600);
}

export class CoverageIndex {
  private entries: Record<string, SourceCoverageEntry> = {};
  constructor(readonly file: string) {
    const v = load(file);
    const list = isObject(v.sources) ? v.sources : {};
    for (const [sha, e] of Object.entries(list)) {
      if (!isObject(e) || typeof e.full !== 'boolean' || typeof e.file !== 'string' || typeof e.jobId !== 'string') continue;
      const entry: SourceCoverageEntry = { full: e.full, file: e.file, lines: typeof e.lines === 'number' ? e.lines : 0, jobId: e.jobId, at: typeof e.at === 'string' ? e.at : '' };
      if (Array.isArray(e.pages)) entry.pages = e.pages.filter((p): p is string => typeof p === 'string');
      if (e.backfilled === true) entry.backfilled = true;
      this.entries[sha] = entry;
    }
  }
  get(sha: string): SourceCoverageEntry | undefined {
    return this.entries[sha];
  }
  isFull(sha: string): boolean {
    return this.entries[sha]?.full === true;
  }
  /** A full read is never downgraded by a later partial one. */
  record(sha: string, e: SourceCoverageEntry): void {
    if (this.entries[sha]?.full && !e.full) return;
    this.entries[sha] = e;
    save(this.file, { version: 1, sources: this.entries });
  }
  all(): Record<string, SourceCoverageEntry> {
    return { ...this.entries };
  }
}

export interface RepairAttempt {
  at: string;
  rereadId?: string;
  file: string;
}

export class RepairLog {
  private attempts: Record<string, RepairAttempt> = {};
  lastScan: Record<string, string> = {};
  constructor(readonly file: string) {
    const v = load(file);
    if (isObject(v.attempts)) {
      for (const [sha, a] of Object.entries(v.attempts)) {
        if (isObject(a) && typeof a.at === 'string' && typeof a.file === 'string') {
          this.attempts[sha] = { at: a.at, file: a.file, ...(typeof a.rereadId === 'string' ? { rereadId: a.rereadId } : {}) };
        }
      }
    }
    if (isObject(v.lastScan)) for (const [k, d] of Object.entries(v.lastScan)) if (typeof d === 'string') this.lastScan[k] = d;
  }
  tried(sha: string): boolean {
    return sha in this.attempts;
  }
  add(sha: string, a: RepairAttempt): void {
    this.attempts[sha] = a;
  }
  save(): void {
    save(this.file, { version: 1, attempts: this.attempts, lastScan: this.lastScan });
  }
}

/** Context windows by model id or alias, as the runner reported them (`modelUsage[…].contextWindow`). */
export class ModelWindows {
  private windows: Record<string, number> = {};
  constructor(readonly file: string) {
    const v = load(file);
    if (isObject(v.windows)) for (const [k, n] of Object.entries(v.windows)) if (typeof n === 'number' && n > 0) this.windows[k] = n;
  }
  get(model: string): number | undefined {
    return this.windows[model];
  }
  set(models: Record<string, number>, alias?: string): void {
    let changed = false;
    for (const [k, n] of Object.entries(models)) {
      if (this.windows[k] !== n) {
        this.windows[k] = n;
        changed = true;
      }
    }
    const first = Object.values(models)[0];
    if (alias && first && Object.keys(models).length === 1 && this.windows[alias] !== first) {
      this.windows[alias] = first;
      changed = true;
    }
    if (changed) save(this.file, { version: 1, windows: this.windows });
  }
}

/** Known context windows when the runner hasn't reported one yet; anything else counts as 200K. */
const KNOWN_WINDOWS: [RegExp, number][] = [
  [/sonnet-5|claude-sonnet-5/i, 1_000_000],
  [/\[1m\]/i, 1_000_000],
];
export const DEFAULT_CONTEXT_WINDOW = 200_000;
export const AUTOMATIC_SHARE = 0.3;
export const AUTOMATIC_CAP = 100_000;
export const MIN_BATCH_TOKENS = 10_000;
export const MAX_BATCH_TOKENS = 300_000;

export function contextWindowFor(model: string, windows: ModelWindows): number {
  const seen = windows.get(model);
  if (seen) return seen;
  for (const [re, n] of KNOWN_WINDOWS) if (re.test(model)) return n;
  return DEFAULT_CONTEXT_WINDOW;
}

/** The batch's source budget in tokens: the setting when set, else Automatic (30% of the window, at most 100K). */
export function batchBudget(setting: number | null | undefined, window: number): number {
  if (typeof setting === 'number' && Number.isFinite(setting) && setting > 0) {
    // A size the model can't hold in one session is capped at half its window.
    return Math.min(MAX_BATCH_TOKENS, Math.round(window * 0.5), Math.max(MIN_BATCH_TOKENS, Math.round(setting)));
  }
  return Math.min(AUTOMATIC_CAP, Math.round(window * AUTOMATIC_SHARE));
}
