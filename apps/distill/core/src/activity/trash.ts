import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { ActivitySource, TrashItem, TrashItemKind } from '../contracts.js';

/**
 * Distill's trash: a copy of each Ask chat or collector you delete, kept so it can be restored.
 * One file per item, `<state>/trash/<trash-id>.json` (dir 0700, files 0600), holding the item's
 * metadata and the full record (a collector's inline script included). Listing never returns
 * the payload. Retention: KEEP_DAYS, at most KEEP_ITEMS items and MAX_BYTES in all (oldest go first).
 */

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

  /** Keep a copy. Throws when it can't be written: the caller then refuses the delete. */
  put(input: { kind: TrashItemKind; objectID: string; name: string; source: ActivitySource; details: TrashItem['details']; payload: unknown }): TrashItem {
    const at = this.now();
    const id = `trash-${String(at.getTime()).padStart(13, '0')}-${randomBytes(4).toString('hex')}`;
    const body = JSON.stringify(input.payload);
    const item: TrashItem = {
      id,
      kind: input.kind,
      objectID: input.objectID,
      name: input.name,
      deletedAt: at.toISOString(),
      expiresAt: new Date(at.getTime() + this.keepDays * 86_400_000).toISOString(),
      source: input.source,
      sizeBytes: Buffer.byteLength(body),
      details: input.details,
    };
    fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(this.dir, 0o700);
    const target = this.file(id);
    const temp = `${target}.${process.pid}.tmp`;
    fs.writeFileSync(temp, JSON.stringify({ item, payload: input.payload } satisfies TrashFile) + '\n', { mode: 0o600 });
    fs.renameSync(temp, target);
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

  get(id: string): { item: TrashItem; payload: unknown } | undefined {
    return this.read(id);
  }

  remove(id: string): void {
    fs.rmSync(this.file(id), { force: true });
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

  /** Drop expired items, then the oldest beyond the count and size caps. */
  prune(): void {
    const nowMs = this.now().getTime();
    const ids = this.ids().sort().reverse(); // newest first
    let total = 0;
    ids.forEach((id, index) => {
      const file = path.join(this.dir, `${id}.json`);
      let size = 0;
      try {
        size = fs.statSync(file).size;
      } catch {
        return;
      }
      const deletedMs = Number(id.slice(6, 19));
      const expired = nowMs - deletedMs > this.keepDays * 86_400_000;
      total += size;
      if (expired || (index > 0 && (index >= this.keepItems || total > this.maxBytes))) fs.rmSync(file, { force: true });
    });
  }
}
