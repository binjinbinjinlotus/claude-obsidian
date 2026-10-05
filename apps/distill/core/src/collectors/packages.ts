/**
 * v6: how a script runs (its runtime), and package installs for Distill-managed scripts.
 *
 * Runtimes, all found on the login shell's PATH:
 * - zsh, node: as before.
 * - python3: the folder's .venv/bin/python3 once packages were installed there, else python3.
 * - typescript: node with its built-in type stripping (on by default from Node 22.18 / 23.6; Node 22.6–22.17
 *   needs --experimental-strip-types). When the folder has tsx installed (a devDependency the user added),
 *   tsx runs it instead, for syntax stripping can't handle (enum, namespace). Older Node: a clear error.
 *
 * Installs (cwd = the script's folder, same environment as a run, 10-minute timeout, Stop):
 * - package.json: `npm install --no-audit --no-fund` with the npm next to the node that runs scripts.
 * - requirements.txt: `python3 -m venv .venv` (when missing), then `.venv/bin/python3 -m pip install -r requirements.txt`.
 * Output is stdout and stderr interleaved, last 64 KB, with URL credentials and auth tokens masked.
 */
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import type { CollectorInstall, CollectorInterpreter, CollectorManifestName } from '../contracts.js';
import { decodeInstall } from './store.js';
import { findOnPath, startProcess, Tail, type ScriptHandle } from './script.js';
import { encodeJSON, isObject, readJSON, str, writeFileAtomic } from '../store/json.js';

export const INSTALL_TIMEOUT_MS = 10 * 60 * 1000;
const PROBE_TTL_MS = 10 * 60 * 1000;

export type Runtime = { command: string; args: string[] } | { error: string };

interface NodeInfo {
  version: string;
  typescript: string | null;
}
const nodeProbes = new Map<string, { at: number; info: NodeInfo | null }>();

/** `node -p` for its version and process.features.typescript; cached 10 minutes per node binary. */
export function probeNode(node: string, env: NodeJS.ProcessEnv): Promise<NodeInfo | null> {
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

export async function resolveRuntime(
  interpreter: CollectorInterpreter,
  folder: string | null,
  searchPath: string,
  env: NodeJS.ProcessEnv,
): Promise<Runtime> {
  if (interpreter === 'python3' && folder) {
    const venv = path.join(folder, '.venv', 'bin', 'python3');
    if (isExecutable(venv)) return { command: venv, args: [] };
  }
  const binary = interpreter === 'typescript' ? 'node' : interpreter;
  const found = findOnPath(binary, searchPath);
  if (!found) return { error: interpreter === 'typescript' ? `node isn't on your PATH (TypeScript runs on Node).` : `${interpreter} isn't on your PATH.` };
  if (interpreter !== 'typescript') return { command: found, args: [] };
  if (folder) {
    const tsx = path.join(folder, 'node_modules', 'tsx', 'dist', 'cli.mjs');
    if (fs.existsSync(tsx)) return { command: found, args: [tsx] };
  }
  const info = await probeNode(found, env);
  if (!info) return { error: `Couldn't ask ${found} for its version.` };
  const flags = typescriptFlags(info);
  if (!flags) {
    return { error: `TypeScript needs Node 22.6 or later; ${found} is ${info.version}. Update Node, or add tsx to package.json and Install.` };
  }
  return { command: found, args: flags };
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
}

/** What an install runs, or why it can't. Steps for Python are computed after a clean removed .venv. */
export function planInstall(name: CollectorManifestName, folder: string, searchPath: string): { display: string; steps: InstallStep[] } | { error: string } {
  if (name === 'package.json') {
    const node = findOnPath('node', searchPath);
    const sibling = node ? path.join(path.dirname(node), 'npm') : undefined;
    const npm = sibling && isExecutable(sibling) ? sibling : findOnPath('npm', searchPath);
    if (!npm) return { error: `npm isn't on your PATH.` };
    const args = ['install', '--no-audit', '--no-fund'];
    return { display: `npm ${args.join(' ')}`, steps: [{ command: npm, args }] };
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
      const banner = Buffer.from(`$ ${path.basename(step.command)} ${step.args.join(' ')}\n`);
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
