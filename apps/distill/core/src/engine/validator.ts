import fs from 'node:fs';
import path from 'node:path';
import type { RunnerRegistry, Settings, SetupProblem } from '../contracts.js';
import { activeVault, AI_TASKS, coreScriptPath, selectionFor } from '../store/settings.js';

export function isVault(p: string): boolean {
  return fs.existsSync(path.join(p, '.claude-obsidian.json'));
}

export const problem = {
  noVault: (): SetupProblem => ({ code: 'noVault', message: 'No vault selected.' }),
  notAVault: (p: string): SetupProblem => ({
    code: 'notAVault',
    message: `${p} has no .claude-obsidian.json (run \`claude-obsidian.py init\` or \`adopt\` first).`,
  }),
  missingCore: (p: string): SetupProblem => ({ code: 'missingCore', message: `claude-obsidian core not found at ${p}.` }),
  queueIsVaultInternal: (p: string): SetupProblem => ({
    code: 'queueIsVaultInternal',
    message: `Queue directory ${p} is inside the vault. Use the vault's inbox/ or a folder outside the vault.`,
  }),
  unknownRunner: (id: string): SetupProblem => ({
    code: 'unknownRunner',
    message: `AI runner ${id} is not available in this build.`,
  }),
};

/** realpath of `p`, or of its nearest existing ancestor joined with the rest (a queue folder may not exist yet). */
export function realish(p: string): string {
  const abs = path.resolve(p);
  const rest: string[] = [];
  let cur = abs;
  for (;;) {
    try {
      return path.join(fs.realpathSync(cur), ...rest.reverse());
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return abs;
      rest.push(path.basename(cur));
      cur = parent;
    }
  }
}

/** `child` is `parent` or inside it (folder boundaries respected). */
export function isWithin(child: string, parent: string): boolean {
  return child === parent || child.startsWith(parent.endsWith('/') ? parent : parent + '/');
}

/**
 * A queue folder inside the vault is allowed only when it is exactly `<vault>/inbox` (the user's
 * intake, which claude-obsidian keeps outside its transactions). Anything else inside the vault
 * (its root, `wiki/`, `.raw/`, `.vault-meta/`, a subfolder of `inbox/`) would let a batch or a
 * queue write touch vault files without a reviewed transaction. Decision 2026-10-04.
 */
export function queuePlacementProblem(vaultPath: string, queueDirectory: string): SetupProblem | undefined {
  const vault = realish(vaultPath);
  const queue = realish(queueDirectory);
  if (!isWithin(queue, vault)) return undefined;
  if (queue === path.join(vault, 'inbox')) return undefined;
  return problem.queueIsVaultInternal(path.resolve(queueDirectory));
}

/** Swift `SetupValidator.problems`: these block batching and are listed in Settings. */
export function setupProblems(s: Settings, runners: RunnerRegistry): SetupProblem[] {
  const out: SetupProblem[] = [];
  const v = activeVault(s);
  if (v) {
    if (!isVault(v.path)) out.push(problem.notAVault(v.path));
    const placement = queuePlacementProblem(v.path, v.queueDirectory);
    if (placement) out.push(placement);
  } else {
    out.push(problem.noVault());
  }
  // Every runner that some task is set to use must be ready. Action tasks don't
  // block batching: finding actions reports its own failure after the apply.
  const used = [...new Set(AI_TASKS.filter((t) => !t.startsWith('action')).map((t) => selectionFor(s, t).runnerID))].sort();
  for (const id of used) {
    const runner = runners.get(id);
    if (!runner) {
      out.push(problem.unknownRunner(id));
      continue;
    }
    out.push(...runner.problems(s));
  }
  const core = coreScriptPath(s);
  if (!fs.existsSync(core)) out.push(problem.missingCore(core));
  return out;
}
