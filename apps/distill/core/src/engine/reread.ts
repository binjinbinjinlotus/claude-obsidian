import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { Job, RereadGroup } from '../contracts.js';
import { listValue, parseFrontmatter, scalarValue } from '../labels/frontmatter.js';
import { encodeJSON, isObject, readJSON, writeFileAtomic } from '../store/json.js';
import { NOTE_MANIFEST_SUFFIX, type SourceLabels } from './job-kinds.js';

/**
 * Re-read sources (queue-and-batching.md, "Re-read sources"): sources already ingested are read
 * again, completely, in small groups. Each group is its own ingest batch with a fresh session;
 * one runs at a time per vault. The files stay where they are in inbox/ (create-only for
 * Distill): nothing here writes into the vault. Everything in this file only reads the vault.
 */

/** Sources per batch by default: one session holds about 3 full meeting transcripts (decision 2026-10-05). */
export const DEFAULT_REREAD_PER_BATCH = 3;
export const MAX_REREAD_PER_BATCH = 10;

/** One source: a loose file, or a folder item (its files listed under it). */
export interface RereadItem {
  files: string[];
  folder?: string;
}

/** A re-read waiting to run, kept in <state>/reread.json until every group has started. */
export interface RereadPlan {
  id: string;
  vaultPath: string;
  createdAt: string;
  perBatch: number;
  fromJob?: string;
  instruction?: string;
  groups: RereadGroup[];
}

export function makeRereadID(date: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  const stamp = `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}-${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`;
  return `reread-${stamp}-${randomUUID().slice(0, 4).toLowerCase()}`;
}

/** Items in groups of `perBatch`, in order. */
export function groupItems(items: RereadItem[], perBatch: number): RereadGroup[] {
  const out: RereadGroup[] = [];
  for (let i = 0; i < items.length; i += perBatch) {
    const chunk = items.slice(i, i + perBatch);
    const g: RereadGroup = { files: chunk.flatMap((c) => c.files) };
    const folders = chunk.flatMap((c) => (c.folder ? [c.folder] : []));
    if (folders.length > 0) g.folders = folders;
    out.push(g);
  }
  return out;
}

/**
 * A finished batch's sources as items: its files minus note manifests (instructions, not
 * sources; their images were handled when the note was first ingested), each folder one item.
 */
export function jobSourceItems(job: Pick<Job, 'files' | 'folders'>): { items: RereadItem[]; skipped: { path: string; reason: string }[] } {
  const folders = job.folders ?? [];
  const skipped: { path: string; reason: string }[] = [];
  const items: RereadItem[] = [];
  const byFolder = new Map<string, string[]>();
  for (const f of job.files) {
    if (f.endsWith(NOTE_MANIFEST_SUFFIX)) {
      skipped.push({ path: f, reason: 'a Distill note manifest (instructions, not a source)' });
      continue;
    }
    const folder = folders.find((d) => f.startsWith(d + '/'));
    if (folder) {
      const list = byFolder.get(folder) ?? [];
      if (list.length === 0) {
        byFolder.set(folder, list);
        items.push({ files: list, folder });
      }
      list.push(f);
    } else {
      items.push({ files: [f] });
    }
  }
  return { items: items.filter((i) => i.files.length > 0), skipped };
}

/** Why a vault-relative path can't be re-read in place, or undefined when it can. */
export function inboxFileProblem(vaultPath: string, rel: string): string | undefined {
  if (typeof rel !== 'string' || !rel.startsWith('inbox/') || rel.split('/').some((p) => p === '..' || p === '' || p === '.')) {
    return 'not a path inside inbox/';
  }
  const abs = path.join(vaultPath, rel);
  let st: fs.Stats;
  try {
    st = fs.lstatSync(abs);
  } catch {
    return 'not in inbox/ any more (moved, or cleaned up to the Trash?)';
  }
  if (st.isSymbolicLink()) return 'a symbolic link';
  if (!st.isFile()) return 'not a file';
  try {
    const real = fs.realpathSync(abs);
    const inbox = fs.realpathSync(path.join(vaultPath, 'inbox'));
    if (!real.startsWith(inbox + path.sep)) return 'outside inbox/';
  } catch {
    return 'not readable';
  }
  return undefined;
}

/** Size of a source as the AI will read it: embedded base64 images are not text and are left out. */
export interface SourceSize {
  bytes: number;
  lines: number;
  /** Bytes of text lines (all bytes minus lines that are only embedded `data:` images). */
  textBytes: number;
  /** Lines that are only an embedded image (`[image1]: <data:image/png;base64,...>`). */
  imageLines: number;
  /** Text lines over 2000 characters (the Read tool cuts them; read them with Grep or in parts). */
  longLines: number;
  /** 1-based line numbers of the image lines (the first 20), so the prompt can say where to skip. */
  imageAt?: number[];
}

const DATA_IMAGE_LINE = /^\s*(\[[^\]]*\]:\s*<?data:image\/|!\[[^\]]*\]\(data:image\/)/i;

export function sourceSize(abs: string): SourceSize | undefined {
  let buf: Buffer;
  try {
    buf = fs.readFileSync(abs);
  } catch {
    return undefined;
  }
  const size: SourceSize = { bytes: buf.length, lines: 0, textBytes: 0, imageLines: 0, longLines: 0 };
  if (buf.length === 0) return size;
  const text = buf.toString('utf8');
  const lines = text.split('\n');
  if (lines.at(-1) === '') lines.pop();
  size.lines = lines.length;
  lines.forEach((l, i) => {
    if (DATA_IMAGE_LINE.test(l)) {
      size.imageLines += 1;
      if ((size.imageAt ??= []).length < 20) size.imageAt.push(i + 1);
      return;
    }
    size.textBytes += Buffer.byteLength(l, 'utf8') + 1;
    if (l.length > 2000) size.longLines += 1;
  });
  return size;
}

/** The source page(s) a vault already has for one input, and the labels on the first. */
export interface ExistingSource {
  pages: string[];
  labels?: SourceLabels;
}

function walkMarkdown(dir: string, out: string[], depth = 0): void {
  if (depth > 6) return;
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) walkMarkdown(abs, out, depth + 1);
    else if (e.isFile() && e.name.toLowerCase().endsWith('.md')) out.push(abs);
  }
}

function readText(abs: string): string | undefined {
  try {
    return fs.readFileSync(abs, 'utf8');
  } catch {
    return undefined;
  }
}

/**
 * Existing source pages per input, read-only: the source ledger's records whose origin locator
 * is the input (their `pages` under wiki/sources/), then pages under wiki/sources/ whose
 * `source_path` (or first `sources` entry) is the input. The labels on the first page found are
 * kept as they are (confirmed labels stay confirmed).
 */
export function existingSourcePages(vaultPath: string, files: string[]): Map<string, ExistingSource> {
  const want = new Set(files);
  const found = new Map<string, Set<string>>();
  const add = (file: string, page: string) => {
    if (!want.has(file)) return;
    const s = found.get(file) ?? new Set<string>();
    s.add(page);
    found.set(file, s);
  };
  try {
    const ledger = readJSON(path.join(vaultPath, 'wiki', 'meta', 'ledgers', 'source-ledger.json'));
    const sources = isObject(ledger) && isObject(ledger.sources) ? ledger.sources : {};
    for (const rec of Object.values(sources)) {
      if (!isObject(rec) || !isObject(rec.origin) || typeof rec.origin.locator !== 'string') continue;
      const pages = Array.isArray(rec.pages) ? rec.pages.filter((p): p is string => typeof p === 'string') : [];
      for (const p of pages) if (p.startsWith('wiki/sources/')) add(rec.origin.locator, p);
    }
  } catch {
    /* no ledger yet, or unreadable: the page scan below still runs */
  }
  const pageFiles: string[] = [];
  walkMarkdown(path.join(vaultPath, 'wiki', 'sources'), pageFiles);
  const texts = new Map<string, string>();
  for (const abs of pageFiles) {
    const text = readText(abs);
    if (text === undefined) continue;
    const rel = path.relative(vaultPath, abs).split(path.sep).join('/');
    texts.set(rel, text);
    const fm = parseFrontmatter(text);
    const src = scalarValue(fm, 'source_path') ?? listValue(fm, 'sources')[0];
    if (src) add(src, rel);
  }
  const out = new Map<string, ExistingSource>();
  for (const file of files) {
    const pages = [...(found.get(file) ?? [])].sort();
    if (pages.length === 0) continue;
    const entry: ExistingSource = { pages };
    const text = texts.get(pages[0]!) ?? readText(path.join(vaultPath, pages[0]!));
    if (text !== undefined) entry.labels = labelsOnPage(file, text);
    out.set(file, entry);
  }
  return out;
}

/** The labels a page has now, as a label-plan entry that writes them back unchanged. */
export function labelsOnPage(file: string, text: string): SourceLabels {
  const fm = parseFrontmatter(text);
  const labels = listValue(fm, 'tags').map((t) => t.trim()).filter((t) => t.length > 0);
  const by = scalarValue(fm, 'labels_by');
  const unconfirmed = scalarValue(fm, 'labels_reviewed') === 'false';
  if (by === 'ai' && unconfirmed) {
    const origin = scalarValue(fm, 'labels_origin');
    const entry: SourceLabels = { file, labels, by: 'ai' };
    if (origin === 'queue-folder' || origin === 'cli' || origin === 'suggest') entry.origin = origin;
    return entry;
  }
  return { file, labels, by: 'user' };
}

// ───────────── the waiting list ─────────────

function decodeGroup(v: unknown): RereadGroup | undefined {
  if (!isObject(v) || !Array.isArray(v.files)) return undefined;
  const files = v.files.filter((f): f is string => typeof f === 'string');
  if (files.length === 0) return undefined;
  const g: RereadGroup = { files };
  if (Array.isArray(v.folders)) {
    const folders = v.folders.filter((f): f is string => typeof f === 'string');
    if (folders.length > 0) g.folders = folders;
  }
  if (typeof v.jobId === 'string') g.jobId = v.jobId;
  return g;
}

function decodePlan(v: unknown): RereadPlan | undefined {
  if (!isObject(v) || typeof v.id !== 'string' || typeof v.vaultPath !== 'string' || !Array.isArray(v.groups)) return undefined;
  const groups = v.groups.map(decodeGroup).filter((g): g is RereadGroup => !!g);
  if (groups.length === 0) return undefined;
  const plan: RereadPlan = {
    id: v.id,
    vaultPath: v.vaultPath,
    createdAt: typeof v.createdAt === 'string' ? v.createdAt : new Date(0).toISOString(),
    perBatch: typeof v.perBatch === 'number' ? v.perBatch : DEFAULT_REREAD_PER_BATCH,
    groups,
  };
  if (typeof v.fromJob === 'string') plan.fromJob = v.fromJob;
  if (typeof v.instruction === 'string') plan.instruction = v.instruction;
  return plan;
}

/** Re-reads with groups not started yet, in <state>/reread.json (survives a core restart). */
export class RereadStore {
  plans: RereadPlan[] = [];
  constructor(readonly file: string) {
    try {
      const v = readJSON(file);
      const list = isObject(v) && Array.isArray(v.plans) ? v.plans : [];
      this.plans = list.map(decodePlan).filter((p): p is RereadPlan => !!p);
    } catch {
      this.plans = [];
    }
  }
  save(): void {
    const live = this.plans.filter((p) => p.groups.some((g) => !g.jobId));
    this.plans = live;
    if (live.length === 0) {
      fs.rmSync(this.file, { force: true });
      return;
    }
    writeFileAtomic(this.file, encodeJSON({ plans: live }));
  }
  pending(): boolean {
    return this.plans.some((p) => p.groups.some((g) => !g.jobId));
  }
}
