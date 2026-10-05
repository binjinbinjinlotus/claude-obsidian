/**
 * actions.json: { items: ActionItem[], processedJobs: string[], ...unknown }.
 * User data: decoded leniently, unknown keys (top level and per item) survive
 * a save, an item this build can't decode is written back untouched, and a
 * file that can't be parsed is set aside (preserveUnreadable) before the
 * first save replaces it.
 */
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import type { ActionError, ActionEvent, ActionItem, ActionRawRef, ActionSource, ActionStatus, ActionWikiRef } from '../contracts.js';
import { encodeJSON, isObject, isoDate, normalizeDate, preserveUnreadable, readJSON, str, strArray, writeFileAtomic, type JSONObject } from '../store/json.js';

export const ACTION_STATUSES: ActionStatus[] = ['pending', 'open', 'drafting', 'ready', 'creating', 'created', 'done', 'sent', 'removed', 'dismissed'];
/** In History (removed / done / sent). */
export const HISTORY_STATUSES: ActionStatus[] = ['removed', 'done', 'sent'];
/** Never dropped by the retention sweep. */
export const LIVE_STATUSES: ActionStatus[] = ['pending', 'open', 'drafting', 'ready', 'creating', 'created'];
const ERROR_CODES: ActionError['code'][] = ['not_connected', 'auth_expired', 'refused', 'unreachable', 'ai_failed', 'other'];
/** How many processed job ids are remembered (finding runs once per job). */
const MAX_PROCESSED_JOBS = 500;

export function newActionID(): string {
  return `act-${randomUUID().toLowerCase()}`;
}

function nullableStr(v: unknown): string | null | undefined {
  if (v === null) return null;
  return str(v);
}

/** v11: `[from, to]`, two positive integers with from ≤ to; anything else is dropped. */
function decodeLines(v: unknown): [number, number] | undefined {
  if (!Array.isArray(v) || v.length !== 2) return undefined;
  const [a, b] = v;
  if (typeof a !== 'number' || typeof b !== 'number' || !Number.isInteger(a) || !Number.isInteger(b) || a < 1 || b < a) return undefined;
  return [a, b];
}

/** v11 (action-context.md): the original's lines. Lenient: a missing path drops it; wrong-typed fields are dropped. */
export function decodeRawRef(v: unknown): ActionRawRef | undefined {
  if (!isObject(v)) return undefined;
  const p = str(v.path);
  if (!p) return undefined;
  const r: ActionRawRef = { path: p };
  for (const k of ['inboxPath', 'sha256', 'excerpt'] as const) {
    const x = nullableStr(v[k]);
    if (x !== undefined) r[k] = x;
  }
  const lines = decodeLines(v.lines);
  if (lines) r.lines = lines;
  if (v.match === 'quote' || v.match === 'closest' || v.match === 'none') r.match = v.match;
  return r;
}

export function decodeWikiRefs(v: unknown): ActionWikiRef[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const out: ActionWikiRef[] = [];
  for (const e of v) {
    if (!isObject(e)) continue;
    const p = str(e.path);
    if (!p) continue;
    const r: ActionWikiRef = { path: p };
    for (const k of ['title', 'heading', 'excerpt'] as const) {
      const x = nullableStr(e[k]);
      if (x !== undefined) r[k] = x;
    }
    out.push(r);
  }
  return out;
}

/** v11: raw, wiki and contextNote on a note or ask source. */
function decodeContext(v: JSONObject, s: Extract<ActionSource, { kind: 'note' | 'ask' }>): void {
  const raw = v.raw === null ? null : decodeRawRef(v.raw);
  if (raw !== undefined) s.raw = raw;
  const wiki = decodeWikiRefs(v.wiki);
  if (wiki) s.wiki = wiki;
  const note = nullableStr(v.contextNote);
  if (note !== undefined) s.contextNote = note;
}

function decodeSource(v: unknown): ActionSource {
  if (!isObject(v)) return { kind: 'manual' };
  if (v.kind === 'note') {
    const s: Extract<ActionSource, { kind: 'note' }> = { kind: 'note' };
    for (const k of ['jobID', 'notePath', 'pageTitle', 'quote'] as const) {
      const x = nullableStr(v[k]);
      if (x !== undefined) s[k] = x;
    }
    decodeContext(v, s);
    return s;
  }
  if (v.kind === 'ask') {
    const conversationID = str(v.conversationID);
    if (conversationID !== undefined) {
      const s: Extract<ActionSource, { kind: 'ask' }> = { kind: 'ask', conversationID };
      for (const k of ['question', 'quote'] as const) {
        const x = nullableStr(v[k]);
        if (x !== undefined) s[k] = x;
      }
      const cited = strArray(v.citedPaths);
      if (cited) s.citedPaths = cited;
      if (typeof v.turnIndex === 'number' && Number.isInteger(v.turnIndex) && v.turnIndex >= 0) s.turnIndex = v.turnIndex;
      if (v.gap === true) s.gap = true;
      decodeContext(v, s);
      return s;
    }
  }
  return v.by === 'agent' ? { kind: 'manual', by: 'agent' } : { kind: 'manual' };
}

function decodeEvent(v: unknown, fallback: Date): ActionEvent | undefined {
  if (!isObject(v)) return undefined;
  const event = str(v.event);
  if (!event) return undefined;
  const e: ActionEvent = { at: normalizeDate(v.at, fallback), event };
  const detail = nullableStr(v.detail);
  if (detail !== undefined) e.detail = detail;
  return e;
}

function decodeError(v: unknown): ActionError | undefined {
  if (!isObject(v)) return undefined;
  const code = str(v.code) as ActionError['code'] | undefined;
  const e: ActionError = { code: code && ERROR_CODES.includes(code) ? code : 'other', message: str(v.message) ?? '' };
  const field = nullableStr(v.field);
  if (field !== undefined) e.field = field;
  return e;
}

export function decodeAction(v: unknown, now = new Date()): ActionItem | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const title = str(v.title);
  if (!id || title === undefined) return undefined;
  const status = str(v.status) as ActionStatus | undefined;
  const createdAt = normalizeDate(v.createdAt, now);
  const fields: Record<string, string | null> = {};
  if (isObject(v.fields)) {
    for (const [k, x] of Object.entries(v.fields)) if (typeof x === 'string' || x === null) fields[k] = x;
  }
  const item: ActionItem = {
    id,
    type: str(v.type) ?? 'todo',
    status: status && ACTION_STATUSES.includes(status) ? status : 'open',
    title,
    fields,
    source: decodeSource(v.source),
    createdAt,
    updatedAt: normalizeDate(v.updatedAt, new Date(createdAt)),
    events: Array.isArray(v.events) ? v.events.map((e) => decodeEvent(e, now)).filter((e): e is ActionEvent => !!e) : [],
  };
  for (const k of ['body', 'why', 'vaultPath', 'draftModel', 'previousBody', 'fromActionID'] as const) {
    const x = nullableStr(v[k]);
    if (x !== undefined) item[k] = x;
  }
  const labels = strArray(v.labels);
  if (labels) item.labels = labels;
  if (isObject(v.external)) {
    const ext: NonNullable<ActionItem['external']> = {};
    for (const k of ['key', 'url', 'status', 'checkedAt'] as const) {
      const x = nullableStr(v.external[k]);
      if (x !== undefined) ext[k] = x;
    }
    item.external = ext;
  }
  const error = decodeError(v.error);
  if (error) item.error = error;
  return item;
}

/** Every `source` key this build reads (v11 adds raw, wiki, contextNote). */
const SOURCE_KEYS = ['kind', 'jobID', 'notePath', 'pageTitle', 'quote', 'conversationID', 'question', 'citedPaths', 'turnIndex', 'gap', 'by', 'raw', 'wiki', 'contextNote'];

const ITEM_KEYS = [
  'id', 'type', 'status', 'title', 'body', 'fields', 'why', 'source', 'vaultPath', 'labels', 'createdAt', 'updatedAt',
  'draftModel', 'previousBody', 'external', 'error', 'fromActionID', 'events',
];

/** Strip undefined (JSON drops it anyway) and copy, so stored objects never alias live ones. */
function plain<T>(v: T): T {
  return JSON.parse(JSON.stringify(v)) as T;
}

export function encodeAction(item: ActionItem, raw: JSONObject = {}): JSONObject {
  const out: JSONObject = { ...raw };
  for (const k of ITEM_KEYS) delete out[k];
  const known = plain(item) as unknown as JSONObject;
  for (const [k, v] of Object.entries(known)) if (v !== null || k === 'body') out[k] = v;
  // v11: keys inside `source` this build doesn't know survive a save (same kind only).
  const rawSource = raw.source;
  if (isObject(rawSource) && isObject(out.source) && rawSource.kind === out.source.kind) {
    const known = new Set(SOURCE_KEYS);
    const extra = Object.fromEntries(Object.entries(rawSource).filter(([k]) => !known.has(k)));
    out.source = { ...extra, ...out.source };
  }
  // Null optionals are omitted (Swift-friendly), except inside fields (null = cleared).
  return out;
}

export class ActionStore {
  private raw = new Map<string, JSONObject>();
  /** Entries this build couldn't decode: written back as they were. */
  private undecodable: unknown[] = [];
  private top: JSONObject = {};
  processedJobs: string[] = [];
  /** Path of the copy kept by the last load, when actions.json couldn't be read. */
  preserved?: string;

  constructor(readonly file: string) {}

  load(now = new Date()): ActionItem[] {
    this.raw.clear();
    this.undecodable = [];
    this.top = {};
    this.processedJobs = [];
    if (!fs.existsSync(this.file)) return [];
    const parsed = readJSON(this.file);
    if (!isObject(parsed) || (parsed.items !== undefined && !Array.isArray(parsed.items))) {
      this.preserved = preserveUnreadable(this.file, now) ?? this.preserved;
      return [];
    }
    this.top = { ...parsed };
    this.processedJobs = strArray(parsed.processedJobs) ?? [];
    const items: ActionItem[] = [];
    let dropped = false;
    for (const entry of (parsed.items as unknown[] | undefined) ?? []) {
      const item = decodeAction(entry, now);
      if (item && !this.raw.has(item.id)) {
        items.push(item);
        this.raw.set(item.id, entry as JSONObject);
      } else {
        this.undecodable.push(entry);
        dropped = true;
      }
    }
    if (dropped) this.preserved = preserveUnreadable(this.file, now) ?? this.preserved;
    return items;
  }

  save(items: ActionItem[]): void {
    const encoded = items.map((i) => {
      const e = encodeAction(i, this.raw.get(i.id) ?? {});
      this.raw.set(i.id, e);
      return e;
    });
    for (const id of [...this.raw.keys()]) if (!items.some((i) => i.id === id)) this.raw.delete(id);
    const out: JSONObject = { ...this.top, version: 1, items: [...encoded, ...this.undecodable], processedJobs: this.processedJobs.slice(-MAX_PROCESSED_JOBS) };
    writeFileAtomic(this.file, encodeJSON(out));
  }
}

/** When the item last changed status (its last event, else updatedAt): the History clock. */
export function leftAt(item: ActionItem): Date {
  const last = item.events.at(-1)?.at ?? item.updatedAt;
  const d = new Date(last);
  return Number.isNaN(d.getTime()) ? new Date(item.updatedAt) : d;
}

export function event(now: Date, name: string, detail?: string | null): ActionEvent {
  return detail != null ? { at: isoDate(now), event: name, detail } : { at: isoDate(now), event: name };
}
