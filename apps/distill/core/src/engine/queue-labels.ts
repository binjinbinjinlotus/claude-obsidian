import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { LabelSuggestion, QueueEntry, QueueLabels } from '../contracts.js';
import { isTextInput, readText } from '../labels/batch.js';
import { bodyOf } from '../labels/frontmatter.js';
import type { SuggestInput } from '../labels/suggest.js';
import { pageTags } from '../labels/vault.js';
import type { NoteLabelOverlay, NoteLabelStore } from './note-labels.js';

/**
 * Labels for queue files before the batch (labels-and-sources.md, "Queue files").
 *
 * Every text file that is Ready in the queue and is not a Distill note (a collector's or a
 * dropped .md, .txt, ...) gets labels suggested in the background, at most `concurrency` (3)
 * files at a time, until every file is labeled. The state lives in Distill's `labels/notes.json`
 * overlay keyed `file:<sha256 of the content>`, never in the file: a queue that *is* the vault's
 * inbox/ must not be edited, and one model serves both placements. The key follows the content,
 * so the labels are still found after the batch moves the file into inbox/, and a restart simply
 * finds the files without a result and queues them again.
 */

/** Largest file hashed and labeled (bigger text files are left to the batch). */
const MAX_HASH_BYTES = 8 * 1024 * 1024;

export const DEFAULT_LABEL_CONCURRENCY = 3;

/** A small worker pool: at most `size` tasks run at once; the rest wait in order. */
export class Pool {
  private running = 0;
  private readonly waiting: (() => void)[] = [];
  constructor(readonly size: number) {}

  async run<T>(task: () => Promise<T>): Promise<T> {
    if (this.running >= this.size) await new Promise<void>((resolve) => this.waiting.push(resolve));
    this.running += 1;
    try {
      return await task();
    } finally {
      this.running -= 1;
      this.waiting.shift()?.();
    }
  }
}

/** Run `fn` over `items` with at most `size` at a time; results in input order. */
export async function mapPool<T, R>(items: T[], size: number, fn: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const pool = new Pool(Math.max(1, size));
  return Promise.all(items.map((item, i) => pool.run(() => fn(item, i))));
}

const hashCache = new Map<string, { mtimeMs: number; size: number; key: string }>();

/** `file:<sha256>` of a regular file's content (cached by path, mtime and size); undefined when unreadable or too big. */
export function fileLabelKey(abs: string): string | undefined {
  let st: fs.Stats;
  try {
    st = fs.statSync(abs);
  } catch {
    return undefined;
  }
  if (!st.isFile() || st.size > MAX_HASH_BYTES) return undefined;
  const hit = hashCache.get(abs);
  if (hit && hit.mtimeMs === st.mtimeMs && hit.size === st.size) return hit.key;
  let key: string;
  try {
    key = 'file:' + createHash('sha256').update(fs.readFileSync(abs)).digest('hex');
  } catch {
    return undefined;
  }
  hashCache.set(abs, { mtimeMs: st.mtimeMs, size: st.size, key });
  if (hashCache.size > 5000) hashCache.delete(hashCache.keys().next().value as string);
  return key;
}

/** What a tool-less suggestion reads for a text file; undefined when there is nothing to read. */
export function suggestInputFor(abs: string): { input: SuggestInput; own: string[] } | undefined {
  const text = readText(abs);
  if (text === undefined || text.trim() === '') return undefined;
  const md = abs.toLowerCase().endsWith('.md');
  return { input: { title: path.basename(abs), text: md ? bodyOf(text) : text }, own: md ? pageTags(text) : [] };
}

export interface QueueLabelerDeps {
  store: NoteLabelStore;
  /** A suggestion for one file; throws on failure. */
  suggest(input: SuggestInput, signal: AbortSignal): Promise<{ labels: LabelSuggestion[]; costUSD: number }>;
  /** labeling.autoLabelQueueFolder. */
  enabled(): boolean;
  /** A file's labels changed: rescan so clients get a `queue` event. */
  onChange(): void;
  /** Per-file progress (`labelSuggest`, key `label:<sha>`, item = file name). */
  started(key: string, item: string): void;
  finished(key: string, error?: string): void;
  now(): Date;
  /** Register background work (Engine.whenIdle waits for it). */
  track?(p: Promise<void>): void;
  concurrency?: number;
}

interface Waiting {
  key: string;
  abs: string;
}

export class QueueLabeler {
  private readonly waiting: Waiting[] = [];
  private readonly running = new Map<string, AbortController>();
  private readonly concurrency: number;

  constructor(private readonly deps: QueueLabelerDeps) {
    this.concurrency = Math.max(1, deps.concurrency ?? DEFAULT_LABEL_CONCURRENCY);
  }

  /** Whether an entry is one this labeler handles: a settled, readable text file that is not a note. */
  static handles(e: QueueEntry): boolean {
    return (e.kind ?? 'file') === 'file' && e.settled && !e.problem && !e.waiting && isTextInput(e.name);
  }

  /** The entry's labels, queueing a suggestion when it has none yet. */
  describe(e: QueueEntry): QueueLabels | undefined {
    if (!QueueLabeler.handles(e)) return undefined;
    const key = fileLabelKey(e.path);
    if (!key) return undefined;
    const o = this.deps.store.get(key);
    if (o?.labels !== undefined) return { state: 'confirmed', labels: o.labels.map((name) => ({ name, existing: true })) };
    if (!this.deps.enabled()) return undefined;
    const own = this.ownTags(key, e.path);
    if (own === null) return undefined;
    if (own.length > 0) return { state: 'own', labels: own.map((name) => ({ name, existing: true })) };
    if (o?.suggestedLabels !== undefined) return { state: 'suggested', labels: o.suggestedLabels };
    if (o?.suggestError !== undefined) return { state: 'failed', labels: [], error: o.suggestError };
    if (this.running.has(key)) return { state: 'suggesting', labels: [] };
    if (!this.waiting.some((w) => w.key === key)) this.waiting.push({ key, abs: e.path });
    this.schedulePump();
    return { state: 'waiting', labels: [] };
  }

  /** The overlay for a file (by content), for the batch. */
  lookup(abs: string): NoteLabelOverlay | undefined {
    const key = fileLabelKey(abs);
    return key ? this.deps.store.get(key) : undefined;
  }

  /** Store a suggestion the batch made, so a later batch or a restart reuses it. */
  remember(abs: string, outcome: { labels: LabelSuggestion[] } | { error: string }): void {
    const key = fileLabelKey(abs);
    if (key) this.deps.store.setSuggestion(key, outcome, this.deps.now());
  }

  confirm(abs: string, labels: string[]): boolean {
    const key = fileLabelKey(abs);
    if (!key) return false;
    this.deps.store.setLabels(key, labels, this.deps.now());
    return true;
  }

  retry(abs: string): boolean {
    const key = fileLabelKey(abs);
    if (!key) return false;
    this.deps.store.clearSuggestion(key, this.deps.now());
    return true;
  }

  /** Running and waiting counts (tests, status). */
  counts(): { running: number; waiting: number } {
    return { running: this.running.size, waiting: this.waiting.length };
  }

  /** Stop everything (vault switch, shutdown); unfinished files are queued again by the next describe(). */
  stopAll(): void {
    this.waiting.length = 0;
    for (const c of this.running.values()) c.abort();
  }

  /** The file's own tags ([] = none), null when it has no readable text; cached by content key. */
  private readonly own = new Map<string, string[] | null>();
  private ownTags(key: string, abs: string): string[] | null {
    let v = this.own.get(key);
    if (v === undefined) {
      const read = suggestInputFor(abs);
      v = read ? read.own : null;
      this.own.set(key, v);
      if (this.own.size > 5000) this.own.delete(this.own.keys().next().value as string);
    }
    return v;
  }

  private pumpScheduled = false;
  /** describe() runs inside a queue listing: start work after it, never during it. */
  private schedulePump(): void {
    if (this.pumpScheduled) return;
    this.pumpScheduled = true;
    const p = Promise.resolve().then(() => {
      this.pumpScheduled = false;
      this.pump();
    });
    if (this.deps.track) this.deps.track(p);
  }

  private pump(): void {
    while (this.running.size < this.concurrency && this.waiting.length > 0) {
      const next = this.waiting.shift()!;
      if (this.running.has(next.key)) continue;
      const o = this.deps.store.get(next.key);
      if (o && (o.labels !== undefined || o.suggestedLabels !== undefined || o.suggestError !== undefined)) continue;
      const read = suggestInputFor(next.abs);
      if (!read || read.own.length > 0) continue;
      const controller = new AbortController();
      this.running.set(next.key, controller);
      const item = path.basename(next.abs);
      this.deps.started(next.key, item);
      const work = (async () => {
        let error: string | undefined;
        try {
          const out = await this.deps.suggest(read.input, controller.signal);
          if (!controller.signal.aborted) this.deps.store.setSuggestion(next.key, { labels: out.labels }, this.deps.now());
        } catch (err) {
          error = (err as Error).message;
          if (!controller.signal.aborted) this.deps.store.setSuggestion(next.key, { error }, this.deps.now());
        } finally {
          this.running.delete(next.key);
          this.deps.finished(next.key, controller.signal.aborted ? 'Stopped.' : error);
          this.deps.onChange();
          this.pump();
        }
      })();
      if (this.deps.track) this.deps.track(work);
      else void work;
    }
  }
}
