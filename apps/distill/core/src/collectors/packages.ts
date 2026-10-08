/**
 * v6: how a script runs (its runtime), and package installs for Distill-managed scripts.
 *
 * Runtimes:
 * - zsh: from the login shell's PATH.
 * - python3: the folder's .venv/bin/python3 once packages were installed there, else python3 from the login PATH.
 * - node: Distill's own Node (the one the core runs on, process.execPath), never the login shell's node.
 * - typescript: Distill's Node with its built-in type stripping (on by default from Node 22.18 / 23.6; Node
 *   22.6–22.17 needs --experimental-strip-types). When the folder has tsx installed (a devDependency the user
 *   added), tsx runs it instead (on the same Node), for syntax stripping can't handle (enum, namespace).
 *
 * Installs (cwd = the script's folder, same environment as a run, 10-minute timeout, Stop):
 * - package.json: `npm install --no-audit --no-fund` with the npm that ships with Distill's Node, run by that
 *   Node. If npm rewrote package.json, the caller puts the approved bytes back.
 * - requirements.txt: `python3 -m venv .venv` (when missing), then `.venv/bin/python3 -m pip install -r requirements.txt`.
 * Output is stdout and stderr interleaved, last 64 KB, with URL credentials and auth tokens masked.
 */
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import type { CollectorInstall, CollectorInterpreter, CollectorManifestName, CollectorRuntime } from '../contracts.js';
import { decodeInstall } from './store.js';
import { findOnPath, startProcess, Tail, type ScriptHandle } from './script.js';
import { encodeJSON, isObject, readJSON, str, writeFileAtomic } from '../store/json.js';

export const INSTALL_TIMEOUT_MS = 10 * 60 * 1000;
const PROBE_TTL_MS = 10 * 60 * 1000;

export type RuntimeInfo = CollectorRuntime;

export type Runtime = { command: string; args: string[]; runtime: RuntimeInfo } | { error: string };

interface NodeInfo {
  version: string;
  typescript: string | null;
}
const nodeProbes = new Map<string, { at: number; info: NodeInfo | null }>();

/** `node -p` for its version and process.features.typescript; cached 10 minutes per node binary. */
export function probeNode(node: string, env: NodeJS.ProcessEnv): Promise<NodeInfo | null> {
  if (node === process.execPath) {
    const features = process.features as { typescript?: unknown };
    return Promise.resolve({ version: process.versions.node, typescript: typeof features.typescript === 'string' ? features.typescript : null });
  }
  const hit = nodeProbes.get(node);
  if (hit && Date.now() - hit.at < PROBE_TTL_MS) return Promise.resolve(hit.info);
  const code = 'JSON.stringify({v: process.versions.node, ts: (process.features && process.features.typescript) || null})';
  return new Promise((resolve) => {
    execFile(node, ['-p', code], { timeout: 10_000, env }, (err, stdout) => {
      let info: NodeInfo | null = null;
      if (!err) {
        try {
          const o = JSON.parse(String(stdout).trim()) as { v?: unknown; ts?: unknown };
          if (typeof o.v === 'string') info = { version: o.v, typescript: typeof o.ts === 'string' ? o.ts : null };
        } catch {
          info = null;
        }
      }
      nodeProbes.set(node, { at: Date.now(), info });
      resolve(info);
    });
  });
}

/** Strip-types flags for this node: [] when it strips by default, the flag for 22.6+, else undefined (unsupported). */
export function typescriptFlags(info: NodeInfo): string[] | undefined {
  if (info.typescript) return [];
  const [major = 0, minor = 0] = info.version.split('.').map((n) => Number.parseInt(n, 10));
  if (major > 22 || (major === 22 && minor >= 6)) return ['--experimental-strip-types', '--disable-warning=ExperimentalWarning'];
  return undefined;
}

/**
 * The PATH a JavaScript or TypeScript run (or an npm install) gets: Distill's Node's folder first, so a script
 * that spawns `node`, a `#!/usr/bin/env node` bin and npm's lifecycle scripts find the same Node, never an
 * older one earlier on the login shell's PATH.
 */
export function nodeSearchPath(nodePath: string, searchPath: string): string {
  const dir = path.dirname(nodePath);
  return [dir, ...searchPath.split(':').filter((d) => d && d !== dir)].join(':');
}

/**
 * zsh and python3 come from the login shell's PATH (python3 from the folder's .venv once packages are
 * installed). JavaScript and TypeScript always run on `nodePath`, the Node Distill's core runs on
 * (process.execPath): Distill already needs that Node, npm installs packages with it (native addons are built
 * for the Node that installs them), and an older node earlier on the login PATH can't import ESM or strip types.
 */
export async function resolveRuntime(
  interpreter: CollectorInterpreter,
  folder: string | null,
  searchPath: string,
  env: NodeJS.ProcessEnv,
  nodePath: string = process.execPath,
): Promise<Runtime> {
  if (interpreter === 'python3' && folder) {
    const venv = path.join(folder, '.venv', 'bin', 'python3');
    if (isExecutable(venv)) return { command: venv, args: [], runtime: { label: 'python3 (.venv)', path: venv } };
  }
  if (interpreter === 'zsh' || interpreter === 'python3') {
    const found = findOnPath(interpreter, searchPath);
    if (!found) return { error: `${interpreter} isn't on your PATH.` };
    return { command: found, args: [], runtime: { label: interpreter, path: found } };
  }
  if (!isExecutable(nodePath)) return { error: `Distill's Node (${nodePath}) isn't there any more.` };
  const info = await probeNode(nodePath, env);
  if (!info) return { error: `Couldn't ask ${nodePath} for its version.` };
  const runtime: RuntimeInfo = { label: `Node ${info.version}`, path: nodePath, version: info.version };
  if (interpreter === 'node') return { command: nodePath, args: [], runtime };
  if (folder) {
    const tsx = path.join(folder, 'node_modules', 'tsx', 'dist', 'cli.mjs');
    if (fs.existsSync(tsx)) return { command: nodePath, args: [tsx], runtime: { ...runtime, label: `${runtime.label} with tsx` } };
  }
  const flags = typescriptFlags(info);
  if (!flags) {
    return {
      error: `TypeScript needs Node 22.6 or later; Distill runs on Node ${info.version} (${nodePath}). Choose a newer Node for Distill, or add tsx to package.json and Install.`,
    };
  }
  return { command: nodePath, args: flags, runtime };
}

/**
 * The npm that ships with `nodePath`, run by that Node: `<bin>/../lib/node_modules/npm/bin/npm-cli.js`, or what
 * `<bin>/npm` links to when that is a .js file. Never through npm's `#!/usr/bin/env node` shebang, which finds
 * whichever node comes first on PATH. Last resort: `<bin>/npm` itself (the install puts `<bin>` first on PATH).
 */
export function npmFor(nodePath: string): { command: string; args: string[] } | undefined {
  const dir = path.dirname(nodePath);
  const cli = path.resolve(dir, '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js');
  if (fs.existsSync(cli)) return { command: nodePath, args: [cli] };
  const sibling = path.join(dir, 'npm');
  let real: string;
  try {
    real = fs.realpathSync(sibling);
  } catch {
    return undefined;
  }
  if (real.endsWith('.js')) return { command: nodePath, args: [real] };
  return isExecutable(sibling) ? { command: sibling, args: [] } : undefined;
}

function isExecutable(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// ───────────── installs ─────────────

export interface InstallStep {
  command: string;
  args: string[];
  /** The banner line in the output when it isn't `<command's name> <args>` (npm run by its Node). */
  label?: string;
}

/** What an install runs, or why it can't. Steps for Python are computed after a clean removed .venv. */
export function planInstall(
  name: CollectorManifestName,
  folder: string,
  searchPath: string,
  nodePath: string = process.execPath,
): { display: string; steps: InstallStep[] } | { error: string } {
  if (name === 'package.json') {
    const npm = npmFor(nodePath);
    if (!npm) return { error: `There's no npm next to Distill's Node (${nodePath}).` };
    const args = ['install', '--no-audit', '--no-fund'];
    const display = `npm ${args.join(' ')}`;
    return { display, steps: [{ command: npm.command, args: [...npm.args, ...args], label: display }] };
  }
  const venvPython = path.join(folder, '.venv', 'bin', 'python3');
  const steps: InstallStep[] = [];
  const display: string[] = [];
  if (!isExecutable(venvPython)) {
    const python = findOnPath('python3', searchPath);
    if (!python) return { error: `python3 isn't on your PATH.` };
    // --symlinks (macOS's default, made explicit): .venv/bin/python3 resolves to the same python3 binary, so
    // the Keychain sees the same program. Never --copies, and never --clear: an existing venv is reused.
    steps.push({ command: python, args: ['-m', 'venv', '--symlinks', '.venv'] });
    display.push('python3 -m venv --symlinks .venv');
  }
  const pip = ['-m', 'pip', 'install', '--disable-pip-version-check', '-r', 'requirements.txt'];
  steps.push({ command: venvPython, args: pip });
  display.push(`.venv/bin/python3 ${pip.join(' ')}`);
  return { display: display.join(' && '), steps };
}

/** Mask credentials an install might print: user:password@ in URLs, and _authToken / token / password values. */
export function redact(text: string): string {
  return text
    .replace(/(\b[a-z][a-z0-9+.-]*:\/\/)[^\s/@:]+:[^\s/@]+@/gi, '$1***@')
    .replace(/((?:_authToken|_auth|_password|authToken|token|password|passwd)\s*[=:]\s*)("?)[^\s"']+\2/gi, '$1$2***$2');
}

export interface InstallOutcome {
  exitCode: number | null;
  signal: string | null;
  timedOut: boolean;
  stopped: boolean;
  spawnError?: string;
  outputTail: string;
}

/** Runs the steps one after another (a failing step ends it). The handle's stop() ends the current step. */
export function startInstall(input: {
  steps: InstallStep[];
  cwd: string;
  env: NodeJS.ProcessEnv;
  timeoutMs?: number;
  killGraceMs?: number;
  onOutput?: (text: string) => void;
}): { done: Promise<InstallOutcome>; stop(): void } {
  const tail = new Tail();
  let current: ScriptHandle | undefined;
  let stopped = false;
  const deadline = Date.now() + (input.timeoutMs ?? INSTALL_TIMEOUT_MS);
  const done = (async (): Promise<InstallOutcome> => {
    let last: InstallOutcome = { exitCode: 0, signal: null, timedOut: false, stopped: false, outputTail: '' };
    for (const step of input.steps) {
      if (stopped) return { ...last, stopped: true, outputTail: redact(tail.text()) };
      const banner = Buffer.from(`$ ${step.label ?? `${path.basename(step.command)} ${step.args.join(' ')}`}\n`);
      tail.push(banner);
      input.onOutput?.(banner.toString('utf8'));
      current = startProcess({
        command: step.command,
        args: step.args,
        cwd: input.cwd,
        env: input.env,
        timeoutMs: Math.max(1, deadline - Date.now()),
        ...(input.killGraceMs !== undefined ? { killGraceMs: input.killGraceMs } : {}),
        onOutput: (_stream, chunk) => {
          tail.push(chunk);
          input.onOutput?.(redact(chunk.toString('utf8')));
        },
      });
      if (stopped) current.stop();
      const o = await current.done;
      last = { exitCode: o.exitCode, signal: o.signal, timedOut: o.timedOut, stopped: o.stopped || stopped, outputTail: '' };
      if (o.spawnError) last.spawnError = o.spawnError;
      if (o.spawnError || o.timedOut || last.stopped || o.exitCode !== 0) break;
    }
    return { ...last, outputTail: redact(tail.text()) };
  })();
  return {
    done,
    stop() {
      stopped = true;
      current?.stop();
    },
  };
}

/** <state>/collectors/installs/<id>.json: the newest install, and the manifest hash of the last one that succeeded. */
export class InstallStore {
  private cache = new Map<string, { last: CollectorInstall | null; installedSha256: string | null }>();
  constructor(readonly dir: string) {}

  file(collectorId: string): string {
    return path.join(this.dir, `${collectorId.replace(/[^A-Za-z0-9_-]/g, '_')}.json`);
  }

  get(collectorId: string): { last: CollectorInstall | null; installedSha256: string | null } {
    const hit = this.cache.get(collectorId);
    if (hit) return hit;
    const raw = fs.existsSync(this.file(collectorId)) ? readJSON(this.file(collectorId)) : undefined;
    const entry = {
      last: isObject(raw) ? (decodeInstall(raw.last) ?? null) : null,
      installedSha256: isObject(raw) ? (str(raw.installedSha256) ?? null) : null,
    };
    // An install left running by a core that stopped never finishes.
    if (entry.last?.result === 'running') {
      entry.last.result = 'failed';
      entry.last.error = { code: 'interrupted', message: 'Distill stopped during this install.' };
    }
    this.cache.set(collectorId, entry);
    return entry;
  }

  put(install: CollectorInstall): void {
    const entry = this.get(install.collectorId);
    entry.last = structuredClone(install);
    if (install.result === 'success') entry.installedSha256 = install.manifestSha256;
    writeFileAtomic(this.file(install.collectorId), encodeJSON({ version: 1, last: entry.last, installedSha256: entry.installedSha256 }));
  }

  remove(collectorId: string): void {
    this.cache.delete(collectorId);
    fs.rmSync(this.file(collectorId), { force: true });
  }
}
