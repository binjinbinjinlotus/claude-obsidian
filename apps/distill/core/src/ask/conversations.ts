import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { ModelSelection } from '../contracts.js';

/** Persisted as <stateDir>/<conversationID>.json. */
export interface ConversationRecord {
  conversationID: string;
  /** Runner session id; null until a turn has actually run (e.g. a zero-match first question). */
  sessionID: string | null;
  selection: ModelSelection;
  /** Real path of the vault the session runs in (sessions are keyed by cwd). */
  vaultPath: string;
  /** cwd the session runs in (the Ask workspace, not the vault). */
  workingDirectory?: string;
  createdAt: string;
  updatedAt: string;
  turns: number;
  costUSD: number;
}

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;

export function isValidConversationID(id: string): boolean {
  return ID_PATTERN.test(id);
}

export class ConversationStore {
  constructor(private readonly dir: string) {}

  private file(id: string): string {
    if (!isValidConversationID(id)) throw new Error(`ask: invalid conversation id "${id}"`);
    return path.join(this.dir, `${id}.json`);
  }

  newID(): string {
    return randomUUID();
  }

  async load(id: string): Promise<ConversationRecord | undefined> {
    let text: string;
    try {
      text = await fs.readFile(this.file(id), 'utf8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
      throw error;
    }
    const record = JSON.parse(text) as ConversationRecord;
    if (record.conversationID !== id || typeof record.vaultPath !== 'string' || !record.selection?.runnerID) {
      throw new Error(`ask: conversation ${id} state is corrupt`);
    }
    return record;
  }

  /** Atomic write: temp file then rename. */
  async save(record: ConversationRecord): Promise<void> {
    const target = this.file(record.conversationID);
    await fs.mkdir(this.dir, { recursive: true });
    const temp = `${target}.${process.pid}.${randomUUID()}.tmp`;
    await fs.writeFile(temp, JSON.stringify(record, null, 2) + '\n', { mode: 0o600 });
    await fs.rename(temp, target);
  }
}

/** Serializes work per key so two follow-ups on one conversation never race the same session. */
export class KeyedMutex {
  private readonly tails = new Map<string, Promise<unknown>>();

  async run<T>(key: string, work: () => Promise<T>): Promise<T> {
    const previous = this.tails.get(key) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(work);
    this.tails.set(key, next);
    try {
      return await next;
    } finally {
      if (this.tails.get(key) === next) this.tails.delete(key);
    }
  }
}
