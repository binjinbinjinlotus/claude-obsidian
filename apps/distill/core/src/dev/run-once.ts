/**
 * Headless single batch through the TS core (port of Swift `Distill --run-once`).
 *
 *   node --import tsx src/dev/run-once.ts --vault PATH --state-dir PATH
 *     [--queue PATH] [--model ID] [--effort LEVEL] [--product-root PATH]
 *     [--claude-path PATH] [--approve]
 *
 * --state-dir (or DISTILL_STATE_DIR) is required so a dev run never touches
 * the real ~/Library/Application Support/Distill. Use a throwaway vault.
 */
import fs from 'node:fs';
import path from 'node:path';
import type { Job } from '../contracts.js';
import { createEngine } from '../engine/index.js';
import { totalCostUSD } from '../store/jobs.js';
import { statePaths } from '../store/paths.js';
import { defaultQueueDirectory } from '../store/settings.js';

const argv = process.argv.slice(2);
const value = (flag: string): string | undefined => {
  const i = argv.indexOf(flag);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
};

function fail(message: string): never {
  process.stderr.write(`error: ${message}\n`);
  process.exit(2);
}

function report(job: Job): void {
  console.log(`state: ${job.state}  cost: $${totalCostUSD(job).toFixed(3)}`);
  const last = job.turns.at(-1);
  if (last) console.log(`last turn (${last.author}):\n${last.text}`);
  const a = job.approval;
  if (a) {
    if (a.plan) console.log(`plan ${a.plan.operation_id} valid=${a.plan.valid} sha=${a.plan.approval_sha256}\n  ${a.plan.changed_paths.join('\n  ')}`);
    if (a.planError) console.log(`plan error: ${a.planError}`);
    if (a.questions.length) console.log(`questions: ${JSON.stringify(a.questions)}`);
    if (a.denials.length) console.log(`denials: ${JSON.stringify(a.denials)}`);
  }
  if (job.changedPaths.length) console.log(`changed: ${JSON.stringify(job.changedPaths)}`);
  if (job.error) console.log(`error: ${job.error}`);
}

/** Session id of every saved turn envelope, to prove all turns shared one session. */
function turnSessions(job: Job): string[] {
  const dir = path.join(job.vaultPath, '.vault-meta', 'worker', job.id);
  let names: string[] = [];
  try {
    names = fs.readdirSync(dir).filter((n) => /^turn-\d+\.json$/.test(n));
  } catch {
    return [];
  }
  names.sort((a, b) => Number(a.slice(5, -5)) - Number(b.slice(5, -5)));
  return names.map((n) => {
    try {
      const env = JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8')) as { session_id?: string };
      return `${n}: ${env.session_id ?? '?'}`;
    } catch {
      return `${n}: unreadable`;
    }
  });
}

async function main(): Promise<void> {
  const vaultArg = value('--vault') ?? fail('--vault is required');
  const stateDir = value('--state-dir') ?? process.env.DISTILL_STATE_DIR ?? fail('--state-dir (or DISTILL_STATE_DIR) is required');
  const engine = createEngine({ paths: statePaths(path.resolve(stateDir)), tickMs: 2000 });
  const vault = path.resolve(vaultArg);
  const settings = engine.getSettings();
  const profile = { path: vault, queueDirectory: path.resolve(value('--queue') ?? defaultQueueDirectory(vault)) };
  const vaults = settings.vaults.filter((v) => v.path !== vault).concat(profile);
  const patch: Parameters<typeof engine.updateSettings>[0] = { vaults, activeVaultPath: vault, autoProcessEnabled: false };
  const model = value('--model');
  if (model) patch.model = model;
  const effort = value('--effort');
  if (effort) patch.taskDefaults = { ...settings.taskDefaults, ingest: { runnerID: 'claude-code', model: model ?? settings.model, effort } };
  const root = value('--product-root');
  if (root) patch.productRoot = path.resolve(root);
  const claude = value('--claude-path');
  if (claude) patch.claudePath = claude;
  await engine.updateSettings(patch);

  const status = await engine.status();
  if (status.problems[0]) fail(status.problems[0].message);
  const job = await engine.processQueue({ force: true });
  if (!job) fail(`Nothing to process in ${profile.queueDirectory}`);
  console.log(`job ${job.id} session ${job.sessionID} files ${JSON.stringify(job.files)}`);

  const approve = argv.includes('--approve');
  let approved = false;
  for (;;) {
    await engine.whenIdle();
    const j = engine.getJob(job.id);
    if (!j) fail('job vanished');
    report(j);
    if (j.state === 'awaitingApproval' && approve && !approved && j.approval?.plan?.valid && j.approval.bundlePath) {
      approved = true;
      console.log(`approving ${j.approval.plan.approval_sha256}`);
      await engine.approve(j.id);
      continue;
    }
    console.log(`turn sessions:\n  ${turnSessions(j).join('\n  ')}`);
    await engine.stop();
    process.exit(j.state === 'failed' ? 1 : 0);
  }
}

main().catch((err: unknown) => fail(err instanceof Error ? err.message : String(err)));
