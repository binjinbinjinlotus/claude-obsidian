/**
 * Collector state, under the user-data rules (docs/specs/user-data.md):
 *
 * - <state>/collectors.json  {version, collectors: [...], ticks: {id: iso}, ...unknown}
 * - <state>/collectors/runs/<collector-id>.jsonl  run history, oldest first
 * - <state>/collectors/ledger-<vault-id>.jsonl    Folder ledger (sha256 dedupe), append-only
 *
 * Decoding is lenient; unknown keys survive a save; an entry this build can't
 * decode is written back untouched; a file that can't be read is set aside
 * (preserveUnreadable) before anything replaces it.
 */
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type {
  CollectedFile,
  Collector,
  CollectorInstall,
  CollectorManifestName,
  CollectorErrorCode,
  CollectorInterpreter,
  CollectorRun,
  CollectorRunFile,
  CollectorRunResult,
  CollectorTrigger,
  SchedulePreset,
  ScriptSource,
} from '../contracts.js';
import { bool, encodeJSON, isObject, normalizeDate, num, preserveUnreadable, readJSON, str, strArray, writeFileAtomic, type JSONObject } from '../store/json.js';

export const INTERPRETERS: CollectorInterpreter[] = ['zsh', 'python3', 'node', 'typescript'];
export const PRESETS: SchedulePreset[] = ['every15', 'hourly', 'daily', 'weekdays', 'custom'];
export const RUN_RESULTS: CollectorRunResult[] = ['queued', 'running', 'success', 'nothing', 'failed', 'timedout', 'skipped', 'notTrusted', 'stopped'];
const TRIGGERS: CollectorTrigger[] = ['schedule', 'now', 'catchup'];
const ERROR_CODES: CollectorErrorCode[] = [
  'sourceMissing', 'noPermission', 'queueMissing', 'vaultMissing', 'scriptMissing', 'interpreterMissing',
  'scriptFailed', 'notAllowed', 'scriptChanged', 'interrupted', 'installFailed', 'other',
];
const FILE_OUTCOMES: CollectorRunFile['outcome'][] = ['copied', 'moved', 'skipped', 'waiting', 'error'];

export const DEFAULT_TIMEOUT_SECONDS = 300;
export const MAX_TIMEOUT_SECONDS = 3600;
export const DEFAULT_CRON = '0 * * * *';

export function newCollectorID(): string {
  return `col-${randomUUID().toLowerCase()}`;
}

export function newInstallID(): string {
  return `ins-${randomUUID().toLowerCase()}`;
}

export function newRunID(): string {
  return `run-${randomUUID().toLowerCase()}`;
}

/** Copy without undefined (JSON drops it anyway), so stored objects never alias live ones. */
function plain<T>(v: T): T {
  return JSON.parse(JSON.stringify(v)) as T;
}

function nullableStr(v: unknown): string | null | undefined {
  return v === null ? null : str(v);
}

function decodeScriptSource(v: unknown): ScriptSource | undefined {
  if (!isObject(v)) return undefined;
  if (typeof v.inline === 'string') return { inline: v.inline };
  if (typeof v.file === 'string') return v.managed === true ? { file: v.file, managed: true } : { file: v.file };
  return undefined;
}

const INSTALL_RESULTS: CollectorInstall['result'][] = ['running', 'success', 'failed', 'timedout', 'stopped'];

/** v6: a package install record (installs/<id>.json), decoded leniently. */
export function decodeInstall(v: unknown, now = new Date()): CollectorInstall | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const collectorId = str(v.collectorId);
  const result = str(v.result) as CollectorInstall['result'] | undefined;
  const manifestName = str(v.manifestName) as CollectorManifestName | undefined;
  if (!id || !collectorId || !result || !INSTALL_RESULTS.includes(result)) return undefined;
  const out: CollectorInstall = {
    id,
    collectorId,
    trigger: v.trigger === 'beforeRun' ? 'beforeRun' : 'manual',
    startedAt: normalizeDate(v.startedAt, now),
    result,
    command: str(v.command) ?? '',
    manifestName: manifestName === 'requirements.txt' ? 'requirements.txt' : 'package.json',
    manifestSha256: str(v.manifestSha256) ?? '',
  };
  if (v.endedAt !== undefined) out.endedAt = normalizeDate(v.endedAt, now);
  const duration = num(v.durationMs);
  if (duration !== undefined) out.durationMs = duration;
  if (v.clean === true) out.clean = true;
  if (v.exitCode === null || typeof v.exitCode === 'number') out.exitCode = v.exitCode as number | null;
  const signal = nullableStr(v.signal);
  if (signal !== undefined) out.signal = signal;
  if (isObject(v.error)) {
    const code = str(v.error.code) as CollectorErrorCode | undefined;
    out.error = { code: code && ERROR_CODES.includes(code) ? code : 'other', message: str(v.error.message) ?? '' };
  }
  const tail = str(v.outputTail);
  if (tail !== undefined) out.outputTail = tail;
  return out;
}

export function clampTimeout(v: unknown): number {
  const n = num(v);
  if (n === undefined) return DEFAULT_TIMEOUT_SECONDS;
  return Math.min(MAX_TIMEOUT_SECONDS, Math.max(1, Math.round(n)));
}

/** Undefined when the entry lacks what a collector needs (it is then kept as it was). */
export function decodeCollector(v: unknown, now = new Date()): Collector | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const kind = str(v.kind);
  const vaultPath = str(v.vaultPath);
  if (!id || !vaultPath || (kind !== 'folder' && kind !== 'script')) return undefined;
  const createdAt = normalizeDate(v.createdAt, now);
  const sched = isObject(v.schedule) ? v.schedule : {};
  const preset = str(sched.preset) as SchedulePreset | undefined;
  const c: Collector = {
    id,
    kind,
    name: str(v.name) ?? (kind === 'folder' ? 'Distill Inbox' : 'Script'),
    vaultPath,
    enabled: bool(v.enabled) ?? false,
    schedule: { cron: str(sched.cron) ?? DEFAULT_CRON, ...(preset && PRESETS.includes(preset) ? { preset } : {}) },
    createdAt,
    updatedAt: normalizeDate(v.updatedAt, new Date(createdAt)),
  };
  if (kind === 'folder') {
    const f = isObject(v.folder) ? v.folder : {};
    const source = str(f.source);
    if (!source) return undefined;
    c.folder = { source, afterCollect: f.afterCollect === 'move' ? 'move' : 'copy' };
    // v5: absent (a collector saved before subfolders existed) stays absent and reads as off.
    if (typeof f.includeSubfolders === 'boolean') c.folder.includeSubfolders = f.includeSubfolders;
  } else {
    const s = isObject(v.script) ? v.script : {};
    const source = decodeScriptSource(s.source);
    const interpreter = str(s.interpreter) as CollectorInterpreter | undefined;
    if (!source || !interpreter || !INTERPRETERS.includes(interpreter)) return undefined;
    c.script = { source, interpreter, timeoutSeconds: clampTimeout(s.timeoutSeconds) };
    const allowed = nullableStr(s.allowedSha256);
    const allowedAt = nullableStr(s.allowedAt);
    if (allowed !== undefined) c.script.allowedSha256 = allowed;
    if (allowedAt !== undefined) c.script.allowedAt = allowedAt;
    // v6
    if (s.allowedFiles === null) c.script.allowedFiles = null;
    else if (isObject(s.allowedFiles) && typeof s.allowedFiles.script === 'string') {
      c.script.allowedFiles = { script: s.allowedFiles.script, manifest: str(s.allowedFiles.manifest) ?? null };
    }
  }
  return c;
}

const COLLECTOR_KEYS = ['id', 'kind', 'name', 'vaultPath', 'enabled', 'schedule', 'folder', 'script', 'createdAt', 'updatedAt', 'status'];

export function encodeCollector(c: Collector, raw: JSONObject = {}): JSONObject {
  const out: JSONObject = { ...raw };
  for (const k of COLLECTOR_KEYS) delete out[k];
  const { status: _status, ...rest } = c;
  const known = plain(rest) as unknown as JSONObject;
  // Unknown keys inside folder/script survive too.
  for (const nested of ['folder', 'script', 'schedule'] as const) {
    if (isObject(raw[nested]) && isObject(known[nested])) known[nested] = { ...raw[nested], ...known[nested] };
  }
  return { ...out, ...known };
}

export class CollectorStore {
  private raw = new Map<string, JSONObject>();
  private undecodable: unknown[] = [];
  private top: JSONObject = {};
  /** Last scheduled tick handled, by collector id (scheduler state; catch-up runs once from here). */
  ticks = new Map<string, string>();
  preserved?: string;

  constructor(readonly file: string) {}

  load(now = new Date()): Collector[] {
    this.raw.clear();
    this.undecodable = [];
    this.top = {};
    this.ticks.clear();
    if (!fs.existsSync(this.file)) return [];
    const parsed = readJSON(this.file);
    if (!isObject(parsed) || (parsed.collectors !== undefined && !Array.isArray(parsed.collectors))) {
      this.preserved = preserveUnreadable(this.file, now) ?? this.preserved;
      return [];
    }
    this.top = { ...parsed };
    if (isObject(parsed.ticks)) {
      for (const [id, t] of Object.entries(parsed.ticks)) if (typeof t === 'string') this.ticks.set(id, t);
    }
    const out: Collector[] = [];
    let dropped = false;
    for (const entry of (parsed.collectors as unknown[] | undefined) ?? []) {
      const c = decodeCollector(entry, now);
      if (c && !this.raw.has(c.id)) {
        out.push(c);
        this.raw.set(c.id, entry as JSONObject);
      } else {
        this.undecodable.push(entry);
        dropped = true;
      }
    }
    if (dropped) this.preserved = preserveUnreadable(this.file, now) ?? this.preserved;
    return out;
  }

  save(collectors: Collector[]): void {
    const encoded = collectors.map((c) => {
      const e = encodeCollector(c, this.raw.get(c.id) ?? {});
      this.raw.set(c.id, e);
      return e;
    });
    for (const id of [...this.raw.keys()]) if (!collectors.some((c) => c.id === id)) this.raw.delete(id);
    const ticks: JSONObject = {};
    for (const c of collectors) {
      const t = this.ticks.get(c.id);
      if (t) ticks[c.id] = t;
    }
    writeFileAtomic(this.file, encodeJSON({ ...this.top, version: 1, collectors: [...encoded, ...this.undecodable], ticks }));
  }
}

// ───────────── run history ─────────────

/** 30 days or the newest 200 runs per collector, whichever keeps more. */
export const RUN_KEEP_DAYS = 30;
export const RUN_KEEP_COUNT = 200;
const DAY_MS = 24 * 60 * 60 * 1000;

function counts(v: unknown): CollectorRun['counts'] {
  const o = isObject(v) ? v : {};
  const n = (k: string) => Math.max(0, Math.trunc(num(o[k]) ?? 0));
  return { copied: n('copied'), moved: n('moved'), skipped: n('skipped'), waiting: n('waiting'), errors: n('errors'), added: n('added') };
}

export function decodeRun(v: unknown, now = new Date()): CollectorRun | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const collectorId = str(v.collectorId);
  const result = str(v.result) as CollectorRunResult | undefined;
  if (!id || !collectorId || !result || !RUN_RESULTS.includes(result)) return undefined;
  const trigger = str(v.trigger) as CollectorTrigger | undefined;
  const run: CollectorRun = {
    id,
    collectorId,
    kind: v.kind === 'script' ? 'script' : 'folder',
    vaultPath: str(v.vaultPath) ?? '',
    trigger: trigger && TRIGGERS.includes(trigger) ? trigger : 'schedule',
    startedAt: normalizeDate(v.startedAt, now),
    result,
    counts: counts(v.counts),
    filesAdded: strArray(v.filesAdded) ?? [],
  };
  if (v.endedAt !== undefined) run.endedAt = normalizeDate(v.endedAt, now);
  const duration = num(v.durationMs);
  if (duration !== undefined) run.durationMs = duration;
  if (v.waiting === 'slot' || v.waiting === 'batch') run.waiting = v.waiting;
  const skipReason = str(v.skipReason);
  if (skipReason) run.skipReason = skipReason;
  if (isObject(v.error)) {
    const code = str(v.error.code) as CollectorErrorCode | undefined;
    run.error = { code: code && ERROR_CODES.includes(code) ? code : 'other', message: str(v.error.message) ?? '' };
  }
  if (Array.isArray(v.files)) {
    run.files = v.files.flatMap((f): CollectorRunFile[] => {
      if (!isObject(f)) return [];
      const name = str(f.name);
      const outcome = str(f.outcome) as CollectorRunFile['outcome'] | undefined;
      if (!name || !outcome || !FILE_OUTCOMES.includes(outcome)) return [];
      const file: CollectorRunFile = { name, outcome };
      const reason = str(f.reason);
      const queueName = str(f.queueName);
      const size = num(f.size);
      if (reason) file.reason = reason;
      if (queueName) file.queueName = queueName;
      if (size !== undefined) file.size = size;
      // v5: folder items.
      if (f.kind === 'folder' || f.kind === 'file') file.kind = f.kind;
      const fileCount = num(f.fileCount);
      const newCount = num(f.newCount);
      if (fileCount !== undefined) file.fileCount = fileCount;
      if (newCount !== undefined) file.newCount = newCount;
      return [file];
    });
  }
  if (v.exitCode === null || typeof v.exitCode === 'number') run.exitCode = v.exitCode as number | null;
  const signal = nullableStr(v.signal);
  if (signal !== undefined) run.signal = signal;
  for (const k of ['sha256', 'stdoutTail', 'stderrTail', 'installId'] as const) {
    const x = str(v[k]);
    if (x !== undefined) run[k] = x;
  }
  return run;
}

/** Keep runs newer than 30 days, and always the newest 200. `runs` is oldest first. */
export function pruneRuns(runs: CollectorRun[], now: Date): CollectorRun[] {
  const cutoff = now.getTime() - RUN_KEEP_DAYS * DAY_MS;
  const keepFrom = Math.max(0, runs.length - RUN_KEEP_COUNT);
  return runs.filter((r, i) => i >= keepFrom || r.result === 'queued' || r.result === 'running' || new Date(r.startedAt).getTime() >= cutoff);
}

export class RunStore {
  private cache = new Map<string, { runs: CollectorRun[]; raw: Map<string, JSONObject>; undecodable: string[] }>();

  constructor(readonly dir: string) {}

  file(collectorId: string): string {
    return path.join(this.dir, `${collectorId.replace(/[^A-Za-z0-9_-]/g, '_')}.jsonl`);
  }

  private load(collectorId: string, now: Date) {
    const hit = this.cache.get(collectorId);
    if (hit) return hit;
    const entry = { runs: [] as CollectorRun[], raw: new Map<string, JSONObject>(), undecodable: [] as string[] };
    const file = this.file(collectorId);
    let text = '';
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch {
      text = '';
    }
    let dirty = false;
    for (const line of text.split('\n')) {
      if (line.trim() === '') continue;
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        parsed = undefined;
      }
      const run = decodeRun(parsed, now);
      if (run && !entry.raw.has(run.id)) {
        // A run left queued/running by a core that stopped never finishes: close it.
        if (run.result === 'queued' || run.result === 'running') {
          run.result = 'failed';
          run.error = { code: 'interrupted', message: 'Distill stopped during this run.' };
          delete run.waiting;
          dirty = true;
        }
        entry.runs.push(run);
        entry.raw.set(run.id, parsed as JSONObject);
      } else {
        entry.undecodable.push(line);
      }
    }
    if (entry.undecodable.length > 0) preserveUnreadable(file, now);
    this.cache.set(collectorId, entry);
    if (dirty) this.write(collectorId, now);
    return entry;
  }

  /** Newest first. */
  list(collectorId: string, now = new Date()): CollectorRun[] {
    return [...this.load(collectorId, now).runs].reverse();
  }

  latest(collectorId: string, now = new Date()): CollectorRun | undefined {
    return this.load(collectorId, now).runs.at(-1);
  }

  /** Insert or replace a run, prune, and write the file atomically. */
  put(run: CollectorRun, now = new Date()): void {
    const entry = this.load(run.collectorId, now);
    const i = entry.runs.findIndex((r) => r.id === run.id);
    if (i >= 0) entry.runs[i] = plain(run);
    else entry.runs.push(plain(run));
    entry.runs = pruneRuns(entry.runs, now);
    this.write(run.collectorId, now);
  }

  private write(collectorId: string, now: Date): void {
    const entry = this.load(collectorId, now);
    const keep = new Set(entry.runs.map((r) => r.id));
    for (const id of [...entry.raw.keys()]) if (!keep.has(id)) entry.raw.delete(id);
    const lines = [
      ...entry.undecodable,
      ...entry.runs.map((r) => {
        const raw = entry.raw.get(r.id) ?? {};
        const out = { ...raw, ...(plain(r) as unknown as JSONObject) };
        entry.raw.set(r.id, out);
        return JSON.stringify(out);
      }),
    ];
    writeFileAtomic(this.file(collectorId), lines.join('\n') + '\n');
  }

  /** Delete a collector's history (the collector was deleted). */
  remove(collectorId: string): void {
    this.cache.delete(collectorId);
    fs.rmSync(this.file(collectorId), { force: true });
  }
}

// ───────────── ledger ─────────────

export function vaultID(vaultPath: string): string {
  return createHash('sha256').update(path.resolve(vaultPath)).digest('hex').slice(0, 16);
}

/** Ledger entries carry the exact mtime in ms (for the path+size+mtime shortcut) next to the CollectedFile fields. */
export type LedgerEntry = CollectedFile & { mtimeMs: number };

export function decodeLedgerEntry(v: unknown, now = new Date()): LedgerEntry | undefined {
  if (!isObject(v)) return undefined;
  const sha256 = str(v.sha256);
  const sourcePath = str(v.sourcePath);
  if (!sha256 || !/^[0-9a-f]{64}$/.test(sha256) || !sourcePath) return undefined;
  const mtimeMs = num(v.mtimeMs) ?? new Date(str(v.mtime) ?? 0).getTime();
  return {
    sha256,
    sourcePath,
    name: str(v.name) ?? path.basename(sourcePath),
    size: num(v.size) ?? 0,
    mtime: normalizeDate(v.mtime, new Date(Number.isFinite(mtimeMs) ? mtimeMs : 0)),
    mtimeMs: Number.isFinite(mtimeMs) ? mtimeMs : 0,
    collectedAt: normalizeDate(v.collectedAt, now),
    collectorId: str(v.collectorId) ?? '',
    queueName: str(v.queueName) ?? '',
    outcome: v.outcome === 'moved' ? 'moved' : 'copied',
  };
}

export function publicEntry(e: LedgerEntry): CollectedFile {
  const { mtimeMs: _ms, ...rest } = e;
  return rest;
}

/** One vault's ledger. Appends on collect; Forget rewrites it atomically, keeping lines it can't read. */
export class Ledger {
  entries: LedgerEntry[] = [];
  private undecodable: string[] = [];
  private bySha = new Set<string>();

  constructor(readonly file: string) {}

  load(now = new Date()): this {
    this.entries = [];
    this.undecodable = [];
    let text = '';
    try {
      text = fs.readFileSync(this.file, 'utf8');
    } catch {
      text = '';
    }
    for (const line of text.split('\n')) {
      if (line.trim() === '') continue;
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        parsed = undefined;
      }
      const e = decodeLedgerEntry(parsed, now);
      if (e) this.entries.push(e);
      else this.undecodable.push(line);
    }
    if (this.undecodable.length > 0) preserveUnreadable(this.file, now);
    this.reindex();
    return this;
  }

  private reindex(): void {
    this.bySha = new Set(this.entries.map((e) => e.sha256));
  }

  hasSha(sha: string): boolean {
    return this.bySha.has(sha);
  }

  /** The shortcut that skips hashing: same path, size and mtime as an entry. */
  hasStat(sourcePath: string, size: number, mtimeMs: number): boolean {
    return this.entries.some((e) => e.sourcePath === sourcePath && e.size === size && e.mtimeMs === mtimeMs);
  }

  append(entry: LedgerEntry): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    let prefix = '';
    try {
      const st = fs.statSync(this.file);
      if (st.size > 0) {
        const fd = fs.openSync(this.file, 'r');
        try {
          const b = Buffer.alloc(1);
          fs.readSync(fd, b, 0, 1, st.size - 1);
          if (b[0] !== 0x0a) prefix = '\n'; // a torn last line stays on its own line
        } finally {
          fs.closeSync(fd);
        }
      }
    } catch {
      prefix = '';
    }
    fs.appendFileSync(this.file, `${prefix}${JSON.stringify(entry)}\n`, { mode: 0o600 });
    this.entries.push(entry);
    this.bySha.add(entry.sha256);
  }

  /** Remove matching entries; returns them. */
  remove(match: (e: LedgerEntry) => boolean): LedgerEntry[] {
    const removed = this.entries.filter(match);
    if (removed.length === 0) return [];
    this.entries = this.entries.filter((e) => !match(e));
    this.reindex();
    const lines = [...this.undecodable, ...this.entries.map((e) => JSON.stringify(e))];
    writeFileAtomic(this.file, lines.length ? lines.join('\n') + '\n' : '');
    return removed;
  }
}

export function ledgerFile(dir: string, vaultPath: string): string {
  return path.join(dir, `ledger-${vaultID(vaultPath)}.jsonl`);
}

