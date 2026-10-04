/**
 * The built-in Folder collector: copies (default) or moves every settled,
 * top-level, non-hidden regular file of a source folder into the target
 * vault's queue folder. Dedupe is by content (sha256) against the vault's
 * ledger; an identical file under another name is skipped, an edited file is
 * collected again.
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { CollectorErrorCode, CollectorRun, CollectorRunFile, FolderCollectorSettings } from '../contracts.js';
import { isoDate } from '../store/json.js';
import { isSettled, moveIntoDirNoOverwrite, PARTIAL_SUFFIXES } from '../engine/queue.js';
import type { Ledger } from './store.js';

export interface FolderRunInput {
  collectorId: string;
  folder: FolderCollectorSettings;
  queueDir: string;
  ledger: Ledger;
  settleSeconds: number;
  now: () => Date;
  shouldStop: () => boolean;
}

export type FolderRunOutcome = Pick<CollectorRun, 'result' | 'files' | 'counts' | 'filesAdded' | 'error'>;

export function sha256File(file: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    fs.createReadStream(file)
      .on('error', reject)
      .on('data', (chunk) => hash.update(chunk))
      .on('end', () => resolve(hash.digest('hex')));
  });
}

/** Map a folder-level fs error to a run error. */
export function folderError(err: unknown, what: 'source' | 'queue', dir: string): { code: CollectorErrorCode; message: string } {
  const code = (err as NodeJS.ErrnoException).code;
  if (code === 'ENOENT' || code === 'ENOTDIR') {
    return what === 'source'
      ? { code: 'sourceMissing', message: `The source folder ${dir} doesn't exist.` }
      : { code: 'queueMissing', message: `The queue folder ${dir} doesn't exist.` };
  }
  if (code === 'EACCES' || code === 'EPERM') {
    return { code: 'noPermission', message: `Distill isn't allowed to read ${dir} (macOS privacy settings).` };
  }
  return { code: 'other', message: `${dir}: ${(err as Error).message}` };
}

function emptyCounts(): CollectorRun['counts'] {
  return { copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 0, added: 0 };
}

/** Hidden files (".DS_Store", "._x") and the macOS folder icon file "Icon\r". */
export function isHiddenName(name: string): boolean {
  return name.startsWith('.') || name === 'Icon\r';
}

async function copyNoOverwrite(src: string, dir: string, name: string): Promise<string> {
  const ext = path.extname(name);
  const base = ext ? name.slice(0, -ext.length) : name;
  for (let n = 1; n < 10_000; n++) {
    const dest = path.join(dir, n === 1 ? name : `${base} ${n}${ext}`);
    try {
      await fs.promises.copyFile(src, dest, fs.constants.COPYFILE_EXCL);
      return dest;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'EEXIST') continue;
      throw err;
    }
  }
  throw new Error(`No free name for ${name} in ${dir}.`);
}

export async function runFolder(input: FolderRunInput): Promise<FolderRunOutcome> {
  const { folder, queueDir, ledger } = input;
  const source = path.resolve(folder.source);
  const counts = emptyCounts();
  const files: CollectorRunFile[] = [];
  const filesAdded: string[] = [];

  let names: string[];
  try {
    if (!fs.statSync(source).isDirectory()) throw Object.assign(new Error('not a folder'), { code: 'ENOTDIR' });
    names = fs.readdirSync(source);
  } catch (err) {
    return { result: 'failed', counts, files, filesAdded, error: folderError(err, 'source', source) };
  }
  try {
    if (!fs.statSync(queueDir).isDirectory()) throw Object.assign(new Error('not a folder'), { code: 'ENOTDIR' });
  } catch (err) {
    return { result: 'failed', counts, files, filesAdded, error: folderError(err, 'queue', queueDir) };
  }

  // Oldest first, like the queue.
  const entries: { name: string; full: string; st: fs.Stats }[] = [];
  for (const name of names) {
    if (isHiddenName(name)) continue;
    const full = path.join(source, name);
    let st: fs.Stats;
    try {
      st = fs.lstatSync(full);
    } catch {
      continue;
    }
    if (!st.isFile()) continue; // subfolders and symlinks are left alone
    entries.push({ name, full, st });
  }
  entries.sort((a, b) => a.st.mtimeMs - b.st.mtimeMs || a.name.localeCompare(b.name));

  for (const { name, full, st } of entries) {
    if (input.shouldStop()) {
      return { result: 'stopped', counts, files, filesAdded };
    }
    const lower = name.toLowerCase();
    if (PARTIAL_SUFFIXES.some((s) => lower.endsWith(s))) {
      files.push({ name, outcome: 'waiting', reason: 'still downloading', size: st.size });
      counts.waiting += 1;
      continue;
    }
    if (!isSettled({ path: full, name, modifiedMs: st.mtimeMs, size: st.size }, input.settleSeconds, input.now())) {
      files.push({ name, outcome: 'waiting', reason: 'still changing', size: st.size });
      counts.waiting += 1;
      continue;
    }
    if (ledger.hasStat(full, st.size, st.mtimeMs)) {
      // Unchanged since it was collected: counted, but no line, so a run over a folder of
      // 500 kept originals stays small in the history (copy mode leaves them all there).
      counts.skipped += 1;
      continue;
    }
    try {
      const sha = await sha256File(full);
      if (ledger.hasSha(sha)) {
        files.push({ name, outcome: 'skipped', reason: 'already collected', size: st.size });
        counts.skipped += 1;
        continue;
      }
      let dest: string;
      if (folder.afterCollect === 'move') {
        dest = moveIntoDirNoOverwrite(full, queueDir);
        fs.utimesSync(dest, st.atime, st.mtime);
      } else {
        dest = await copyNoOverwrite(full, queueDir, name);
        fs.utimesSync(dest, st.atime, st.mtime); // keeps its mtime, so a settled file is ready for the next batch
        // Changed while we copied: drop the copy and wait for the next run.
        let after: fs.Stats | undefined;
        try {
          after = fs.statSync(full);
        } catch {
          after = undefined;
        }
        if (!after || after.size !== st.size || after.mtimeMs !== st.mtimeMs) {
          fs.rmSync(dest, { force: true });
          files.push({ name, outcome: 'waiting', reason: 'still changing', size: st.size });
          counts.waiting += 1;
          continue;
        }
      }
      const queueName = path.basename(dest);
      const outcome = folder.afterCollect === 'move' ? 'moved' : 'copied';
      ledger.append({
        sha256: sha,
        name,
        sourcePath: full,
        size: st.size,
        mtime: isoDate(st.mtime),
        mtimeMs: st.mtimeMs,
        collectedAt: isoDate(input.now()),
        collectorId: input.collectorId,
        queueName,
        outcome,
      });
      files.push({ name, outcome, queueName, size: st.size });
      filesAdded.push(queueName);
      counts[outcome] += 1;
      counts.added += 1;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      const reason = code === 'EACCES' || code === 'EPERM' ? 'no permission to read it' : (err as Error).message;
      files.push({ name, outcome: 'error', reason, size: st.size });
      counts.errors += 1;
    }
  }

  const result = counts.added > 0 ? 'success' : counts.errors > 0 ? 'failed' : 'nothing';
  const error =
    result === 'failed' ? { code: 'other' as const, message: `${counts.errors} file${counts.errors === 1 ? '' : 's'} couldn't be collected.` } : undefined;
  return { result, counts, files, filesAdded, ...(error ? { error } : {}) };
}
