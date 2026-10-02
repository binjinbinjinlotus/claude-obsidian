import fs from 'node:fs';
import path from 'node:path';
import type { AddNoteRequest, AddNoteResult, LabelSuggestion, NoteImage, VaultProfile } from '../contracts.js';
import { encodeJSON, isObject, readJSON, str, strArray, writeFileAtomic } from '../store/json.js';
import { yamlScalar } from '../labels/frontmatter.js';
import { CoreError } from './errors.js';
import { NOTE_MANIFEST_SUFFIX } from './job-kinds.js';
import { inboxDir } from './queue.js';

/** Sidecar recording the user's choices for a composed note. */
export interface NoteManifest {
  title: string;
  source?: string;
  sourceRef?: string;
  images: { file: string; mode: NoteImage['mode'] }[];
  /** Handle for labelNote(); absent in manifests written before labels existed. */
  requestID?: string;
  /** Who added the note (decides the fallback when nothing is confirmed). Absent = app. */
  origin?: 'app' | 'cli';
  /** Labels the user confirmed (present, even empty, = confirmed). */
  labels?: string[];
  /** AI suggestions, once known. Never applied unless the origin's fallback says so. */
  suggestedLabels?: LabelSuggestion[];
  suggestError?: string;
}

/** Label state recorded at write time. */
export interface NoteLabelState {
  requestID: string;
  origin: 'app' | 'cli';
  labels?: string[];
  suggestedLabels?: LabelSuggestion[];
  suggestError?: string;
}

export function decodeManifest(raw: unknown): NoteManifest | undefined {
  if (!isObject(raw)) return undefined;
  const title = str(raw.title);
  if (title === undefined) return undefined;
  const m: NoteManifest = {
    title,
    images: Array.isArray(raw.images)
      ? raw.images.flatMap((i) =>
          isObject(i) && typeof i.file === 'string' ? [{ file: i.file, mode: i.mode === 'extract' ? 'extract' : 'keep' } as const] : [],
        )
      : [],
  };
  const source = str(raw.source);
  if (source !== undefined) m.source = source;
  const sourceRef = str(raw.sourceRef);
  if (sourceRef !== undefined) m.sourceRef = sourceRef;
  const requestID = str(raw.requestID);
  if (requestID !== undefined) m.requestID = requestID;
  if (raw.origin === 'app' || raw.origin === 'cli') m.origin = raw.origin;
  const labels = strArray(raw.labels);
  if (labels) m.labels = labels;
  if (Array.isArray(raw.suggestedLabels)) {
    m.suggestedLabels = raw.suggestedLabels.flatMap((l) =>
      isObject(l) && typeof l.name === 'string' ? [{ name: l.name, existing: l.existing === true }] : [],
    );
  }
  const suggestError = str(raw.suggestError);
  if (suggestError !== undefined) m.suggestError = suggestError;
  return m;
}

export function readManifest(file: string): NoteManifest | undefined {
  return decodeManifest(readJSON(file));
}

export function writeManifest(file: string, manifest: NoteManifest): void {
  writeFileAtomic(file, encodeJSON(manifest));
}

/** `<stem>.distill.json` → `<stem>.md` */
export function noteFileFor(manifestPath: string): string {
  return manifestPath.slice(0, -NOTE_MANIFEST_SUFFIX.length) + '.md';
}

const MAX_STEM = 120;

/**
 * A file-name stem from a title: no path separators, colons or control
 * characters, never hidden (the scanner skips dot-files), bounded length.
 */
export function noteStem(title: string): string {
  let s = title
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/[/\\:]/g, '-')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^[.\s-]+/, '')
    .replace(/[.\s]+$/, '');
  if (s.length > MAX_STEM) s = s.slice(0, MAX_STEM).trimEnd();
  return s || 'Note';
}

/** Image file names drop the characters Obsidian reads inside `![[…]]` (heading, block, alias, brackets). */
export function imageStem(stem: string): string {
  return stem.replace(/[#[\]|^]/g, '').replace(/\s+/g, ' ').trim() || 'Note';
}

const EMBED_RE = /!\[\[([^\]|#^\n]+)((?:[#|^][^\]\n]*)?)\]\]/g;

/**
 * The note text with each `![[<pasted file name>]]` pointing at the name the
 * image gets in the queue. Images that share a file name are matched in order;
 * an embed of an unknown name is left as written.
 */
export function rewriteImageEmbeds(text: string, images: { from: string; to: string }[]): string {
  const pending = new Map<string, string[]>();
  for (const img of images) pending.set(img.from, [...(pending.get(img.from) ?? []), img.to]);
  const last = new Map<string, string>();
  return text.replace(EMBED_RE, (whole, rawName: string, suffix: string) => {
    const name = rawName.trim();
    const queue = pending.get(name);
    const to = queue && queue.length > 0 ? queue.shift()! : last.get(name);
    if (to === undefined) return whole;
    last.set(name, to);
    return `![[${to}${suffix}]]`;
  });
}

function yamlString(s: string): string {
  // JSON strings are valid YAML double-quoted scalars.
  return JSON.stringify(s);
}

function localDate(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function noteMarkdown(req: AddNoteRequest, now: Date): string {
  const lines = ['---', `title: ${yamlString(req.title.trim())}`];
  if (req.source) lines.push(`source_type: ${yamlString(req.source)}`);
  if (req.sourceRef) lines.push(`source_ref: ${yamlString(req.sourceRef)}`);
  lines.push(`created: ${localDate(now)}`);
  if (req.labels && req.labels.length > 0) lines.push('tags:', ...req.labels.map((l) => `  - ${yamlScalar(l)}`));
  lines.push('---');
  const body = req.text.replace(/\s+$/, '');
  return lines.join('\n') + '\n' + (body ? '\n' + body + '\n' : '');
}

/**
 * Write one note, its images and its manifest into the queue folder. The stem
 * is chosen so none of the names exist in the queue or in the vault inbox, so
 * the mover never renames one file of the set and breaks the manifest's links.
 * Synchronous on purpose: a batch can never claim half a note.
 */
export function validateNote(req: AddNoteRequest): { title: string; images: NoteImage[] } {
  const title = (req.title ?? '').trim();
  if (!title) throw new CoreError('invalid_request', 'A note needs a title.');
  if (typeof req.text !== 'string') throw new CoreError('invalid_request', 'A note needs text (may be empty with images).');
  const images = (req.images ?? []).map((img) => ({ path: path.resolve(img.path), mode: img.mode === 'extract' ? 'extract' : 'keep' }) as NoteImage);
  if (!req.text.trim() && images.length === 0) throw new CoreError('invalid_request', 'A note needs text or at least one image.');
  for (const img of images) {
    let st: fs.Stats;
    try {
      st = fs.statSync(img.path);
    } catch {
      throw new CoreError('invalid_request', `Image not found: ${img.path}`);
    }
    if (!st.isFile()) throw new CoreError('invalid_request', `Image is not a file: ${img.path}`);
  }
  return { title, images };
}

export function writeNote(req: AddNoteRequest, vault: VaultProfile, now: Date, labels?: NoteLabelState): AddNoteResult {
  const { title, images } = validateNote(req);

  const queue = path.resolve(vault.queueDirectory);
  const inbox = inboxDir(vault);
  fs.mkdirSync(queue, { recursive: true });

  const base = noteStem(title);
  const namesFor = (stem: string) => ({
    note: `${stem}.md`,
    manifest: `${stem}${NOTE_MANIFEST_SUFFIX}`,
    images: images.map((img, i) => `${imageStem(stem)} image ${i + 1}${path.extname(img.path).toLowerCase()}`),
  });
  const taken = (name: string) => fs.existsSync(path.join(queue, name)) || fs.existsSync(path.join(inbox, name));
  let stem = base;
  let names = namesFor(stem);
  for (let n = 2; [names.note, names.manifest, ...names.images].some(taken); n++) {
    stem = `${base} ${n}`;
    names = namesFor(stem);
  }

  const queued: string[] = [];
  images.forEach((img, i) => {
    const dest = path.join(queue, names.images[i] as string);
    fs.copyFileSync(img.path, dest, fs.constants.COPYFILE_EXCL);
    queued.push(dest);
  });

  const manifest: NoteManifest = {
    title,
    images: images.map((img, i) => ({ file: names.images[i] as string, mode: img.mode })),
  };
  if (req.source) manifest.source = req.source;
  if (req.sourceRef) manifest.sourceRef = req.sourceRef;
  if (labels) {
    manifest.requestID = labels.requestID;
    manifest.origin = labels.origin;
    if (labels.labels) manifest.labels = labels.labels;
    if (labels.suggestedLabels) manifest.suggestedLabels = labels.suggestedLabels;
    if (labels.suggestError) manifest.suggestError = labels.suggestError;
  }
  const manifestPath = path.join(queue, names.manifest);
  fs.writeFileSync(manifestPath, encodeJSON(manifest), { flag: 'wx' });
  queued.push(manifestPath);

  const notePath = path.join(queue, names.note);
  const confirmed = labels?.labels;
  const { labels: _ignored, ...rest } = req;
  // The text embeds each image where it was pasted (`![[name]]`); point those at the queued names.
  const text = rewriteImageEmbeds(req.text, images.map((img, i) => ({ from: path.basename(img.path), to: names.images[i] as string })));
  fs.writeFileSync(notePath, noteMarkdown({ ...rest, text, title, ...(confirmed ? { labels: confirmed } : {}) }, now), { flag: 'wx' });
  queued.unshift(notePath);
  return { queued, notePath, requestID: labels?.requestID ?? '' };
}
