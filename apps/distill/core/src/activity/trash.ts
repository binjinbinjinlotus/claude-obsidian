import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { ActivitySource, TrashItem, TrashItemKind } from '../contracts.js';

/**
 * Distill's trash: a copy of each Ask chat or collector you delete, kept so it can be restored.
 * One file per item, `<state>/trash/<trash-id>.json` (dir 0700, files 0600), holding the item's
 * metadata and the full record. A script collector's folder (its script file and package manifest,
 * without node_modules/.venv) is copied next to it as `<trash-id>.files/` (v6: one trash for both).
 * Listing never returns the payload. Retention: KEEP_DAYS, at most KEEP_ITEMS items and MAX_BYTES in
 * all (oldest go first); a folder goes with its item.
 */

/** Installed packages are never kept: they can be large and are reinstalled when the script is allowed again. */
const SKIP_IN_FOLDER = new Set(['node_modules', '.venv']);

function folderBytes(dir: string): number {
  let total = 0;
  let entries: fs.Dirent[] = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return 0;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    try {
      if (e.isDirectory()) total += folderBytes(p);
      else total += fs.lstatSync(p).size;
    } catch {
      // gone
    }
  }
  return total;
}

export const TRASH_DEFAULTS = { keepDays: 30, keepItems: 200, maxBytes: 50 * 1024 * 1024 };

export interface TrashOptions {
  dir: string;
  now?: () => Date;
  keepDays?: number;
  keepItems?: number;
  maxBytes?: number;
}

interface TrashFile {
  item: TrashItem;
  payload: unknown;
}

const ID = /^trash-[0-9]{13}-[0-9a-f]{8}$/;

export class Trash {
  readonly dir: string;
  private readonly now: () => Date;
  private readonly keepDays: number;
  private readonly keepItems: number;
  private readonly maxBytes: number;

  constructor(opts: TrashOptions) {
    this.dir = opts.dir;
    this.now = opts.now ?? (() => new Date());
    this.keepDays = opts.keepDays ?? TRASH_DEFAULTS.keepDays;
    this.keepItems = opts.keepItems ?? TRASH_DEFAULTS.keepItems;
    this.maxBytes = opts.maxBytes ?? TRASH_DEFAULTS.maxBytes;
  }

  private file(id: string): string {
    if (!ID.test(id)) throw Object.assign(new Error(`No trash item ${id}.`), { code: 'not_found' });
    return path.join(this.dir, `${id}.json`);
  }

  /** `<trash-id>.files`: the copied folder of an item, when it has one. */
  private filesDir(id: string): string {
    return this.file(id).replace(/\.json$/, '.files');
  }

  /**
   * Keep a copy (and a copy of `folder`, without installed packages). Throws when it can't be written:
   * the caller then refuses the delete, and nothing half-written stays behind.
   */
  put(input: { kind: TrashItemKind; objectID: string; name: string; source: ActivitySource; details: TrashItem['details']; payload: unknown; folder?: string; keepHours?: number }): TrashItem {
    const at = this.now();
    const id = `trash-${String(at.getTime()).padStart(13, '0')}-${randomBytes(4).toString('hex')}`;
    const body = JSON.stringify(input.payload);
    fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(this.dir, 0o700);
    let filesBytes = 0;
    const filesDir = this.filesDir(id);
    if (input.folder && fs.existsSync(input.folder)) {
      const temp = `${filesDir}.${process.pid}.tmp`;
      try {
        const root = path.resolve(input.folder);
        fs.cpSync(root, temp, {
          recursive: true,
          verbatimSymlinks: true,
          filter: (src) => !(path.dirname(path.resolve(src)) === root && SKIP_IN_FOLDER.has(path.basename(src))),
        });
        fs.chmodSync(temp, 0o700);
        fs.renameSync(temp, filesDir);
      } catch (err) {
        fs.rmSync(temp, { recursive: true, force: true });
        throw err;
      }
      filesBytes = folderBytes(filesDir);
    }
    const item: TrashItem = {
      id,
      kind: input.kind,
      objectID: input.objectID,
      name: input.name,
      deletedAt: at.toISOString(),
      // keepHours: a shorter stay (chats deleted while Keep history is off: 24 hours).
      expiresAt: new Date(at.getTime() + (input.keepHours !== undefined ? Math.min(input.keepHours * 3_600_000, this.keepDays * 86_400_000) : this.keepDays * 86_400_000)).toISOString(),
      source: input.source,
      sizeBytes: Buffer.byteLength(body) + filesBytes,
      details: { ...input.details, ...(fs.existsSync(filesDir) ? { scriptFolder: true } : {}) },
    };
    const target = this.file(id);
    const temp = `${target}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(temp, JSON.stringify({ item, payload: input.payload } satisfies TrashFile) + '\n', { mode: 0o600 });
      fs.renameSync(temp, target);
    } catch (err) {
      fs.rmSync(temp, { force: true });
      fs.rmSync(filesDir, { recursive: true, force: true });
      throw err;
    }
    this.prune();
    return item;
  }

  private read(id: string): TrashFile | undefined {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.file(id), 'utf8')) as TrashFile;
      return parsed?.item?.id === id ? parsed : undefined;
    } catch {
      return undefined;
    }
  }

  /** Newest first, without payloads. */
  list(): TrashItem[] {
    this.prune();
    return this.ids()
      .map((id) => this.read(id)?.item)
      .filter((i): i is TrashItem => !!i)
      .sort((a, b) => b.id.localeCompare(a.id));
  }

  /** The item, its payload, and its copied folder when it has one. */
  get(id: string): { item: TrashItem; payload: unknown; files?: string } | undefined {
    const kept = this.read(id);
    if (!kept) return undefined;
    const files = this.filesDir(id);
    return fs.existsSync(files) ? { ...kept, files } : kept;
  }

  remove(id: string): void {
    fs.rmSync(this.file(id), { force: true });
    fs.rmSync(this.filesDir(id), { recursive: true, force: true });
  }

  private ids(): string[] {
    try {
      return fs
        .readdirSync(this.dir)
        .filter((n) => n.endsWith('.json'))
        .map((n) => n.slice(0, -5))
        .filter((id) => ID.test(id));
    } catch {
      return [];
    }
  }

  /** Drop expired items, then the oldest beyond the count and size caps. A folder goes with its item; one without an item goes too. */
  prune(): void {
    const nowMs = this.now().getTime();
    const ids = this.ids().sort().reverse(); // newest first
    let total = 0;
    ids.forEach((id, index) => {
      const file = path.join(this.dir, `${id}.json`);
      const files = path.join(this.dir, `${id}.files`);
      let size = 0;
      try {
        size = fs.statSync(file).size + (fs.existsSync(files) ? folderBytes(files) : 0);
      } catch {
        return;
      }
      const deletedMs = Number(id.slice(6, 19));
      // Its own expiry when it has a shorter one; never longer than the trash's days.
      const own = Date.parse(this.read(id)?.item.expiresAt ?? '');
      const expired = nowMs - deletedMs > this.keepDays * 86_400_000 || (Number.isFinite(own) && nowMs >= own);
      total += size;
      if (expired || (index > 0 && (index >= this.keepItems || total > this.maxBytes))) {
        fs.rmSync(file, { force: true });
        fs.rmSync(files, { recursive: true, force: true });
      }
    });
    try {
      const kept = new Set(this.ids());
      for (const name of fs.readdirSync(this.dir)) {
        const m = /^(trash-[0-9]{13}-[0-9a-f]{8})\.files$/.exec(name);
        // An orphan folder older than a minute (a put that crashed between the two writes).
        if (m && !kept.has(m[1]!) && nowMs - Number(m[1]!.slice(6, 19)) > 60_000) fs.rmSync(path.join(this.dir, name), { recursive: true, force: true });
      }
    } catch {
      // no trash yet
    }
  }
}
