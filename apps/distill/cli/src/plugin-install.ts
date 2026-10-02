import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CliError } from './client.js';

/** apps/distill/plugin, resolved from this module (src/ or dist/). Override: DISTILL_PLUGIN_DIR. */
export function defaultPluginDir(env: NodeJS.ProcessEnv): string {
  return env.DISTILL_PLUGIN_DIR ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'plugin');
}

export interface PluginAction {
  action: 'link' | 'copy' | 'replace' | 'unchanged' | 'conflict' | 'run';
  skill?: string;
  source?: string;
  destination?: string;
  command?: string[];
  status?: number | null;
}

export interface PluginInstallResult {
  target: 'claude' | 'codex';
  dryRun: boolean;
  pluginDir: string;
  actions: PluginAction[];
  notes: string[];
}

function readJSON(file: string): Record<string, unknown> {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')) as Record<string, unknown>;
  } catch (err) {
    throw new CliError(`cannot read ${file}: ${(err as Error).message}`, 'plugin_manifest');
  }
}

export function listSkills(pluginDir: string): { name: string; dir: string }[] {
  const root = path.join(pluginDir, 'skills');
  if (!fs.existsSync(root)) throw new CliError(`no skills directory at ${root}`, 'plugin_missing');
  return fs
    .readdirSync(root, { withFileTypes: true })
    .filter((d) => d.isDirectory() && fs.existsSync(path.join(root, d.name, 'SKILL.md')))
    .map((d) => ({ name: d.name, dir: path.join(root, d.name) }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** The two `claude plugin` commands that install the Distill plugin from the local marketplace. */
export function claudeCommands(pluginDir: string): string[][] {
  const marketplace = readJSON(path.join(pluginDir, '.claude-plugin', 'marketplace.json'));
  const plugin = readJSON(path.join(pluginDir, '.claude-plugin', 'plugin.json'));
  return [
    ['claude', 'plugin', 'marketplace', 'add', pluginDir],
    ['claude', 'plugin', 'install', `${String(plugin.name)}@${String(marketplace.name)}`],
  ];
}

export interface InstallOptions {
  target: 'claude' | 'codex';
  dryRun: boolean;
  copy: boolean;
  force: boolean;
  home: string;
  pluginDir: string;
  /** Runs one argv; returns its exit status (default: spawnSync with inherited stdio). */
  run?: (argv: string[]) => number | null;
}

const defaultRun = (argv: string[]): number | null => {
  const r = spawnSync(argv[0]!, argv.slice(1), { stdio: 'inherit' });
  if (r.error) throw new CliError(`cannot run ${argv[0]}: ${r.error.message}`, 'command_failed');
  return r.status;
};

export function installPlugin(opts: InstallOptions): PluginInstallResult {
  if (!fs.existsSync(path.join(opts.pluginDir, '.claude-plugin', 'plugin.json'))) {
    throw new CliError(`no Distill plugin at ${opts.pluginDir}`, 'plugin_missing');
  }
  const result: PluginInstallResult = { target: opts.target, dryRun: opts.dryRun, pluginDir: opts.pluginDir, actions: [], notes: [] };

  if (opts.target === 'claude') {
    const run = opts.run ?? defaultRun;
    for (const command of claudeCommands(opts.pluginDir)) {
      if (opts.dryRun) {
        result.actions.push({ action: 'run', command });
        continue;
      }
      const status = run(command);
      result.actions.push({ action: 'run', command, status });
      if (status !== 0) throw new CliError(`\`${command.join(' ')}\` failed (exit ${status})`, 'command_failed');
    }
    result.notes.push('Restart Claude Code to load the skills: /distill:distill-ask and /distill:distill-note.');
    return result;
  }

  const skillsRoot = path.join(opts.home, '.agents', 'skills');
  const planned: PluginAction[] = [];
  for (const skill of listSkills(opts.pluginDir)) {
    const destination = path.join(skillsRoot, skill.name);
    const mode = opts.copy ? 'copy' : 'link';
    let existing: fs.Stats | null = null;
    try {
      existing = fs.lstatSync(destination);
    } catch {
      existing = null;
    }
    if (!existing) {
      planned.push({ action: mode, skill: skill.name, source: skill.dir, destination });
      continue;
    }
    const sameLink =
      existing.isSymbolicLink() && !opts.copy && fs.realpathSync(destination) === fs.realpathSync(skill.dir);
    if (sameLink) planned.push({ action: 'unchanged', skill: skill.name, source: skill.dir, destination });
    else if (opts.force) planned.push({ action: 'replace', skill: skill.name, source: skill.dir, destination });
    else planned.push({ action: 'conflict', skill: skill.name, source: skill.dir, destination });
  }
  result.actions = planned;
  result.notes.push(
    `Codex loads user skills from ${skillsRoot}. Older Codex builds used ~/.codex/skills/; if yours does not list the skills, link them there too.`,
  );

  const conflicts = planned.filter((a) => a.action === 'conflict');
  if (conflicts.length > 0 && !opts.dryRun) {
    throw new CliError(
      `already exists (not ours): ${conflicts.map((c) => c.destination).join(', ')}. Re-run with --force to replace.`,
      'conflict',
    );
  }
  if (opts.dryRun) return result;

  fs.mkdirSync(skillsRoot, { recursive: true });
  for (const a of planned) {
    if (a.action === 'unchanged' || a.action === 'conflict') continue;
    if (a.action === 'replace') fs.rmSync(a.destination!, { recursive: true, force: true });
    if (opts.copy) fs.cpSync(a.source!, a.destination!, { recursive: true });
    else fs.symlinkSync(a.source!, a.destination!, 'dir');
  }
  return result;
}
