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

export function toQueueEntry(e: ScanEntry, settleSeconds: number, now: Date): QueueEntry {
  return {
    path: e.path,
    name: e.name,
    modified: isoDate(new Date(e.modifiedMs)),
    size: e.size,
    settled: isSettled(e, settleSeconds, now),
  };
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
