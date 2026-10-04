import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { ActivityEntry, ActivityPage, ActivityQuery } from '../contracts.js';
import { clip, redactDetails, redactText } from './redact.js';

/**
 * The activity log: append-only JSON Lines in `<state>/activity/`.
 *
 * - `activity.jsonl` is the live file. Each entry is one `appendFileSync` (O_APPEND, one write
 *   call, at most MAX_LINE_BYTES), so lines from the server, its scheduler and any other
 *   process sharing the state dir never interleave.
 * - Past MAX_FILE_BYTES the live file is renamed to `activity-<time>-<pid>-<rand>.jsonl` under a
 *   lock directory (stale after 30 s). Rotated files older than KEEP_DAYS or beyond KEEP_FILES go.
 * - Never leaves the machine; never holds secrets (see redact.ts).
 */

export const ACTIVITY_DEFAULTS = {
  maxFileBytes: 2 * 1024 * 1024,
  keepFiles: 10,
  keepDays: 180,
  maxLineBytes: 8 * 1024,
};

export interface ActivityLogOptions {
  dir: string;
  now?: () => Date;
  maxFileBytes?: number;
  keepFiles?: number;
  keepDays?: number;
}

export type NewActivityEntry = Omit<ActivityEntry, 'id' | 'at' | 'pid' | 'details'> & { at?: string; details?: Record<string, unknown> };

const LIVE = 'activity.jsonl';
const ROTATED = /^activity-(\d{8}T\d{6}Z)-\d+-[0-9a-f]+\.jsonl$/;
const LOCK = '.rotate.lock';
const LOCK_STALE_MS = 30_000;
const MAX_LIMIT = 500;
const DEFAULT_LIMIT = 50;

let seq = 0;

/** "<13-digit ms>-<4 base36 seq>-<6 hex>": sorts by time, then by order within a process. */
export function newActivityID(ms: number): string {
  seq = (seq + 1) % 36 ** 4;
  return `${String(ms).padStart(13, '0')}-${seq.toString(36).padStart(4, '0')}-${randomBytes(3).toString('hex')}`;
}

function stamp(d: Date): string {
  return d.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

export class ActivityLog {
  readonly dir: string;
  private readonly now: () => Date;
  private readonly maxFileBytes: number;
  private readonly keepFiles: number;
  private readonly keepDays: number;
  private listeners = new Set<(entry: ActivityEntry) => void>();

  constructor(opts: ActivityLogOptions) {
    this.dir = opts.dir;
    this.now = opts.now ?? (() => new Date());
    this.maxFileBytes = opts.maxFileBytes ?? ACTIVITY_DEFAULTS.maxFileBytes;
    this.keepFiles = opts.keepFiles ?? ACTIVITY_DEFAULTS.keepFiles;
    this.keepDays = opts.keepDays ?? ACTIVITY_DEFAULTS.keepDays;
  }

  get file(): string {
    return path.join(this.dir, LIVE);
  }

  onEntry(listener: (entry: ActivityEntry) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Append one entry. Never throws: a log that can't be written must not fail the change it records. */
  record(input: NewActivityEntry): ActivityEntry | undefined {
    try {
      const entry = this.sanitize(input);
      let line = JSON.stringify(entry);
      if (Buffer.byteLength(line) > ACTIVITY_DEFAULTS.maxLineBytes) {
        const { details: _d, ...rest } = entry;
        line = JSON.stringify({ ...rest, details: { truncated: true } });
      }
      fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
      fs.appendFileSync(this.file, line + '\n', { mode: 0o600 });
      this.maybeRotate();
      for (const l of this.listeners) {
        try {
          l(entry);
        } catch {
          /* a listener never fails a write */
        }
      }
      return entry;
    } catch {
      return undefined;
    }
  }

  private sanitize(input: NewActivityEntry): ActivityEntry {
    const at = this.now();
    const object = { ...input.object };
    if (object.name !== undefined) object.name = clip(object.name, 160);
    if (object.id !== undefined) object.id = clip(object.id, 300);
    const entry: ActivityEntry = {
      id: newActivityID(at.getTime()),
      at: input.at ?? at.toISOString(),
      type: input.type,
      source: input.source,
      object,
      summary: clip(input.summary, 300),
      outcome: input.outcome,
      pid: process.pid,
    };
    if (input.error) entry.error = clip(input.error, 300);
    const details = redactDetails(input.details);
    if (details && Object.keys(details).length > 0) entry.details = details;
    if (input.recovery) {
      entry.recovery =
        input.recovery.kind === 'macosTrash' ? { kind: 'macosTrash', path: redactText(input.recovery.path) } : input.recovery;
    }
    return entry;
  }

  private maybeRotate(): void {
    let size: number;
    try {
      size = fs.statSync(this.file).size;
    } catch {
      return;
    }
    if (size < this.maxFileBytes) return;
    const lock = path.join(this.dir, LOCK);
    try {
      fs.mkdirSync(lock);
    } catch {
      // Someone else is rotating; take over a lock left by a process that died mid-rotation.
      try {
        if (Date.now() - fs.statSync(lock).mtimeMs < LOCK_STALE_MS) return;
        fs.rmSync(lock, { recursive: true, force: true });
        fs.mkdirSync(lock);
      } catch {
        return;
      }
    }
    try {
      // Re-check under the lock: another process may just have rotated.
      if (fs.statSync(this.file).size < this.maxFileBytes) return;
      const name = `activity-${stamp(this.now())}-${process.pid}-${randomBytes(3).toString('hex')}.jsonl`;
      fs.renameSync(this.file, path.join(this.dir, name));
      this.prune();
    } catch {
      /* the next write tries again */
    } finally {
      fs.rmSync(lock, { recursive: true, force: true });
    }
  }

  /** Rotated files, newest first: by last write (names can tie within a second across processes). */
  private rotated(): string[] {
    let names: string[];
    try {
      names = fs.readdirSync(this.dir);
    } catch {
      return [];
    }
    const withTime = names
      .filter((n) => ROTATED.test(n))
      .map((n) => {
        try {
          return { n, t: fs.statSync(path.join(this.dir, n)).mtimeMs };
        } catch {
          return { n, t: 0 };
        }
      });
    return withTime.sort((a, b) => b.t - a.t || (a.n < b.n ? 1 : -1)).map((x) => x.n);
  }

  private prune(): void {
    const cutoff = this.now().getTime() - this.keepDays * 86_400_000;
    this.rotated().forEach((name, index) => {
      const file = path.join(this.dir, name);
      let old = index >= this.keepFiles;
      if (!old) {
        try {
          old = fs.statSync(file).mtimeMs < cutoff;
        } catch {
          return;
        }
      }
      if (old) fs.rmSync(file, { force: true });
    });
  }

  /** Every file, newest first: the live file, then rotated ones. */
  files(): string[] {
    return [this.file, ...this.rotated().map((n) => path.join(this.dir, n))];
  }

  /** Newest first, filtered; reads files newest-first and stops once a page is full. */
  list(query: ActivityQuery = {}): ActivityPage {
    const limit = Math.min(Math.max(1, Math.floor(query.limit ?? DEFAULT_LIMIT)), MAX_LIMIT);
    const match = matcher(query);
    const out: ActivityEntry[] = [];
    for (const file of this.files()) {
      let text: string;
      try {
        text = fs.readFileSync(file, 'utf8');
      } catch {
        continue;
      }
      const entries: ActivityEntry[] = [];
      for (const line of text.split('\n')) {
        if (!line.trim()) continue;
        try {
          const e = JSON.parse(line) as ActivityEntry;
          if (typeof e?.id === 'string' && typeof e.type === 'string' && typeof e.at === 'string') entries.push(e);
        } catch {
          /* a torn or foreign line is skipped, never fatal */
        }
      }
      // Within a file lines are in write order; ids sort by time across processes.
      entries.sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
      for (const e of entries) if (match(e)) out.push(e);
      // Files are chronological: once this file gave a full page, older files can't beat it.
      if (out.length > limit) break;
    }
    out.sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
    const page = out.slice(0, limit);
    return { entries: page, nextCursor: out.length > limit ? page[page.length - 1]!.id : null };
  }
}

function matcher(q: ActivityQuery): (e: ActivityEntry) => boolean {
  const types = q.types?.map((t) => t.trim()).filter(Boolean) ?? [];
  const text = q.text?.trim().toLowerCase();
  return (e) => {
    if (q.cursor && !(e.id < q.cursor)) return false;
    if (types.length && !types.some((t) => e.type === t || e.type.startsWith(`${t}.`))) return false;
    if (q.objectKind && e.object?.kind !== q.objectKind) return false;
    if (q.objectID && e.object?.id !== q.objectID) return false;
    if (q.sources?.length && !q.sources.includes(e.source)) return false;
    if (q.outcome && e.outcome !== q.outcome) return false;
    if (q.since && e.at < q.since) return false;
    if (q.until && e.at >= q.until) return false;
    if (text) {
      const hay = [e.summary, e.type, e.object?.name, e.object?.id, e.error, e.details ? JSON.stringify(e.details) : '']
        .filter(Boolean)
        .join('\n')
        .toLowerCase();
      if (!hay.includes(text)) return false;
    }
    return true;
  };
}
