/**
 * The built-in Folder collector: copies (default) or moves every settled,
 * top-level, non-hidden regular file of a source folder into the target
 * vault's queue folder. Dedupe is by content (sha256) against the vault's
 * ledger; an identical file under another name is skipped, an edited file is
 * collected again. With includeSubfolders (v5), each top-level subfolder is
 * one folder item, collected when any file in it is new or changed.
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { QUEUE_FOLDER_LIMITS, type CollectorErrorCode, type CollectorRun, type CollectorRunFile, type FolderCollectorSettings } from '../contracts.js';
import { isoDate } from '../store/json.js';
import {
  FOLDER_MANIFEST_NAME,
  folderTreeEntries,
  isHiddenName as isHiddenQueueName,
  isSettled,
  moveFolderIntoDirNoOverwrite,
  moveIntoDirNoOverwrite,
  PARTIAL_SUFFIXES,
  walkFolder,
  type FolderManifest,
  type FolderWalk,
} from '../engine/queue.js';
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
export const isHiddenName = isHiddenQueueName;

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

interface RunAcc {
  counts: CollectorRun['counts'];
  files: CollectorRunFile[];
  filesAdded: string[];
}

/** Same files, sizes and mtimes (the subfolder didn't change while it was copied). */
function sameWalk(a: FolderWalk, b: FolderWalk): boolean {
  if (a.files.length !== b.files.length || a.partialCount !== b.partialCount) return false;
  return a.files.every((f, i) => f.rel === b.files[i]!.rel && f.size === b.files[i]!.size && f.modifiedMs === b.files[i]!.modifiedMs);
}

/**
 * One top-level subfolder as one folder item (v5). The dedupe unit stays the file: each file is
 * checked against the ledger (path+size+mtime, else sha256). Nothing new → skipped. Copy mode copies
 * only the new and changed files into `<name>` (" 2" on a clash) with their relative paths; move mode
 * moves the whole folder. Either way the item gets `.distill-folder.json` with the whole tree, files
 * collected before marked seenBefore (listed for the AI, never sources). Limits: 200 new files and
 * 500 MB of them; 8 levels deep.
 */
async function collectSubfolder(input: FolderRunInput, name: string, full: string, acc: RunAcc): Promise<void> {
  const { folder, queueDir, ledger } = input;
  const line = (f: Omit<CollectorRunFile, 'name' | 'kind'>) => acc.files.push({ name: `${name}/`, kind: 'folder', ...f });
  const w = walkFolder(full, { maxFiles: Number.POSITIVE_INFINITY, maxBytes: Number.POSITIVE_INFINITY, maxDepth: QUEUE_FOLDER_LIMITS.maxDepth });
  if (w.unreadable) {
    line({ outcome: 'error', reason: 'no permission to read it' });
    acc.counts.errors += 1;
    return;
  }
  if (w.tooBig) {
    line({ outcome: 'skipped', reason: 'too big', fileCount: w.fileCount, size: w.totalSize });
    acc.counts.skipped += 1;
    return;
  }
  if (w.tooDeep) {
    line({ outcome: 'skipped', reason: 'too deep', fileCount: w.fileCount, size: w.totalSize });
    acc.counts.skipped += 1;
    return;
  }
  if (w.partialCount > 0) {
    line({ outcome: 'waiting', reason: 'still downloading', fileCount: w.fileCount, size: w.totalSize });
    acc.counts.waiting += 1;
    return;
  }
  if (w.fileCount > 0 && !isSettled({ path: full, name, modifiedMs: w.newestMs, size: w.totalSize }, input.settleSeconds, input.now())) {
    line({ outcome: 'waiting', reason: 'still changing', fileCount: w.fileCount, size: w.totalSize });
    acc.counts.waiting += 1;
    return;
  }
  // Which files are new: the cheap stat match first, then the content hash.
  const fresh: { rel: string; size: number; mtimeMs: number; sha: string }[] = [];
  const seen = new Set<string>();
  let hashedKnown = false;
  try {
    for (const f of w.files) {
      const abs = path.join(full, ...f.rel.split('/'));
      if (ledger.hasStat(abs, f.size, f.modifiedMs)) {
        seen.add(f.rel);
        continue;
      }
      const sha = await sha256File(abs);
      if (ledger.hasSha(sha)) {
        seen.add(f.rel);
        hashedKnown = true;
        continue;
      }
      fresh.push({ rel: f.rel, size: f.size, mtimeMs: f.modifiedMs, sha });
    }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    line({ outcome: 'error', reason: code === 'EACCES' || code === 'EPERM' ? 'no permission to read it' : (err as Error).message });
    acc.counts.errors += 1;
    return;
  }
  if (fresh.length === 0) {
    // Unchanged since it was collected: counted; a line only when a file matched by content alone.
    if (hashedKnown) line({ outcome: 'skipped', reason: 'already collected', fileCount: w.fileCount, size: w.totalSize });
    acc.counts.skipped += 1;
    return;
  }
  const freshBytes = fresh.reduce((n, f) => n + f.size, 0);
  if (fresh.length > QUEUE_FOLDER_LIMITS.maxFiles || freshBytes > QUEUE_FOLDER_LIMITS.maxBytes) {
    line({ outcome: 'skipped', reason: 'too big', fileCount: w.fileCount, newCount: fresh.length, size: freshBytes });
    acc.counts.skipped += 1;
    return;
  }
  const outcome = folder.afterCollect === 'move' ? 'moved' : 'copied';
  const manifest: FolderManifest = {
    version: 1,
    name,
    collectorId: input.collectorId,
    collectedAt: isoDate(input.now()),
    tree: folderTreeEntries(w).map((e) => (e.kind !== 'dir' && seen.has(e.path) ? { ...e, seenBefore: true } : e)),
  };
  let dest: string;
  try {
    if (outcome === 'moved') {
      dest = moveFolderIntoDirNoOverwrite(full, queueDir);
    } else {
      dest = makeFolderNoOverwrite(queueDir, name);
      for (const f of fresh) {
        const from = path.join(full, ...f.rel.split('/'));
        const to = path.join(dest, ...f.rel.split('/'));
        fs.mkdirSync(path.dirname(to), { recursive: true });
        fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL);
        const st = fs.statSync(from);
        fs.utimesSync(to, st.atime, st.mtime); // keeps its mtime, so a settled folder is ready for the next batch
      }
      // Changed while we copied: drop the copy and wait for the next run.
      const after = walkFolder(full, { maxFiles: Number.POSITIVE_INFINITY, maxBytes: Number.POSITIVE_INFINITY, maxDepth: QUEUE_FOLDER_LIMITS.maxDepth });
      if (!sameWalk(w, after)) {
        fs.rmSync(dest, { recursive: true, force: true });
        line({ outcome: 'waiting', reason: 'still changing', fileCount: w.fileCount, size: w.totalSize });
        acc.counts.waiting += 1;
        return;
      }
    }
    fs.writeFileSync(path.join(dest, FOLDER_MANIFEST_NAME), JSON.stringify(manifest, null, 2) + '\n');
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    line({ outcome: 'error', reason: code === 'EACCES' || code === 'EPERM' ? 'no permission to read it' : (err as Error).message });
    acc.counts.errors += 1;
    return;
  }
  const queueName = path.basename(dest);
  const logged = new Set<string>();
  for (const f of fresh) {
    if (logged.has(f.sha)) continue; // two identical files inside: one ledger entry
    logged.add(f.sha);
    ledger.append({
      sha256: f.sha,
      name: `${name}/${f.rel}`,
      sourcePath: path.join(full, ...f.rel.split('/')),
      size: f.size,
      mtime: isoDate(new Date(f.mtimeMs)),
      mtimeMs: f.mtimeMs,
      collectedAt: isoDate(input.now()),
      collectorId: input.collectorId,
      queueName: `${queueName}/${f.rel}`,
      outcome,
    });
  }
  line({ outcome, queueName, fileCount: w.fileCount, newCount: fresh.length, size: freshBytes });
  acc.filesAdded.push(queueName);
  acc.counts[outcome] += 1;
  acc.counts.added += 1;
}

/** Creates `<dir>/<name>`, `<name> 2`, ... (never an existing folder). */
function makeFolderNoOverwrite(dir: string, name: string): string {
  for (let n = 1; n < 10_000; n++) {
    const dest = path.join(dir, n === 1 ? name : `${name} ${n}`);
    try {
      fs.mkdirSync(dest);
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
  const subfolders: { name: string; full: string }[] = [];
  for (const name of names) {
    if (isHiddenName(name)) continue;
    const full = path.join(source, name);
    let st: fs.Stats;
    try {
      st = fs.lstatSync(full);
    } catch {
      continue;
    }
    if (st.isDirectory()) {
      if (folder.includeSubfolders === true) subfolders.push({ name, full });
      continue;
    }
    if (!st.isFile()) continue; // symlinks are left alone
    entries.push({ name, full, st });
  }
  entries.sort((a, b) => a.st.mtimeMs - b.st.mtimeMs || a.name.localeCompare(b.name));
  subfolders.sort((a, b) => a.name.localeCompare(b.name));

  for (const sub of subfolders) {
    if (input.shouldStop()) return { result: 'stopped', counts, files, filesAdded };
    await collectSubfolder(input, sub.name, sub.full, { counts, files, filesAdded });
  }

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
