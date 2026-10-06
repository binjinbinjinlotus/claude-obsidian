/**
 * The apply queue (review-queue.md, sections 1 and 2): pure helpers, apart from file reads. One apply at a
 * time per vault; a queued approval applies only when `transaction inspect` proves its hash unchanged.
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { Job, SinceApproved, StatusResponse } from '../contracts.js';
import { pageShas, readBundle } from './review-labels.js';

export interface StalePath {
  path: string;
  expected: string | null;
  current: string | null;
}

function sha256Of(file: string): string | null {
  try {
    return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  } catch {
    return null;
  }
}

/**
 * The cheap freshness filter: each `expected_hashes` entry of the bundle (null = must not exist) against the
 * vault now. Inspect is the authority; this only names the paths for the owner and the refresh.
 */
export function staleFor(vaultPath: string, bundlePath: string): StalePath[] {
  let bundle: unknown;
  try {
    bundle = JSON.parse(fs.readFileSync(bundlePath, 'utf8'));
  } catch {
    return [];
  }
  const expected = (bundle as { expected_hashes?: unknown })?.expected_hashes;
  if (!expected || typeof expected !== 'object') return [];
  const out: StalePath[] = [];
  for (const [rel, digest] of Object.entries(expected as Record<string, unknown>)) {
    if (digest !== null && typeof digest !== 'string') continue;
    const current = sha256Of(path.join(vaultPath, rel));
    if (current !== digest) out.push({ path: rel, expected: digest, current });
  }
  return out;
}

/** Jobs waiting in a vault's apply queue, head first (the first approve's time; a re-approval keeps it). */
export function queueOrder(jobs: Job[], vaultPath: string): Job[] {
  return jobs
    .filter((j) => j.vaultPath === vaultPath && j.state === 'awaitingApproval' && j.queuedApply)
    .sort((a, b) => a.queuedApply!.order - b.queuedApply!.order || a.createdAt.localeCompare(b.createdAt));
}

/** A batch's plain name for status lines: its first file without folder and extension, "+2" for the rest. */
export function plainBatchName(j: Job): string {
  const first = j.files[0];
  return first ? `${path.basename(first).replace(/\.[^.]+$/, '')}${j.files.length > 1 ? ` +${j.files.length - 1}` : ''}` : j.id;
}

/** `distill status`: the apply queue (approvals waiting their turn, head first per vault) and recovering batches. */
export function queueStatus(jobs: Job[]): Pick<StatusResponse, 'applyQueue' | 'recovering'> {
  const vaults = [...new Set(jobs.filter((j) => j.queuedApply?.planSha256).map((j) => j.vaultPath))];
  const applyQueue = vaults.flatMap((v) =>
    queueOrder(jobs, v)
      .filter((j) => j.queuedApply!.planSha256)
      .map((j, i) => ({ id: j.id, name: plainBatchName(j), vaultPath: v, position: i + 1 })),
  );
  const recovering = jobs
    .filter((j) => j.recovery && j.recovery.state !== 'fixed' && (j.state === 'awaitingApproval' || j.state === 'failed' || j.state === 'running'))
    .map((j) => ({
      id: j.id,
      name: plainBatchName(j),
      signature: j.recovery!.signature,
      state: j.recovery!.state,
      ...(j.recovery!.state === 'waiting' && j.recovery!.waitUntil ? { waitUntil: j.recovery!.waitUntil } : {}),
    }));
  return { applyQueue, recovering };
}

/** Bookkeeping pages every batch writes again (review-queue.md, What changed since you approved). */
export function isBookkeeping(p: string): boolean {
  return /^wiki\/(hot|log|index|overview)\.md$/.test(p) || p.startsWith('wiki/meta/ledgers/');
}


function writesOf(bundlePath: string): Map<string, string> {
  const b = readBundle(bundlePath);
  return b ? pageShas(b) : new Map();
}

/** The approved bundle against the rebuilt one, path by path. Source pages are proven equal by checkRebuiltPart. */
export function sinceApproved(approvedBundle: string, rebuiltBundle: string, sourcePages: string[]): SinceApproved {
  const a = writesOf(approvedBundle);
  const b = writesOf(rebuiltBundle);
  const sources = new Set(sourcePages);
  const out: SinceApproved = { sources: 'same', content: [], added: [], dropped: [], bookkeeping: [] };
  for (const [p, h] of b) {
    if (sources.has(p)) continue;
    if (isBookkeeping(p)) out.bookkeeping.push(p);
    else if (!a.has(p)) out.added.push(p);
    else if (a.get(p) !== h) out.content.push(p);
  }
  for (const p of a.keys()) if (!b.has(p) && !sources.has(p) && !isBookkeeping(p)) out.dropped.push(p);
  return out;
}
