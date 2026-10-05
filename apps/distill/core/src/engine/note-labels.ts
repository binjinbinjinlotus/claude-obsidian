import path from 'node:path';
import type { LabelSuggestion } from '../contracts.js';
import { isObject, isoDate, readJSON, str, strArray, writeJSONAtomic } from '../store/json.js';
import type { NoteManifest } from './notes.js';

/**
 * Label state for a note that sits in the vault's `inbox/` (the queue is the inbox), kept in
 * Distill's state instead of the note's files: claude-obsidian keeps `inbox/` outside its
 * transactions and Distill never edits a file already there (decision 2026-10-04). Keyed by the
 * note's requestID; readers merge it over the manifest (`withLabelOverlay`).
 *
 * Queue files that are not notes (a collector's or a dropped .md, .txt, ...) use the same store,
 * keyed `file:<sha256 of the content>` (queue-labels.ts), so their labels follow the content when
 * a batch moves the file into inbox/ and never touch the file itself (2026-10-05).
 */
export interface NoteLabelOverlay {
  /** Present (even empty) = the user confirmed these labels. */
  labels?: string[];
  /** Present = the latest suggestion; it clears any earlier `suggestError`. */
  suggestedLabels?: LabelSuggestion[];
  suggestError?: string;
  updatedAt: string;
}

/** Oldest entries are dropped past this (a note's overlay matters only until its batch reads it). */
const MAX_ENTRIES = 2000;

function decodeOverlay(raw: unknown): NoteLabelOverlay | undefined {
  if (!isObject(raw)) return undefined;
  const out: NoteLabelOverlay = { updatedAt: str(raw.updatedAt) ?? '' };
  const labels = strArray(raw.labels);
  if (labels) out.labels = labels;
  if (Array.isArray(raw.suggestedLabels)) {
    out.suggestedLabels = raw.suggestedLabels.flatMap((l) =>
      isObject(l) && typeof l.name === 'string' ? [{ name: l.name, existing: l.existing === true }] : [],
    );
  }
  const err = str(raw.suggestError);
  if (err !== undefined) out.suggestError = err;
  return out;
}

/** `<state>/labels/notes.json`: { [requestID]: NoteLabelOverlay }. Loaded once, written through. */
export class NoteLabelStore {
  private readonly entries = new Map<string, NoteLabelOverlay>();

  constructor(readonly file: string) {
    const raw = readJSON(file);
    if (isObject(raw)) {
      const loaded = Object.entries(raw).flatMap(([id, v]) => {
        const o = decodeOverlay(v);
        return o ? [[id, o] as const] : [];
      });
      // Stored with sorted keys: restore oldest-first order from updatedAt.
      loaded.sort((a, b) => (a[1].updatedAt < b[1].updatedAt ? -1 : a[1].updatedAt > b[1].updatedAt ? 1 : 0));
      for (const [id, o] of loaded) this.entries.set(id, o);
    }
  }

  static at(stateDir: string): NoteLabelStore {
    return new NoteLabelStore(path.join(stateDir, 'labels', 'notes.json'));
  }

  get(requestID: string | undefined): NoteLabelOverlay | undefined {
    return requestID ? this.entries.get(requestID) : undefined;
  }

  /** The user confirmed labels ([] = confirmed: no labels). */
  setLabels(requestID: string, labels: string[], now: Date): void {
    const next: NoteLabelOverlay = { ...this.entries.get(requestID), labels: [...labels], updatedAt: isoDate(now) };
    this.save(requestID, next);
  }

  /** A suggestion finished: its labels, or why it failed. */
  setSuggestion(requestID: string, outcome: { labels: LabelSuggestion[] } | { error: string }, now: Date): void {
    const next: NoteLabelOverlay = { ...this.entries.get(requestID), updatedAt: isoDate(now) };
    if ('error' in outcome) next.suggestError = outcome.error;
    else {
      next.suggestedLabels = outcome.labels;
      delete next.suggestError;
    }
    this.save(requestID, next);
  }

  /** Forget the last suggestion (and its error) so a new one runs; confirmed labels stay. */
  clearSuggestion(id: string, now: Date): void {
    const current = this.entries.get(id);
    if (!current) return;
    const { suggestedLabels: _s, suggestError: _e, ...rest } = current;
    this.save(id, { ...rest, updatedAt: isoDate(now) });
  }

  private save(requestID: string, value: NoteLabelOverlay): void {
    this.entries.delete(requestID);
    this.entries.set(requestID, value); // newest last
    while (this.entries.size > MAX_ENTRIES) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
    writeJSONAtomic(this.file, Object.fromEntries(this.entries));
  }
}

/** The manifest as readers should see it: overlay fields win over the manifest's own. */
export function withLabelOverlay(m: NoteManifest, overlay: NoteLabelOverlay | undefined): NoteManifest {
  if (!overlay) return m;
  const out: NoteManifest = { ...m };
  if (overlay.labels !== undefined) out.labels = [...overlay.labels];
  if (overlay.suggestedLabels !== undefined) {
    out.suggestedLabels = overlay.suggestedLabels;
    delete out.suggestError;
  }
  if (overlay.suggestError !== undefined) out.suggestError = overlay.suggestError;
  return out;
}
