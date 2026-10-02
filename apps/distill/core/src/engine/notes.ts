import fs from 'node:fs';
import path from 'node:path';
import type { AddNoteRequest, AddNoteResult, NoteImage, VaultProfile } from '../contracts.js';
import { encodeJSON } from '../store/json.js';
import { CoreError } from './errors.js';
import { NOTE_MANIFEST_SUFFIX } from './job-kinds.js';
import { inboxDir } from './queue.js';

/** Sidecar recording the user's choices for a composed note. */
export interface NoteManifest {
  title: string;
  source?: string;
  sourceRef?: string;
  images: { file: string; mode: NoteImage['mode'] }[];
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
  lines.push(`created: ${localDate(now)}`, '---');
  const body = req.text.replace(/\s+$/, '');
  return lines.join('\n') + '\n' + (body ? '\n' + body + '\n' : '');
}

/**
 * Write one note, its images and its manifest into the queue folder. The stem
 * is chosen so none of the names exist in the queue or in the vault inbox, so
 * the mover never renames one file of the set and breaks the manifest's links.
 * Synchronous on purpose: a batch can never claim half a note.
 */
export function writeNote(req: AddNoteRequest, vault: VaultProfile, now: Date): AddNoteResult {
  const title = req.title.trim();
  if (!title) throw new CoreError('invalid_request', 'A note needs a title.');
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

  const queue = path.resolve(vault.queueDirectory);
  const inbox = inboxDir(vault);
  fs.mkdirSync(queue, { recursive: true });

  const base = noteStem(title);
  const namesFor = (stem: string) => ({
    note: `${stem}.md`,
    manifest: `${stem}${NOTE_MANIFEST_SUFFIX}`,
    images: images.map((img, i) => `${stem} image ${i + 1}${path.extname(img.path).toLowerCase()}`),
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
  const manifestPath = path.join(queue, names.manifest);
  fs.writeFileSync(manifestPath, encodeJSON(manifest), { flag: 'wx' });
  queued.push(manifestPath);

  const notePath = path.join(queue, names.note);
  fs.writeFileSync(notePath, noteMarkdown({ ...req, title }, now), { flag: 'wx' });
  queued.unshift(notePath);
  return { queued, notePath, requestID: '' };
}
