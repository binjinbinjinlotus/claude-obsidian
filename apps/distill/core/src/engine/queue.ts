import fs from 'node:fs';
import path from 'node:path';
import type { QueueEntry, VaultProfile } from '../contracts.js';
import { isoDate } from '../store/json.js';

// ───────────── Batch interval ─────────────

export type IntervalPart = 'days' | 'hours' | 'minutes';

export const INTERVAL_RANGES: Record<IntervalPart, [number, number]> = {
  days: [0, 30],
  hours: [0, 23],
  minutes: [0, 59],
};

/**
 * The batch interval split into days / hours / minutes for editing. Settings
 * keep storing total minutes, so the scheduler is unaffected.
 */
export class BatchInterval {
  days: number;
  hours: number;
  minutes: number;

  constructor(totalMinutes: number) {
    const total = Math.max(1, Math.trunc(totalMinutes));
    this.days = Math.floor(total / 1440);
    this.hours = Math.floor((total % 1440) / 60);
    this.minutes = total % 60;
  }

  /** Never below one minute: an all-zero interval would batch continuously. */
  get totalMinutes(): number {
    return Math.max(1, this.days * 1440 + this.hours * 60 + this.minutes);
  }

  get(part: IntervalPart): number {
    return this[part];
  }

  set(part: IntervalPart, value: number): void {
    const [lo, hi] = INTERVAL_RANGES[part];
    this[part] = Math.min(Math.max(Math.trunc(value), lo), hi);
  }

  /** "1d 2h 30m", "45m", "3h". */
  toString(): string {
    const t = this.totalMinutes;
    const parts: [number, string][] = [
      [Math.floor(t / 1440), 'd'],
      [Math.floor((t % 1440) / 60), 'h'],
      [t % 60, 'm'],
    ];
    return parts.filter(([n]) => n > 0).map(([n, u]) => `${n}${u}`).join(' ');
  }
}

// ───────────── Scanner ─────────────

export const PARTIAL_SUFFIXES = ['.crdownload', '.part', '.download', '.tmp', '.partial'];

export interface ScanEntry {
  path: string;
  name: string;
  modifiedMs: number;
  size: number;
}

/** Top-level, non-hidden regular files, oldest first. Folders are left for the user. */
export function pendingFiles(dir: string): ScanEntry[] {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const out: ScanEntry[] = [];
  for (const name of names) {
    if (name.startsWith('.')) continue;
    const lower = name.toLowerCase();
    if (PARTIAL_SUFFIXES.some((s) => lower.endsWith(s))) continue;
    const full = path.join(dir, name);
    let st: fs.Stats;
    try {
      st = fs.lstatSync(full);
    } catch {
      continue;
    }
    if (!st.isFile()) continue;
    out.push({ path: full, name, modifiedMs: st.mtimeMs, size: st.size });
  }
  return out.sort((a, b) => a.modifiedMs - b.modifiedMs);
}

/** Entries unmodified for at least `settleSeconds` (still-copying files wait). */
export function settledFiles(entries: ScanEntry[], settleSeconds: number, now: Date): ScanEntry[] {
  return entries.filter((e) => isSettled(e, settleSeconds, now));
}

export function isSettled(e: ScanEntry, settleSeconds: number, now: Date): boolean {
  // No delay means every file (an mtime can sit a fraction of a ms past Date.now()).
  if (settleSeconds <= 0) return true;
  return (now.getTime() - e.modifiedMs) / 1000 >= settleSeconds;
}

/** Same as NOTE_MANIFEST_SUFFIX in job-kinds.ts (kept here so queue.ts stays import-free). */
const MANIFEST_SUFFIX = '.distill.json';

/** A note written by addNote, as found in a queue scan: its `.md`, manifest and the listed images present. */
export interface NoteSet {
  note: string;
  manifest: string;
  /** Listed images that are in the scan, in manifest order. */
  images: string[];
  /** From the manifest; absent when it can't be read or has none. */
  source?: string;
  labelsConfirmed: boolean;
  imageCount: number;
}

interface ParsedManifest {
  source?: string;
  labelsConfirmed: boolean;
  images: string[];
}

/** Lenient read of a manifest (queue.ts stays independent of notes.ts). Unreadable = no fields. */
function parseManifest(file: string): ParsedManifest {
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return { labelsConfirmed: false, images: [] };
  }
  const obj = raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const images = Array.isArray(obj.images)
    ? obj.images.flatMap((img) => {
        const name = (img as { file?: unknown } | null)?.file;
        return typeof name === 'string' ? [name] : [];
      })
    : [];
  // Labels present (even empty) = confirmed, as in NoteManifest.
  const out: ParsedManifest = { labelsConfirmed: Array.isArray(obj.labels), images };
  if (typeof obj.source === 'string' && obj.source.trim() !== '') out.source = obj.source;
  return out;
}

/** Note sets whose `.md` is in the scan (an orphan manifest or image is not a set). */
export function noteSets(entries: ScanEntry[]): NoteSet[] {
  const byName = new Map(entries.map((e) => [e.name, e.path]));
  const out: NoteSet[] = [];
  for (const e of entries) {
    if (!e.name.endsWith(MANIFEST_SUFFIX)) continue;
    const stem = e.name.slice(0, -MANIFEST_SUFFIX.length);
    const note = byName.get(`${stem}.md`);
    if (!note) continue;
    const m = parseManifest(e.path);
    const images = m.images.flatMap((f) => {
      const p = byName.get(f);
      return p && p !== note && p !== e.path ? [p] : [];
    });
    const set: NoteSet = { note, manifest: e.path, images, labelsConfirmed: m.labelsConfirmed, imageCount: m.images.length };
    if (m.source) set.source = m.source;
    out.push(set);
  }
  return out;
}

/**
 * Paths of every file that belongs to a note written by addNote: the
 * `<stem>.distill.json` manifest, its `<stem>.md` and the images it lists.
 * A note is complete when it is queued, so the whole set skips the settle
 * wait (and a batch never takes the note without its manifest or images).
 */
export function noteSetPaths(entries: ScanEntry[]): Set<string> {
  const byName = new Map(entries.map((e) => [e.name, e.path]));
  const out = new Set<string>();
  for (const e of entries) {
    if (!e.name.endsWith(MANIFEST_SUFFIX)) continue;
    out.add(e.path);
    const stem = e.name.slice(0, -MANIFEST_SUFFIX.length);
    const note = byName.get(`${stem}.md`);
    if (note) out.add(note);
    // An unreadable manifest still marks its note; its images wait like other files.
    for (const file of parseManifest(e.path).images) {
      const p = byName.get(file);
      if (p) out.add(p);
    }
  }
  return out;
}

/** Why the core can't use a queued file, or undefined. Narrow on purpose: today only "can't read it". */
export function queueProblem(e: ScanEntry): string | undefined {
  try {
    fs.accessSync(e.path, fs.constants.R_OK);
    return undefined;
  } catch {
    return "Distill can't read this file. Check its permissions, or remove it.";
  }
}

/**
 * Files a batch may take now: settled ones and every note set, minus files
 * with a problem (they stay in the queue, marked, until the user removes them).
 */
export function readyFiles(entries: ScanEntry[], settleSeconds: number, now: Date): ScanEntry[] {
  const notes = noteSetPaths(entries);
  return entries.filter((e) => (notes.has(e.path) || isSettled(e, settleSeconds, now)) && !queueProblem(e));
}

export function toQueueEntry(
  e: ScanEntry,
  settleSeconds: number,
  now: Date,
  notes: Set<string> = new Set(),
  firstSeenMs?: number,
): QueueEntry {
  const kind = notes.has(e.path) ? 'note' : 'file';
  const settled = kind === 'note' || isSettled(e, settleSeconds, now);
  const entry: QueueEntry = {
    path: e.path,
    name: e.name,
    modified: isoDate(new Date(e.modifiedMs)),
    size: e.size,
    settled,
    kind,
  };
  // Rounded up to the second so the shown time is never before the file is really ready.
  if (!settled) entry.readyAt = isoDate(new Date(Math.ceil((e.modifiedMs + settleSeconds * 1000) / 1000) * 1000));
  // Omitted when false (like problem), so an unchanged queue compares equal.
  if (!settled && firstSeenMs !== undefined && e.modifiedMs > firstSeenMs) entry.changing = true;
  const problem = queueProblem(e);
  if (problem) entry.problem = problem;
  return entry;
}

export interface QueueListOptions {
  /** The mtime each path had when the core first saw it (drives `changing`). */
  firstSeen?: ReadonlyMap<string, number>;
  /** Display text for a manifest's source id (e.g. "in-person" → "In person"). */
  sourceLabel?: (source: string) => string;
}

/**
 * What clients see: one entry per file, except that a note set is one entry
 * for its `.md` carrying `members` (manifest, then images) and `note`; the
 * members are not listed on their own. A member's problem is carried up to
 * the note row, the only row clients show.
 */
export function queueList(entries: ScanEntry[], settleSeconds: number, now: Date, opts: QueueListOptions = {}): QueueEntry[] {
  const notes = noteSetPaths(entries);
  const sets = new Map(noteSets(entries).map((s) => [s.note, s]));
  const hidden = new Set<string>();
  for (const s of sets.values()) for (const p of [s.manifest, ...s.images]) hidden.add(p);
  const byPath = new Map(entries.map((e) => [e.path, e]));
  const out: QueueEntry[] = [];
  for (const e of entries) {
    if (hidden.has(e.path)) continue;
    const entry = toQueueEntry(e, settleSeconds, now, notes, opts.firstSeen?.get(e.path));
    const set = sets.get(e.path);
    if (set) {
      const members = [set.manifest, ...set.images];
      entry.members = members;
      const note: NonNullable<QueueEntry['note']> = { labelsConfirmed: set.labelsConfirmed, imageCount: set.imageCount };
      if (set.source) note.source = opts.sourceLabel ? opts.sourceLabel(set.source) : set.source;
      entry.note = note;
      if (!entry.problem) {
        for (const m of members) {
          const member = byPath.get(m);
          const problem = member && queueProblem(member);
          if (problem) {
            entry.problem = `${path.basename(m)}: ${problem}`;
            break;
          }
        }
      }
    }
    out.push(entry);
  }
  return out;
}

/** The note set `file` belongs to as a member (manifest or image), if its `.md` is queued. */
export function noteSetOfMember(entries: ScanEntry[], file: string): NoteSet | undefined {
  return noteSets(entries).find((s) => s.manifest === file || s.images.includes(file));
}

// ───────────── Mover ─────────────

export function inboxDir(vault: VaultProfile): string {
  return path.join(path.resolve(vault.path), 'inbox');
}

export function queueIsInbox(vault: VaultProfile): boolean {
  return path.resolve(vault.queueDirectory) === inboxDir(vault);
}

/** `name.ext`, then `name 2.ext`, `name 3.ext`, ... */
export function uniqueDestination(name: string, dir: string): string {
  let candidate = path.join(dir, name);
  const ext = path.extname(name);
  const base = ext ? name.slice(0, -ext.length) : name;
  let n = 2;
  while (fs.existsSync(candidate)) {
    candidate = path.join(dir, `${base} ${n}${ext}`);
    n += 1;
  }
  return candidate;
}

/** Rename, or copy then unlink across volumes. */
export function moveFile(from: string, to: string): void {
  try {
    fs.renameSync(from, to);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EXDEV') throw err;
    fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL);
    fs.unlinkSync(from);
  }
}

/**
 * Moves a file into `dir` as `name.ext`, `name 2.ext`, ... without ever replacing an existing file,
 * even where the directory cannot be listed (macOS privacy rules on ~/.Trash): hard link then
 * unlink, or an exclusive copy across volumes; a taken name moves on to the next. Returns the destination.
 */
export function moveIntoDirNoOverwrite(from: string, dir: string): string {
  const name = path.basename(from);
  const ext = path.extname(name);
  const base = ext ? name.slice(0, -ext.length) : name;
  for (let n = 1; n < 10_000; n++) {
    const dest = path.join(dir, n === 1 ? name : `${base} ${n}${ext}`);
    try {
      fs.linkSync(from, dest);
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code === 'EEXIST') continue;
      if (code !== 'EXDEV' && code !== 'EPERM' && code !== 'ENOTSUP') throw err;
      try {
        fs.copyFileSync(from, dest, fs.constants.COPYFILE_EXCL);
      } catch (copyErr) {
        if ((copyErr as NodeJS.ErrnoException).code === 'EEXIST') continue;
        throw copyErr;
      }
    }
    fs.unlinkSync(from);
    return dest;
  }
  throw new Error(`No free name for ${name} in ${dir}.`);
}

/**
 * Moves settled queue files into `<vault>/inbox/` so provenance stays inside
 * the vault. Returns vault-relative paths. When the queue *is* the inbox,
 * files stay put and only unclaimed ones are returned.
 */
export function claimFiles(entries: ScanEntry[], vault: VaultProfile, alreadyClaimed: Set<string>): string[] {
  const inbox = inboxDir(vault);
  fs.mkdirSync(inbox, { recursive: true });
  const inPlace = queueIsInbox(vault);
  const claimed: string[] = [];
  for (const entry of entries) {
    let target: string;
    if (inPlace) {
      target = path.resolve(entry.path);
    } else {
      target = uniqueDestination(entry.name, inbox);
      moveFile(entry.path, target);
    }
    const rel = 'inbox/' + path.basename(target);
    if (!alreadyClaimed.has(rel)) claimed.push(rel);
  }
  return claimed;
}

// ───────────── Intake ─────────────

/** Drops copy (the original stays where it was). Folders and missing paths are skipped. */
export function copyIntoQueue(files: string[], queue: string): string[] {
  fs.mkdirSync(queue, { recursive: true });
  const out: string[] = [];
  for (const file of files) {
    let st: fs.Stats;
    try {
      st = fs.statSync(file);
    } catch {
      continue;
    }
    if (st.isDirectory()) continue;
    const dest = uniqueDestination(path.basename(file), queue);
    fs.copyFileSync(file, dest, fs.constants.COPYFILE_EXCL);
    out.push(dest);
  }
  return out;
}

/** `<prefix> yyyy-MM-dd HHmmss.<ext>` in local time. */
export function intakeFileName(prefix: string, ext: string, date: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  const stamp = `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())} ${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`;
  return `${prefix} ${stamp}.${ext}`;
}

/** Pastes become new files in the queue. */
export function writeIntoQueue(data: string | Uint8Array, prefix: string, ext: string, queue: string, date = new Date()): string {
  fs.mkdirSync(queue, { recursive: true });
  const dest = uniqueDestination(intakeFileName(prefix, ext, date), queue);
  fs.writeFileSync(dest, data, { flag: 'wx' });
  return dest;
}
