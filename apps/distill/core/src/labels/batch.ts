import fs from 'node:fs';
import path from 'node:path';
import type { LabelingPreferences } from '../contracts.js';
import type { SourceLabels } from '../engine/job-kinds.js';
import { NOTE_MANIFEST_SUFFIX } from '../engine/job-kinds.js';
import { readManifest } from '../engine/notes.js';
import { withLabelOverlay, type NoteLabelOverlay } from '../engine/note-labels.js';
import { bodyOf } from './frontmatter.js';
import type { SuggestInput } from './suggest.js';
import { pageTags } from './vault.js';

/** Inputs whose text a tool-less labelSuggest run can read. Others (PDF, images, ...) stay unlabeled. */
const TEXT_EXTENSIONS = new Set([
  '.md', '.markdown', '.txt', '.text', '.html', '.htm', '.csv', '.json', '.xml', '.org', '.rst', '.tex', '.yaml', '.yml',
]);

export function isTextInput(rel: string): boolean {
  return TEXT_EXTENSIONS.has(path.extname(rel).toLowerCase());
}

const MAX_READ = 64 * 1024;

export function readText(abs: string): string | undefined {
  try {
    const fd = fs.openSync(abs, 'r');
    try {
      const buffer = Buffer.alloc(MAX_READ);
      const n = fs.readSync(fd, buffer, 0, MAX_READ, 0);
      return buffer.subarray(0, n).toString('utf8');
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return undefined;
  }
}

export interface PendingSuggestion {
  entry: SourceLabels;
  input: SuggestInput;
}

export interface BatchLabelDraft {
  /** One entry per source input, in batch order (manifests and note images are not sources). */
  plan: SourceLabels[];
  /** Entries that still need an AI suggestion before the first turn. */
  pending: PendingSuggestion[];
}

/**
 * Decide each batch input's labels from its manifest and the labeling
 * preferences (labels-and-sources.md):
 * - composed note with confirmed labels → those, `labels_by: user`;
 * - CLI note without confirmed labels, cliFallbackToAI → AI labels (the
 *   manifest's suggestions, or a new suggestion), unconfirmed, origin `cli`;
 * - app note without confirmed labels → none (no fallback);
 * - any other text file, autoLabelQueueFolder → AI labels, unconfirmed,
 *   origin `queue-folder`; binary files → none.
 */
export function draftBatchLabels(
  vaultPath: string,
  files: string[],
  prefs: LabelingPreferences,
  /** Label state kept in Distill's state for notes in `inbox/` (note-labels.ts); wins over the manifest. */
  overlay?: (requestID: string | undefined) => NoteLabelOverlay | undefined,
  /** Labels a queue file got before the batch (queue-labels.ts), by vault-relative input. */
  fileLabels?: (rel: string) => NoteLabelOverlay | undefined,
): BatchLabelDraft {
  const plan: SourceLabels[] = [];
  const pending: PendingSuggestion[] = [];
  const owned = new Set<string>();
  const inBatch = new Set(files);

  for (const rel of files.filter((f) => f.endsWith(NOTE_MANIFEST_SUFFIX))) {
    owned.add(rel);
    const noteRel = rel.slice(0, -NOTE_MANIFEST_SUFFIX.length) + '.md';
    owned.add(noteRel);
    const read = readManifest(path.join(vaultPath, rel));
    const manifest = read && withLabelOverlay(read, overlay?.(read.requestID));
    const dir = path.posix.dirname(rel);
    for (const img of manifest?.images ?? []) owned.add(`${dir}/${img.file}`);
    if (!inBatch.has(noteRel)) continue;
    const entry: SourceLabels = { file: noteRel, labels: [], by: 'ai' };
    plan.push(entry);
    if (!manifest) continue;
    if (manifest.labels !== undefined) {
      entry.labels = [...manifest.labels];
      entry.by = 'user';
    } else if ((manifest.origin ?? 'app') === 'cli' && prefs.cliFallbackToAI) {
      entry.origin = 'cli';
      if (manifest.suggestedLabels && manifest.suggestedLabels.length > 0) {
        entry.labels = manifest.suggestedLabels.map((l) => l.name);
      } else {
        const text = readText(path.join(vaultPath, noteRel)) ?? '';
        const input: SuggestInput = { title: manifest.title, text: bodyOf(text) };
        if (manifest.source) input.source = manifest.source;
        if (manifest.sourceRef) input.sourceRef = manifest.sourceRef;
        pending.push({ entry, input });
      }
    }
  }

  for (const rel of files) {
    if (owned.has(rel)) continue;
    const entry: SourceLabels = { file: rel, labels: [], by: 'ai' };
    plan.push(entry);
    if (!isTextInput(rel)) continue;
    const text = readText(path.join(vaultPath, rel));
    if (text === undefined || text.trim() === '') continue;
    // Labels confirmed in the queue (queue-labels.ts) win, even over the file's own tags.
    const known = fileLabels?.(rel);
    if (known?.labels !== undefined) {
      entry.labels = [...known.labels];
      entry.by = 'user';
      continue;
    }
    // Sent without labels by the user (the label gate let it through).
    if (known?.skipLabels) continue;
    if (!prefs.autoLabelQueueFolder) continue;
    const own = rel.toLowerCase().endsWith('.md') ? pageTags(text) : [];
    if (own.length > 0) {
      // Tags the user wrote in the file count as their choice: keep them, no AI call.
      entry.labels = own;
      entry.by = 'user';
      continue;
    }
    // Suggested in the queue already: used as they are, no new AI call.
    if (known?.suggestedLabels && known.suggestedLabels.length > 0) {
      entry.labels = known.suggestedLabels.map((l) => l.name);
      entry.origin = 'queue-folder';
      continue;
    }
    entry.origin = 'queue-folder';
    pending.push({ entry, input: { title: path.posix.basename(rel), text: rel.toLowerCase().endsWith('.md') ? bodyOf(text) : text } });
  }
  return { plan, pending };
}
