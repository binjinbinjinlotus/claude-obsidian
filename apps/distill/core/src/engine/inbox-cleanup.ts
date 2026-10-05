import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type {
  InboxCleanupItem,
  InboxCleanupPreview,
  InboxCleanupResult,
  InboxCleanupStay,
  InboxStayReason,
  Job,
} from '../contracts.js';
import { readManifest } from './notes.js';
import { runProcess, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { moveFolderIntoDirNoOverwrite, moveIntoDirNoOverwrite } from './queue.js';

/**
 * Clean up inbox (spec inbox-cleanup.md, decision 2026-10-05). claude-obsidian keeps inbox/ as the
 * user's; Distill never deletes from it on its own. When the user asks, a file may go to the Trash
 * only when all three hold:
 *   1. the source ledger has an entry whose origin.locator names the file (vault-relative);
 *   2. the file's sha256 equals that entry's content_sha256 (unchanged since it was added);
 *   3. every path in that entry's `pages` exists.
 * A note's .distill.json and the images it lists go with the note; a folder item goes as one, only
 * when every source file inside passes. Files a pending batch claimed, and queued files not yet
 * batched, never go. This module reads the ledger; it never writes the ledger, wiki/ or .raw/.
 */

export const LEDGER_PATH = 'wiki/meta/ledgers/source-ledger.json';
const MANIFEST_SUFFIX = '.distill.json';
const FOLDER_MANIFEST = '.distill-folder.json';

interface LedgerEntry {
  locator: string;
  sha?: string;
  pages: string[];
  addedAt?: string;
}

export interface Ledger {
  /** NFC locator → entries. */
  exact: Map<string, LedgerEntry[]>;
  /** NFC, case-folded locator → entries. */
  folded: Map<string, LedgerEntry[]>;
}

const nfc = (s: string) => s.normalize('NFC');
const fold = (s: string) => nfc(s).toLowerCase();

/** Read the vault's source ledger (missing or unreadable = empty). Only `file` origins can name an inbox file. */
export function readLedger(vaultPath: string): Ledger {
  const exact = new Map<string, LedgerEntry[]>();
  const folded = new Map<string, LedgerEntry[]>();
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(path.join(vaultPath, LEDGER_PATH), 'utf8'));
  } catch {
    return { exact, folded };
  }
  const sources = raw && typeof raw === 'object' ? (raw as { sources?: unknown }).sources : undefined;
  if (!sources || typeof sources !== 'object') return { exact, folded };
  for (const rec of Object.values(sources as Record<string, unknown>)) {
    if (!rec || typeof rec !== 'object') continue;
    const r = rec as Record<string, unknown>;
    const origin = r.origin as Record<string, unknown> | undefined;
    if (!origin || origin.kind !== 'file' || typeof origin.locator !== 'string' || !origin.locator) continue;
    const entry: LedgerEntry = {
      locator: origin.locator,
      pages: Array.isArray(r.pages) ? r.pages.filter((p): p is string => typeof p === 'string') : [],
      ...(typeof r.content_sha256 === 'string' ? { sha: r.content_sha256.toLowerCase() } : {}),
      ...(typeof r.ingested_at === 'string' ? { addedAt: r.ingested_at } : {}),
    };
    const k = nfc(entry.locator);
    exact.set(k, [...(exact.get(k) ?? []), entry]);
    const f = fold(entry.locator);
    folded.set(f, [...(folded.get(f) ?? []), entry]);
  }
  return { exact, folded };
}

export function sha256File(abs: string): string {
  return createHash('sha256').update(fs.readFileSync(abs)).digest('hex');
}

type FileCheck = { ok: true; entry: LedgerEntry } | { ok: false; reason: InboxStayReason; detail?: string };

/** The three checks for one vault-relative file. */
export function checkFile(vaultPath: string, rel: string, ledger: Ledger, hash: (abs: string) => string = sha256File): FileCheck {
  const abs = path.join(vaultPath, rel);
  let sha: string;
  try {
    sha = hash(abs);
  } catch {
    return { ok: false, reason: 'unreadable' };
  }
  let candidates = ledger.exact.get(nfc(rel)) ?? [];
  let caseOnly = false;
  if (candidates.length === 0) {
    candidates = ledger.folded.get(fold(rel)) ?? [];
    caseOnly = true;
  }
  if (candidates.length === 0) return { ok: false, reason: 'notAdded' };
  // A case-only match counts only when one entry matches and its hash agrees.
  if (caseOnly && candidates.length !== 1) return { ok: false, reason: 'notAdded' };
  const entry = candidates.find((e) => e.sha === sha);
  if (!entry) return { ok: false, reason: 'changed' };
  if (entry.pages.length === 0) return { ok: false, reason: 'pageMissing', detail: 'no page is listed for it' };
  const missing = entry.pages.find((p) => !fs.existsSync(path.join(vaultPath, p)));
  if (missing) return { ok: false, reason: 'pageMissing', detail: path.basename(missing, '.md') };
  return { ok: true, entry };
}

export interface CleanupScope {
  vaultPath: string;
  jobs: Job[];
  /** Limit to the files this batch used. */
  jobId?: string;
  /** Vault-relative paths of queue entries not yet batched (only when the queue folder is inbox/). */
  queued?: Set<string>;
  now?: Date;
  hash?: (abs: string) => string;
}

interface Unit {
  path: string;
  kind: 'file' | 'note' | 'folder';
  members: string[];
  /** Files to check (vault-relative). */
  checks: string[];
  /** All files it holds. */
  files: string[];
}

const hidden = (name: string) => name.startsWith('.');

function walkFiles(vaultPath: string, rel: string): string[] {
  const out: string[] = [];
  let names: fs.Dirent[];
  try {
    names = fs.readdirSync(path.join(vaultPath, rel), { withFileTypes: true });
  } catch {
    return out;
  }
  for (const d of names) {
    const child = `${rel}/${d.name}`;
    if (d.isSymbolicLink()) continue;
    if (d.isDirectory()) {
      if (!hidden(d.name)) out.push(...walkFiles(vaultPath, child));
    } else if (d.isFile()) out.push(child);
  }
  return out;
}

function isFile(vaultPath: string, rel: string): boolean {
  try {
    return fs.lstatSync(path.join(vaultPath, rel)).isFile();
  } catch {
    return false;
  }
}

function isDir(vaultPath: string, rel: string): boolean {
  try {
    return fs.lstatSync(path.join(vaultPath, rel)).isDirectory();
  } catch {
    return false;
  }
}

function sizeOf(vaultPath: string, rels: string[]): number {
  let n = 0;
  for (const r of rels) {
    try {
      n += fs.statSync(path.join(vaultPath, r)).size;
    } catch {
      /* gone */
    }
  }
  return n;
}

const underInbox = (rel: string) => rel.startsWith('inbox/') && !rel.split('/').includes('..');

/** Folder items known from batches (vault-relative), present on disk. */
function folderItems(vaultPath: string, jobs: Job[]): string[] {
  const all = new Set<string>();
  for (const j of jobs) if (j.vaultPath === vaultPath) for (const f of j.folders ?? []) if (underInbox(f)) all.add(f);
  return [...all].filter((f) => isDir(vaultPath, f));
}

/** Group loose files into notes (an .md with its manifest and images) and plain files. */
function groupFiles(vaultPath: string, files: string[]): Unit[] {
  const set = new Set(files);
  const taken = new Set<string>();
  const units: Unit[] = [];
  for (const f of files) {
    if (!f.endsWith(MANIFEST_SUFFIX)) continue;
    const stem = f.slice(0, -MANIFEST_SUFFIX.length);
    const note = `${stem}.md`;
    if (!set.has(note)) continue;
    const dir = path.posix.dirname(f);
    const images = (readManifest(path.join(vaultPath, f))?.images ?? []).map((i) => `${dir}/${i.file}`).filter((p) => set.has(p));
    const members = [f, ...images];
    for (const m of [note, ...members]) taken.add(m);
    units.push({ path: note, kind: 'note', members, checks: [note], files: [note, ...members] });
  }
  for (const f of files) {
    if (taken.has(f)) continue;
    units.push({ path: f, kind: 'file', members: [], checks: [f], files: [f] });
  }
  return units;
}

function unitsFor(scope: CleanupScope): Unit[] {
  const { vaultPath } = scope;
  const folders = folderItems(vaultPath, scope.jobs);
  const inFolder = (rel: string) => folders.some((f) => rel === f || rel.startsWith(f + '/'));
  let loose: string[];
  let useFolders = folders;
  if (scope.jobId) {
    const job = scope.jobs.find((j) => j.id === scope.jobId);
    if (!job) return [];
    useFolders = (job.folders ?? []).filter((f) => underInbox(f) && isDir(vaultPath, f));
    loose = job.files.filter((f) => underInbox(f) && !useFolders.some((d) => f.startsWith(d + '/')) && isFile(vaultPath, f));
  } else {
    loose = walkFiles(vaultPath, 'inbox').filter((f) => !inFolder(f) && !hidden(path.posix.basename(f)));
  }
  const units = groupFiles(vaultPath, loose);
  for (const f of useFolders) {
    const files = walkFiles(vaultPath, f);
    const checks = files.filter((p) => {
      const b = path.posix.basename(p);
      return !hidden(b) && !b.endsWith('.gdoc');
    });
    units.push({ path: f, kind: 'folder', members: [], checks, files: files.filter((p) => path.posix.basename(p) !== FOLDER_MANIFEST) });
  }
  return units.sort((a, b) => a.path.localeCompare(b.path));
}

/** Paths a batch still holds: running or waiting in Review (files and folders). */
function claimed(scope: CleanupScope): { files: Map<string, string>; folders: Map<string, string> } {
  const files = new Map<string, string>();
  const folders = new Map<string, string>();
  for (const j of scope.jobs) {
    if (j.vaultPath !== scope.vaultPath) continue;
    if (j.state !== 'running' && j.state !== 'awaitingApproval') continue;
    for (const f of j.files) files.set(nfc(f), j.id);
    for (const f of j.folders ?? []) folders.set(nfc(f), j.id);
  }
  return { files, folders };
}

const REASON_ORDER: InboxStayReason[] = ['inReview', 'inQueue', 'unreadable', 'changed', 'pageMissing', 'notAdded'];

const reasonNoun: Record<InboxStayReason, string> = {
  notAdded: 'not added yet',
  changed: 'changed since it was added',
  pageMissing: 'its page is missing',
  inReview: 'waiting in Review',
  inQueue: 'in the queue',
  unreadable: 'can’t be read',
};

/** What could move to the Trash now, and what stays and why. Read-only. */
export function previewCleanup(scope: CleanupScope): InboxCleanupPreview {
  const { vaultPath } = scope;
  const ledger = readLedger(vaultPath);
  const held = claimed(scope);
  const items: InboxCleanupItem[] = [];
  const stays: InboxCleanupStay[] = [];
  for (const u of unitsFor(scope)) {
    const n = Math.max(1, u.files.length);
    const holder = u.files.map((f) => held.files.get(nfc(f))).find(Boolean) ?? held.folders.get(nfc(u.path))
      ?? [...held.folders.entries()].find(([f]) => nfc(u.path).startsWith(f + '/'))?.[1];
    if (holder && holder !== scope.jobId) {
      stays.push({ path: u.path, kind: u.kind, reason: 'inReview', fileCount: n });
      continue;
    }
    if (holder) {
      // The scoped batch itself still holds it (a part still waits in Review).
      stays.push({ path: u.path, kind: u.kind, reason: 'inReview', fileCount: n });
      continue;
    }
    if (scope.queued && u.files.some((f) => scope.queued!.has(nfc(f)))) {
      stays.push({ path: u.path, kind: u.kind, reason: 'inQueue', fileCount: n });
      continue;
    }
    if (u.checks.length === 0) {
      stays.push({ path: u.path, kind: u.kind, reason: 'notAdded', detail: 'nothing in it was a source', fileCount: n });
      continue;
    }
    const results = u.checks.map((c) => ({ file: c, r: checkFile(vaultPath, c, ledger, scope.hash) }));
    const bad = results.filter((x) => !x.r.ok) as { file: string; r: Extract<FileCheck, { ok: false }> }[];
    if (bad.length > 0) {
      const worst = REASON_ORDER.find((r) => bad.some((b) => b.r.reason === r)) ?? bad[0]!.r.reason;
      const first = bad.find((b) => b.r.reason === worst)!;
      const detail = u.kind === 'folder'
        ? `${bad.filter((b) => b.r.reason === worst).length} of ${u.checks.length} files ${reasonNoun[worst]}`
        : first.r.detail;
      stays.push({ path: u.path, kind: u.kind, reason: worst, ...(detail ? { detail } : {}), fileCount: n });
      continue;
    }
    const entries = results.map((x) => (x.r as Extract<FileCheck, { ok: true }>).entry);
    const pages = [...new Set(entries.flatMap((e) => e.pages))];
    const addedAt = entries.map((e) => e.addedAt).filter((d): d is string => !!d).sort().pop();
    const jobId = scope.jobId ?? scope.jobs.find((j) => j.vaultPath === vaultPath && (j.files.includes(u.checks[0]!) || (j.folders ?? []).includes(u.path)))?.id;
    items.push({
      path: u.path,
      kind: u.kind,
      ...(u.members.length ? { members: u.members } : {}),
      fileCount: n,
      size: sizeOf(vaultPath, u.files),
      ...(jobId ? { jobId } : {}),
      ...(addedAt ? { addedAt } : {}),
      pages,
    });
  }
  return { vaultPath, ...(scope.jobId ? { jobId: scope.jobId } : {}), items, stays, checkedAt: (scope.now ?? new Date()).toISOString() };
}

export type TrashMover = (abs: string[]) => Promise<{ method: 'finder' | 'rename'; failed: { path: string; error: string }[] }>;

/** Rename into a Trash folder (tests, and the fallback when Finder can't be asked). Put Back does not work for these. */
export function renameTrash(dir: string): TrashMover {
  return async (abs) => {
    const failed: { path: string; error: string }[] = [];
    fs.mkdirSync(dir, { recursive: true });
    for (const a of abs) {
      try {
        if (fs.lstatSync(a).isDirectory()) moveFolderIntoDirNoOverwrite(a, dir);
        else moveIntoDirNoOverwrite(a, dir);
      } catch (err) {
        failed.push({ path: a, error: (err as Error).message });
      }
    }
    return { method: 'rename', failed };
  };
}

const FINDER_SCRIPT = [
  'on run argv',
  'set out to {}',
  'repeat with p in argv',
  'try',
  'tell application "Finder" to delete (POSIX file (p as text) as alias)',
  'on error e',
  'set end of out to (p as text) & tab & e',
  'end try',
  'end repeat',
  'set AppleScript\'s text item delimiters to linefeed',
  'return out as text',
  'end run',
];

/**
 * Ask Finder to move the items to the Trash, so Put Back works. Falls back to a rename into ~/.Trash
 * when Finder can't be asked (automation not allowed, no Finder): the copy then says to drag a file back.
 */
export function finderTrash(fallbackDir: string, launch: (o: RunProcessOptions) => Promise<ProcessOutput> = runProcess): TrashMover {
  const fallback = renameTrash(fallbackDir);
  return async (abs) => {
    if (abs.length === 0) return { method: 'finder', failed: [] };
    let out: ProcessOutput | undefined;
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 120_000);
    try {
      out = await launch({
        executable: '/usr/bin/osascript',
        args: [...FINDER_SCRIPT.flatMap((l) => ['-e', l]), ...abs],
        cwd: fallbackDir.startsWith('/') ? path.dirname(fallbackDir) : '/',
        signal: ctl.signal,
      });
    } catch {
      out = undefined;
    } finally {
      clearTimeout(timer);
    }
    if (!out || out.status !== 0) return fallback(abs.filter((a) => fs.existsSync(a)));
    const failed: { path: string; error: string }[] = [];
    for (const line of out.stdout.toString('utf8').split('\n')) {
      const [p, e] = line.split('\t');
      if (p && e) failed.push({ path: p, error: e });
    }
    // Finder refused some (permissions): try those by rename, so the result is the same either way.
    if (failed.length > 0) {
      const again = await fallback(failed.map((f) => f.path).filter((a) => fs.existsSync(a)));
      return { method: failed.length === abs.length ? 'rename' : 'finder', failed: again.failed };
    }
    return { method: 'finder', failed };
  };
}

/** Check again, then move what still passes. Items not in the preview, or failing now, stay. */
export async function runCleanup(scope: CleanupScope, paths: string[], trash: TrashMover): Promise<InboxCleanupResult> {
  const preview = previewCleanup(scope);
  const want = new Set(paths.map(nfc));
  const go = preview.items.filter((i) => want.has(nfc(i.path)));
  const stayed: InboxCleanupStay[] = preview.stays.filter((s) => want.has(nfc(s.path)));
  const known = new Set([...go, ...stayed].map((x) => nfc(x.path)));
  for (const p of paths) if (!known.has(nfc(p))) stayed.push({ path: p, kind: 'file', reason: 'notAdded', detail: 'not in inbox/ any more, or not offered', fileCount: 0 });
  const failed: { path: string; error: string }[] = [];
  const moved: { path: string; fileCount: number }[] = [];
  if (go.length === 0) return { moved, stayed, failed, method: 'none' };
  // Members first, so a note never sits in inbox/ without its manifest for long.
  const abs = go.flatMap((i) => [...(i.members ?? []), i.path].map((r) => path.join(scope.vaultPath, r)));
  const r = await trash(abs);
  const bad = new Map(r.failed.map((f) => [path.resolve(f.path), f.error]));
  for (const i of go) {
    const errs = [...(i.members ?? []), i.path].map((m) => bad.get(path.join(scope.vaultPath, m))).filter(Boolean);
    if (errs.length > 0) failed.push({ path: i.path, error: String(errs[0]) });
    else moved.push({ path: i.path, fileCount: i.fileCount });
  }
  return { moved, stayed, failed, method: r.method };
}
