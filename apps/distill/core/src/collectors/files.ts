/**
 * Script files (v6): each script collector Distill manages has its own folder,
 *
 *   <state>/collectors/scripts/<collector-id>/
 *     collector.zsh | collector.py | collector.js | collector.ts   the script (a real file)
 *     package.json (node, typescript) | requirements.txt (python3) the package manifest, optional
 *     node_modules/ | .venv/                                        installed packages
 *
 * collectors.json keeps only `{file, managed: true}`. Consent is bound to the script's bytes and, when a
 * manifest exists, to the manifest's bytes too (installing packages runs third-party code). Without a
 * manifest the hash is exactly sha256(script), so collectors allowed before v6 stay allowed.
 *
 * Deleting a collector: Distill's trash (activity/trash.ts) copies the folder without installed packages
 * next to the record, then the folder is removed; Restore puts it back here.
 *
 * Spec: apps/distill/docs/specs/collectors.md ("Script files").
 */
import fs from 'node:fs';
import path from 'node:path';
import type { Collector, CollectorInterpreter, CollectorManifestName } from '../contracts.js';
import { isoDate, writeFileAtomic } from '../store/json.js';
import { INLINE_EXTENSION, sha256Text } from './script.js';

/** New managed scripts. (Migrated node code keeps `.mjs`, the extension its inline code always ran with.) */
export const SCRIPT_EXTENSION: Record<CollectorInterpreter, string> = { zsh: 'zsh', python3: 'py', node: 'js', typescript: 'ts' };
export const MANIFEST: Record<CollectorInterpreter, CollectorManifestName | null> = {
  zsh: null,
  python3: 'requirements.txt',
  node: 'package.json',
  typescript: 'package.json',
};
/** Installed packages, per manifest: removed by a clean install and before a folder goes to the trash. */
export const PACKAGES_DIR: Record<CollectorManifestName, string> = { 'package.json': 'node_modules', 'requirements.txt': '.venv' };
export const TRASH_KEEP_DAYS = 30;
export const TEST_KEEP_DAYS = 7;
const DAY_MS = 24 * 60 * 60 * 1000;
const FILE_MODE = 0o600;

export function safeID(id: string): string {
  return id.replace(/[^A-Za-z0-9_-]/g, '_') || '_';
}

function isInside(child: string, parent: string): boolean {
  const rel = path.relative(parent, child);
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/**
 * The consent hash: sha256(script) without a manifest; with one, a hash over both files' hashes, so a
 * changed package list needs the user's OK like changed code. A lockfile is not part of it.
 */
export function consentHash(script: Buffer, manifest?: { name: CollectorManifestName; bytes: Buffer } | null): string {
  const scriptSha = sha256Text(script);
  if (!manifest) return scriptSha;
  return sha256Text(`distill-collector-consent-v2\nscript ${scriptSha}\n${manifest.name} ${sha256Text(manifest.bytes)}\n`);
}

/** How many packages the manifest lists; -1 for a package.json that can't be read (npm reports it). */
export function packageCount(name: CollectorManifestName, bytes: Buffer): number {
  const text = bytes.toString('utf8');
  if (name === 'requirements.txt') {
    // Requirement lines, plus -r / -e lines (another file, an editable package); other options don't count.
    return text.split(/\r?\n/).filter((l) => {
      const t = l.replace(/(^|\s)#.*$/, '').trim();
      return t !== '' && (!t.startsWith('-') || /^(-r|-e|--requirement|--editable)\b/.test(t));
    }).length;
  }
  try {
    const pkg = JSON.parse(text) as Record<string, unknown>;
    let n = 0;
    for (const k of ['dependencies', 'devDependencies', 'optionalDependencies']) {
      const v = pkg[k];
      if (v && typeof v === 'object') n += Object.keys(v).length;
    }
    return n;
  } catch {
    return -1;
  }
}

/** The manifest lists at least one package. An unreadable package.json counts as having some. */
export function hasDependencies(name: CollectorManifestName, bytes: Buffer): boolean {
  return packageCount(name, bytes) !== 0;
}

export interface ManifestFile {
  name: CollectorManifestName;
  path: string;
  bytes: Buffer | null;
}

export class ScriptFolders {
  constructor(readonly dir: string) {}

  get scriptsDir(): string {
    return path.join(this.dir, 'scripts');
  }

  /** Legacy: <state>/collectors/trash from an earlier v6 build. Nothing new goes here (Distill's trash keeps script folders). */
  get trashDir(): string {
    return path.join(this.dir, 'trash');
  }

  /** v6: a test run's scratch folder, <state>/collectors/test-runs/<id>; emptied at the start of each test run. */
  testDir(id: string): string {
    const root = path.join(this.dir, 'test-runs');
    const f = path.join(root, safeID(id));
    if (!isInside(f, root)) throw new Error(`Bad collector id ${id}.`);
    return f;
  }

  /** Remove test-run folders not touched for 7 days. */
  pruneTestRuns(now: Date): void {
    const root = path.join(this.dir, 'test-runs');
    let names: string[] = [];
    try {
      names = fs.readdirSync(root);
    } catch {
      return;
    }
    for (const name of names) {
      const p = path.join(root, name);
      try {
        if (isInside(p, root) && fs.statSync(p).mtimeMs < now.getTime() - TEST_KEEP_DAYS * DAY_MS) fs.rmSync(p, { recursive: true, force: true });
      } catch {
        // gone
      }
    }
  }

  /** <state>/collectors/scripts/<id>; never outside scripts/ whatever the id holds. */
  folder(id: string): string {
    const f = path.join(this.scriptsDir, safeID(id));
    if (!isInside(f, this.scriptsDir)) throw new Error(`Bad collector id ${id}.`);
    return f;
  }

  /** The file is directly in this collector's folder. */
  isManagedPath(id: string, file: string): boolean {
    return path.dirname(path.resolve(file)) === this.folder(id);
  }

  /** The collector folder name a file sits directly in (another collector's managed script), else undefined. */
  ownerOf(file: string): string | undefined {
    const dir = path.dirname(path.resolve(file));
    return path.dirname(dir) === this.scriptsDir ? path.basename(dir) : undefined;
  }

  /** Where a managed script's file is now (the stored name, in this state dir's folder). */
  managedPath(id: string, storedFile: string): string {
    return path.join(this.folder(id), path.basename(storedFile));
  }

  /**
   * Write `bytes` as the collector's script and return its path. `name` keeps an existing file name;
   * without it the file is collector.<ext>, or collector-2.<ext>… when another file already holds that name
   * (a crash between writing and saving collectors.json leaves identical bytes, which are reused).
   */
  writeScript(id: string, interpreter: CollectorInterpreter, bytes: Buffer, opts: { name?: string; migrated?: boolean } = {}): string {
    const folder = this.folder(id);
    fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
    let file: string;
    if (opts.name) {
      file = path.join(folder, path.basename(opts.name));
    } else {
      const ext = opts.migrated ? INLINE_EXTENSION[interpreter] : SCRIPT_EXTENSION[interpreter];
      file = path.join(folder, `collector.${ext}`);
      for (let n = 2; fs.existsSync(file); n += 1) {
        try {
          if (fs.readFileSync(file).equals(bytes)) return file;
        } catch {
          // a folder or unreadable: take the next name
        }
        file = path.join(folder, `collector-${n}.${ext}`);
      }
    }
    writeFileAtomic(file, bytes, FILE_MODE);
    return file;
  }

  /**
   * After a language change: the file gets the new language's extension (TypeScript needs `.ts`). A file
   * already holding that name is kept as `<name>.old-<time>`, never overwritten.
   */
  renameForLanguage(file: string, interpreter: CollectorInterpreter, now: Date): string {
    const target = path.join(path.dirname(file), `collector.${SCRIPT_EXTENSION[interpreter]}`);
    if (path.resolve(target) === path.resolve(file) || !fs.existsSync(file)) return file;
    if (fs.existsSync(target)) fs.renameSync(target, `${target}.old-${stamp(now)}`);
    fs.renameSync(file, target);
    return target;
  }

  manifest(id: string, interpreter: CollectorInterpreter): ManifestFile | null {
    const name = MANIFEST[interpreter];
    if (!name) return null;
    const p = path.join(this.folder(id), name);
    let bytes: Buffer | null = null;
    try {
      bytes = fs.readFileSync(p);
    } catch {
      bytes = null;
    }
    return { name, path: p, bytes };
  }

  writeManifest(id: string, interpreter: CollectorInterpreter, text: string | null): void {
    const m = this.manifest(id, interpreter);
    if (!m) throw new Error('A zsh script has no package manifest.');
    if (text === null) {
      fs.rmSync(m.path, { force: true });
      return;
    }
    fs.mkdirSync(path.dirname(m.path), { recursive: true, mode: 0o700 });
    writeFileAtomic(m.path, text, FILE_MODE);
  }

  /** Remove installed packages (node_modules / .venv) from the collector's folder. */
  removePackages(id: string, name: CollectorManifestName): void {
    const folder = this.folder(id);
    const target = path.join(folder, PACKAGES_DIR[name]);
    if (!isInside(target, folder)) return;
    fs.rmSync(target, { recursive: true, force: true });
  }

  /** Remove a deleted collector's folder (Distill's trash, activity/trash.ts, keeps the copy). */
  removeFolder(id: string): void {
    fs.rmSync(this.folder(id), { recursive: true, force: true });
  }

  /**
   * Restore: put a trash copy of a script folder back as this collector's folder. A folder already
   * there is kept as `<folder>.old-<time>`, never overwritten.
   */
  restoreFolder(id: string, from: string, now: Date): string {
    const target = this.folder(id);
    fs.mkdirSync(this.scriptsDir, { recursive: true, mode: 0o700 });
    if (fs.existsSync(target)) fs.renameSync(target, `${target}.old-${stamp(now)}`);
    fs.cpSync(from, target, { recursive: true, verbatimSymlinks: true });
    return target;
  }

  /** A folder an earlier v6 build moved to <state>/collectors/trash on delete (the newest for this id), for restores. */
  legacyTrashFolder(id: string): string | undefined {
    try {
      const prefix = `${safeID(id)}-`;
      const names = fs.readdirSync(this.trashDir).filter((n) => n.startsWith(prefix)).sort();
      const last = names.at(-1);
      return last ? path.join(this.trashDir, last) : undefined;
    } catch {
      return undefined;
    }
  }

  /** Legacy (an earlier v6 build's own trash): remove its folders after 30 days. New deletes use Distill's trash. */
  pruneTrash(now: Date): string[] {
    const removed: string[] = [];
    let names: string[] = [];
    try {
      names = fs.readdirSync(this.trashDir);
    } catch {
      return removed;
    }
    const cutoff = now.getTime() - TRASH_KEEP_DAYS * DAY_MS;
    for (const name of names) {
      const p = path.join(this.trashDir, name);
      if (!isInside(p, this.trashDir)) continue;
      try {
        const st = fs.statSync(p);
        if (st.isDirectory() && st.mtimeMs < cutoff) {
          fs.rmSync(p, { recursive: true, force: true });
          removed.push(p);
        }
      } catch {
        // gone already
      }
    }
    return removed;
  }
}

/** 20261004-093000 in UTC: sortable, safe in file names. */
export function stamp(d: Date): string {
  return isoDate(d).replace(/[-:]/g, '').replace('T', '-').replace('Z', '');
}

/**
 * Keep a copy of collectors.json before a migration rewrites it, next to it (`collectors.json.<tag>-<time>`),
 * unless an identical copy is already there. Returns the copy's path.
 */
export function backupFile(file: string, tag: string, now: Date): string | undefined {
  let bytes: Buffer;
  try {
    bytes = fs.readFileSync(file);
  } catch {
    return undefined;
  }
  const dir = path.dirname(file);
  const base = path.basename(file);
  try {
    for (const name of fs.readdirSync(dir)) {
      if (name.startsWith(`${base}.${tag}-`) && fs.readFileSync(path.join(dir, name)).equals(bytes)) return path.join(dir, name);
    }
  } catch {
    // write a new one
  }
  const dest = path.join(dir, `${base}.${tag}-${stamp(now)}`);
  writeFileAtomic(dest, bytes, FILE_MODE);
  return dest;
}
