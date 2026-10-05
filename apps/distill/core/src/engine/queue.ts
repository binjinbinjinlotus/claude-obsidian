import fs from 'node:fs';
import path from 'node:path';
import { QUEUE_FOLDER_LIMITS, type GoogleDocLink, type QueueEntry, type QueueTreeEntry, type VaultProfile } from '../contracts.js';
import { isoDate } from '../store/json.js';
import { realish } from '../store/realpath.js';

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
  /** For a folder: the newest change inside it (see walkFolder). */
  modifiedMs: number;
  /** For a folder: the total size of its files. */
  size: number;
  /** Set for a folder item (scanQueue only; pendingFiles never returns folders). */
  folder?: FolderWalk;
  /** Set for a `.gdoc` file: the parsed link, or why it can't be used. */
  gdoc?: GoogleDocLink | { problem: string };
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

// ───────────── Folders and Google Docs (v5) ─────────────

/** Hidden files (".DS_Store", "._x") and the macOS folder icon file "Icon\r". Never counted, listed or used for the wait. */
export function isHiddenName(name: string): boolean {
  return name.startsWith('.') || name === 'Icon\r';
}

export function isPartialName(name: string): boolean {
  const lower = name.toLowerCase();
  return PARTIAL_SUFFIXES.some((s) => lower.endsWith(s));
}

/** Entries visited before a walk gives up (a folder of 100 000 files must not stall the 5-second tick); hitting it = too big. */
export const FOLDER_WALK_CAP = 5000;

/** Written by the Folder collector inside a folder item it queued (hidden, so never a source or counted). */
export const FOLDER_MANIFEST_NAME = '.distill-folder.json';

/** `.distill-folder.json`: the subfolder's whole tree, with files collected before marked `seenBefore`. */
export interface FolderManifest {
  version: 1;
  /** The subfolder's name in the source folder. */
  name: string;
  collectorId?: string;
  collectedAt?: string;
  /** Every file and dir in the source subfolder when it was collected. */
  tree: QueueTreeEntry[];
}

export function readFolderManifest(dir: string): FolderManifest | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(path.join(dir, FOLDER_MANIFEST_NAME), 'utf8'));
  } catch {
    return undefined;
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  const obj = raw as Record<string, unknown>;
  const tree = Array.isArray(obj.tree)
    ? obj.tree.flatMap((t): QueueTreeEntry[] => {
        const e = t as Record<string, unknown> | null;
        if (!e || typeof e.path !== 'string' || e.path === '' || e.path.startsWith('/') || e.path.split('/').includes('..')) return [];
        const kind = e.kind === 'dir' || e.kind === 'gdoc' ? e.kind : 'file';
        const out: QueueTreeEntry = { path: e.path, size: typeof e.size === 'number' && e.size >= 0 ? e.size : 0, kind };
        if (e.seenBefore === true) out.seenBefore = true;
        return [out];
      })
    : [];
  const m: FolderManifest = { version: 1, name: typeof obj.name === 'string' ? obj.name : path.basename(dir), tree };
  if (typeof obj.collectorId === 'string') m.collectorId = obj.collectorId;
  if (typeof obj.collectedAt === 'string') m.collectedAt = obj.collectedAt;
  return m;
}

export interface FolderFile {
  /** Relative to the folder, "/"-separated. */
  rel: string;
  size: number;
  modifiedMs: number;
  /** A .gdoc pointer: listed, never a source. */
  gdoc?: boolean;
  /** Marked seenBefore in the folder's manifest: listed, never a source. */
  seenBefore?: boolean;
}

/** What walkFolder found inside a folder item. */
export interface FolderWalk {
  /** Files present (hidden files, partial downloads and the manifest not counted), .gdoc included. */
  fileCount: number;
  folderCount: number;
  /** Bytes of those files. */
  totalSize: number;
  /** Files the AI would read: not .gdoc, not seenBefore. */
  sourceCount: number;
  sourceBytes: number;
  gdocCount: number;
  /** Partial downloads inside (not counted as files, but their mtime counts for the wait). */
  partialCount: number;
  /** The newest file change inside (partial downloads included); the folder's own mtime when it has no files. */
  newestMs: number;
  /** The folder's own mtime when walked (a change means entries were added or removed directly inside). */
  dirMtimeMs: number;
  /** Over maxFiles/maxBytes in sources, or over the walk cap. */
  tooBig: boolean;
  tooDeep: boolean;
  /** Set when the folder itself can't be listed. */
  unreadable?: boolean;
  /** Present files, sorted by path. */
  files: FolderFile[];
  /** Subfolders, relative, sorted. */
  folders: string[];
  /** Manifest entries for files collected before that are not in the folder (copy mode keeps them out). */
  absentSeenBefore: QueueTreeEntry[];
}

const byPath = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/**
 * Walks a folder item: regular files at any depth up to maxDepth, skipping hidden names,
 * symlinks and anything that isn't a file or folder. Partial downloads only move
 * `newestMs`. Folders' own mtimes are ignored (Finder bumps them when it writes .DS_Store),
 * so the wait follows the newest file. A Folder collector manifest marks files seen before.
 */
export function walkFolder(dir: string, limits: { maxFiles: number; maxBytes: number; maxDepth: number } = QUEUE_FOLDER_LIMITS): FolderWalk {
  const out: FolderWalk = {
    fileCount: 0, folderCount: 0, totalSize: 0, sourceCount: 0, sourceBytes: 0, gdocCount: 0, partialCount: 0,
    newestMs: 0, dirMtimeMs: 0, tooBig: false, tooDeep: false, files: [], folders: [], absentSeenBefore: [],
  };
  try {
    out.dirMtimeMs = fs.statSync(dir).mtimeMs;
  } catch {
    out.unreadable = true;
    return out;
  }
  const manifest = readFolderManifest(dir);
  const seen = new Set((manifest?.tree ?? []).filter((t) => t.seenBefore && t.kind !== 'dir').map((t) => t.path));
  let visited = 0;
  let newestFile = 0;
  const stack: { abs: string; rel: string; depth: number }[] = [{ abs: dir, rel: '', depth: 0 }];
  while (stack.length > 0) {
    const cur = stack.pop()!;
    let names: string[];
    try {
      names = fs.readdirSync(cur.abs);
    } catch {
      if (cur.depth === 0) out.unreadable = true;
      continue;
    }
    for (const name of names) {
      if (isHiddenName(name)) continue;
      if (++visited > FOLDER_WALK_CAP) {
        out.tooBig = true;
        stack.length = 0;
        break;
      }
      const abs = path.join(cur.abs, name);
      const rel = cur.rel ? `${cur.rel}/${name}` : name;
      let st: fs.Stats;
      try {
        st = fs.lstatSync(abs);
      } catch {
        continue;
      }
      const depth = cur.depth + 1;
      if (st.isDirectory()) {
        // A folder at maxDepth can't hold anything: its files would be deeper than allowed.
        if (depth >= limits.maxDepth) {
          let inside: string[] = [];
          try {
            inside = fs.readdirSync(abs);
          } catch {
            /* unreadable: nothing to count */
          }
          if (inside.some((n) => !isHiddenName(n))) out.tooDeep = true;
          continue;
        }
        out.folderCount += 1;
        out.folders.push(rel);
        stack.push({ abs, rel, depth });
      } else if (st.isFile()) {
        newestFile = Math.max(newestFile, st.mtimeMs);
        if (isPartialName(name)) {
          out.partialCount += 1;
          continue;
        }
        const f: FolderFile = { rel, size: st.size, modifiedMs: st.mtimeMs };
        out.fileCount += 1;
        out.totalSize += st.size;
        if (isGoogleDocName(name)) {
          f.gdoc = true;
          out.gdocCount += 1;
        } else if (seen.has(rel)) {
          f.seenBefore = true;
        } else {
          out.sourceCount += 1;
          out.sourceBytes += st.size;
        }
        out.files.push(f);
      }
    }
  }
  if (out.sourceCount > limits.maxFiles || out.sourceBytes > limits.maxBytes) out.tooBig = true;
  out.newestMs = newestFile > 0 ? newestFile : out.dirMtimeMs;
  out.files.sort((a, b) => byPath(a.rel, b.rel));
  out.folders.sort(byPath);
  const present = new Set(out.files.map((f) => f.rel));
  // Collected before and left out (copy mode), or a .gdoc left behind in the queue folder: listed, never read.
  out.absentSeenBefore = (manifest?.tree ?? []).filter((t) => (t.seenBefore || t.kind === 'gdoc') && t.kind !== 'dir' && !present.has(t.path));
  return out;
}

/** Why a folder item can't be batched, or undefined. 'too big' / 'too deep' / 'empty folder' are the designed short reasons. */
export function folderProblem(w: FolderWalk): string | undefined {
  if (w.unreadable) return "Distill can't read this folder. Check its permissions, or remove it.";
  if (w.tooBig) return 'too big';
  if (w.tooDeep) return 'too deep';
  if (w.fileCount === 0 && w.partialCount === 0 && w.absentSeenBefore.length === 0) return 'empty folder';
  return undefined;
}

/**
 * The folder's tree, sorted by path: dirs, files (.gdoc as kind gdoc) and files collected before
 * that the collector left out (seenBefore). Dir sizes are the total of their files.
 */
export function folderTreeEntries(w: FolderWalk): QueueTreeEntry[] {
  const dirs = new Map<string, QueueTreeEntry>(w.folders.map((rel) => [rel, { path: rel, size: 0, kind: 'dir' as const }]));
  const entries: QueueTreeEntry[] = [...dirs.values()];
  const add = (rel: string, size: number, kind: QueueTreeEntry['kind'], seenBefore: boolean) => {
    const e: QueueTreeEntry = { path: rel, size, kind };
    if (seenBefore) e.seenBefore = true;
    entries.push(e);
    for (let p = rel; p.includes('/'); ) {
      p = p.slice(0, p.lastIndexOf('/'));
      let d = dirs.get(p);
      if (!d) {
        // A dir known only from the manifest (copy mode left all its files out).
        d = { path: p, size: 0, kind: 'dir' };
        dirs.set(p, d);
        entries.push(d);
      }
      d.size += size;
    }
  };
  for (const f of w.files) add(f.rel, f.size, f.gdoc ? 'gdoc' : 'file', f.seenBefore === true);
  for (const t of w.absentSeenBefore) add(t.path, t.size, t.kind === 'gdoc' ? 'gdoc' : 'file', t.seenBefore === true);
  return entries.sort((a, b) => byPath(a.path, b.path));
}

/** "12 KB", "18.4 MB". */
export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB'];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v >= 100 ? Math.round(v) : Math.round(v * 10) / 10} ${units[i]}`;
}

const plural = (n: number, noun: string) => `${n} ${noun}${n === 1 ? '' : 's'}`;

/**
 * The prompt block for one folder item: relative paths (from the batch folder), names and sizes,
 * never absolute paths. `.gdoc` and files collected before are listed but marked as not sources.
 */
export function folderSourceBlock(name: string, w: FolderWalk): string {
  // .gdoc pointers left behind in the queue folder still count: the folder had them.
  const leftGdocs = w.absentSeenBefore.filter((t) => t.kind === 'gdoc' && !t.seenBefore);
  const files = w.fileCount + leftGdocs.length;
  const bytes = w.totalSize + leftGdocs.reduce((n, t) => n + t.size, 0);
  const lines = [`Folder source: ${name}/ (${plural(files, 'file')}, ${plural(w.folderCount, 'folder')}, ${formatBytes(bytes)})`];
  const tree = folderTreeEntries(w);
  for (const e of tree.slice(0, QUEUE_FOLDER_LIMITS.maxTreeEntries)) {
    const p = `${name}/${e.path}`;
    if (e.kind === 'dir') lines.push(`- ${p}/`);
    else if (e.kind === 'gdoc') lines.push(`- ${p} (Google Doc, not read)`);
    else if (e.seenBefore) lines.push(`- ${p} (${formatBytes(e.size)}, seen before, not a source)`);
    else lines.push(`- ${p} (${formatBytes(e.size)})`);
  }
  if (tree.length > QUEUE_FOLDER_LIMITS.maxTreeEntries) lines.push(`- … ${tree.length - QUEUE_FOLDER_LIMITS.maxTreeEntries} more not listed`);
  lines.push('Treat these as one source; the paths and names are context.');
  return lines.join('\n');
}

export const GDOC_EXTENSION = '.gdoc';
const GDOC_MAX_BYTES = 64 * 1024;
/** A .gdoc with no usable url or doc_id (often Drive hasn't synced it yet). */
export const GDOC_PROBLEM = 'no link inside';
/** `QueueEntry.waiting` for a .gdoc: only a pointer, and Distill can't read Google Drive yet. */
export const GDOC_WAITING = 'google-drive';

export function isGoogleDocName(name: string): boolean {
  return name.toLowerCase().endsWith(GDOC_EXTENSION);
}

/**
 * A Google Drive `.gdoc` pointer: small JSON with `url`, `doc_id` and maybe `email`.
 * Only the title (the file name) and the link are kept; the email is never read out.
 * The link must be https on docs.google.com or drive.google.com; with no usable `url`,
 * it is built from `doc_id`.
 */
export function parseGoogleDoc(text: string, fileName: string): GoogleDocLink | { problem: string } {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return { problem: GDOC_PROBLEM };
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return { problem: GDOC_PROBLEM };
  const obj = raw as Record<string, unknown>;
  const title = isGoogleDocName(fileName) ? fileName.slice(0, -GDOC_EXTENSION.length) : fileName;
  const validId = (v: unknown): v is string => typeof v === 'string' && /^[A-Za-z0-9_-]{10,200}$/.test(v);
  let url: string | undefined;
  if (typeof obj.url === 'string') {
    try {
      const u = new URL(obj.url);
      if (u.protocol === 'https:' && (u.hostname === 'docs.google.com' || u.hostname === 'drive.google.com') && !u.username && !u.password) {
        url = u.toString();
      }
    } catch {
      /* not a URL */
    }
  }
  const fromUrl = url?.match(/\/d\/([A-Za-z0-9_-]+)/)?.[1];
  const docId = validId(obj.doc_id) ? obj.doc_id : validId(fromUrl) ? fromUrl : undefined;
  if (!url && docId) url = `https://docs.google.com/document/d/${docId}/edit`;
  if (!url) return { problem: GDOC_PROBLEM };
  const out: GoogleDocLink = { title, url };
  if (docId) out.docId = docId;
  return out;
}

/** Reads and parses a `.gdoc` file (never more than 64 KB). */
export function readGoogleDoc(file: string): GoogleDocLink | { problem: string } {
  try {
    const st = fs.statSync(file);
    if (st.size > GDOC_MAX_BYTES) return { problem: GDOC_PROBLEM };
    return parseGoogleDoc(fs.readFileSync(file, 'utf8'), path.basename(file));
  } catch {
    return { problem: GDOC_PROBLEM };
  }
}

export interface ScanOptions {
  /** Names to leave out before anything is read (inbox mode: items a batch already took). */
  exclude?: ReadonlySet<string>;
  /**
   * Folder walks from earlier scans, by path. A cached walk is reused while the folder's own mtime
   * is unchanged; `fresh` walks every folder again (Refresh, the queue check, batches).
   * Updated in place: folders that are gone are dropped.
   */
  cache?: Map<string, FolderWalk>;
  fresh?: boolean;
}

/**
 * The queue folder as queue items: what pendingFiles returns, plus each top-level folder as one
 * item (v5) and `.gdoc` files parsed. Oldest first. Used by the queue list and batches only;
 * pendingFiles stays file-only for the note manifest lookups. Throws when the folder exists
 * but can't be read (a missing folder is an empty queue).
 */
export function scanQueueFolder(dir: string, opts: ScanOptions = {}): ScanEntry[] {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch (err) {
    opts.cache?.clear();
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw err;
  }
  const out: ScanEntry[] = [];
  const seenFolders = new Set<string>();
  for (const name of names) {
    if (name.startsWith('.') || isPartialName(name) || opts.exclude?.has(name)) continue;
    const full = path.join(dir, name);
    let st: fs.Stats;
    try {
      st = fs.lstatSync(full);
    } catch {
      continue;
    }
    if (st.isFile()) {
      const e: ScanEntry = { path: full, name, modifiedMs: st.mtimeMs, size: st.size };
      if (isGoogleDocName(name)) e.gdoc = readGoogleDoc(full);
      out.push(e);
    } else if (st.isDirectory()) {
      seenFolders.add(full);
      const cached = opts.cache?.get(full);
      const w = !opts.fresh && cached && cached.dirMtimeMs === st.mtimeMs ? cached : walkFolder(full);
      opts.cache?.set(full, w);
      out.push({ path: full, name, modifiedMs: w.newestMs, size: w.totalSize, folder: w });
    }
  }
  if (opts.cache) for (const p of [...opts.cache.keys()]) if (!seenFolders.has(p)) opts.cache.delete(p);
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
  /** The manifest's requestID (label state for a note in inbox/ lives in Distill's state under it). */
  requestID?: string;
}

interface ParsedManifest {
  source?: string;
  labelsConfirmed: boolean;
  images: string[];
  requestID?: string;
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
  if (typeof obj.requestID === 'string' && obj.requestID !== '') out.requestID = obj.requestID;
  return out;
}

/** Note sets whose `.md` is in the scan (an orphan manifest or image is not a set). */
export function noteSets(all: ScanEntry[]): NoteSet[] {
  const entries = all.filter((e) => !e.folder);
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
    if (m.requestID) set.requestID = m.requestID;
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
export function noteSetPaths(all: ScanEntry[]): Set<string> {
  const entries = all.filter((e) => !e.folder);
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
  if (e.folder) return folderProblem(e.folder);
  try {
    fs.accessSync(e.path, fs.constants.R_OK);
  } catch {
    return "Distill can't read this file. Check its permissions, or remove it.";
  }
  // A .gdoc that isn't a usable link is marked, so its JSON (with the account email) never reaches a runner.
  if (e.gdoc && 'problem' in e.gdoc) return e.gdoc.problem;
  return undefined;
}

/**
 * What a healthy item waits for before any batch may take it, or undefined: 'google-drive' for a
 * .gdoc, and for a folder whose only files are .gdoc pointers (nothing else in it can be read).
 */
export function queueWaiting(e: ScanEntry): string | undefined {
  if (e.gdoc && !('problem' in e.gdoc)) return GDOC_WAITING;
  if (e.folder && e.folder.sourceCount === 0 && e.folder.gdocCount > 0) return GDOC_WAITING;
  return undefined;
}

/**
 * Files a batch may take now: settled ones and every note set, minus files
 * with a problem (they stay in the queue, marked, until the user removes them).
 */
export function readyFiles(entries: ScanEntry[], settleSeconds: number, now: Date): ScanEntry[] {
  const notes = noteSetPaths(entries);
  // A note set goes all or nothing: a problem on any of its files holds the whole note back.
  const byPath = new Map(entries.map((e) => [e.path, e]));
  const held = new Set<string>();
  for (const s of noteSets(entries)) {
    const files = [s.note, s.manifest, ...s.images];
    if (files.some((p) => { const e = byPath.get(p); return e !== undefined && queueProblem(e) !== undefined; })) {
      for (const p of files) held.add(p);
    }
  }
  return entries.filter(
    (e) => (notes.has(e.path) || isSettled(e, settleSeconds, now)) && !held.has(e.path) && !queueProblem(e) && !queueWaiting(e),
  );
}

export function toQueueEntry(
  e: ScanEntry,
  settleSeconds: number,
  now: Date,
  notes: Set<string> = new Set(),
  firstSeenMs?: number,
): QueueEntry {
  // Every .gdoc is a Google Doc row; one with no usable link also carries problem 'no link inside'.
  const kind = e.folder ? 'folder' : notes.has(e.path) ? 'note' : e.gdoc ? 'gdoc' : 'file';
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
  if (e.folder) {
    entry.fileCount = e.folder.fileCount;
    entry.folderCount = e.folder.folderCount;
    const tree = folderTreeEntries(e.folder);
    entry.tree = tree.slice(0, QUEUE_FOLDER_LIMITS.maxTreeEntries);
    if (tree.length > QUEUE_FOLDER_LIMITS.maxTreeEntries) entry.treeTruncated = true;
  }
  if (e.gdoc && !('problem' in e.gdoc)) entry.gdoc = { ...e.gdoc };
  const waiting = problem ? undefined : queueWaiting(e);
  if (waiting) entry.waiting = waiting;
  return entry;
}

export interface QueueListOptions {
  /** The mtime each path had when the core first saw it (drives `changing`). */
  firstSeen?: ReadonlyMap<string, number>;
  /** Display text for a manifest's source id (e.g. "in-person" → "In person"). */
  sourceLabel?: (source: string) => string;
  /** Whether labels were confirmed for this requestID in Distill's state (a note in inbox/; note-labels.ts). */
  labelsConfirmed?: (requestID: string) => boolean;
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
      const confirmed = set.labelsConfirmed || (set.requestID !== undefined && opts.labelsConfirmed?.(set.requestID) === true);
      const note: NonNullable<QueueEntry['note']> = { labelsConfirmed: confirmed, imageCount: set.imageCount };
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

/** Compared after resolving symlinks, so it agrees with the placement check (validator.ts). */
export function queueIsInbox(vault: VaultProfile): boolean {
  return realish(vault.queueDirectory) === path.join(realish(vault.path), 'inbox');
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

/** `name`, then `name 2`, `name 3`, ... (folders: no extension split, so "Trip.v2" becomes "Trip.v2 2"). */
export function uniqueFolderDestination(name: string, dir: string): string {
  let candidate = path.join(dir, name);
  for (let n = 2; fs.existsSync(candidate); n++) candidate = path.join(dir, `${name} ${n}`);
  return candidate;
}

/** Rename, or copy then unlink across volumes. Folders are copied whole (times kept) and then removed. */
export function moveFile(from: string, to: string): void {
  try {
    fs.renameSync(from, to);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EXDEV') throw err;
    if (fs.lstatSync(from).isDirectory()) {
      fs.cpSync(from, to, { recursive: true, errorOnExist: true, force: false, preserveTimestamps: true });
      fs.rmSync(from, { recursive: true, force: true });
      return;
    }
    fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL);
    fs.unlinkSync(from);
  }
}

/**
 * Moves a folder into `dir` as `name`, `name 2`, ... without replacing anything, even where `dir`
 * can't be listed (~/.Trash): it claims the name with an exclusive mkdir, then renames the folder
 * onto that empty folder (or copies into it across volumes). Returns the destination.
 */
export function moveFolderIntoDirNoOverwrite(from: string, dir: string): string {
  const name = path.basename(from);
  for (let n = 1; n < 10_000; n++) {
    const dest = path.join(dir, n === 1 ? name : `${name} ${n}`);
    try {
      fs.mkdirSync(dest);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'EEXIST') continue;
      throw err;
    }
    try {
      fs.renameSync(from, dest);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EXDEV') {
        fs.rmdirSync(dest);
        throw err;
      }
      fs.cpSync(from, dest, { recursive: true, force: false, preserveTimestamps: true });
      fs.rmSync(from, { recursive: true, force: true });
    }
    return dest;
  }
  throw new Error(`No free name for ${name} in ${dir}.`);
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
  return claimItems(entries, vault, alreadyClaimed).files;
}

/**
 * Moves a folder item's .gdoc files (keeping their relative paths) into a hidden staging folder
 * next to it in the queue folder, before the folder goes to the vault. Hidden, so no scan lists it.
 */
function setGoogleDocsAside(folder: string, gdocs: FolderFile[]): string {
  const staging = fs.mkdtempSync(path.join(path.dirname(folder), '.distill-gdocs-'));
  for (const g of gdocs) {
    const to = path.join(staging, ...g.rel.split('/'));
    fs.mkdirSync(path.dirname(to), { recursive: true });
    moveFile(path.join(folder, ...g.rel.split('/')), to);
    // Subfolders that held only the pointer don't travel to the vault empty (hidden files count as content).
    for (let dir = path.dirname(path.join(folder, ...g.rel.split('/'))); dir !== folder; dir = path.dirname(dir)) {
      try {
        fs.rmdirSync(dir);
      } catch {
        break; // not empty
      }
    }
  }
  return staging;
}

/**
 * Records a folder item's .gdoc pointers (path, size, kind only) in its `.distill-folder.json`
 * while the folder is still in the queue folder, so the prompt still lists them as "Google Doc,
 * not read" after the move. Nothing inside the folder is written once it is in the vault inbox.
 */
function recordGoogleDocs(folder: string, name: string, gdocs: FolderFile[]): void {
  const manifest = readFolderManifest(folder) ?? { version: 1 as const, name, tree: [] };
  const listed = new Set(manifest.tree.map((t) => t.path));
  for (const g of gdocs) if (!listed.has(g.rel)) manifest.tree.push({ path: g.rel, size: g.size, kind: 'gdoc' });
  fs.writeFileSync(path.join(folder, FOLDER_MANIFEST_NAME), JSON.stringify(manifest, null, 2) + '\n');
}

/**
 * Puts the staged .gdoc files back in the queue folder as a folder of the original name (" 2" if
 * that is taken again), where they wait for Google Drive access.
 */
function leaveGoogleDocsQueued(staging: string, original: string, name: string): void {
  const remaining = fs.existsSync(original) ? uniqueFolderDestination(name, path.dirname(original)) : original;
  fs.renameSync(staging, remaining);
}

/** `yyyy-MM-dd` in local time: the inbox folder a batch moves folder items into. */
export function batchDateFolder(date: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}`;
}

/**
 * claimFiles for files and folder items. A folder moves whole to `inbox/<date>/<name>` (keeping its
 * structure; " 2" on a clash); its sources (files that aren't hidden, partial, .gdoc or seen before)
 * go into `files` and the folder itself into `folders`. When the queue is the inbox, folders stay
 * where they are.
 */
export function claimItems(
  entries: ScanEntry[],
  vault: VaultProfile,
  alreadyClaimed: Set<string>,
  date: Date = new Date(),
): { files: string[]; folders: string[] } {
  const inbox = inboxDir(vault);
  fs.mkdirSync(inbox, { recursive: true });
  const inPlace = queueIsInbox(vault);
  const files: string[] = [];
  const folders: string[] = [];
  for (const entry of entries) {
    if (entry.folder) {
      let rel: string;
      if (inPlace) {
        rel = 'inbox/' + entry.name;
      } else {
        const day = path.join(inbox, batchDateFolder(date));
        fs.mkdirSync(day, { recursive: true });
        // .gdoc pointers never enter the vault: they step aside first and stay queued, waiting.
        // The folder's manifest is written while it is still in the queue folder; the move into
        // inbox/ is create-only (" 2" on a clash) and nothing inside the folder is written after it.
        const gdocs = entry.folder.files.filter((f) => f.gdoc);
        const staging = gdocs.length > 0 ? setGoogleDocsAside(entry.path, gdocs) : undefined;
        if (staging) recordGoogleDocs(entry.path, entry.name, gdocs);
        const target = moveFolderIntoDirNoOverwrite(entry.path, day);
        if (staging) leaveGoogleDocsQueued(staging, entry.path, entry.name);
        rel = `inbox/${path.basename(day)}/${path.basename(target)}`;
      }
      const sources = entry.folder.files.filter((f) => !f.gdoc && !f.seenBefore).map((f) => `${rel}/${f.rel}`);
      const fresh = sources.filter((f) => !alreadyClaimed.has(f));
      if (fresh.length > 0) {
        folders.push(rel);
        files.push(...fresh);
      }
      continue;
    }
    let target: string;
    if (inPlace) {
      target = path.resolve(entry.path);
    } else {
      // Create-only: never replaces a file already in inbox/ (`name 2.ext` on a clash).
      target = moveIntoDirNoOverwrite(entry.path, inbox);
    }
    const rel = 'inbox/' + path.basename(target);
    if (!alreadyClaimed.has(rel)) files.push(rel);
  }
  return { files, folders };
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
