import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { LabelOrigin } from '../contracts.js';
import { encodeJSON, isObject, readJSON, str, strArray, writeFileAtomic } from '../store/json.js';
import { setLabelProperties, type LabelProperties } from './frontmatter.js';

/** One page's desired labels. */
export interface LabelEdit {
  path: string; // vault-relative, under wiki/
  labels: string[];
  /** user = confirmed (clears the unconfirmed marks); ai = unconfirmed with `origin`. */
  by: 'user' | 'ai';
  origin?: LabelOrigin;
}

/** What a label job wants, saved next to the bundle so a stale plan can be rebuilt. */
export interface LabelRequest {
  mode: 'confirm' | 'suggest';
  edits: LabelEdit[];
}

export interface BundleWrite {
  path: string;
  mode: 'replace';
  content: string;
}

/** `claude-obsidian.transaction.v1`, the subset label jobs use. */
export interface LabelBundle {
  schema: 'claude-obsidian.transaction.v1';
  operation_id: string;
  operation_type: 'markdown';
  expected_hashes: Record<string, string>;
  writes: BundleWrite[];
}

export interface BuiltBundle {
  bundle: LabelBundle;
  /** Pages left out, with why. */
  skipped: string[];
}

export function propertiesFor(edit: LabelEdit): LabelProperties {
  if (edit.labels.length === 0) return { tags: [] };
  if (edit.by === 'user') return { tags: edit.labels, labels_by: 'user' };
  const props: LabelProperties = { tags: edit.labels, labels_by: 'ai', labels_reviewed: false };
  if (edit.origin) props.labels_origin = edit.origin;
  return props;
}

/** A safe vault-relative page path under wiki/, or undefined. */
export function wikiPagePath(raw: string): string | undefined {
  const p = raw.replace(/\\/g, '/').replace(/^\.\//, '');
  if (p.startsWith('/') || p.includes('\0')) return undefined;
  const norm = path.posix.normalize(p);
  if (norm !== p || !norm.startsWith('wiki/') || norm.split('/').some((s) => s === '..' || s.startsWith('.'))) return undefined;
  if (!norm.toLowerCase().endsWith('.md')) return undefined;
  return norm;
}

const sha256 = (data: Uint8Array) => createHash('sha256').update(data).digest('hex');
const utf8 = new TextDecoder('utf-8', { fatal: true });

/** Reads a page as a regular file (no symlinks). */
export function readPage(vaultPath: string, rel: string): { bytes: Buffer; text: string } | string {
  const abs = path.join(vaultPath, rel);
  let st: fs.Stats;
  try {
    st = fs.lstatSync(abs);
  } catch {
    return 'not found';
  }
  if (!st.isFile()) return 'not a regular file';
  const bytes = fs.readFileSync(abs);
  try {
    return { bytes, text: utf8.decode(bytes) };
  } catch {
    return 'not UTF-8 text';
  }
}

/**
 * Builds the bundle deterministically from the pages as they are now: each
 * changed page is one `replace` write with the page's current SHA-256 in
 * `expected_hashes`, so `transaction apply` refuses if it changed meanwhile.
 */
export function buildLabelBundle(vaultPath: string, edits: LabelEdit[], operationID: string): BuiltBundle {
  const bundle: LabelBundle = {
    schema: 'claude-obsidian.transaction.v1',
    operation_id: operationID,
    operation_type: 'markdown',
    expected_hashes: {},
    writes: [],
  };
  const skipped: string[] = [];
  for (const edit of edits) {
    const page = readPage(vaultPath, edit.path);
    if (typeof page === 'string') {
      skipped.push(`${edit.path}: ${page}`);
      continue;
    }
    const next = setLabelProperties(page.text, propertiesFor(edit));
    if (next === page.text) {
      skipped.push(`${edit.path}: already has these labels`);
      continue;
    }
    bundle.expected_hashes[edit.path] = sha256(page.bytes);
    bundle.writes.push({ path: edit.path, mode: 'replace', content: next });
  }
  return { bundle, skipped };
}

export function writeLabelRequest(file: string, request: LabelRequest): void {
  writeFileAtomic(file, encodeJSON(request));
}

export function readLabelRequest(file: string): LabelRequest | undefined {
  const raw = readJSON(file);
  if (!isObject(raw) || (raw.mode !== 'confirm' && raw.mode !== 'suggest') || !Array.isArray(raw.edits)) return undefined;
  const edits: LabelEdit[] = [];
  for (const e of raw.edits) {
    if (!isObject(e)) continue;
    const p = str(e.path);
    const labels = strArray(e.labels);
    if (!p || !labels || (e.by !== 'user' && e.by !== 'ai')) continue;
    const edit: LabelEdit = { path: p, labels, by: e.by };
    const origin = str(e.origin);
    if (origin === 'queue-folder' || origin === 'cli' || origin === 'suggest') edit.origin = origin;
    edits.push(edit);
  }
  return { mode: raw.mode, edits };
}
