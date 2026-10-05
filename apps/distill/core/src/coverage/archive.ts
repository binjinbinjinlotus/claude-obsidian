import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { isObject, readJSON } from '../store/json.js';
import type { ArchiveFacts } from '../engine/job-kinds.js';

/**
 * Option A (full-read.md, section 4; owner decision 2026-10-05): each batch's bundle archives the
 * originals into `.raw/captured/<sha256>.<ext>` (create-only, byte for byte, the same layout as
 * claude-obsidian's `capture apply`), and the source ledger record points there. Because the
 * ledger ID hashes the locator (`stable_source_id`, ledgers.py), a record that had the inbox
 * locator is replaced by one with `supersedes: <old id>`. Lookups key on `content_sha256`.
 */

const SAFE = new Set(['.md', '.markdown', '.txt', '.json', '.csv', '.yaml', '.yml', '.html', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.mp3', '.wav', '.m4a', '.mp4', '.mov', '.webm', '.pdf', '.epub']);

export const LEDGER = path.join('wiki', 'meta', 'ledgers', 'source-ledger.json');
export const CLAIM_LEDGER = path.join('wiki', 'meta', 'ledgers', 'claim-ledger.json');

/** `.raw/captured/<sha>.<ext>` for a source, as claude-obsidian's capture names it. */
export function capturedPath(sha256: string, file: string): string {
  const ext = path.extname(file).toLowerCase();
  return `.raw/captured/${sha256}${SAFE.has(ext) ? ext : '.bin'}`;
}

/** claude-obsidian's `stable_source_id(origin_kind, locator, content_sha256)` (ledgers.py). */
export function stableSourceId(kind: string, locator: string, sha256: string | null): string {
  const loc = kind.toLowerCase() === 'file' ? locator.split('\\').join('/') : locator;
  const digest = createHash('sha256').update(`${kind.toLowerCase()}\0${loc}\0${(sha256 ?? '').toLowerCase()}`, 'utf8').digest('hex');
  return `src-${digest.slice(0, 20)}`;
}

export interface LedgerRecord {
  id: string;
  kind: string;
  locator: string;
  sha256?: string;
  pages: string[];
  supersedes?: string;
}

/** The source ledger's records (read-only). */
export function ledgerRecords(vaultPath: string): LedgerRecord[] {
  let v: unknown;
  try {
    v = readJSON(path.join(vaultPath, LEDGER));
  } catch {
    return [];
  }
  return recordsOf(v);
}

export function recordsOf(v: unknown): LedgerRecord[] {
  const sources = isObject(v) && isObject(v.sources) ? v.sources : {};
  const out: LedgerRecord[] = [];
  for (const [id, rec] of Object.entries(sources)) {
    if (!isObject(rec) || !isObject(rec.origin) || typeof rec.origin.locator !== 'string') continue;
    const r: LedgerRecord = {
      id,
      kind: typeof rec.origin.kind === 'string' ? rec.origin.kind : 'file',
      locator: rec.origin.locator.normalize('NFC'),
      pages: Array.isArray(rec.pages) ? rec.pages.filter((p): p is string => typeof p === 'string') : [],
    };
    if (typeof rec.content_sha256 === 'string') r.sha256 = rec.content_sha256.toLowerCase();
    if (typeof rec.supersedes === 'string') r.supersedes = rec.supersedes;
    out.push(r);
  }
  return out;
}

function claimCounts(vaultPath: string): Map<string, number> {
  const counts = new Map<string, number>();
  try {
    const text = fs.readFileSync(path.join(vaultPath, CLAIM_LEDGER), 'utf8');
    for (const m of text.matchAll(/"(src-[0-9a-f]{20})"/g)) counts.set(m[1]!, (counts.get(m[1]!) ?? 0) + 1);
  } catch {
    /* no claim ledger yet */
  }
  return counts;
}

/** An existing archived copy of this content (any extension), vault-relative, or undefined. */
export function archivedCopy(vaultPath: string, sha256: string): string | undefined {
  const dir = path.join(vaultPath, '.raw', 'captured');
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return undefined;
  }
  const hit = names.find((n) => n.startsWith(sha256 + '.') || n === sha256);
  return hit ? `.raw/captured/${hit}` : undefined;
}

/** The archive facts the prompt gives for one source. */
export function archiveFacts(vaultPath: string, file: string, sha256: string, records = ledgerRecords(vaultPath), claims = claimCounts(vaultPath)): ArchiveFacts {
  const existing = archivedCopy(vaultPath, sha256);
  const target = existing ?? capturedPath(sha256, file);
  const id = stableSourceId('file', target, sha256);
  const replaces = records
    .filter((r) => r.sha256 === sha256 && r.id !== id && r.kind.toLowerCase() === 'file')
    .map((r) => ({ id: r.id, locator: r.locator, claims: claims.get(r.id) ?? 0 }));
  return { path: target, exists: existing !== undefined, id, replaces, manifestKey: file.startsWith('.raw/') ? (replaces[0]?.locator ?? file) : file };
}

export function archiveFactsFor(vaultPath: string, items: { file: string; sha256: string }[]): Map<string, ArchiveFacts> {
  const records = ledgerRecords(vaultPath);
  const claims = claimCounts(vaultPath);
  return new Map(items.map((i) => [i.file, archiveFacts(vaultPath, i.file, i.sha256, records, claims)]));
}

/**
 * After inspect: problems with the bundle's archive writes and ledger (Option A), for the given
 * sources. Every source has its archive write (or an existing copy), a ledger record whose locator
 * is its archive path, and exactly one source record for its content sha256.
 */
export function archiveProblems(
  bundleWrites: { path: string; text?: string }[],
  vaultPath: string,
  sources: { file: string; sha256: string; archive: ArchiveFacts }[],
): string[] {
  const problems: string[] = [];
  const written = new Set(bundleWrites.map((w) => w.path));
  const ledgerWrite = bundleWrites.find((w) => w.path === LEDGER.split(path.sep).join('/'));
  let records: LedgerRecord[] | undefined;
  if (ledgerWrite?.text !== undefined) {
    try {
      records = recordsOf(JSON.parse(ledgerWrite.text));
    } catch {
      problems.push('the source ledger in the change is not valid JSON');
    }
  }
  records ??= ledgerRecords(vaultPath);
  for (const s of sources) {
    if (!s.archive.exists && !written.has(s.archive.path) && !archivedCopy(vaultPath, s.sha256)) problems.push(`${s.file}: no archive write ${s.archive.path}`);
    const same = records.filter((r) => r.sha256 === s.sha256 && r.kind.toLowerCase() === 'file');
    if (same.length === 0) problems.push(`${s.file}: no source ledger record for it`);
    else if (same.length > 1) problems.push(`${s.file}: ${same.length} source ledger records for the same content (${same.map((r) => r.id).join(', ')}); keep one`);
    else if (same[0]!.locator !== s.archive.path) problems.push(`${s.file}: its ledger locator is ${same[0]!.locator}, not ${s.archive.path}`);
  }
  return problems;
}
