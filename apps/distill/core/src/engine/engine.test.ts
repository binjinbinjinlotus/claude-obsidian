import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type {
  AgentRunner,
  CoreEvent,
  Job,
  RunRequest,
  RunResult,
  RunnerCapability,
} from '../contracts.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { writableRoots } from '../runners/codex.js';
import { cancelledError, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { statePaths } from '../store/paths.js';
import { RECOVERY_NOTE } from '../store/jobs.js';
import { createEngine, type Engine } from './index.js';

type Step = Partial<RunResult> & { hang?: boolean };

/** Scripted runner: each turn pops the next step and records the request. */
class FakeRunner implements AgentRunner {
  readonly id = 'claude-code';
  readonly displayName = 'Fake';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly requests: RunRequest[] = [];
  constructor(
    readonly steps: Step[],
    readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>([
      'agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput',
    ]),
  ) {}
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    await new Promise((r) => setImmediate(r)); // a real turn never finishes within one microtask
    const step = this.steps.shift() ?? { structured: { status: 'failed', summary: 'no more steps' } };
    if (step.hang) {
      await new Promise<void>((_, reject) => {
        if (request.signal?.aborted) reject(cancelledError());
        request.signal?.addEventListener('abort', () => reject(cancelledError()), { once: true });
      });
    }
    const sid = 'start' in request.session ? request.session.start : request.session.resume;
    const { hang: _hang, ...rest } = step;
    const result: RunResult = { sessionID: sid, resultText: '', isError: false, costUSD: 0.01, denials: [], raw: '', ...rest };
    result.raw = JSON.stringify({ session_id: sid, structured_output: result.structured ?? null });
    return result;
  }
}

const PLAN = {
  schema: 'claude-obsidian.transaction-plan.v1',
  operation_id: 'op-1',
  operation_type: 'ingest',
  valid: true,
  changed_paths: ['wiki/a.md'],
  approval_sha256: 'f'.repeat(64),
};

interface Harness {
  root: string;
  vault: string;
  queue: string;
  engine: Engine;
  runner: FakeRunner;
  inspectCalls: string[][];
  events: CoreEvent[];
  bundle: (job: Job) => string;
}

let h: Harness;
let tmp: string;

function setup(
  steps: Step[],
  o: {
    runner?: FakeRunner; jobs?: unknown; queueIsInbox?: boolean; tickMs?: number; now?: () => Date; settings?: Record<string, unknown>;
    onJobApplied?: (job: Job) => void;
    /** What `transaction apply` returns (core-applies path); inspect always returns PLAN. */
    apply?: () => ProcessOutput;
  } = {},
): Harness {
  const root = tmp;
  const vault = path.join(root, 'vault');
  const product = path.join(root, 'product');
  const state = path.join(root, 'state');
  fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.mkdirSync(path.join(product, 'scripts'), { recursive: true });
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '# fake core\n');
  const queue = o.queueIsInbox ? path.join(vault, 'inbox') : path.join(root, 'queue');
  fs.mkdirSync(queue, { recursive: true });
  fs.mkdirSync(state, { recursive: true });
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({
      vaults: [{ path: vault, queueDirectory: queue }],
      activeVaultPath: vault,
      productRoot: product,
      settleSeconds: 0,
      pythonPath: '/usr/bin/python3',
      autoProcessEnabled: false,
      // The fake runner is scripted per turn; queue-folder label suggestions are tested in labels.test.ts.
      labeling: { autoLabelQueueFolder: false },
      ...o.settings,
    }),
  );
  if (o.jobs) fs.writeFileSync(path.join(state, 'jobs.json'), JSON.stringify(o.jobs));
  const runner = o.runner ?? new FakeRunner(steps);
  const inspectCalls: string[][] = [];
  const launch = async (opts: RunProcessOptions): Promise<ProcessOutput> => {
    inspectCalls.push([opts.executable, ...opts.args]);
    if (opts.args.includes('apply') && o.apply) return o.apply();
    return { status: 0, stdout: Buffer.from(JSON.stringify(PLAN)), stderr: Buffer.alloc(0) };
  };
  const engine = createEngine({
    paths: statePaths(state),
    runners: createRunnerRegistry([runner]),
    launch,
    tickMs: o.tickMs ?? 60_000,
    ...(o.now ? { now: o.now } : {}),
    ...(o.onJobApplied ? { onJobApplied: o.onJobApplied } : {}),
  });
  const events: CoreEvent[] = [];
  engine.subscribe((e) => events.push(e));
  return {
    root, vault, queue, engine, runner, inspectCalls, events,
    bundle: (job) => path.join(vault, '.vault-meta', 'worker', job.id, 'bundle.json'),
  };
}

function needsApproval(bundle: string): Step {
  return { structured: { status: 'needs_approval', summary: 'Adds a page.', bundle_path: bundle } };
}

beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-engine-')));
});
afterEach(async () => {
  await h?.engine.stop();
  fs.rmSync(tmp, { recursive: true, force: true });
});

async function firstJob(): Promise<Job> {
  fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
  const job = await h.engine.processQueue({ force: true });
  assert.ok(job, 'a job was created');
  return job;
}

describe('engine state machine', () => {
  test('needs_approval → approve grants exactly the apply rule → done', async () => {
    h = setup([]);
    // The bundle path depends on the job id, so script the first step lazily.
    const steps = h.runner.steps;
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const originalRun = h.runner.run.bind(h.runner);
    h.runner.run = async (req) => {
      if (h.runner.requests.length === 0) {
        const jobID = h.engine.listJobs()[0]!.id;
        steps.push(needsApproval(path.join(h.vault, '.vault-meta/worker', jobID, 'bundle.json')));
        // The model's changed_paths are not trusted: the plan's are recorded.
        steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: 'op-1', changed_paths: ['wiki/model-says.md'] } });
      }
      return originalRun(req);
    };
    const created = await h.engine.processQueue({ force: true });
    assert.ok(created);
    assert.equal(created.state, 'running');
    assert.deepEqual(created.files, ['inbox/a.md']);
    assert.ok(fs.existsSync(path.join(h.vault, 'inbox', 'a.md')), 'moved into the inbox');
    assert.equal(fs.existsSync(path.join(h.queue, 'a.md')), false);
    await h.engine.whenIdle();

    let job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.deepEqual(job.approval?.plan, {
      operation_id: 'op-1', operation_type: 'ingest', valid: true, changed_paths: ['wiki/a.md'], approval_sha256: PLAN.approval_sha256,
    });
    assert.equal(job.approval?.bundlePath, h.bundle(job));
    assert.deepEqual(h.inspectCalls[0]!.slice(1), [
      path.join(h.root, 'product/scripts/claude-obsidian.py'), 'transaction', 'inspect', h.bundle(job), '--vault', h.vault,
    ]);
    assert.ok(fs.existsSync(path.join(h.vault, '.vault-meta/worker', job.id, 'turn-1.json')), 'raw envelope saved');

    await h.engine.approve(job.id);
    await h.engine.whenIdle();
    job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    assert.equal(job.operationID, 'op-1');
    assert.deepEqual(job.changedPaths, ['wiki/a.md'], 'from the inspected plan, not the model');
    assert.equal(job.approval, undefined);
    assert.equal(job.turns.at(-1)!.text, 'Applied op-1:\n- wiki/a.md');
    assert.ok(fs.existsSync(path.join(h.vault, '.vault-meta/worker', job.id, 'turn-3.json')));
    assert.ok(job.turns.some((t) => t.author === 'user' && t.text === `Approved op-1 (${'f'.repeat(12)}…)`));

    const [first, second] = h.runner.requests;
    assert.deepEqual(first!.session, { start: job.sessionID });
    assert.deepEqual(second!.session, { resume: job.sessionID });
    assert.ok(!first!.allowedTools.some((t) => t.includes('transaction apply')), 'phase 1 never allows apply');
    const applyRules = second!.allowedTools.filter((t) => t.includes('transaction apply'));
    const core = path.join(h.root, 'product/scripts/claude-obsidian.py');
    assert.deepEqual(applyRules, [
      `Bash(python3 ${core} transaction apply ${h.bundle(job)} --vault ${h.vault} --approved-plan-sha256 ${PLAN.approval_sha256})`,
    ]);
    assert.equal(first!.workingDirectory, h.vault);
    assert.equal(first!.environment?.CLAUDE_OBSIDIAN_VAULT, h.vault);
    assert.ok(first!.prompt.includes('inbox/a.md'));
    // Every runner gets the skill's absolute path (Codex loads no plugin).
    assert.ok(first!.prompt.includes(`read ${path.join(h.root, 'product/skills/wiki-ingest/SKILL.md')} with the Read tool`));
    assert.ok(second!.prompt.includes('APPROVED operation op-1'));
    const persisted = JSON.parse(fs.readFileSync(path.join(h.root, 'state/jobs.json'), 'utf8'));
    assert.equal(persisted[0].state, 'completed');
    assert.ok(h.events.some((e) => e.type === 'job' && e.job.state === 'awaitingApproval'));
  });

  test('reply resumes the same session with the reply prompt', async () => {
    h = setup([
      { structured: { status: 'needs_input', summary: 'Which title?', questions: ['Which title?'] } },
      { structured: { status: 'nothing_to_do', summary: 'Nothing durable.' } },
    ]);
    const created = await firstJob();
    await h.engine.whenIdle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.deepEqual(job.approval?.questions, ['Which title?']);
    await assert.rejects(h.engine.approve(job.id), /no valid plan/);
    await assert.rejects(h.engine.reply(job.id, '   '), /empty/);
    await h.engine.reply(job.id, '  Use "Tea".  ');
    assert.equal(h.engine.getJob(job.id)!.state, 'running', 'running before the turn finishes');
    await assert.rejects(h.engine.reply(job.id, 'again'), /running/);
    await h.engine.whenIdle();
    job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    const second = h.runner.requests[1]!;
    assert.deepEqual(second.session, { resume: job.sessionID });
    assert.ok(second.prompt.includes('The user replied instead of approving:\n\nUse "Tea".'));
  });

  test('missing structured output becomes needs_input; is_error fails', async () => {
    h = setup([{ resultText: 'plain text' }, { resultText: 'boom', isError: true }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.approval?.summary, 'plain text');
    await h.engine.reply(job.id, 'go on');
    await h.engine.whenIdle();
    job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'failed');
    assert.equal(job.error, 'boom');
  });

  test('denials route to approval (deduped); allow grants rules for later turns', async () => {
    const denial = { toolName: 'Bash', input: { command: 'ls /tmp' } };
    h = setup([
      { structured: { status: 'failed', summary: 'Needed ls.' }, denials: [denial, { ...denial, input: { command: 'ls /tmp' } }] },
      { structured: { status: 'nothing_to_do', summary: 'ok' } },
    ]);
    const created = await firstJob();
    await h.engine.whenIdle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.deepEqual(job.approval?.denials, [denial]);
    await h.engine.allow(job.id, ['Bash(ls /tmp)']);
    await h.engine.whenIdle();
    job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    assert.deepEqual(job.grantedTools, ['Bash(ls /tmp)']);
    const second = h.runner.requests[1]!;
    assert.ok(second.allowedTools.includes('Bash(ls /tmp)'));
    assert.ok(second.prompt.includes('- Bash(ls /tmp)'));
  });

  test('done in the apply turn with another operation id records nothing; onJobApplied does not fire', async () => {
    const applied: Job[] = [];
    h = setup([], { onJobApplied: (j) => void applied.push(j) });
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    h.runner.steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: 'op-made-up', changed_paths: ['wiki/x.md'] } });
    await h.engine.whenIdle();
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    assert.equal(job.operationID, undefined);
    assert.deepEqual(job.changedPaths, []);
    assert.match(job.turns.at(-1)!.text, /^Nothing recorded as applied: the turn did not report the approved operation op-1 \(it reported op-made-up\)/);
    assert.equal(applied.length, 0);
    const last = h.events.filter((e) => e.type === 'progress').at(-1);
    assert.ok(last?.type === 'progress' && last.progress.finished && last.progress.message === 'Not applied', JSON.stringify(last));
  });

  test('done outside an approved apply turn records nothing, even with an operation id', async () => {
    const applied: Job[] = [];
    h = setup([{ structured: { status: 'done', summary: 'Applied it myself.', operation_id: 'op-1', changed_paths: ['wiki/a.md'] } }], {
      onJobApplied: (j) => void applied.push(j),
    });
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    assert.equal(job.operationID, undefined);
    assert.deepEqual(job.changedPaths, []);
    assert.equal(job.turns.at(-1)!.text, 'Nothing was applied: this turn had no approved plan to apply.');
    assert.equal(applied.length, 0);
  });

  test('a verified agent apply fires onJobApplied once with the plan paths', async () => {
    const applied: Job[] = [];
    h = setup([], { onJobApplied: (j) => void applied.push(j) });
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    h.runner.steps.push({ structured: { status: 'done', summary: 'ok', operation_id: 'op-1' } });
    await h.engine.whenIdle();
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    assert.deepEqual(applied.map((j) => [j.operationID, j.changedPaths]), [['op-1', ['wiki/a.md']]]);
    const last = h.events.filter((e) => e.type === 'progress').at(-1);
    assert.ok(last?.type === 'progress' && last.progress.finished && last.progress.message === 'Applied', JSON.stringify(last));
  });

  test('nothing_to_do never records changed paths', async () => {
    h = setup([{ structured: { status: 'nothing_to_do', summary: 'none', changed_paths: ['wiki/a.md'] } }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    assert.deepEqual(h.engine.getJob(created.id)!.changedPaths, []);
  });

  test('allow refuses rules that get round the approval gate, before changing anything', async () => {
    h = setup([{ structured: { status: 'failed', summary: 'Needed tools.' }, denials: [{ toolName: 'Bash', input: { command: 'ls /tmp' } }] }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    const dir = path.dirname(h.bundle(created));
    const before = h.engine.getJob(created.id)!;
    for (const rule of [
      'Bash',
      'Bash(*)',
      'Bash(python3:*)',
      'Bash(/usr/bin/python3:*)',
      'Bash(bash -c x)',
      `Bash(python3 ${path.join(h.root, 'product/scripts/claude-obsidian.py')} transaction apply x --vault ${h.vault} --approved-plan-sha256 abc)`,
      'Edit',
      `Edit(//${h.vault.slice(1)}/wiki/**)`,
      `Edit(/${dir}/../../../wiki/**)`,
      `Edit(/${path.join(path.dirname(dir), 'job-other')}/**)`,
      `Edit(/${dir}/*/x/**)`,
      'Edit(wiki/a.md)',
    ]) {
      await assert.rejects(h.engine.allow(created.id, ['Read(//tmp/x)', rule]), { code: 'invalid_request', message: /without your review/ }, rule);
    }
    const after = h.engine.getJob(created.id)!;
    assert.deepEqual(after.grantedTools, before.grantedTools);
    assert.equal(after.state, 'awaitingApproval');
    assert.equal(after.turns.length, before.turns.length);
    // Inside this job's own folder is fine.
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.allow(created.id, [`Edit(/${dir}/drafts/**)`, 'Bash(ls /tmp)']);
    await h.engine.whenIdle();
    assert.deepEqual(h.engine.getJob(created.id)!.grantedTools, ['Bash(ls /tmp)', `Edit(/${dir}/drafts/**)`]);
  });

  test('planningTools drops gate-breaking extraAllowedTools at use time; saved settings are untouched', async () => {
    const extras = ['Bash(python3:*)', 'Edit(//etc/**)', 'Bash', 'Read(//opt/docs/**)', 'WebFetch(domain:example.com)'];
    h = setup([{ structured: { status: 'nothing_to_do', summary: 'ok' } }], { settings: { extraAllowedTools: extras } });
    const saved = fs.readFileSync(path.join(h.root, 'state/settings.json'), 'utf8');
    const created = await firstJob();
    await h.engine.whenIdle();
    const tools = h.runner.requests[0]!.allowedTools;
    assert.ok(tools.includes('Read(//opt/docs/**)') && tools.includes('WebFetch(domain:example.com)'));
    for (const bad of ['Bash(python3:*)', 'Edit(//etc/**)', 'Bash']) assert.ok(!tools.includes(bad), bad);
    // Codex turns directory Edit rules into sandbox writable roots: it sees the filtered list.
    assert.deepEqual(writableRoots(h.runner.requests[0]!), [path.dirname(h.bundle(created))]);
    assert.equal(fs.readFileSync(path.join(h.root, 'state/settings.json'), 'utf8'), saved);
    assert.deepEqual(h.engine.getSettings().extraAllowedTools, extras);
  });

  test("with extraAllowedTools: [] (the owner's setup) the phase-1 tools are exactly the defaults", async () => {
    h = setup([{ structured: { status: 'nothing_to_do', summary: 'ok' } }], { settings: { extraAllowedTools: [] } });
    const created = await firstJob();
    await h.engine.whenIdle();
    const core = path.join(h.root, 'product/scripts/claude-obsidian.py');
    assert.deepEqual(h.runner.requests[0]!.allowedTools, [
      'Skill', 'Read', 'Glob', 'Grep',
      `Edit(/${path.dirname(h.bundle(created))}/**)`,
      `Bash(python3 ${core} transaction inspect:*)`,
      `Bash(python3 ${core} doctor:*)`,
      `Bash(python3 ${core} lint:*)`,
      'Bash(shasum -a 256:*)',
    ]);
  });

  test('done ignores denials', async () => {
    const denial = { toolName: 'Read', input: { file_path: '/etc/hosts' } };
    h = setup([{ structured: { status: 'done', summary: 'ok' }, denials: [denial] }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.state, 'completed');
  });

  test('reject ends the job and keeps inbox files', async () => {
    h = setup([{ structured: { status: 'needs_input', summary: '?' } }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    await h.engine.reject(created.id);
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'rejected');
    assert.equal(job.turns.at(-1)!.text, 'Rejected. Inbox files are kept; nothing was applied.');
    assert.ok(fs.existsSync(path.join(h.vault, 'inbox', 'a.md')));
    await assert.rejects(h.engine.reject(created.id), /not awaiting approval/);
  });

  test('one job per vault: a pending approval blocks the next batch', async () => {
    h = setup([{ structured: { status: 'needs_input', summary: '?' } }, { structured: { status: 'done', summary: 'ok' } }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    assert.equal(await h.engine.processQueue(), null);
    assert.equal(await h.engine.processQueue({ force: true }), null);
    const log = h.events.find((e) => e.type === 'log');
    assert.ok(log && log.type === 'log' && log.message === `Waiting for your decision on ${created.id}.`);
    assert.ok(fs.existsSync(path.join(h.queue, 'b.md')), 'blocked batches leave the queue alone');
    assert.equal((await h.engine.status()).pendingApprovals, 1);
    await h.engine.reject(created.id);
    const next = await h.engine.processQueue({ force: true });
    assert.ok(next);
    assert.deepEqual(next.files, ['inbox/b.md']);
    await h.engine.whenIdle();
  });

  test('bundle outside the job directory is refused, not inspected', async () => {
    h = setup([needsApproval('/tmp/elsewhere/bundle.json')]);
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.match(job.approval?.planError ?? '', /outside this job's directory/);
    assert.equal(h.inspectCalls.length, 0);
    await assert.rejects(h.engine.approve(job.id));
  });

  test('cancel aborts a running turn; reply resumes it', async () => {
    h = setup([{ hang: true }, { structured: { status: 'done', summary: 'ok' } }]);
    const created = await firstJob();
    assert.equal(h.engine.getJob(created.id)!.state, 'running');
    await h.engine.cancel(created.id);
    await h.engine.whenIdle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'cancelled');
    assert.equal(job.turns.at(-1)!.text, 'Cancelled. Reply to resume the session.');
    await h.engine.reply(job.id, 'continue');
    await h.engine.whenIdle();
    job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    assert.deepEqual(h.runner.requests[1]!.session, { resume: job.sessionID });
  });

  test('recovery: a job running at load awaits a reply that resumes its session', async () => {
    const vault = path.join(tmp, 'vault');
    const jobs = [{
      id: 'job-20261001-154200-ab12', kind: 'ingest', vaultPath: vault, files: ['inbox/a.md'], sessionID: 'sess-1',
      model: 'sonnet', state: 'running', createdAt: '2026-10-01T15:42:00Z', updatedAt: '2026-10-01T15:42:00Z',
      turns: [], grantedTools: [], changedPaths: [],
    }];
    h = setup([{ structured: { status: 'done', summary: 'ok' } }], { jobs });
    let job = h.engine.getJob('job-20261001-154200-ab12')!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.approval?.summary, RECOVERY_NOTE);
    await h.engine.reply(job.id, 'resume');
    await h.engine.whenIdle();
    job = h.engine.getJob(job.id)!;
    assert.equal(job.state, 'completed');
    assert.deepEqual(h.runner.requests[0]!.session, { resume: 'sess-1' });
    assert.equal(h.runner.requests[0]!.selection.runnerID, 'claude-code', 'old jobs without runnerID use Claude Code');
  });

  test('per-job runner/model/effort come from task defaults and are kept on the job', async () => {
    h = setup([{ structured: { status: 'needs_input', summary: '?' } }, { structured: { status: 'done', summary: 'ok' } }]);
    await h.engine.updateSettings({ taskDefaults: { ingest: { runnerID: 'claude-code', model: 'opus', effort: 'high' } } });
    const created = await firstJob();
    assert.equal(created.model, 'opus');
    assert.equal(created.effort, 'high');
    assert.equal(created.runnerID, 'claude-code');
    await h.engine.whenIdle();
    await h.engine.updateSettings({ taskDefaults: {}, model: 'haiku' });
    await h.engine.reply(created.id, 'ok');
    await h.engine.whenIdle();
    assert.deepEqual(h.runner.requests[1]!.selection, { runnerID: 'claude-code', model: 'opus', effort: 'high' });
  });

  test('a runner lacking the capabilities fails the job before running', async () => {
    const weak = new FakeRunner([], new Set<RunnerCapability>(['structuredOutput', 'vision']));
    h = setup([], { runner: weak });
    const created = await firstJob();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'failed');
    assert.match(job.error ?? '', /can't do ingest/);
    assert.equal(weak.requests.length, 0);
  });

  test('queue = inbox: files stay put and are claimed once', async () => {
    h = setup([{ structured: { status: 'done', summary: 'ok' } }], { queueIsInbox: true });
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    assert.equal(h.engine.listQueue().length, 1);
    const job = await h.engine.processQueue({ force: true });
    assert.ok(job);
    assert.deepEqual(job.files, ['inbox/a.md']);
    await h.engine.whenIdle();
    assert.ok(fs.existsSync(path.join(h.vault, 'inbox', 'a.md')));
    assert.equal(h.engine.listQueue().length, 0, 'claimed files leave the queue view');
    assert.equal(await h.engine.processQueue({ force: true }), null);
  });

  test('settle delay applies unless forced', async () => {
    h = setup([{ structured: { status: 'done', summary: 'ok' } }]);
    await h.engine.updateSettings({ settleSeconds: 3600 });
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    assert.equal(h.engine.listQueue()[0]!.settled, false);
    assert.equal(await h.engine.processQueue(), null);
    assert.ok(await h.engine.processQueue({ force: true }));
    await h.engine.whenIdle();
  });

  test('queue entries carry readyAt (a clock time), kind and problem', async () => {
    h = setup([]);
    await h.engine.updateSettings({ settleSeconds: 600 });
    const file = path.join(h.queue, 'a.md');
    fs.writeFileSync(file, '# A\n');
    const modified = new Date(Math.floor(Date.now() / 1000) * 1000 - 60_000 + 250);
    fs.utimesSync(file, modified, modified);
    const expected = new Date(Math.floor(modified.getTime() / 1000) * 1000 + 601_000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    const entry = h.engine.listQueue()[0]!;
    assert.equal(entry.kind, 'file');
    assert.equal(entry.settled, false);
    assert.equal(entry.readyAt, expected, 'modified + settle, rounded up to the second');
    assert.equal(entry.problem, undefined);
    fs.chmodSync(file, 0o000);
    try {
      const blocked = h.engine.listQueue()[0]!;
      if (process.getuid?.() !== 0) assert.match(blocked.problem ?? '', /can't read/);
    } finally {
      fs.chmodSync(file, 0o644);
    }
    await h.engine.updateSettings({ settleSeconds: 0 });
    const ready = h.engine.listQueue()[0]!;
    assert.equal(ready.settled, true);
    assert.equal(ready.readyAt, undefined, 'absent once ready');
  });

  test('notes skip the settle wait: the whole note set goes into the next batch', async () => {
    h = setup([{ structured: { status: 'done', summary: 'ok' } }]);
    await h.engine.updateSettings({ settleSeconds: 3600 });
    const img = path.join(tmp, 'card.png');
    fs.writeFileSync(img, 'PNGDATA');
    await h.engine.addNote({
      title: 'Gyokuro at 60 °C', text: 'Shop said 60 °C.', images: [{ path: img, mode: 'keep' }], suggest: 'none',
      source: 'in-person', labels: ['tea'],
    });
    fs.writeFileSync(path.join(h.queue, 'plain.md'), '# Plain\n');
    const entries = h.engine.listQueue();
    const byName = new Map(entries.map((e) => [e.name, e]));
    assert.deepEqual([...byName.keys()].sort(), ['Gyokuro at 60 °C.md', 'plain.md'], 'one row per note: members are not listed');
    const note = byName.get('Gyokuro at 60 °C.md')!;
    assert.equal(note.kind, 'note');
    assert.equal(note.settled, true);
    assert.equal(note.readyAt, undefined);
    assert.deepEqual(note.members, [path.join(h.queue, 'Gyokuro at 60 °C.distill.json'), path.join(h.queue, 'Gyokuro at 60 °C image 1.png')]);
    assert.deepEqual(note.note, { source: 'In person', labelsConfirmed: true, imageCount: 1 }, 'source id shown as its taxonomy label');
    assert.equal((await h.engine.status()).queueCount, 2, 'queueCount counts rows');
    assert.equal(byName.get('plain.md')?.kind, 'file');
    assert.equal(byName.get('plain.md')?.members, undefined);
    assert.equal(byName.get('plain.md')?.settled, false);
    assert.ok(byName.get('plain.md')?.readyAt);

    const job = await h.engine.processQueue();
    assert.ok(job, 'a scheduled (not forced) batch takes the note right away');
    assert.deepEqual([...job.files].sort(), [
      'inbox/Gyokuro at 60 °C image 1.png', 'inbox/Gyokuro at 60 °C.distill.json', 'inbox/Gyokuro at 60 °C.md',
    ]);
    assert.ok(fs.existsSync(path.join(h.queue, 'plain.md')), 'the plain file still waits');
    await h.engine.whenIdle();
  });

  test('a note row: free-text source passes through; unconfirmed labels; unreadable member carried up', async () => {
    h = setup([]);
    const img = path.join(tmp, 'card.png');
    fs.writeFileSync(img, 'PNGDATA');
    await h.engine.addNote({ title: 'Cli note', text: 'x', source: 'hallway chat', images: [{ path: img, mode: 'keep' }], suggest: 'none' });
    const [entry] = h.engine.listQueue();
    assert.deepEqual(entry!.note, { source: 'hallway chat', labelsConfirmed: false, imageCount: 1 });
    const image = path.join(h.queue, 'Cli note image 1.png');
    fs.chmodSync(image, 0o000);
    try {
      if (process.getuid?.() !== 0) {
        assert.match(h.engine.listQueue()[0]!.problem ?? '', /^Cli note image 1\.png: Distill can't read/);
        assert.equal(await h.engine.processQueue({ force: true }), null, 'the whole note is held back');
        assert.ok(fs.existsSync(path.join(h.queue, 'Cli note.md')) && fs.existsSync(path.join(h.queue, 'Cli note.distill.json')));
      }
    } finally {
      fs.chmodSync(image, 0o644);
    }
    // An orphan manifest (its .md gone) is an ordinary row again.
    fs.rmSync(path.join(h.queue, 'Cli note.md'));
    assert.deepEqual(h.engine.listQueue().map((e) => e.name).sort(), ['Cli note image 1.png', 'Cli note.distill.json']);
  });

  test('changing: a file whose mtime moves after the core first saw it, until it settles', async () => {
    h = setup([]);
    await h.engine.updateSettings({ settleSeconds: 3600 });
    const file = path.join(h.queue, 'Clipping 0309.md');
    fs.writeFileSync(file, '# A\n');
    const first = new Date(Math.floor(Date.now() / 1000) * 1000 - 120_000);
    fs.utimesSync(file, first, first);
    const before = h.engine.listQueue()[0]!;
    assert.equal(before.changing, undefined, 'omitted until the file changes');
    const later = new Date(first.getTime() + 60_000);
    fs.utimesSync(file, later, later);
    const after = h.engine.listQueue()[0]!;
    assert.equal(after.changing, true);
    assert.ok(after.readyAt! > before.readyAt!, 'the ready time moved');
    await h.engine.updateSettings({ settleSeconds: 0 });
    assert.equal(h.engine.listQueue()[0]!.changing, undefined, 'a settled file is not changing');
    // Gone, then added again: first seen again, so not changing.
    await h.engine.updateSettings({ settleSeconds: 3600 });
    fs.rmSync(file);
    h.engine.listQueue();
    fs.writeFileSync(file, '# B\n');
    assert.equal(h.engine.listQueue()[0]!.changing, undefined);
  });

  test('scheduler: tick runs a batch once nextBatchAt passes', async () => {
    let clock = new Date('2026-10-01T12:00:00Z');
    h = setup([{ structured: { status: 'done', summary: 'ok' } }], { tickMs: 5, now: () => clock });
    await h.engine.updateSettings({ autoProcessEnabled: true, batchIntervalMinutes: 1 });
    await h.engine.start();
    assert.equal((await h.engine.status()).nextBatchAt, '2026-10-01T12:01:00Z');
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(h.engine.listJobs().length, 0, 'nothing before the interval');
    clock = new Date('2026-10-01T12:01:01Z');
    for (let i = 0; i < 100 && h.engine.listJobs().length === 0; i++) await new Promise((r) => setTimeout(r, 5));
    assert.equal(h.engine.listJobs().length, 1);
    assert.equal((await h.engine.status()).nextBatchAt, '2026-10-01T12:02:01Z');
    await h.engine.stop();
    await h.engine.whenIdle();
  });

  test('status reports problems, runners and counts', async () => {
    h = setup([]);
    await h.engine.updateSettings({ productRoot: path.join(tmp, 'missing') });
    const s = await h.engine.status();
    assert.ok(s.problems.some((p) => p.code === 'missingCore'));
    assert.equal(s.activeVault?.path, h.vault);
    assert.deepEqual(s.runners.map((r) => [r.id, r.enabled]), [['claude-code', true]]);
    assert.equal(await h.engine.processQueue({ force: true }), null);
  });

  test('addQueueFiles copies; originals stay', async () => {
    h = setup([]);
    const src = path.join(tmp, 'outside.md');
    fs.writeFileSync(src, 'x');
    const entries = await h.engine.addQueueFiles([src, tmp]);
    assert.equal(entries.length, 1);
    assert.equal(entries[0]!.name, 'outside.md');
    assert.ok(fs.existsSync(src));
    const again = await h.engine.addQueueFiles([src]);
    assert.equal(again[0]!.name, 'outside 2.md');
  });
});

describe('exit 75 from a core apply is worded by its error code', () => {
  const sandboxed = () => new FakeRunner([], new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']));
  const conflict = (code: string): ProcessOutput => ({ status: 75, stdout: Buffer.alloc(0), stderr: Buffer.from(`ERR ${code}: details\n`) });

  async function approveWith(code: string): Promise<Job> {
    const runner = sandboxed();
    h = setup([], { runner, apply: () => conflict(code) });
    const created = await firstJob();
    runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.state, 'awaitingApproval');
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    return h.engine.getJob(created.id)!;
  }

  test('LOCK_TIMEOUT: another process held the lock; the plan is kept so Approve retries', async () => {
    const job = await approveWith('LOCK_TIMEOUT');
    assert.equal(job.state, 'awaitingApproval');
    assert.ok(job.approval?.plan, 'plan kept');
    assert.equal(job.approval?.planError, undefined);
    assert.match(job.turns.at(-1)!.text, /another process held the vault lock .*approve again/);
    assert.ok(!job.turns.some((t) => t.text.includes('vault changed')));
  });

  test('OPERATION_ID_REUSED: says the id was used, not that the vault changed', async () => {
    const job = await approveWith('OPERATION_ID_REUSED');
    assert.equal(job.approval?.plan, undefined);
    assert.match(job.approval?.planError ?? '', /already has an operation with this ID .*may already be applied/);
    assert.equal(job.turns.at(-1)!.text, 'Not applied: this operation ID was already used in the vault.');
  });

  test('stale hashes keep the "vault changed" wording, with the code', async () => {
    const job = await approveWith('EXPECTED_HASH_MISMATCH');
    assert.match(job.approval?.planError ?? '', /^The vault changed after this plan was reviewed \(transaction apply exited 75, EXPECTED_HASH_MISMATCH\)/);
    assert.equal(job.turns.at(-1)!.text, 'Not applied: the vault changed after review.');
  });
});
