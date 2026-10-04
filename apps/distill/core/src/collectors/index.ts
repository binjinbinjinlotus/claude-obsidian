/**
 * Collectors: fill a vault's queue folder on a schedule (built-in Folder, or a
 * custom script the user allowed). One list for all vaults. What they bring
 * goes through the normal batch, review and approval.
 *
 * Spec: apps/distill/docs/specs/collectors.md
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  CoreError,
  type CollectedFile,
  type Collector,
  type CollectorPatch,
  type CollectorRun,
  type CollectorSchedule,
  type CollectorTrigger,
  type CoreEvent,
  type DistillCore,
  type FolderCollectorSettings,
  type NewCollectorInput,
  type ScheduleCheck,
  type ScriptCollectorSettings,
  type ScriptSource,
  type Settings,
  type VaultProfile,
} from '../contracts.js';
import type { CollectorsOwned } from '../engine/index.js';
import { isoDate } from '../store/json.js';
import { asScheduler } from '../activity/context.js';
import { checkSchedule, CronError, nextRun, parseCron, presetOf } from './cron.js';
import { runFolder } from './folder.js';
import { findOnPath, INLINE_EXTENSION, loginShellPath, scriptBytes, sha256Text, startScript, type ScriptHandle } from './script.js';
import {
  clampTimeout,
  CollectorStore,
  decodeCollector,
  DEFAULT_CRON,
  INTERPRETERS,
  Ledger,
  ledgerFile,
  MAX_TIMEOUT_SECONDS,
  newCollectorID,
  newRunID,
  publicEntry,
  RunStore,
  type LedgerEntry,
} from './store.js';

export const MAX_CONCURRENT_COLLECTORS = 2;
/** A due tick handled later than this counts as a catch-up (the Mac slept, or the core was off). */
const CATCHUP_GRACE_MS = 2 * 60 * 1000;
const OUTPUT_THROTTLE_MS = 250;
const LOGIN_PATH_TTL_MS = 10 * 60 * 1000;

export interface CollectorsOptions {
  emit: (event: CoreEvent) => void;
  getSettings: () => Settings;
  /** <state>/collectors.json */
  file: string;
  /** <state>/collectors (ledgers, runs/) */
  dir: string;
  now?: () => Date;
  /** True while a batch runs or applies in this vault (scripts wait for it). */
  isVaultBusy?: (vaultPath: string) => boolean;
  /** Scheduler tick (default 15 s). */
  tickMs?: number;
  /** SIGTERM → SIGKILL grace (default 10 s). */
  killGraceMs?: number;
  maxConcurrent?: number;
  /** For "~" in folder paths (default os.homedir()). */
  homeDir?: string;
  /** The PATH scripts run with (default: the login shell's PATH). */
  loginPath?: () => Promise<string>;
  /** The environment scripts start from (default process.env). Distill's own DISTILL_* variables are removed. */
  baseEnv?: NodeJS.ProcessEnv;
  /** Where run folders go (default os.tmpdir()). */
  tmpDir?: string;
}

export type CollectorsService = Pick<DistillCore, CollectorsOwned> & {
  start(): void;
  /** Stops the scheduler and every running script; resolves when they have exited. */
  stop(): Promise<void>;
  /** One scheduler pass (tests call it with a fake clock). */
  tick(): void;
  /** Start queued runs that can start now (a slot freed, a batch finished). */
  pump(): void;
  /** Resolves when no run is queued or running. */
  whenIdle(): Promise<void>;
  /**
   * v6: put a deleted collector back from Distill's trash (activity-log.md). It keeps its id unless
   * that is taken, comes back off, and a script needs consent again.
   */
  restoreCollector(record: unknown): Promise<Collector>;
};

interface Active {
  run: CollectorRun;
  stopRequested: boolean;
  /** The core is stopping (not the user's Stop). */
  shutdown?: boolean;
  script?: ScriptHandle;
  done: Promise<void>;
}

const clone = <T>(v: T): T => structuredClone(v);

/** `file` is inside `dir` (at any depth): Folder ledger entries of a collector, subfolders included. */
function isUnder(file: string, dir: string): boolean {
  return file.startsWith(dir.endsWith(path.sep) ? dir : dir + path.sep);
}

function samePath(a: string, b: string): boolean {
  return path.resolve(a) === path.resolve(b);
}

function emptyCounts(): CollectorRun['counts'] {
  return { copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 0, added: 0 };
}

/** "6:00 AM" in local time. */
function clock(d: Date): string {
  return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
}

export function createCollectorsService(opts: CollectorsOptions): CollectorsService {
  const now = opts.now ?? (() => new Date());
  const home = opts.homeDir ?? os.homedir();
  const maxConcurrent = opts.maxConcurrent ?? MAX_CONCURRENT_COLLECTORS;
  const store = new CollectorStore(opts.file);
  const runs = new RunStore(path.join(opts.dir, 'runs'));
  const ledgers = new Map<string, Ledger>();
  let collectors = store.load(now());
  const active = new Map<string, Active>();
  /** Queued runs, FIFO. */
  let pending: CollectorRun[] = [];
  let timer: NodeJS.Timeout | undefined;
  let idleWaiters: (() => void)[] = [];
  let loginPathCache: { value: string; at: number } | undefined;

  // ───────────── helpers ─────────────

  function expandHome(p: string): string {
    if (p === '~') return home;
    if (p.startsWith('~/')) return path.join(home, p.slice(2));
    return p;
  }

  function persist(): void {
    store.save(collectors);
  }

  function find(id: string): Collector | undefined {
    return collectors.find((c) => c.id === id);
  }

  function require(id: string): Collector {
    const c = find(id);
    if (!c) throw new CoreError('not_found', `Unknown collector ${id}.`);
    return c;
  }

  function vaultProfile(vaultPath: string): VaultProfile | undefined {
    return opts.getSettings().vaults.find((v) => samePath(v.path, vaultPath));
  }

  function ledgerFor(vaultPath: string): Ledger {
    const file = ledgerFile(opts.dir, vaultPath);
    let l = ledgers.get(file);
    if (!l) {
      l = new Ledger(file).load(now());
      ledgers.set(file, l);
    }
    return l;
  }

  function currentHash(script: ScriptCollectorSettings): { sha256: string } | { problem: string } {
    try {
      return { sha256: sha256Text(scriptBytes(script.source)) };
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      const file = 'file' in script.source ? script.source.file : '';
      if (code === 'ENOENT') return { problem: `The script ${file} doesn't exist.` };
      if (code === 'EACCES' || code === 'EPERM') return { problem: `Distill isn't allowed to read ${file}.` };
      return { problem: (err as Error).message };
    }
  }

  function lastTick(c: Collector): Date {
    const t = store.ticks.get(c.id);
    const d = t ? new Date(t) : undefined;
    return d && !Number.isNaN(d.getTime()) ? d : new Date(c.updatedAt);
  }

  function dueAt(c: Collector): Date | undefined {
    try {
      return nextRun(parseCron(c.schedule.cron), lastTick(c));
    } catch {
      return undefined;
    }
  }

  function collectedIn(c: Collector): LedgerEntry[] {
    if (c.kind !== 'folder' || !c.folder) return [];
    const source = path.resolve(c.folder.source);
    return ledgerFor(c.vaultPath).entries.filter((e) => isUnder(e.sourcePath, source));
  }

  function summary(run: CollectorRun | undefined): CollectorRun | null {
    if (!run) return null;
    const { files: _f, stdoutTail: _o, stderrTail: _e, ...rest } = run;
    return clone(rest);
  }

  function view(c: Collector): Collector {
    const out = clone(c);
    const isRunning = active.has(c.id) || pending.some((r) => r.collectorId === c.id);
    const due = c.enabled ? dueAt(c) : undefined;
    const last = active.get(c.id)?.run ?? pending.find((r) => r.collectorId === c.id) ?? runs.latest(c.id, now());
    let needsConsent = false;
    out.status = { running: isRunning, nextRunAt: due ? isoDate(due.getTime() < now().getTime() ? now() : due) : null, lastRun: summary(last), needsConsent, needsAttention: false };
    if (c.kind === 'script' && c.script) {
      const h = currentHash(c.script);
      if ('sha256' in h) {
        out.status.currentSha256 = h.sha256;
        needsConsent = c.script.allowedSha256 !== h.sha256;
      } else {
        out.status.currentSha256 = null;
        out.status.scriptProblem = h.problem;
        needsConsent = !c.script.allowedSha256;
      }
      out.status.needsConsent = needsConsent;
    } else {
      out.status.collectedCount = collectedIn(c).length;
    }
    const failed = !!last && ['failed', 'timedout', 'notTrusted'].includes(last.result);
    out.status.needsAttention = needsConsent || failed;
    return out;
  }

  function changed(c: Collector): void {
    opts.emit({ type: 'collector.changed', collector: view(c) });
  }

  // ───────────── validation ─────────────

  function validSchedule(s: CollectorSchedule | undefined): CollectorSchedule {
    const cron = (s?.cron ?? DEFAULT_CRON).trim().replace(/\s+/g, ' ');
    try {
      const spec = parseCron(cron);
      if (!nextRun(spec, now())) throw new CronError('This schedule never runs.');
    } catch (err) {
      throw new CoreError('invalid_request', `Invalid schedule "${cron}": ${(err as Error).message}`);
    }
    return { cron, preset: s?.preset ?? presetOf(cron) };
  }

  function validVault(vaultPath: string | undefined): string {
    const settings = opts.getSettings();
    if (vaultPath !== undefined) {
      const v = vaultProfile(vaultPath);
      if (!v) throw new CoreError('invalid_request', `${vaultPath} is not one of your vaults.`);
      return v.path;
    }
    const active = settings.vaults.find((v) => v.path === settings.activeVaultPath) ?? settings.vaults[0];
    if (!active) throw new CoreError('no_vault', 'No vault selected.');
    return active.path;
  }

  function validFolder(f: Partial<FolderCollectorSettings> | undefined, base: FolderCollectorSettings | undefined, vaultPath: string): FolderCollectorSettings {
    const source = expandHome((f?.source ?? base?.source ?? '~/Distill Inbox').trim());
    if (!path.isAbsolute(source)) throw new CoreError('invalid_request', 'The source folder must be an absolute path.');
    const afterCollect = f?.afterCollect ?? base?.afterCollect ?? 'copy';
    if (afterCollect !== 'copy' && afterCollect !== 'move') throw new CoreError('invalid_request', '"afterCollect" must be "copy" or "move".');
    const queue = vaultProfile(vaultPath)?.queueDirectory;
    if (queue && samePath(queue, source)) throw new CoreError('invalid_request', 'The source folder is the vault’s queue folder.');
    // New collectors include subfolders; a saved one without the field keeps reading as off.
    const includeSubfolders = f?.includeSubfolders ?? base?.includeSubfolders ?? (base ? undefined : true);
    if (includeSubfolders !== undefined && typeof includeSubfolders !== 'boolean') {
      throw new CoreError('invalid_request', '"includeSubfolders" must be true or false.');
    }
    const out: FolderCollectorSettings = { source: path.resolve(source), afterCollect };
    if (includeSubfolders !== undefined) out.includeSubfolders = includeSubfolders;
    return out;
  }

  function validScriptSource(s: ScriptSource): ScriptSource {
    if (s && typeof s === 'object' && 'inline' in s && typeof s.inline === 'string') {
      if (s.inline.trim() === '') throw new CoreError('invalid_request', 'The script is empty.');
      return { inline: s.inline };
    }
    if (s && typeof s === 'object' && 'file' in s && typeof s.file === 'string') {
      const file = expandHome(s.file.trim());
      if (!path.isAbsolute(file)) throw new CoreError('invalid_request', 'The script file must be an absolute path.');
      return { file: path.resolve(file) };
    }
    throw new CoreError('invalid_request', 'A script needs {"file": path} or {"inline": code}.');
  }

  function validTimeout(v: unknown): number {
    if (v === undefined) return clampTimeout(undefined);
    if (typeof v !== 'number' || !Number.isFinite(v) || v < 1 || v > MAX_TIMEOUT_SECONDS) {
      throw new CoreError('invalid_request', `The timeout must be 1–${MAX_TIMEOUT_SECONDS} seconds.`);
    }
    return Math.round(v);
  }

  function ensureDir(dir: string): void {
    try {
      fs.mkdirSync(dir, { recursive: true });
    } catch {
      // The run reports it (source missing / no permission).
    }
  }

  // ───────────── runs ─────────────

  function newRun(c: Collector, trigger: CollectorTrigger): CollectorRun {
    return {
      id: newRunID(),
      collectorId: c.id,
      kind: c.kind,
      vaultPath: c.vaultPath,
      trigger,
      startedAt: isoDate(now()),
      result: 'queued',
      waiting: 'slot',
      counts: emptyCounts(),
      filesAdded: [],
    };
  }

  function record(run: CollectorRun): void {
    runs.put(run, now());
  }

  function closeRun(run: CollectorRun, started: Date): void {
    const end = now();
    run.endedAt = isoDate(end);
    run.durationMs = Math.max(0, end.getTime() - started.getTime());
    delete run.waiting;
  }

  /** A run that never started (skipped, not trusted): recorded and announced at once. */
  function finishedRun(c: Collector, trigger: CollectorTrigger, result: CollectorRun['result'], extra: Partial<CollectorRun>): CollectorRun {
    const run: CollectorRun = { ...newRun(c, trigger), result, ...extra };
    closeRun(run, new Date(run.startedAt));
    record(run);
    opts.emit({ type: 'collector.run.finished', run: clone(run) });
    changed(c);
    return run;
  }

  function enqueue(c: Collector, trigger: CollectorTrigger): CollectorRun {
    const run = newRun(c, trigger);
    pending.push(run);
    record(run);
    changed(c);
    pump();
    return clone(active.get(c.id)?.run ?? pending.find((r) => r.id === run.id) ?? run);
  }

  function pump(): void {
    let changedAny = false;
    for (const run of [...pending]) {
      const c = find(run.collectorId);
      if (!c) {
        pending = pending.filter((r) => r !== run);
        continue;
      }
      let waiting: CollectorRun['waiting'];
      if (active.size >= maxConcurrent) waiting = 'slot';
      else if (c.kind === 'script' && opts.isVaultBusy?.(c.vaultPath)) waiting = 'batch';
      if (waiting) {
        if (run.waiting !== waiting) {
          run.waiting = waiting;
          record(run);
          changed(c);
          changedAny = true;
        }
        continue;
      }
      pending = pending.filter((r) => r !== run);
      begin(c, run);
      changedAny = true;
    }
    if (!changedAny) checkIdle();
  }

  function begin(c: Collector, run: CollectorRun): void {
    const started = now();
    run.result = 'running';
    run.startedAt = isoDate(started);
    delete run.waiting;
    const entry: Active = { run, stopRequested: false, done: Promise.resolve() };
    active.set(c.id, entry);
    record(run);
    opts.emit({ type: 'collector.run.started', run: clone(run) });
    changed(c);
    entry.done = execute(clone(c), entry)
      .catch((err: unknown) => {
        run.result = 'failed';
        run.error = { code: 'other', message: (err as Error).message };
      })
      .then(() => {
        if (entry.shutdown && (run.result === 'stopped' || run.result === 'running')) {
          run.result = 'failed';
          run.error = { code: 'interrupted', message: 'Distill stopped during this run.' };
        }
        closeRun(run, started);
        active.delete(c.id);
        record(run);
        opts.emit({ type: 'collector.run.finished', run: clone(run) });
        const current = find(c.id);
        if (current) changed(current);
        pump();
        checkIdle();
      });
  }

  async function execute(c: Collector, entry: Active): Promise<void> {
    const run = entry.run;
    const vault = vaultProfile(c.vaultPath);
    if (!vault) {
      run.result = 'failed';
      run.error = { code: 'vaultMissing', message: `${c.vaultPath} is no longer one of your vaults.` };
      return;
    }
    const queueDir = path.resolve(vault.queueDirectory);
    if (c.kind === 'folder' && c.folder) {
      const outcome = await runFolder({
        collectorId: c.id,
        folder: c.folder,
        queueDir,
        ledger: ledgerFor(c.vaultPath),
        settleSeconds: opts.getSettings().settleSeconds ?? 600,
        now,
        shouldStop: () => entry.stopRequested,
      });
      Object.assign(run, outcome);
      if (!outcome.error) delete run.error;
      return;
    }
    if (c.kind === 'script' && c.script) await executeScript(c, c.script, vault, queueDir, entry);
  }

  async function executeScript(c: Collector, script: ScriptCollectorSettings, vault: VaultProfile, queueDir: string, entry: Active): Promise<void> {
    const run = entry.run;
    // Consent, checked right before every run.
    let bytes: Buffer;
    try {
      bytes = scriptBytes(script.source);
    } catch (err) {
      const h = currentHash(script);
      run.result = 'failed';
      run.error = { code: 'scriptMissing', message: 'problem' in h ? h.problem : (err as Error).message };
      return;
    }
    const sha = sha256Text(bytes);
    run.sha256 = sha;
    if (!script.allowedSha256) {
      run.result = 'notTrusted';
      run.error = { code: 'notAllowed', message: 'Not run · you haven’t allowed this script yet.' };
      return;
    }
    if (script.allowedSha256 !== sha) {
      run.result = 'notTrusted';
      run.error = { code: 'scriptChanged', message: 'Not run · the script changed since you allowed it.' };
      return;
    }
    try {
      if (!fs.statSync(queueDir).isDirectory()) throw new Error('not a folder');
    } catch {
      run.result = 'failed';
      run.error = { code: 'queueMissing', message: `The queue folder ${queueDir} doesn't exist.` };
      return;
    }
    const searchPath = await loginPath();
    const interpreter = findOnPath(script.interpreter, searchPath);
    if (!interpreter) {
      run.result = 'failed';
      run.error = { code: 'interpreterMissing', message: `${script.interpreter} isn't on your PATH.` };
      return;
    }
    if (entry.stopRequested) {
      run.result = 'stopped';
      return;
    }
    const tmp = opts.tmpDir ?? os.tmpdir();
    const cwd = fs.mkdtempSync(path.join(tmp, `distill-run-${run.id}-`));
    let scriptDir: string | undefined;
    let scriptPath: string;
    if ('inline' in script.source) {
      scriptDir = fs.mkdtempSync(path.join(tmp, `distill-script-${run.id}-`));
      scriptPath = path.join(scriptDir, `collector.${INLINE_EXTENSION[script.interpreter]}`);
      fs.writeFileSync(scriptPath, bytes, { mode: 0o600 }); // exactly the bytes that were hashed
    } else {
      scriptPath = script.source.file;
    }
    const before = queueNames(queueDir);
    const env: NodeJS.ProcessEnv = {};
    for (const [k, v] of Object.entries(opts.baseEnv ?? process.env)) if (!k.startsWith('DISTILL_')) env[k] = v;
    Object.assign(env, {
      PATH: searchPath,
      DISTILL_VAULT: path.resolve(vault.path),
      DISTILL_QUEUE_DIR: queueDir,
      DISTILL_COLLECTOR_ID: c.id,
      DISTILL_RUN_ID: run.id,
    });
    const output = throttledOutput(c.id, run.id);
    try {
      entry.script = startScript({
        interpreterPath: interpreter,
        scriptPath,
        vaultPath: path.resolve(vault.path),
        queueDir,
        cwd,
        env,
        timeoutMs: script.timeoutSeconds * 1000,
        ...(opts.killGraceMs !== undefined ? { killGraceMs: opts.killGraceMs } : {}),
        onOutput: output.push,
      });
      if (entry.stopRequested) entry.script.stop();
      const o = await entry.script.done;
      output.flush();
      run.exitCode = o.exitCode;
      run.signal = o.signal;
      run.stdoutTail = o.stdoutTail;
      run.stderrTail = o.stderrTail;
      const after = queueNames(queueDir);
      run.filesAdded = [...after].filter((n) => !before.has(n)).sort();
      run.counts = { ...emptyCounts(), added: run.filesAdded.length };
      if (o.spawnError) {
        run.result = 'failed';
        run.error = { code: 'interpreterMissing', message: `${script.interpreter} couldn't start: ${o.spawnError}` };
      } else if (o.stopped) {
        run.result = 'stopped';
      } else if (o.timedOut) {
        run.result = 'timedout';
        run.error = { code: 'scriptFailed', message: `Timed out after ${formatSeconds(script.timeoutSeconds)}.` };
      } else if (o.exitCode === 0) {
        run.result = run.filesAdded.length > 0 ? 'success' : 'nothing';
      } else {
        run.result = 'failed';
        run.error = {
          code: 'scriptFailed',
          message: o.exitCode !== null ? `The script exited with code ${o.exitCode}.` : `The script was killed (${o.signal ?? 'signal'}).`,
        };
      }
    } finally {
      output.flush();
      fs.rmSync(cwd, { recursive: true, force: true });
      if (scriptDir) fs.rmSync(scriptDir, { recursive: true, force: true });
    }
  }

  function formatSeconds(s: number): string {
    if (s % 3600 === 0) return `${s / 3600} h`;
    if (s % 60 === 0) return `${s / 60} min`;
    return `${s} s`;
  }

  /** Regular, non-hidden names in the queue folder, folders included (what batching would see). */
  function queueNames(dir: string): Set<string> {
    const out = new Set<string>();
    try {
      for (const d of fs.readdirSync(dir, { withFileTypes: true })) if ((d.isFile() || d.isDirectory()) && !d.name.startsWith('.')) out.add(d.name);
    } catch {
      // empty
    }
    return out;
  }

  function throttledOutput(collectorId: string, runId: string) {
    const buffers: Record<'stdout' | 'stderr', Buffer[]> = { stdout: [], stderr: [] };
    let t: NodeJS.Timeout | undefined;
    const flush = () => {
      if (t) clearTimeout(t);
      t = undefined;
      for (const stream of ['stdout', 'stderr'] as const) {
        if (buffers[stream].length === 0) continue;
        const text = Buffer.concat(buffers[stream]).toString('utf8');
        buffers[stream] = [];
        opts.emit({ type: 'collector.run.output', collectorId, runId, stream, text: text.slice(-16 * 1024) });
      }
    };
    return {
      push: (stream: 'stdout' | 'stderr', chunk: Buffer) => {
        buffers[stream].push(chunk);
        if (!t) {
          t = setTimeout(flush, OUTPUT_THROTTLE_MS);
          t.unref();
        }
      },
      flush,
    };
  }

  async function loginPath(): Promise<string> {
    if (opts.loginPath) return opts.loginPath();
    if (loginPathCache && now().getTime() - loginPathCache.at < LOGIN_PATH_TTL_MS) return loginPathCache.value;
    const value = await loginShellPath(opts.baseEnv ?? process.env);
    loginPathCache = { value, at: now().getTime() };
    return value;
  }

  function checkIdle(): void {
    if (active.size > 0 || pending.length > 0) return;
    const waiters = idleWaiters;
    idleWaiters = [];
    for (const w of waiters) w();
  }

  // ───────────── scheduler ─────────────

  function tick(): void {
    const t = now();
    let touched = false;
    for (const c of collectors) {
      if (!c.enabled) continue;
      const due = dueAt(c);
      if (!due || due.getTime() > t.getTime()) continue;
      // Every missed tick collapses into one run.
      const following = nextRun(parseCron(c.schedule.cron), due);
      const trigger: CollectorTrigger =
        (following && following.getTime() <= t.getTime()) || t.getTime() - due.getTime() > CATCHUP_GRACE_MS ? 'catchup' : 'schedule';
      store.ticks.set(c.id, isoDate(t));
      touched = true;
      const running = active.get(c.id)?.run ?? pending.find((r) => r.collectorId === c.id);
      if (running) {
        finishedRun(c, trigger, 'skipped', { skipReason: `the ${clock(new Date(running.startedAt))} run was still going` });
        continue;
      }
      if (c.kind === 'script' && c.script) {
        // A script waiting for consent records "Not run" once, not every tick.
        const h = currentHash(c.script);
        const last = runs.latest(c.id, t);
        if ('sha256' in h && c.script.allowedSha256 !== h.sha256 && last?.result === 'notTrusted' && last.sha256 === h.sha256) continue;
      }
      enqueue(c, trigger);
    }
    if (touched) persist();
  }

  // ───────────── API ─────────────

  return {
    start() {
      if (timer) return;
      // A collector with no tick yet starts counting now (no run for time before Distill knew it).
      let touched = false;
      for (const c of collectors) {
        if (!store.ticks.has(c.id)) {
          store.ticks.set(c.id, isoDate(now()));
          touched = true;
        }
      }
      if (touched) persist();
      // Scheduled runs are logged as the scheduler's (activity-log.md).
      asScheduler(tick)();
      timer = setInterval(asScheduler(() => {
        try {
          tick();
          pump();
        } catch {
          // a bad entry never stops the scheduler
        }
      }), opts.tickMs ?? 15_000);
      timer.unref();
    },
    async stop() {
      if (timer) clearInterval(timer);
      timer = undefined;
      for (const run of pending) {
        run.result = 'failed';
        run.error = { code: 'interrupted', message: 'Distill stopped before this run started.' };
        closeRun(run, new Date(run.startedAt));
        record(run);
      }
      pending = [];
      for (const a of active.values()) {
        a.stopRequested = true;
        a.shutdown = true;
        a.script?.stop();
      }
      await Promise.all([...active.values()].map((a) => a.done));
    },
    tick,
    pump,
    whenIdle() {
      if (active.size === 0 && pending.length === 0) return Promise.resolve();
      return new Promise((resolve) => idleWaiters.push(resolve));
    },

    async listCollectors() {
      return collectors.map(view);
    },
    async getCollector(id) {
      const c = find(id);
      return c ? view(c) : undefined;
    },
    async createCollector(input: NewCollectorInput) {
      if (input.kind !== 'folder' && input.kind !== 'script') throw new CoreError('invalid_request', '"kind" must be "folder" or "script".');
      const vaultPath = validVault(input.vaultPath);
      const t = isoDate(now());
      const c: Collector = {
        id: newCollectorID(),
        kind: input.kind,
        name: input.name?.trim() || (input.kind === 'folder' ? 'Distill Inbox' : 'Script'),
        vaultPath,
        enabled: input.kind === 'folder' ? (input.enabled ?? true) : false,
        schedule: validSchedule(input.schedule),
        createdAt: t,
        updatedAt: t,
      };
      if (input.kind === 'folder') {
        c.folder = validFolder(input.folder, undefined, vaultPath);
        ensureDir(c.folder.source);
      } else {
        if (!input.script) throw new CoreError('invalid_request', 'A script collector needs "script".');
        if (!INTERPRETERS.includes(input.script.interpreter)) throw new CoreError('invalid_request', '"interpreter" must be zsh, python3 or node.');
        c.script = {
          source: validScriptSource(input.script.source),
          interpreter: input.script.interpreter,
          timeoutSeconds: validTimeout(input.script.timeoutSeconds),
        };
      }
      collectors.push(c);
      store.ticks.set(c.id, t);
      persist();
      changed(c);
      return view(c);
    },
    async updateCollector(id, patch: CollectorPatch) {
      const c = require(id);
      const next = clone(c);
      if (patch.name !== undefined) {
        if (!patch.name.trim()) throw new CoreError('invalid_request', 'The name is empty.');
        next.name = patch.name.trim();
      }
      if (patch.vaultPath !== undefined) next.vaultPath = validVault(patch.vaultPath);
      if (patch.schedule !== undefined) next.schedule = validSchedule(patch.schedule);
      if (next.kind === 'folder') {
        if (patch.script !== undefined) throw new CoreError('invalid_request', 'A Folder collector has no script.');
        if (patch.folder !== undefined || patch.vaultPath !== undefined) next.folder = validFolder(patch.folder, c.folder, next.vaultPath);
      } else {
        if (patch.folder !== undefined) throw new CoreError('invalid_request', 'A script collector has no folder.');
      }
      if (next.kind === 'script' && patch.script !== undefined) {
        const s = next.script!;
        if (patch.script.source !== undefined) s.source = validScriptSource(patch.script.source);
        if (patch.script.timeoutSeconds !== undefined) s.timeoutSeconds = validTimeout(patch.script.timeoutSeconds);
        if (patch.script.interpreter !== undefined) {
          if (!INTERPRETERS.includes(patch.script.interpreter)) throw new CoreError('invalid_request', '"interpreter" must be zsh, python3 or node.');
          // The same code under another interpreter is another program: consent again.
          if (patch.script.interpreter !== s.interpreter) {
            s.allowedSha256 = null;
            s.allowedAt = null;
          }
          s.interpreter = patch.script.interpreter;
        }
      }
      if (patch.enabled !== undefined) next.enabled = patch.enabled;
      if (next.kind === 'script' && next.enabled && next.script) {
        const h = currentHash(next.script);
        if (!('sha256' in h) || next.script.allowedSha256 !== h.sha256) {
          if (patch.enabled === true) throw new CoreError('invalid_state', 'Allow this script before turning it on.');
        }
      }
      if (next.kind === 'folder' && next.folder && patch.folder?.source !== undefined) ensureDir(next.folder.source);
      const turnedOn = !c.enabled && next.enabled;
      const scheduleChanged = patch.schedule !== undefined && patch.schedule.cron.trim() !== c.schedule.cron;
      next.updatedAt = isoDate(now());
      Object.assign(c, next);
      if (!next.folder) delete c.folder;
      if (!next.script) delete c.script;
      // Turning on, or a new schedule, counts from now: no catch-up for the time before.
      if (turnedOn || scheduleChanged) store.ticks.set(c.id, isoDate(now()));
      persist();
      changed(c);
      return view(c);
    },
    async deleteCollector(id) {
      const c = require(id);
      if (active.has(id) || pending.some((r) => r.collectorId === id)) throw new CoreError('busy', 'Stop the run before deleting this collector.');
      collectors = collectors.filter((x) => x.id !== id);
      store.ticks.delete(id);
      persist();
      runs.remove(id);
      opts.emit({ type: 'collector.changed', collector: clone(c), deleted: true });
    },
    async restoreCollector(record: unknown) {
      const decoded = decodeCollector(record, now());
      if (!decoded) throw new CoreError('invalid_request', "The trash copy isn't a collector this build can read.");
      const c: Collector = { ...decoded, enabled: false, updatedAt: isoDate(now()) };
      if (find(c.id)) c.id = newCollectorID();
      if (c.script) {
        // A restored script is reviewed again before it can run.
        delete c.script.allowedSha256;
        delete c.script.allowedAt;
      }
      collectors.push(c);
      store.ticks.set(c.id, isoDate(now()));
      persist();
      changed(c);
      return view(c);
    },
    async runCollector(id) {
      const c = require(id);
      if (active.has(id) || pending.some((r) => r.collectorId === id)) throw new CoreError('busy', `${c.name} is already running.`);
      return enqueue(c, 'now');
    },
    async stopCollector(id) {
      require(id);
      const queued = pending.find((r) => r.collectorId === id);
      if (queued) {
        pending = pending.filter((r) => r !== queued);
        queued.result = 'stopped';
        closeRun(queued, new Date(queued.startedAt));
        record(queued);
        opts.emit({ type: 'collector.run.finished', run: clone(queued) });
        const c = find(id);
        if (c) changed(c);
        checkIdle();
        return clone(queued);
      }
      const a = active.get(id);
      if (!a) return null;
      a.stopRequested = true;
      a.script?.stop();
      return clone(a.run);
    },
    async allowCollector(id, sha256) {
      const c = require(id);
      if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Only script collectors need consent.');
      const h = currentHash(c.script);
      if (!('sha256' in h)) throw new CoreError('invalid_state', h.problem);
      if (typeof sha256 !== 'string' || sha256.toLowerCase() !== h.sha256) {
        throw new CoreError('invalid_state', 'The script changed since you reviewed it; review this version and allow it again.');
      }
      c.script.allowedSha256 = h.sha256;
      c.script.allowedAt = isoDate(now());
      if (!c.enabled) store.ticks.set(c.id, isoDate(now()));
      c.enabled = true;
      c.updatedAt = isoDate(now());
      persist();
      changed(c);
      return view(c);
    },
    async revokeCollector(id) {
      const c = require(id);
      if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Only script collectors have consent.');
      c.script.allowedSha256 = null;
      c.script.allowedAt = null;
      c.enabled = false;
      c.updatedAt = isoDate(now());
      persist();
      changed(c);
      return view(c);
    },
    async listCollectorRuns(id, o) {
      require(id);
      const list = runs.list(id, now());
      const limit = o?.limit;
      return clone(limit && limit > 0 ? list.slice(0, limit) : list);
    },
    async listCollected(id, query) {
      const c = require(id);
      const q = query?.trim().toLowerCase();
      return collectedIn(c)
        .filter((e) => !q || e.name.toLowerCase().includes(q))
        .sort((a, b) => b.collectedAt.localeCompare(a.collectedAt))
        .map(publicEntry);
    },
    async forgetCollected(id, sha256) {
      const c = require(id);
      if (c.kind !== 'folder' || !c.folder) throw new CoreError('invalid_request', 'Only Folder collectors keep a collected list.');
      const ledger = ledgerFor(c.vaultPath);
      const source = path.resolve(c.folder.source);
      // Forget one: every entry with that content in this vault (dedupe is vault-wide), so it is collected again.
      const removed = sha256
        ? ledger.remove((e) => e.sha256 === sha256.toLowerCase())
        : ledger.remove((e) => isUnder(e.sourcePath, source));
      if (sha256 && removed.length === 0) throw new CoreError('not_found', `Nothing collected with sha256 ${sha256}.`);
      changed(c);
      return removed.map(publicEntry);
    },
    async restoreCollected(id, files: CollectedFile[]) {
      const c = require(id);
      if (c.kind !== 'folder') throw new CoreError('invalid_request', 'Only Folder collectors keep a collected list.');
      const ledger = ledgerFor(c.vaultPath);
      let n = 0;
      for (const f of files) {
        if (!/^[0-9a-f]{64}$/.test(f.sha256) || typeof f.sourcePath !== 'string') throw new CoreError('invalid_request', 'Each file needs "sha256" and "sourcePath".');
        if (ledger.entries.some((e) => e.sha256 === f.sha256 && e.sourcePath === f.sourcePath)) continue;
        const mtimeMs = new Date(f.mtime).getTime();
        ledger.append({ ...f, mtimeMs: Number.isFinite(mtimeMs) ? mtimeMs : 0 });
        n += 1;
      }
      changed(c);
      return n;
    },
    async createCollectorFolder(id, which) {
      const c = require(id);
      let dir: string;
      if (which === 'source') {
        if (!c.folder) throw new CoreError('invalid_request', 'Only Folder collectors have a source folder.');
        dir = c.folder.source;
      } else if (which === 'queue') {
        const v = vaultProfile(c.vaultPath);
        if (!v) throw new CoreError('invalid_state', `${c.vaultPath} is no longer one of your vaults.`);
        dir = v.queueDirectory;
      } else {
        throw new CoreError('invalid_request', '"which" must be "source" or "queue".');
      }
      try {
        fs.mkdirSync(dir, { recursive: true });
      } catch (err) {
        throw new CoreError('invalid_state', `Couldn't create ${dir}: ${(err as Error).message}`);
      }
      changed(c);
      return view(c);
    },
    async checkSchedule(cron): Promise<ScheduleCheck> {
      return checkSchedule(cron, now());
    },
  };
}
