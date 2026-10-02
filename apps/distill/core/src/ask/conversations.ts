import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { CoreError, type AskConversation, type AskConversationSummary, type AskTurn, type ModelSelection } from '../contracts.js';

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
  /** Filter scope of the session ('' = all notes). A session never crosses scopes. */
  scope?: string;
  createdAt: string;
  /** Last message; retention counts from here. Pinning does not change it. */
  updatedAt: string;
  /** Runner turns that actually ran (legacy v1 field, kept for compatibility). */
  turns: number;
  costUSD: number;
  // ── v2 (absent in v1 records) ──
  /** First question, trimmed to 80 characters. */
  title?: string;
  pinned?: boolean;
  /** Every question and answer, oldest first (v1 records have none). */
  history?: AskTurn[];
}

export const TITLE_MAX = 80;
const LEGACY_TITLE = 'Earlier conversation';

export function titleFrom(question: string): string {
  const flat = question.replace(/\s+/g, ' ').trim();
  return flat.length <= TITLE_MAX ? flat : `${flat.slice(0, TITLE_MAX - 1).trimEnd()}…`;
}

export function summaryOf(record: ConversationRecord): AskConversationSummary {
  return {
    id: record.conversationID,
    title: record.title || LEGACY_TITLE,
    vaultPath: record.vaultPath,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    pinned: record.pinned === true,
    turnCount: record.history ? record.history.length : record.turns,
  };
}

export function conversationOf(record: ConversationRecord): AskConversation {
  return { ...summaryOf(record), turns: record.history ?? [] };
}

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;

export function isValidConversationID(id: string): boolean {
  return ID_PATTERN.test(id);
}

export class ConversationStore {
  constructor(private readonly dir: string) {}

  private file(id: string): string {
    if (!isValidConversationID(id)) throw new CoreError('invalid_request', `ask: invalid conversation id "${id}"`);
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
    if (record.history !== undefined && !Array.isArray(record.history)) delete record.history;
    return record;
  }

  /** Ids of every stored conversation (files named <valid id>.json). */
  async ids(): Promise<string[]> {
    let names: string[];
    try {
      names = await fs.readdir(this.dir);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
      throw error;
    }
    return names
      .filter((name) => name.endsWith('.json'))
      .map((name) => name.slice(0, -'.json'.length))
      .filter(isValidConversationID);
  }

  /** true when a file was removed. */
  async delete(id: string): Promise<boolean> {
    try {
      await fs.unlink(this.file(id));
      return true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
      throw error;
    }
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

  /** true while work for the key is running or queued. */
  busy(key: string): boolean {
    return this.tails.has(key);
  }

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
