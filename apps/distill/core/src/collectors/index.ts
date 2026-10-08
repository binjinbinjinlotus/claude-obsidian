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
  type CollectorInstall,
  type CollectorInterpreter,
  type CollectorOutsideChange,
  type CollectorRun,
  type CollectorSchedule,
  type CollectorScriptFiles,
  type CollectorScriptStatus,
  type CollectorScriptUpdate,
  type CollectorTrigger,
  type CoreEvent,
  type DistillCore,
  type FolderCollectorSettings,
  type NewCollectorInput,
  type ScheduleCheck,
  type ScriptCollectorSettings,
  type ScriptCommand,
  type ScriptSource,
  type Settings,
  type VaultProfile,
} from '../contracts.js';
import type { CollectorsOwned } from '../engine/index.js';
import { isoDate, writeFileAtomic } from '../store/json.js';
import { asScheduler } from '../activity/context.js';
import { checkSchedule, CronError, nextRun, parseCron, presetOf } from './cron.js';
import { runFolder } from './folder.js';
import { queuePlacementProblem } from '../engine/validator.js';
import { isWithin, realish } from '../store/realpath.js';
import { backupFile, consentHash, hasDependencies, MANIFEST, packageCount, PACKAGES_DIR, ScriptFolders } from './files.js';
import { InstallStore, nodeSearchPath, planInstall, probeNode, resolveRuntime, startInstall } from './packages.js';
import { INLINE_EXTENSION, loginShellPath, scriptBytes, sha256Text, startProcess, startScript, type ScriptHandle } from './script.js';
import { maskSecrets, validCommands } from './commands.js';
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
  newInstallID,
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
  /**
   * v6: the Node that runs JavaScript and TypeScript scripts, and whose npm installs package.json (default
   * process.execPath: the Node the core itself runs on). Its folder comes first on those runs' PATH.
   */
  nodePath?: string;
  /** The environment scripts start from (default process.env). Distill's own DISTILL_* variables are removed. */
  baseEnv?: NodeJS.ProcessEnv;
  /** Where run folders go (default os.tmpdir()). */
  tmpDir?: string;
  /** v6: package install timeout (default 10 minutes). */
  installTimeoutMs?: number;
  /**
   * v6: Distill's trash keeps a deleted collector's script folder (the activity layer copies it before the
   * delete), so deleting removes the folder. Without it (the service on its own) the folder is left in place.
   */
  trashKeepsScriptFolders?: boolean;
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
  restoreCollector(record: unknown, files?: string): Promise<Collector>;
  /** Automations: a command run for an action button (action-buttons.md). Never a shell; argv as given. */
  runCommand(input: CommandRunInput): CommandRunHandle;
  /** The script's current consent hash (part of a button's approval), or why there is none. */
  scriptConsent(id: string): { sha256: string; allowed: boolean } | { problem: string };
};

export interface CommandRunInput {
  collectorId: string;
  commandId: string;
  /** After the script path, from buildArgv. */
  args: string[];
  timeoutSeconds: number;
  buttonId: string;
  actionId: string;
  actionType: string;
  /** The item as JSON, written to a 0600 temp file (DISTILL_ACTION_JSON). */
  itemJson: string;
}

export interface CommandRunHandle {
  run: CollectorRun;
  done: Promise<CollectorRun>;
  stop(): void;
}

interface Active {
  run: CollectorRun;
  stopRequested: boolean;
  /** The core is stopping (not the user's Stop). */
  shutdown?: boolean;
  script?: ScriptHandle;
  /** v6: stops the install a run does first. */
  stopInstall?: () => void;
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

const INTERPRETER_ERROR = '"interpreter" must be zsh, python3, node or typescript.';

export function createCollectorsService(opts: CollectorsOptions): CollectorsService {
  const now = opts.now ?? (() => new Date());
  const home = opts.homeDir ?? os.homedir();
  const maxConcurrent = opts.maxConcurrent ?? MAX_CONCURRENT_COLLECTORS;
  const store = new CollectorStore(opts.file);
  const runs = new RunStore(path.join(opts.dir, 'runs'));
  const ledgers = new Map<string, Ledger>();
  let collectors = store.load(now());
  const folders = new ScriptFolders(opts.dir);
  const installs = new InstallStore(path.join(opts.dir, 'installs'));
  /** v6: package installs going on, by collector id (one operation per collector: never with a run). */
  const installing = new Map<string, { install: CollectorInstall; stop(): void; done: Promise<void> }>();
  migrateScripts();
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

  // ───────────── script files (v6; files.ts, packages.ts) ─────────────

  /**
   * Old inline scripts become real files in their own folder (same bytes, so consent stays valid).
   * collectors.json is copied to collectors.json.pre-script-files-<time> first. A script that can't be
   * written stays inline and still runs (from a temp file, as before).
   */
  function migrateScripts(): void {
    let changedAny = false;
    let backedUp = false;
    for (const c of collectors) {
      const s = c.script;
      if (c.kind !== 'script' || !s) continue;
      if ('inline' in s.source) {
        try {
          if (!backedUp) backupFile(opts.file, 'pre-script-files', now());
          backedUp = true;
          const file = folders.writeScript(c.id, s.interpreter, Buffer.from(s.source.inline, 'utf8'), { migrated: true });
          s.source = { file, managed: true };
          markKnown(c);
          changedAny = true;
        } catch {
          // stays inline
        }
      } else if (s.source.managed) {
        // The state dir moved (a restore, another DISTILL_STATE_DIR): the folder is this state dir's.
        const file = folders.managedPath(c.id, s.source.file);
        if (file !== s.source.file) {
          s.source = { file, managed: true };
          changedAny = true;
        }
        // Collectors saved before knownFiles: what is on disk now is the starting point (no entry).
        if (s.knownFiles === undefined) {
          markKnown(c);
          changedAny = true;
        }
      }
    }
    if (changedAny) persist();
  }

  function isManaged(script: ScriptCollectorSettings): boolean {
    return 'file' in script.source && script.source.managed === true;
  }

  function manifestOf(c: Collector) {
    return c.script && isManaged(c.script) ? folders.manifest(c.id, c.script.interpreter) : null;
  }

  /** The consent hash: the script's bytes, and the manifest's when a managed script has one. */
  function currentHash(c: Collector): { sha256: string } | { problem: string } {
    const script = c.script!;
    try {
      const m = manifestOf(c);
      return { sha256: consentHash(scriptBytes(script.source), m?.bytes ? { name: m.name, bytes: m.bytes } : null) };
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      const file = 'file' in script.source ? script.source.file : '';
      if (code === 'ENOENT') return { problem: `The script ${file} doesn't exist.` };
      if (code === 'EACCES' || code === 'EPERM') return { problem: `Distill isn't allowed to read ${file}.` };
      return { problem: (err as Error).message };
    }
  }

  /** The last install was of this exact manifest and failed: no automatic retry (Install tries again). */
  function installFailedFor(c: Collector): boolean {
    const m = manifestOf(c);
    const last = installs.get(c.id).last;
    return !!m?.bytes && !!last && last.manifestSha256 === sha256Text(m.bytes) && ['failed', 'timedout'].includes(last.result);
  }

  function needsInstall(c: Collector): boolean {
    const m = manifestOf(c);
    if (!m?.bytes || !hasDependencies(m.name, m.bytes)) return false;
    if (installs.get(c.id).installedSha256 !== sha256Text(m.bytes)) return true;
    return !fs.existsSync(path.join(folders.folder(c.id), PACKAGES_DIR[m.name]));
  }

  function scriptStatus(c: Collector): CollectorScriptStatus {
    const script = c.script!;
    const managed = isManaged(script);
    const out: CollectorScriptStatus = { path: 'file' in script.source ? script.source.file : '', dir: managed ? folders.folder(c.id) : null, managed, manifest: null };
    const m = manifestOf(c);
    if (m) {
      const record = installs.get(c.id);
      const running = installing.get(c.id)?.install;
      const last = running ?? record.last;
      let lastInstall: CollectorInstall | null = null;
      if (last) {
        const { outputTail: _tail, ...rest } = last;
        lastInstall = clone(rest);
      }
      out.manifest = {
        name: m.name,
        path: m.path,
        exists: !!m.bytes,
        hasDependencies: !!m.bytes && hasDependencies(m.name, m.bytes),
        packageCount: m.bytes ? Math.max(0, packageCount(m.name, m.bytes)) : 0,
        sha256: m.bytes ? sha256Text(m.bytes) : null,
        installedSha256: installs.get(c.id).installedSha256,
        needsInstall: needsInstall(c),
        installing: !!running,
        lastInstall,
        state: 'none',
      };
      const mm = out.manifest;
      mm.state = !mm.hasDependencies ? 'none' : running ? 'installing' : !mm.needsInstall ? 'ready' : installFailedFor(c) ? 'failed' : 'needsInstall';
    }
    const allowed = script.allowedFiles;
    if (allowed && script.allowedSha256) {
      const h = currentHash(c);
      if ('sha256' in h && h.sha256 !== script.allowedSha256) {
        const parts = filesNow(c);
        const changes: ('script' | 'manifest')[] = [];
        if (parts.script !== allowed.script) changes.push('script');
        if (parts.manifest !== allowed.manifest) changes.push('manifest');
        out.changes = changes;
      }
    }
    return out;
  }

  /** sha256 of the script's and the manifest's bytes right now (null when missing). */
  function filesNow(c: Collector): { script: string | null; manifest: string | null } {
    let scriptSha: string | null = null;
    try {
      scriptSha = sha256Text(scriptBytes(c.script!.source));
    } catch {
      scriptSha = null;
    }
    const m = manifestOf(c);
    return { script: scriptSha, manifest: m?.bytes ? sha256Text(m.bytes) : null };
  }

  /**
   * After the core writes a kept script's files (create, save, a source or language change, restore,
   * migration): their hashes become the known ones, so only edits made elsewhere are noticed.
   */
  function markKnown(c: Collector): void {
    if (c.kind !== 'script' || !c.script) return;
    if (!isManaged(c.script)) {
      delete c.script.knownFiles;
      return;
    }
    c.script.knownFiles = filesNow(c);
  }

  function modifiedAt(file: string): string {
    try {
      return fs.statSync(file).mtime.toISOString();
    } catch {
      return isoDate(now());
    }
  }

  /**
   * A kept script or manifest edited outside Distill (an editor opened from "Open in editor" writes the
   * file itself; no request reaches the core). Compared with knownFiles at reads, ticks and before
   * consent, runs and saves; logged once per difference (activity-log.md). Returns whether c changed.
   */
  function noticeOutside(c: Collector): boolean {
    const s = c.script;
    if (c.kind !== 'script' || !s || !isManaged(s) || !('file' in s.source)) return false;
    // An install runs npm/pip in the folder; the core puts package.json's bytes back afterwards.
    if (installing.has(c.id)) return false;
    const files = filesNow(c);
    const known = s.knownFiles;
    if (!known) {
      s.knownFiles = files;
      return true;
    }
    const changes: CollectorOutsideChange['changes'] = [];
    if (files.script !== known.script) changes.push('script');
    if (files.manifest !== known.manifest) changes.push('manifest');
    if (changes.length === 0) return false;
    s.knownFiles = files;
    const file = s.source.file;
    let script: CollectorOutsideChange['script'] = null;
    try {
      const bytes = fs.readFileSync(file);
      const text = bytes.toString('utf8');
      const lines = text === '' ? 0 : text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
      script = { path: file, bytes: bytes.length, lines, sha256: sha256Text(bytes), modifiedAt: modifiedAt(file) };
    } catch {
      script = null;
    }
    const change: CollectorOutsideChange = { collectorId: c.id, name: c.name, interpreter: s.interpreter, changes, script };
    if (changes.includes('manifest')) {
      const m = manifestOf(c);
      change.manifest = m?.bytes ? { name: m.name, bytes: m.bytes.length, sha256: sha256Text(m.bytes), modifiedAt: modifiedAt(m.path) } : null;
    }
    opts.emit({ type: 'collector.script.changed_outside', change });
    return true;
  }

  function noticeOutsideOne(c: Collector | undefined): void {
    if (c && noticeOutside(c)) persist();
  }

  function noticeOutsideAll(): void {
    let touched = false;
    for (const c of collectors) if (noticeOutside(c)) touched = true;
    if (touched) persist();
  }

  /** {inline} → the managed file (written now); {file} → the user's own file, unless it is this collector's managed file. */
  function applySource(c: Collector, s: ScriptSource, interpreter: CollectorInterpreter): ScriptSource {
    if (s && typeof s === 'object' && 'inline' in s && typeof s.inline === 'string') {
      if (s.inline.trim() === '') throw new CoreError('invalid_request', 'The script is empty.');
      const current = c.script && isManaged(c.script) && 'file' in c.script.source ? c.script.source.file : undefined;
      const name = current && fs.existsSync(current) ? path.basename(current) : undefined;
      try {
        const file = folders.writeScript(c.id, interpreter, Buffer.from(s.inline, 'utf8'), name ? { name } : {});
        return { file, managed: true };
      } catch (err) {
        throw new CoreError('invalid_state', `Couldn't save the script file: ${(err as Error).message}`);
      }
    }
    if (s && typeof s === 'object' && 'file' in s && typeof s.file === 'string') {
      const expanded = expandHome(s.file.trim());
      if (!path.isAbsolute(expanded)) throw new CoreError('invalid_request', 'The script file must be an absolute path.');
      const file = path.resolve(expanded);
      if (folders.isManagedPath(c.id, file)) return { file, managed: true };
      // Another collector's managed file (Duplicate sends it): this collector gets its own copy, manifest included.
      const owner = folders.ownerOf(file);
      if (owner) {
        try {
          const copy = folders.writeScript(c.id, interpreter, fs.readFileSync(file), { name: path.basename(file) });
          const manifest = MANIFEST[interpreter];
          const from = manifest ? path.join(path.dirname(file), manifest) : undefined;
          const own = folders.manifest(c.id, interpreter);
          if (from && fs.existsSync(from) && own && !own.bytes) folders.writeManifest(c.id, interpreter, fs.readFileSync(from, 'utf8'));
          return { file: copy, managed: true };
        } catch (err) {
          throw new CoreError('invalid_state', `Couldn't copy the script: ${(err as Error).message}`);
        }
      }
      return { file };
    }
    throw new CoreError('invalid_request', 'A script needs {"file": path} or {"inline": code}.');
  }

  function scriptFiles(c: Collector): CollectorScriptFiles {
    if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Only script collectors have a script.');
    const script = c.script;
    const managed = isManaged(script);
    const out: CollectorScriptFiles = {
      collectorId: c.id,
      interpreter: script.interpreter,
      managed,
      path: 'file' in script.source ? script.source.file : '',
      dir: managed ? folders.folder(c.id) : null,
      code: null,
      sha256: null,
      manifest: null,
    };
    try {
      const bytes = scriptBytes(script.source);
      out.code = bytes.toString('utf8');
      out.sha256 = sha256Text(bytes);
    } catch (err) {
      const h = currentHash(c);
      out.problem = 'problem' in h ? h.problem : (err as Error).message;
    }
    const m = manifestOf(c);
    if (m) out.manifest = { name: m.name, path: m.path, text: m.bytes ? m.bytes.toString('utf8') : null, sha256: m.bytes ? sha256Text(m.bytes) : null };
    return out;
  }

  /** The environment a script or an install gets: the core's minus every DISTILL_* variable, the login PATH, and `extra`. */
  function scriptEnv(searchPath: string, extra: Record<string, string>): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = {};
    for (const [k, v] of Object.entries(opts.baseEnv ?? process.env)) if (!k.startsWith('DISTILL_')) env[k] = v;
    return Object.assign(env, { PATH: searchPath, ...extra });
  }

  /**
   * Install the manifest's packages in the collector's folder; resolves with the finished record. `onStart`
   * gets the running record (the API returns it at once); `onHandle` gets a stop function. The caller
   * checks consent and that nothing else runs for this collector.
   */
  async function install(
    c: Collector,
    trigger: CollectorInstall['trigger'],
    clean: boolean,
    hooks: { onStart?: (i: CollectorInstall) => void; onHandle?: (stop: () => void) => void } = {},
  ): Promise<CollectorInstall> {
    const m = manifestOf(c);
    if (!m?.bytes) throw new CoreError('invalid_state', 'This script has no package manifest.');
    const folder = folders.folder(c.id);
    const started = now();
    const rec: CollectorInstall = {
      id: newInstallID(),
      collectorId: c.id,
      trigger,
      startedAt: isoDate(started),
      result: 'running',
      command: '',
      manifestName: m.name,
      manifestSha256: sha256Text(m.bytes),
      ...(clean ? { clean: true } : {}),
    };
    let stopped = false;
    let handle: { stop(): void } | undefined;
    let resolveDone: () => void = () => {};
    const entry = {
      install: rec,
      stop: () => {
        stopped = true;
        handle?.stop();
      },
      done: new Promise<void>((r) => (resolveDone = r)),
    };
    installing.set(c.id, entry);
    hooks.onHandle?.(entry.stop);
    try {
      if (clean) folders.removePackages(c.id, m.name);
      const node = nodePath();
      const npm = m.name === 'package.json';
      const searchPath = npm ? nodeSearchPath(node, await loginPath()) : await loginPath();
      const plan = planInstall(m.name, folder, searchPath, node);
      if (npm && !('error' in plan)) {
        const info = await probeNode(node, scriptEnv(searchPath, {}));
        rec.runtime = info ? { label: `Node ${info.version}`, path: node, version: info.version } : { label: 'Node', path: node };
      }
      if ('error' in plan) {
        rec.result = 'failed';
        rec.error = { code: 'interpreterMissing', message: plan.error };
        hooks.onStart?.(clone(rec));
      } else {
        rec.command = plan.display;
        installs.put(rec);
        opts.emit({ type: 'collector.install.started', install: clone(rec) });
        changed(c);
        hooks.onStart?.(clone(rec));
        const run = startInstall({
          steps: plan.steps,
          cwd: folder,
          env: scriptEnv(searchPath, { DISTILL_COLLECTOR_ID: c.id, npm_config_update_notifier: 'false' }),
          ...(opts.installTimeoutMs !== undefined ? { timeoutMs: opts.installTimeoutMs } : {}),
          ...(opts.killGraceMs !== undefined ? { killGraceMs: opts.killGraceMs } : {}),
          onOutput: (text) => opts.emit({ type: 'collector.install.output', collectorId: c.id, installId: rec.id, text: text.slice(-16 * 1024) }),
        });
        handle = run;
        if (stopped) run.stop();
        const o = await run.done;
        rec.exitCode = o.exitCode;
        rec.signal = o.signal;
        rec.outputTail = o.outputTail;
        if (o.spawnError) {
          rec.result = 'failed';
          rec.error = { code: 'interpreterMissing', message: `The install couldn't start: ${o.spawnError}` };
        } else if (o.stopped) {
          rec.result = 'stopped';
        } else if (o.timedOut) {
          rec.result = 'timedout';
          rec.error = { code: 'installFailed', message: 'The install timed out.' };
        } else if (o.exitCode === 0) {
          rec.result = 'success';
        } else {
          rec.result = 'failed';
          rec.error = {
            code: 'installFailed',
            message: o.exitCode !== null ? `The install exited with code ${o.exitCode}.` : `The install was killed (${o.signal ?? 'signal'}).`,
          };
        }
      }
    } catch (err) {
      rec.result = 'failed';
      rec.error = { code: 'other', message: (err as Error).message };
    }
    // An install never changes what the owner allowed: npm 6 (and some npm 7+ cases) rewrite package.json
    // (key order, formatting, normalized fields). Put the exact bytes back, whatever the outcome. Saves are
    // refused while an install runs (and deleting is), so nothing else wrote the manifest meanwhile. A file
    // that is gone stays gone: npm never deletes it, and a restore must never recreate a removed folder.
    try {
      const nowBytes = find(c.id) && fs.existsSync(m.path) ? fs.readFileSync(m.path) : null;
      if (nowBytes && !nowBytes.equals(m.bytes)) writeFileAtomic(m.path, m.bytes, fs.statSync(m.path).mode & 0o777);
    } catch (err) {
      if (rec.result === 'success') {
        rec.result = 'failed';
        rec.error = { code: 'other', message: `Couldn't restore ${m.name} after the install: ${(err as Error).message}` };
      }
    }
    const end = now();
    rec.endedAt = isoDate(end);
    rec.durationMs = Math.max(0, end.getTime() - started.getTime());
    installing.delete(c.id);
    installs.put(rec);
    opts.emit({ type: 'collector.install.finished', install: clone(rec) });
    const current = find(c.id);
    if (current) changed(current);
    resolveDone();
    pump();
    checkIdle();
    return clone(rec);
  }

  function busyWith(id: string): string | undefined {
    if (active.has(id) || pending.some((r) => r.collectorId === id)) return 'run';
    if (installing.has(id)) return 'install';
    return undefined;
  }

  function lastTick(c: Collector): Date {
    const t = store.ticks.get(c.id);
    const d = t ? new Date(t) : undefined;
    return d && !Number.isNaN(d.getTime()) ? d : new Date(c.updatedAt);
  }

  function dueAt(c: Collector): Date | undefined {
    // Automations: a commands-only script never runs on a schedule.
    if (c.kind === 'script' && c.script?.collects === false) return undefined;
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

  /** The newest run that isn't a test run (test runs never set lastRun or the sidebar count). */
  function latestReal(id: string): CollectorRun | undefined {
    const latest = runs.latest(id, now());
    if (!latest || (latest.trigger !== 'test' && latest.trigger !== 'action')) return latest;
    return runs.list(id, now()).find((r) => r.trigger !== 'test' && r.trigger !== 'action');
  }

  function summary(run: CollectorRun | undefined): CollectorRun | null {
    if (!run) return null;
    const { files: _f, stdoutTail: _o, stderrTail: _e, outputLog: _l, ...rest } = run;
    return clone(rest);
  }

  function view(c: Collector): Collector {
    const out = clone(c);
    const isRunning = active.has(c.id) || pending.some((r) => r.collectorId === c.id);
    const due = c.enabled ? dueAt(c) : undefined;
    const current = active.get(c.id)?.run ?? pending.find((r) => r.collectorId === c.id);
    const last = current && current.trigger !== 'test' ? current : latestReal(c.id);
    let needsConsent = false;
    out.status = { running: isRunning, nextRunAt: due ? isoDate(due.getTime() < now().getTime() ? now() : due) : null, lastRun: summary(last), needsConsent, needsAttention: false };
    let installFailed = false;
    if (c.kind === 'script' && c.script) {
      const h = currentHash(c);
      out.status.script = scriptStatus(c);
      out.status.script.lastTestRun = summary(current?.trigger === 'test' ? current : runs.list(c.id, now()).find((r) => r.trigger === 'test'));
      const m = out.status.script.manifest;
      installFailed = m?.state === 'failed';
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
    out.status.needsAttention = needsConsent || failed || installFailed;
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

  /**
   * Why a Folder collector may not read `source`: it is inside one of the user's vaults. Copying or
   * moving files out of a vault would take them from wiki/, .raw/ or inbox/ outside any reviewed
   * transaction (decision 2026-10-04).
   */
  function sourceInVault(source: string): string | undefined {
    const real = realish(source);
    const vault = opts.getSettings().vaults.find((v) => isWithin(real, realish(v.path)));
    return vault ? `The source folder ${source} is inside the vault ${vault.path}. Pick a folder outside your vaults.` : undefined;
  }

  function validFolder(f: Partial<FolderCollectorSettings> | undefined, base: FolderCollectorSettings | undefined, vaultPath: string): FolderCollectorSettings {
    const source = expandHome((f?.source ?? base?.source ?? '~/Distill Inbox').trim());
    if (!path.isAbsolute(source)) throw new CoreError('invalid_request', 'The source folder must be an absolute path.');
    const afterCollect = f?.afterCollect ?? base?.afterCollect ?? 'copy';
    if (afterCollect !== 'copy' && afterCollect !== 'move') throw new CoreError('invalid_request', '"afterCollect" must be "copy" or "move".');
    const queue = vaultProfile(vaultPath)?.queueDirectory;
    if (queue && samePath(queue, source)) throw new CoreError('invalid_request', 'The source folder is the vault’s queue folder.');
    const inVault = sourceInVault(source);
    if (inVault) throw new CoreError('invalid_request', inVault);
    // New collectors include subfolders; a saved one without the field keeps reading as off.
    const includeSubfolders = f?.includeSubfolders ?? base?.includeSubfolders ?? (base ? undefined : true);
    if (includeSubfolders !== undefined && typeof includeSubfolders !== 'boolean') {
      throw new CoreError('invalid_request', '"includeSubfolders" must be true or false.');
    }
    const out: FolderCollectorSettings = { source: path.resolve(source), afterCollect };
    if (includeSubfolders !== undefined) out.includeSubfolders = includeSubfolders;
    return out;
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
      if (installing.has(c.id) && !active.has(c.id)) waiting = 'install';
      else if (active.size >= maxConcurrent) waiting = 'slot';
      // A test run writes to its scratch folder, not the queue: no need to wait for a batch.
      else if (c.kind === 'script' && run.trigger !== 'test' && opts.isVaultBusy?.(c.vaultPath)) waiting = 'batch';
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
    // A queue folder inside the vault other than exactly <vault>/inbox gets nothing (decision 2026-10-04).
    const placement = queuePlacementProblem(vault.path, vault.queueDirectory);
    if (placement && run.trigger !== 'test') {
      run.result = 'failed';
      run.error = { code: 'other', message: placement.message };
      return;
    }
    let queueDir = path.resolve(vault.queueDirectory);
    if (run.trigger === 'test') {
      // A scratch folder stands in for the queue; the previous test run's output is replaced.
      queueDir = folders.testDir(c.id);
      fs.rmSync(queueDir, { recursive: true, force: true });
      fs.mkdirSync(queueDir, { recursive: true, mode: 0o700 });
      run.outputDir = queueDir;
    }
    if (c.kind === 'folder' && c.folder) {
      // A saved collector whose source became invalid fails visibly in its run history.
      const inVault = sourceInVault(c.folder.source);
      if (inVault) {
        run.result = 'failed';
        run.error = { code: 'other', message: inVault };
        return;
      }
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
    // Consent, checked right before every run: the script's bytes (and the manifest's, when there is one).
    let bytes: Buffer;
    try {
      bytes = scriptBytes(script.source);
    } catch (err) {
      const h = currentHash(c);
      run.result = 'failed';
      run.error = { code: 'scriptMissing', message: 'problem' in h ? h.problem : (err as Error).message };
      return;
    }
    const manifest = manifestOf(c);
    const sha = consentHash(bytes, manifest?.bytes ? { name: manifest.name, bytes: manifest.bytes } : null);
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
    // Safety net: packages missing (node_modules deleted, or a version allowed before v6 installed at once).
    // An install of this exact manifest that already failed isn't retried every run; Install tries again.
    if (needsInstall(c) && installFailedFor(c)) {
      const last = installs.get(c.id).last!;
      run.installId = last.id;
      run.result = 'failed';
      run.error = { code: 'installFailed', message: `Not run · installing packages failed: ${last.error?.message ?? last.result}. Install again.` };
      return;
    }
    if (needsInstall(c)) {
      const done = await install(c, 'beforeRun', false, {
        onStart: (i) => {
          run.installId = i.id;
        },
        onHandle: (stop) => {
          entry.stopInstall = stop;
          if (entry.stopRequested) stop();
        },
      });
      delete entry.stopInstall;
      run.installId = done.id;
      if (done.result === 'stopped' || entry.stopRequested) {
        run.result = 'stopped';
        return;
      }
      if (done.result !== 'success') {
        run.result = 'failed';
        run.error = { code: 'installFailed', message: `Not run · installing packages failed: ${done.error?.message ?? done.result}` };
        return;
      }
    }
    const folder = isManaged(script) ? folders.folder(c.id) : null;
    const onNode = script.interpreter === 'node' || script.interpreter === 'typescript';
    const runPath = onNode ? nodeSearchPath(nodePath(), searchPath) : searchPath;
    const runtime = await resolveRuntime(script.interpreter, folder, runPath, scriptEnv(runPath, {}), nodePath());
    if ('error' in runtime) {
      run.result = 'failed';
      run.error = { code: 'interpreterMissing', message: runtime.error };
      return;
    }
    run.runtime = runtime.runtime;
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
    const env = scriptEnv(runPath, {
      DISTILL_VAULT: path.resolve(vault.path),
      DISTILL_QUEUE_DIR: queueDir,
      DISTILL_COLLECTOR_ID: c.id,
      DISTILL_RUN_ID: run.id,
      // now | schedule | catchup | test: a Test run lets a script skip saving its own "already fetched" state.
      DISTILL_RUN_TRIGGER: run.trigger,
    });
    const output = throttledOutput(c.id, run.id);
    try {
      entry.script = startScript({
        interpreterPath: runtime.command,
        interpreterArgs: runtime.args,
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
      if (o.outputLog.length > 0) run.outputLog = o.outputLog;
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

  /** The Node that runs JavaScript and TypeScript scripts and npm installs: Distill's own (see CollectorsOptions.nodePath). */
  function nodePath(): string {
    return opts.nodePath ?? process.execPath;
  }

  async function loginPath(): Promise<string> {
    if (opts.loginPath) return opts.loginPath();
    if (loginPathCache && now().getTime() - loginPathCache.at < LOGIN_PATH_TTL_MS) return loginPathCache.value;
    const value = await loginShellPath(opts.baseEnv ?? process.env);
    loginPathCache = { value, at: now().getTime() };
    return value;
  }

  function checkIdle(): void {
    if (active.size > 0 || pending.length > 0 || installing.size > 0) return;
    const waiters = idleWaiters;
    idleWaiters = [];
    for (const w of waiters) w();
  }

  // ───────────── scheduler ─────────────

  function tick(): void {
    noticeOutsideAll();
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
        const h = currentHash(c);
        const last = latestReal(c.id);
        if ('sha256' in h && c.script.allowedSha256 !== h.sha256 && last?.result === 'notTrusted' && last.sha256 === h.sha256) continue;
      }
      enqueue(c, trigger);
    }
    if (touched) persist();
  }

  // ───────────── API ─────────────

  // ───────────── commands (Automations) ─────────────

  /** One command run per item at a time; alongside a collect of the same script. */
  const commandRuns = new Map<string, { run: CollectorRun; stop(): void; stopRequested: boolean }>();

  function scriptConsentOf(id: string): { sha256: string; allowed: boolean } | { problem: string } {
    const c = find(id);
    if (!c || c.kind !== 'script' || !c.script) return { problem: 'Script missing' };
    let bytes: Buffer;
    try {
      bytes = scriptBytes(c.script.source);
    } catch (err) {
      return { problem: `Script missing: ${(err as Error).message}` };
    }
    const manifest = manifestOf(c);
    const sha = consentHash(bytes, manifest?.bytes ? { name: manifest.name, bytes: manifest.bytes } : null);
    return { sha256: sha, allowed: c.script.allowedSha256 === sha };
  }

  function runCommand(input: CommandRunInput): CommandRunHandle {
    const c = require(input.collectorId);
    if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', `${c.name} isn't a script.`);
    const command = (c.script.commands ?? []).find((x) => x.id === input.commandId);
    if (!command) throw new CoreError('invalid_request', `${c.name} has no command ${input.commandId}.`);
    if (commandRuns.has(input.actionId)) throw new CoreError('busy', 'A button is already running for this item.');
    const run: CollectorRun = {
      ...newRun(c, 'action'),
      result: 'running',
      command: { id: command.id, buttonId: input.buttonId, actionId: input.actionId, argv: input.args.map(maskSecrets) },
    };
    delete run.waiting;
    const started = now();
    const entry = { run, stopRequested: false, stop: () => undefined as void };
    let handle: ScriptHandle | undefined;
    let stopInstall: (() => void) | undefined;
    entry.stop = () => {
      entry.stopRequested = true;
      handle?.stop();
      stopInstall?.();
    };
    commandRuns.set(input.actionId, entry);
    record(run);
    opts.emit({ type: 'collector.run.started', run: clone(run) });
    const script = c.script;
    const done = (async () => {
      const consent = scriptConsentOf(c.id);
      if ('problem' in consent) {
        run.result = 'failed';
        run.error = { code: 'scriptMissing', message: consent.problem };
        return;
      }
      run.sha256 = consent.sha256;
      if (!consent.allowed) {
        run.result = 'notTrusted';
        run.error = script.allowedSha256
          ? { code: 'scriptChanged', message: 'Not run · the script changed since you allowed it.' }
          : { code: 'notAllowed', message: 'Not run · you haven’t allowed this script yet.' };
        return;
      }
      const searchPath = await loginPath();
      if (needsInstall(c)) {
        const inst = await install(c, 'beforeRun', false, {
          onStart: (i) => {
            run.installId = i.id;
          },
          onHandle: (stop) => {
            stopInstall = stop;
            if (entry.stopRequested) stop();
          },
        });
        stopInstall = undefined;
        if (inst.result !== 'success' || entry.stopRequested) {
          run.result = entry.stopRequested || inst.result === 'stopped' ? 'stopped' : 'failed';
          if (run.result === 'failed') run.error = { code: 'installFailed', message: `Not run · installing packages failed: ${inst.error?.message ?? inst.result}` };
          return;
        }
      }
      const folder = isManaged(script) ? folders.folder(c.id) : null;
      const onNode = script.interpreter === 'node' || script.interpreter === 'typescript';
      const runPath = onNode ? nodeSearchPath(nodePath(), searchPath) : searchPath;
      const runtime = await resolveRuntime(script.interpreter, folder, runPath, scriptEnv(runPath, {}), nodePath());
      if ('error' in runtime) {
        run.result = 'failed';
        run.error = { code: 'interpreterMissing', message: runtime.error };
        return;
      }
      run.runtime = runtime.runtime;
      if (entry.stopRequested) {
        run.result = 'stopped';
        return;
      }
      const tmp = opts.tmpDir ?? os.tmpdir();
      const cwd = fs.mkdtempSync(path.join(tmp, `distill-cmd-${run.id}-`));
      let scriptPath: string;
      if ('inline' in script.source) {
        scriptPath = path.join(cwd, `collector.${INLINE_EXTENSION[script.interpreter]}`);
        fs.writeFileSync(scriptPath, scriptBytes(script.source), { mode: 0o600 });
      } else {
        scriptPath = script.source.file;
      }
      const itemFile = path.join(cwd, '.distill-action.json');
      fs.writeFileSync(itemFile, input.itemJson, { mode: 0o600 });
      const vault = vaultProfile(c.vaultPath);
      const env = scriptEnv(runPath, {
        DISTILL_RUN_TRIGGER: 'action',
        DISTILL_RUN_ID: run.id,
        DISTILL_COLLECTOR_ID: c.id,
        DISTILL_COMMAND: command.id,
        DISTILL_ACTION_ID: input.actionId,
        DISTILL_ACTION_TYPE: input.actionType,
        DISTILL_ACTION_JSON: itemFile,
        ...(vault ? { DISTILL_VAULT: path.resolve(vault.path) } : {}),
      });
      const output = throttledOutput(c.id, run.id);
      try {
        handle = startProcess({
          command: runtime.command,
          args: [...runtime.args, scriptPath, ...input.args],
          cwd,
          env,
          timeoutMs: input.timeoutSeconds * 1000,
          ...(opts.killGraceMs !== undefined ? { killGraceMs: opts.killGraceMs } : {}),
          onOutput: output.push,
        });
        if (entry.stopRequested) handle.stop();
        const o = await handle.done;
        output.flush();
        run.exitCode = o.exitCode;
        run.signal = o.signal;
        run.stdoutTail = maskSecrets(o.stdoutTail);
        run.stderrTail = maskSecrets(o.stderrTail);
        if (o.outputLog.length > 0) run.outputLog = o.outputLog.map((x) => ({ ...x, text: maskSecrets(x.text) }));
        if (o.spawnError) {
          run.result = 'failed';
          run.error = { code: 'interpreterMissing', message: `${script.interpreter} couldn't start: ${o.spawnError}` };
        } else if (o.stopped) {
          run.result = 'stopped';
        } else if (o.timedOut) {
          run.result = 'timedout';
          run.error = { code: 'scriptFailed', message: `Timed out after ${formatSeconds(input.timeoutSeconds)}.` };
        } else if (o.exitCode === 0) {
          run.result = 'success';
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
      }
    })()
      .catch((err: unknown) => {
        run.result = 'failed';
        run.error = { code: 'other', message: (err as Error).message };
      })
      .then(() => {
        closeRun(run, started);
        commandRuns.delete(input.actionId);
        record(run);
        opts.emit({ type: 'collector.run.finished', run: clone(run) });
        return clone(run);
      });
    return { run: clone(run), done, stop: () => entry.stop() };
  }

  return {
    runCommand,
    scriptConsent: scriptConsentOf,
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
      try {
        folders.pruneTrash(now());
        folders.pruneTestRuns(now());
      } catch {
        // the trash is best effort
      }
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
      for (const i of installing.values()) i.stop();
      for (const r of commandRuns.values()) r.stop();
      await Promise.all([...active.values()].map((a) => a.done));
      await Promise.all([...installing.values()].map((i) => i.done));
    },
    tick,
    pump,
    whenIdle() {
      if (active.size === 0 && pending.length === 0 && installing.size === 0) return Promise.resolve();
      return new Promise((resolve) => idleWaiters.push(resolve));
    },

    async listCollectors() {
      noticeOutsideAll();
      return collectors.map(view);
    },
    async getCollector(id) {
      const c = find(id);
      noticeOutsideOne(c);
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
        if (!INTERPRETERS.includes(input.script.interpreter)) throw new CoreError('invalid_request', INTERPRETER_ERROR);
        const timeoutSeconds = validTimeout(input.script.timeoutSeconds);
        const manifest = input.script.manifest;
        if (manifest !== undefined && (typeof manifest !== 'string' || !MANIFEST[input.script.interpreter])) {
          throw new CoreError('invalid_request', 'A zsh script has no package manifest.');
        }
        c.script = { source: applySource(c, input.script.source, input.script.interpreter), interpreter: input.script.interpreter, timeoutSeconds };
        // Automations: "Commands for buttons" never collects on a schedule (absent = collects, as before).
        if (input.script.collects === false) c.script.collects = false;
        if (manifest !== undefined) {
          if (!isManaged(c.script)) throw new CoreError('invalid_request', 'Packages are for scripts Distill keeps (inline code), not your own file.');
          folders.writeManifest(c.id, c.script.interpreter, manifest);
        }
        markKnown(c);
      }
      collectors.push(c);
      store.ticks.set(c.id, t);
      persist();
      changed(c);
      return view(c);
    },
    async updateCollector(id, patch: CollectorPatch) {
      const c = require(id);
      noticeOutsideOne(c);
      const next = clone(c);
      // A refused patch can still have written the kept file (same name): that write is the core's.
      let wrote = false;
      try {
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
          if (patch.script.interpreter !== undefined && !INTERPRETERS.includes(patch.script.interpreter)) throw new CoreError('invalid_request', INTERPRETER_ERROR);
          if (patch.script.timeoutSeconds !== undefined) s.timeoutSeconds = validTimeout(patch.script.timeoutSeconds);
          // Automations: commands and Collect don't change the script's bytes, so consent stays.
          if (patch.script.collects !== undefined) s.collects = patch.script.collects === true;
          if (patch.script.commands !== undefined) s.commands = validCommands(patch.script.commands);
          const interpreter = patch.script.interpreter ?? s.interpreter;
          if (patch.script.source !== undefined) {
            s.source = applySource(c, patch.script.source, interpreter);
            wrote = true;
          }
          if (patch.script.interpreter !== undefined) {
            // The same code under another interpreter is another program: consent again.
            if (patch.script.interpreter !== s.interpreter) {
              s.allowedSha256 = null;
              s.allowedAt = null;
              s.allowedFiles = null;
              // A managed file takes the new language's extension (TypeScript needs .ts).
              if (isManaged(s) && 'file' in s.source) {
                try {
                  s.source = { file: folders.renameForLanguage(s.source.file, patch.script.interpreter, now()), managed: true };
                  wrote = true;
                } catch (err) {
                  throw new CoreError('invalid_state', `Couldn't rename the script file: ${(err as Error).message}`);
                }
              }
            }
            s.interpreter = patch.script.interpreter;
          }
        }
        if (patch.enabled !== undefined) next.enabled = patch.enabled;
        if (next.kind === 'script' && next.enabled && next.script) {
          const h = currentHash(next);
          if (!('sha256' in h) || next.script.allowedSha256 !== h.sha256) {
            if (patch.enabled === true) throw new CoreError('invalid_state', 'Allow this script before turning it on.');
          }
        }
        if (next.kind === 'folder' && next.folder && patch.folder?.source !== undefined) ensureDir(next.folder.source);
        const turnedOn = !c.enabled && next.enabled;
        const scheduleChanged = patch.schedule !== undefined && patch.schedule.cron.trim() !== c.schedule.cron;
        next.updatedAt = isoDate(now());
        markKnown(next);
        Object.assign(c, next);
        if (!next.folder) delete c.folder;
        if (!next.script) delete c.script;
        // Turning on, or a new schedule, counts from now: no catch-up for the time before.
        if (turnedOn || scheduleChanged) store.ticks.set(c.id, isoDate(now()));
        persist();
        changed(c);
        return view(c);
      } catch (err) {
        if (wrote) {
          markKnown(c);
          persist();
        }
        throw err;
      }
    },
    async deleteCollector(id) {
      const c = require(id);
      const busy = busyWith(id);
      if (busy) throw new CoreError('busy', busy === 'run' ? 'Stop the run before deleting this collector.' : 'Stop the install before deleting this collector.');
      collectors = collectors.filter((x) => x.id !== id);
      store.ticks.delete(id);
      persist();
      runs.remove(id);
      installs.remove(id);
      fs.rmSync(folders.testDir(id), { recursive: true, force: true });
      // Distill's trash copied the script folder before this call; without one the folder stays.
      if (opts.trashKeepsScriptFolders) {
        try {
          folders.removeFolder(id);
        } catch {
          // the folder stays where it is
        }
      }
      opts.emit({ type: 'collector.changed', collector: clone(c), deleted: true });
    },
    async restoreCollector(record: unknown, files?: string) {
      const decoded = decodeCollector(record, now());
      if (!decoded) throw new CoreError('invalid_request', "The trash copy isn't a collector this build can read.");
      const c: Collector = { ...decoded, enabled: false, updatedAt: isoDate(now()) };
      const oldID = c.id;
      if (find(c.id)) c.id = newCollectorID();
      if (c.script) {
        // A restored script is reviewed again before it can run; its packages install when it is allowed.
        delete c.script.allowedSha256;
        delete c.script.allowedAt;
        delete c.script.allowedFiles;
        const s = c.script;
        try {
          if ('inline' in s.source) {
            // Deleted before scripts were files: it comes back as one.
            s.source = { file: folders.writeScript(c.id, s.interpreter, Buffer.from(s.source.inline, 'utf8'), { migrated: true }), managed: true };
          } else if (s.source.managed) {
            const from = files ?? folders.legacyTrashFolder(oldID);
            if (from) folders.restoreFolder(c.id, from, now());
            s.source = { file: folders.managedPath(c.id, s.source.file), managed: true };
          }
        } catch (err) {
          throw new CoreError('invalid_state', `Couldn't put the script back: ${(err as Error).message}`);
        }
      }
      markKnown(c);
      collectors.push(c);
      store.ticks.set(c.id, isoDate(now()));
      persist();
      changed(c);
      return view(c);
    },
    async runCollector(id) {
      const c = require(id);
      noticeOutsideOne(c);
      if (c.kind === 'script' && c.script?.collects === false) throw new CoreError('invalid_request', `${c.name} doesn't collect; its commands run from action buttons.`);
      // While packages install, the run waits for them (queued, waiting 'install'): "Allow and run" works.
      if (busyWith(id) === 'run') throw new CoreError('busy', `${c.name} is already running.`);
      return enqueue(c, 'now');
    },
    async testCollector(id) {
      const c = require(id);
      noticeOutsideOne(c);
      if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Test run is for script collectors.');
      if (c.script.collects === false) throw new CoreError('invalid_request', `${c.name} doesn't collect; its commands run from action buttons.`);
      if (busyWith(id) === 'run') throw new CoreError('busy', `${c.name} is already running.`);
      return enqueue(c, 'test');
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
      a.stopInstall?.();
      a.script?.stop();
      return clone(a.run);
    },
    async allowCollector(id, sha256) {
      const c = require(id);
      // An edit made elsewhere is logged before the consent that covers it.
      noticeOutsideOne(c);
      if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Only script collectors need consent.');
      const h = currentHash(c);
      if (!('sha256' in h)) throw new CoreError('invalid_state', h.problem);
      if (typeof sha256 !== 'string' || sha256.toLowerCase() !== h.sha256) {
        throw new CoreError('invalid_state', 'The script changed since you reviewed it; review this version and allow it again.');
      }
      c.script.allowedSha256 = h.sha256;
      c.script.allowedAt = isoDate(now());
      const parts = filesNow(c);
      c.script.allowedFiles = parts.script ? { script: parts.script, manifest: parts.manifest } : null;
      if (!c.enabled) store.ticks.set(c.id, isoDate(now()));
      c.enabled = true;
      c.updatedAt = isoDate(now());
      persist();
      // Packages install as part of adding (or of allowing a changed manifest), not at the first run.
      if (needsInstall(c) && !busyWith(id)) void install(c, 'allow', false);
      changed(c);
      return view(c);
    },
    async revokeCollector(id) {
      const c = require(id);
      if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Only script collectors have consent.');
      c.script.allowedSha256 = null;
      c.script.allowedAt = null;
      c.script.allowedFiles = null;
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
    async getCollectorScript(id) {
      const c = require(id);
      noticeOutsideOne(c);
      return scriptFiles(c);
    },
    async writeCollectorScript(id, update: CollectorScriptUpdate) {
      const c = require(id);
      noticeOutsideOne(c);
      if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Only script collectors have a script.');
      const s = c.script;
      if (!isManaged(s) || !('file' in s.source)) {
        throw new CoreError('invalid_state', 'This collector runs your own file; edit it in your editor.');
      }
      if (update.code === undefined && update.manifest === undefined) throw new CoreError('invalid_request', 'Nothing to save ("code" or "manifest").');
      if (update.code !== undefined && (typeof update.code !== 'string' || update.code.trim() === '')) throw new CoreError('invalid_request', 'The script is empty.');
      if (update.manifest !== undefined && update.manifest !== null && typeof update.manifest !== 'string') throw new CoreError('invalid_request', '"manifest" must be text or null.');
      if (update.manifest !== undefined && !MANIFEST[s.interpreter]) throw new CoreError('invalid_request', 'A zsh script has no package manifest.');
      if (busyWith(id) === 'install') throw new CoreError('busy', 'Wait for the install to finish.');
      const before = scriptFiles(c);
      // Saved over a version changed on disk (an external editor) since it was loaded: refuse, never clobber.
      if (update.code !== undefined && update.baseSha256 !== undefined && update.baseSha256 !== before.sha256) {
        throw new CoreError('invalid_state', 'The script changed on disk since you opened it; reload it first.');
      }
      if (update.manifest !== undefined && update.baseManifestSha256 !== undefined && update.baseManifestSha256 !== (before.manifest?.sha256 ?? null)) {
        throw new CoreError('invalid_state', `${before.manifest?.name ?? 'The manifest'} changed on disk since you opened it; reload it first.`);
      }
      try {
        if (update.code !== undefined) folders.writeScript(c.id, s.interpreter, Buffer.from(update.code, 'utf8'), { name: path.basename(s.source.file) });
        if (update.manifest !== undefined) folders.writeManifest(c.id, s.interpreter, update.manifest);
      } catch (err) {
        // The script may be written and the manifest not: what is on disk is still the core's.
        markKnown(c);
        persist();
        throw new CoreError('invalid_state', `Couldn't save: ${(err as Error).message}`);
      }
      markKnown(c);
      c.updatedAt = isoDate(now());
      persist();
      changed(c);
      return scriptFiles(c);
    },
    async installCollectorPackages(id, o) {
      const c = require(id);
      noticeOutsideOne(c);
      if (c.kind !== 'script' || !c.script) throw new CoreError('invalid_request', 'Only script collectors have packages.');
      if (!isManaged(c.script)) throw new CoreError('invalid_request', 'Packages are for scripts Distill keeps, not your own file.');
      const m = manifestOf(c);
      if (!m) throw new CoreError('invalid_request', 'A zsh script has no packages.');
      if (!m.bytes) throw new CoreError('invalid_state', `There is no ${m.name} yet.`);
      const busy = busyWith(id);
      if (busy) throw new CoreError('busy', busy === 'run' ? `${c.name} is running.` : `${c.name} is already installing packages.`);
      // Installing runs third-party code: only for the version the user allowed.
      const h = currentHash(c);
      if (!('sha256' in h) || c.script.allowedSha256 !== h.sha256) {
        throw new CoreError('invalid_state', 'Allow this version of the script and its packages before installing.');
      }
      return new Promise<CollectorInstall>((resolve) => {
        void install(c, 'manual', o?.clean === true, { onStart: resolve }).then(resolve);
      });
    },
    async stopCollectorInstall(id) {
      require(id);
      const i = installing.get(id);
      if (!i) return null;
      i.stop();
      return clone(i.install);
    },
    async getCollectorInstall(id) {
      require(id);
      const running = installing.get(id)?.install;
      if (running) return clone(running);
      const last = installs.get(id).last;
      return last ? clone(last) : null;
    },
  };
}
