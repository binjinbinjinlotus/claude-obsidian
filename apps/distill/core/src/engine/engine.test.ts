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
  /** What the session store says (session continuity); 'unknown' resumes as before. */
  status: 'unknown' | 'missing' = 'unknown';
  problems() {
    return [];
  }
  sessionStatus() {
    return this.status;
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
    apply?: () => ProcessOutput | Promise<ProcessOutput>;
    /** What `transaction inspect` returns (default PLAN). */
    inspect?: (bundle: string) => ProcessOutput;
    othersActionsPrompt?: (vaultPath: string) => string;
    /** The checkout a missing product root heals to (default '': nothing, so tests never heal to this repo). */
    detectProductRoot?: () => string;
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
    if (opts.args.includes('inspect') && o.inspect) return o.inspect(opts.args[opts.args.indexOf('inspect') + 1]!);
    return { status: 0, stdout: Buffer.from(JSON.stringify(PLAN)), stderr: Buffer.alloc(0) };
  };
  const engine = createEngine({
    paths: statePaths(state),
    runners: createRunnerRegistry([runner]),
    launch,
    tickMs: o.tickMs ?? 60_000,
    ...(o.now ? { now: o.now } : {}),
    ...(o.onJobApplied ? { onJobApplied: o.onJobApplied } : {}),
    ...(o.othersActionsPrompt ? { othersActionsPrompt: o.othersActionsPrompt } : {}),
    detectProductRoot: o.detectProductRoot ?? (() => ''),
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

  test('actions-routing.md: the next batch carries the Others’ actions sections the user’s Actions want', async () => {
    const asked: string[] = [];
    h = setup([{ structured: { status: 'nothing_to_do', summary: 'Nothing.' } }], {
      othersActionsPrompt: (v) => {
        asked.push(v);
        return '\n\nAlso update these EXISTING wiki pages … <page path="wiki/sources/sync.md">';
      },
    });
    await firstJob();
    await h.engine.whenIdle();
    assert.deepEqual(asked, [h.vault]);
    assert.match(h.runner.requests[0]!.prompt, /Also update these EXISTING wiki pages … <page path="wiki\/sources\/sync.md">/);
    // Never on its own: only inside a batch the user approves (nothing is written here).
    assert.equal(fs.existsSync(path.join(h.vault, 'wiki', 'sources', 'sync.md')), false);
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
    const denied: Step = { structured: { status: 'failed', summary: 'Needed ls.' }, denials: [denial, { ...denial, input: { command: 'ls /tmp' } }] };
    // Distill answers the first two itself (review-queue.md); the third reaches the owner.
    const giveUp: Step = { structured: { diagnosis: 'Needs ls.', fix: 'give_up', reason: 'r' } };
    h = setup([denied, denied, denied, giveUp, { structured: { status: 'nothing_to_do', summary: 'ok' } }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.deepEqual(job.approval?.denials, [denial]);
    assert.equal(job.recovery?.state, 'gaveUp');
    await h.engine.allow(job.id, ['Bash(ls /tmp)']);
    await h.engine.whenIdle();
    job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    assert.deepEqual(job.grantedTools, ['Bash(ls /tmp)']);
    const second = h.runner.requests[4]!;
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
    const denied: Step = { structured: { status: 'failed', summary: 'Needed tools.' }, denials: [{ toolName: 'Bash', input: { command: 'ls /tmp' } }] };
    h = setup([denied, denied, denied]);
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

  test('a batch waiting in Review does not block the next one (decision 2026-10-05)', async () => {
    h = setup([{ structured: { status: 'needs_input', summary: '?' } }, { structured: { status: 'nothing_to_do', summary: 'ok' } }]);
    const created = await firstJob();
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.state, 'awaitingApproval');
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    const next = await h.engine.processQueue({ force: true });
    assert.ok(next);
    assert.deepEqual(next.files, ['inbox/b.md']);
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.state, 'awaitingApproval', 'the first batch still waits for its OK');
  });

  test('one running batch per vault: a running batch blocks the next one', async () => {
    h = setup([{ hang: true }]);
    const created = await firstJob();
    await new Promise((r) => setTimeout(r, 10));
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    assert.equal(await h.engine.processQueue({ force: true }), null);
    const log = h.events.find((e) => e.type === 'log');
    assert.ok(log && log.type === 'log' && log.message === `Waiting for ${created.id} to finish.`);
    assert.ok(fs.existsSync(path.join(h.queue, 'b.md')), 'blocked batches leave the queue alone');
    await h.engine.cancel(created.id);
    await h.engine.whenIdle();
  });

  test('bundle outside the job directory is refused, not inspected', async () => {
    h = setup([needsApproval('/tmp/elsewhere/bundle.json')], { settings: { recovery: { automatic: false } } });
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.match(job.approval?.planError ?? '', /outside this job's directory/);
    assert.equal(h.inspectCalls.length, 0);
    // The owner's sentence: plain words, never the path (the raw error stays in planError).
    assert.equal(job.recovery?.summary, 'The vault core couldn’t check this plan: the plan was saved in the wrong place.');
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

  test('LOCK_TIMEOUT: the plan is kept and waits in the queue under the same approval (review-queue.md)', async () => {
    const job = await approveWith('LOCK_TIMEOUT');
    assert.equal(job.state, 'awaitingApproval');
    assert.ok(job.approval?.plan, 'plan kept');
    assert.equal(job.approval?.planError, undefined);
    assert.equal(job.queuedApply?.planSha256, job.approval?.plan?.approval_sha256, 'still approved: it applies when the lock is free');
    assert.match(job.turns.at(-1)!.text, /another process held the vault lock\. Nothing changed; Distill tries again shortly/);
    assert.equal(h.inspectCalls.filter((c) => c.includes('apply')).length, 1, 'no retry before the wait');
    assert.equal((await h.engine.status()).pendingApprovals, 0, 'waiting to apply is not Needs you');
  });

  test('OPERATION_ID_REUSED: says the id was used, not that the vault changed', async () => {
    const job = await approveWith('OPERATION_ID_REUSED');
    assert.equal(job.approval?.plan, undefined);
    assert.match(job.approval?.planError ?? '', /already has an operation with this ID .*may already be applied/);
    assert.equal(job.turns.at(-1)!.text, 'Not applied: this operation ID was already used in the vault.');
  });

  test('stale hashes: the plan is rebuilt in its session and asks the owner once more (review-queue.md)', async () => {
    const runner = sandboxed();
    h = setup([], { runner, apply: () => conflict('EXPECTED_HASH_MISMATCH') });
    const created = await firstJob();
    runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.match(runner.requests.at(-1)!.prompt, /The vault changed after this plan was built/);
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.approval?.planError, undefined, 'never a failure card');
    assert.ok(job.approval?.plan?.valid);
    assert.ok(job.queuedApply && !job.queuedApply.planSha256, 'keeps its place; needs the owner');
    assert.equal(job.refresh, undefined);
    assert.equal((await h.engine.status()).pendingApprovals, 1);
  });
});

describe('blocked commands (review-queue.md)', () => {
  const blocked = (vault: string): Step => ({
    structured: { status: 'needs_input', summary: 'I need to compare the ledgers.' },
    denials: [{ toolName: 'Bash', input: { command: `diff <(python3 -c "print(open('${vault}/wiki/meta/ledgers/claim-ledger.json').read())") x` } }],
  });

  test('Distill answers a blocked command itself and resumes the same session; the plan comes back', async () => {
    h = setup([]);
    h.runner.steps.push(blocked(path.join(tmp, 'vault')));
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 2, 'one answer, one resumed turn');
    const answer = h.runner.requests[1]!;
    assert.ok('resume' in answer.session, 'the same session');
    assert.match(answer.prompt, /Read, Grep or Glob/);
    assert.match(answer.prompt, /claim-ledger\.json/);
    assert.equal(job.state, 'awaitingApproval');
    assert.ok(job.approval?.plan?.valid, 'the plan shows');
    assert.equal(job.recovery?.state, 'fixed');
    assert.equal(job.recovery?.attempts[0]?.fix, 'answer_denial');
    assert.ok(job.turns.some((t) => t.author === 'app' && /Read, Grep or Glob/.test(t.text)), 'the answer is in the conversation');
    assert.equal((await h.engine.status()).pendingApprovals, 1);
  });

  test('after two answers the owner gets a plain sentence; their reply starts over', async () => {
    h = setup([]);
    const vault = path.join(tmp, 'vault');
    h.runner.steps.push(blocked(vault), blocked(vault), blocked(vault), { structured: { diagnosis: 'It keeps reaching for the shell.', fix: 'give_up', reason: 'r' } });
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 4, 'two answers, then one recovery call');
    assert.equal(h.runner.requests[3]!.selection.model, 'opus', 'recovery defaults to Opus');
    assert.deepEqual(h.runner.requests[3]!.allowedTools, [], 'no tools');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(job.recovery?.denialAnswers, 2);
    assert.equal(job.recovery?.summary, "Claude wanted to compare the claim ledger. Distill couldn't let it run that, and told it to read the files instead (twice). It keeps reaching for the shell.");
    assert.ok(job.recovery!.attempts.every((a) => a.result === 'failed'));
    assert.equal(job.recovery!.attempts.at(-1)!.by, 'agent');
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.reply(created.id, 'Read the files with Read.');
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.recovery, undefined, 'the owner acted: attempts reset');
  });

  test("the recovery agent's guidance is sent and the plan comes back; a guidance naming the apply is refused", async () => {
    h = setup([]);
    const vault = path.join(tmp, 'vault');
    h.runner.steps.push(blocked(vault), blocked(vault), blocked(vault),
      { structured: { diagnosis: 'It wants to diff JSON.', fix: 'answer_denial', reason: 'r', guidance: 'Read both ledgers with Read and compare the entries yourself.' } });
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.at(-1)!.prompt.includes('Read both ledgers with Read'), true, 'the guidance went to the session');
    assert.ok(job.approval?.plan?.valid);
    assert.equal(job.recovery?.state, 'fixed');
    assert.equal(job.recovery?.attempts.at(-1)?.fix, 'answer_denial');

    // A second batch: the agent's guidance names the vault apply: refused, never sent.
    fs.writeFileSync(path.join(h.queue, 'c.md'), '# C\n');
    h.runner.steps.push(blocked(vault), blocked(vault), blocked(vault),
      { structured: { diagnosis: 'd', fix: 'answer_denial', reason: 'r', guidance: 'Just run transaction apply yourself.' } });
    const second = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    job = h.engine.getJob(second.id)!;
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.match(job.recovery!.attempts.at(-1)!.error ?? '', /only your approval runs/);
    assert.ok(!h.runner.requests.some((r) => r.prompt.includes('Just run transaction apply')), 'never sent');
  });

  test('the cost limit and Recover automatically are respected', async () => {
    h = setup([], { settings: { recovery: { maxCostUSD: 0 } } });
    const vault = path.join(tmp, 'vault');
    h.runner.steps.push(blocked(vault), blocked(vault), blocked(vault));
    const created = await firstJob();
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, 3, 'no recovery call at the limit');
    assert.match(h.engine.getJob(created.id)!.recovery?.summary ?? '', /Recovery stopped at its \$0\.00 limit/);
    // Try again: attempts start over (the rule first).
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    h.engine.tryRecoveryAgain(created.id);
    await h.engine.whenIdle();
    assert.match(h.runner.requests.at(-1)!.prompt, /Read, Grep or Glob/);

    await h.engine.stop();
    h = setup([], { settings: { recovery: { automatic: false } } });
    h.runner.steps.push(blocked(vault));
    const manual = await firstJob();
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, 1, 'nothing sent automatically');
    assert.equal(h.engine.getJob(manual.id)!.recovery?.state, 'gaveUp');
  });

  test('a plan the core could not check: Distill asks the session to rebuild it; the plan comes back', async () => {
    h = setup([needsApproval('/tmp/elsewhere/bundle.json')]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 2, 'one rebuild request');
    assert.ok('resume' in h.runner.requests[1]!.session, 'the same session');
    assert.match(h.runner.requests[1]!.prompt, /couldn't check the plan/);
    assert.ok(job.approval?.plan?.valid);
    assert.equal(job.recovery?.signature, 'plan-error');
    assert.equal(job.recovery?.state, 'fixed');
  });

  test('plan-error: the rule, then the agent; a second agent attempt waits a minute', async () => {
    const clock = Date.parse('2026-10-05T10:00:00Z');
    h = setup([], { now: () => new Date(clock) });
    const bad = needsApproval('/tmp/elsewhere/bundle.json');
    h.runner.steps.push(bad, bad,
      { structured: { diagnosis: 'The bundle is in the wrong folder.', fix: 'rebuild_in_session', reason: 'r', guidance: 'Write the bundle inside the job directory.' } },
      bad);
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 4, 'first run, rule, agent, agent-guided rebuild');
    assert.match(h.runner.requests[3]!.prompt, /Write the bundle inside the job directory/);
    assert.equal(job.recovery?.state, 'waiting', 'the next agent attempt waits');
    assert.equal(job.recovery?.waitUntil, '2026-10-05T10:01:00Z');
    assert.deepEqual(job.recovery?.attempts.map((a) => a.by), ['rule', 'agent']);
  });

  test('the minute’s wake runs the next agent attempt', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    let clock = Date.parse('2026-10-05T10:00:00Z');
    h = setup([], { now: () => new Date(clock) });
    const bad = needsApproval('/tmp/elsewhere/bundle.json');
    h.runner.steps.push(bad, bad,
      { structured: { diagnosis: 'Wrong folder.', fix: 'rebuild_in_session', reason: 'r', guidance: 'Write the bundle inside the job directory.' } },
      bad, { structured: { diagnosis: 'It needs you.', fix: 'give_up', reason: 'r' } });
    const created = await firstJob();
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.recovery?.state, 'waiting');
    clock += 61_000;
    t.mock.timers.tick(61_000);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 5, 'the second agent call');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.deepEqual(job.recovery?.attempts.map((a) => a.by), ['rule', 'agent', 'agent']);
  });

  test('a wake left from an earlier recovery never revives one the owner reset', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const clock = Date.parse('2026-10-05T10:00:00Z');
    h = setup([], { now: () => new Date(clock) });
    const bad = needsApproval('/tmp/elsewhere/bundle.json');
    h.runner.steps.push(bad, bad,
      { structured: { diagnosis: 'Wrong folder.', fix: 'rebuild_in_session', reason: 'r', guidance: 'Write the bundle inside the job directory.' } },
      bad);
    const created = await firstJob();
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.recovery?.state, 'waiting');
    // The owner replies inside the minute: recovery starts over, and this time gives up.
    h.runner.steps.push(bad, bad, { structured: { diagnosis: 'It needs you.', fix: 'give_up', reason: 'r' } });
    await h.engine.reply(created.id, 'try again');
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.recovery?.state, 'gaveUp');
    const calls = h.runner.requests.length;
    t.mock.timers.tick(61_000);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.recovery?.state, 'gaveUp', 'the old wake leaves the owner’s Couldn’t fix alone');
    assert.equal(h.runner.requests.length, calls);
  });

  test('an agent call whose recovery was replaced while it ran does nothing (the owner replied meanwhile)', async () => {
    h = setup([]);
    const bad = needsApproval('/tmp/elsewhere/bundle.json');
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    let first = true;
    const run = h.runner.run.bind(h.runner);
    h.runner.run = async (req) => {
      if (first && req.prompt.startsWith('You are the recovery step')) {
        first = false;
        h.runner.requests.push(req);
        await held;
        return { sessionID: 's', resultText: '', isError: false, costUSD: 0.01, denials: [], raw: '{}',
          structured: { diagnosis: 'Old.', fix: 'rebuild_in_session', reason: 'r', guidance: 'Write the bundle inside the job directory.' } };
      }
      return run(req);
    };
    h.runner.steps.push(bad, bad);
    const created = await firstJob();
    for (let i = 0; i < 50 && first; i++) await new Promise((r) => setImmediate(r));
    assert.equal(first, false, 'the first agent call is in flight');
    // The owner replies meanwhile; that turn's plan error starts a new recovery, which gives up.
    h.runner.steps.push(bad, bad, { structured: { diagnosis: 'It needs you.', fix: 'give_up', reason: 'r' } });
    await h.engine.reply(created.id, 'try again');
    for (let i = 0; i < 200 && h.engine.getJob(created.id)!.recovery?.state !== 'gaveUp'; i++) await new Promise((r) => setImmediate(r));
    assert.equal(h.engine.getJob(created.id)!.recovery?.state, 'gaveUp');
    const calls = h.runner.requests.length;
    release();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, calls, 'no turn from the stale answer');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(job.recovery?.summary?.includes('Old.'), false);
  });

  test('recovery that alternates blocked commands and plan errors stays bounded across signatures', async () => {
    h = setup([]);
    const vault = path.join(tmp, 'vault');
    const bad = needsApproval('/tmp/elsewhere/bundle.json');
    for (let i = 0; i < 15; i++) h.runner.steps.push(blocked(vault), bad);
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.ok(h.runner.requests.length <= 6, `bounded: ${h.runner.requests.length} runner calls`);
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.ok(job.recovery!.attempts.every((a) => a.result !== 'running'));
  });

  test('an apply turn with a blocked call is not answered', async () => {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.unshift(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    h.runner.steps.push(blocked(path.join(tmp, 'vault')));
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.recovery, undefined);
    assert.equal(h.runner.requests.length, 2);
  });

  test('a batch already waiting on blocked calls gets the answer once at start', async () => {
    h = setup([]);
    const vault = path.join(tmp, 'vault');
    h.runner.steps.push(blocked(vault));
    const created = await firstJob();
    // Simulate a build before this rule: the job waits with denials and no recovery.
    await h.engine.whenIdle();
    await h.engine.stop();
    const jobsFile = path.join(tmp, 'state', 'jobs.json');
    const saved = JSON.parse(fs.readFileSync(jobsFile, 'utf8')) as Array<Record<string, unknown>>;
    const old = saved.find((j) => j.id === created.id)!;
    old.state = 'awaitingApproval';
    old.approval = { summary: 'blocked', questions: [], denials: blocked(vault).denials, skipped: [] };
    delete old.recovery;
    fs.writeFileSync(jobsFile, JSON.stringify(saved));
    const steps: Step[] = [{ structured: { status: 'nothing_to_do', summary: 'done' } }];
    h = setup([], { runner: new FakeRunner(steps), jobs: saved });
    await h.engine.start();
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, 1);
    assert.match(h.runner.requests[0]!.prompt, /Read, Grep or Glob/);
  });

  // 2026-10-06, the owner's job-20261005-124947-9958: a denial, Distill's answer, then questions and no plan.
  const stillBlocked: Step = {
    structured: { status: 'needs_input', summary: 'Still blocked, and this session no longer allows the commands I would need.', questions: ['Can you clear the lock?'] },
  };

  test('a denial answered, then questions without denials: recovery escalates once to the agent, then needs the owner', async () => {
    h = setup([]);
    const vault = path.join(tmp, 'vault');
    h.runner.steps.push(blocked(vault), stillBlocked, { structured: { diagnosis: 'Claude thinks it must clear a lock.', fix: 'give_up', reason: 'r' } });
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 3, 'the batch, the rule answer, one recovery call');
    assert.match(h.runner.requests[1]!.prompt, /Distill runs `transaction inspect` itself/, 'the answer says who inspects and applies');
    assert.equal(job.recovery?.state, 'gaveUp', 'never left running');
    assert.deepEqual(job.recovery!.attempts.map((a) => [a.by, a.result]), [['rule', 'failed'], ['agent', 'failed']]);
    assert.equal(job.recovery?.summary, 'Distill answered Claude’s blocked command, but Claude stopped with questions instead of a plan. Claude thinks it must clear a lock.');
    assert.equal((await h.engine.status()).pendingApprovals, 1, 'needs the owner');
  });

  test('the agent’s answer that also ends in questions gives up (one escalation, no loop)', async () => {
    h = setup([]);
    const vault = path.join(tmp, 'vault');
    h.runner.steps.push(blocked(vault), stillBlocked,
      { structured: { diagnosis: 'Read the files.', fix: 'answer_denial', reason: 'r', guidance: 'Use Read on the ledger, then finish.' } }, stillBlocked);
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 4, 'no second agent call');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.ok(job.recovery!.attempts.every((a) => a.result !== 'running'));
    assert.equal(job.state, 'awaitingApproval');
  });

  test('at start, a recovery left running with nothing working on it settles (the owner’s stuck batch)', async () => {
    h = setup([]);
    h.runner.steps.push(stillBlocked);
    const created = await firstJob();
    await h.engine.whenIdle();
    await h.engine.stop();
    const jobsFile = path.join(tmp, 'state', 'jobs.json');
    const saved = JSON.parse(fs.readFileSync(jobsFile, 'utf8')) as Array<Record<string, unknown>>;
    const old = saved.find((j) => j.id === created.id)!;
    old.recovery = { state: 'running', signature: 'denial', denialAnswers: 1, attempts: [{ at: '2026-10-05T12:55:00Z', by: 'rule', fix: 'answer_denial', result: 'running', costUSD: 0 }] };
    old.queuedApply = { at: '2026-10-05T12:50:00Z', order: 1, bundlePath: '/x/bundle.json', labels: 'confirm', carries: 'confirm' };
    fs.writeFileSync(jobsFile, JSON.stringify(saved));
    h = setup([], { runner: new FakeRunner([{ structured: { diagnosis: 'It needs you.', fix: 'give_up', reason: 'r' } }]), jobs: saved });
    await h.engine.start();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 1, 'one recovery call, no session turn');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal((await h.engine.status()).pendingApprovals, 1);

    // Recover automatically off: it settles straight to the owner.
    await h.engine.stop();
    const again = JSON.parse(fs.readFileSync(jobsFile, 'utf8')) as Array<Record<string, unknown>>;
    again.find((j) => j.id === created.id)!.recovery = old.recovery;
    h = setup([], { jobs: again, settings: { recovery: { automatic: false } } });
    await h.engine.start();
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, 0);
    assert.equal(h.engine.getJob(created.id)!.recovery?.state, 'gaveUp');
  });
});

describe('the apply queue (review-queue.md)', () => {
  const sandboxed = (steps: Step[] = []) => new FakeRunner(steps, new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']));
  const ok = (op: string): ProcessOutput => ({ status: 0, stdout: Buffer.from(JSON.stringify({ operation_id: op, changed_paths: ['wiki/a.md'] })), stderr: Buffer.alloc(0) });

  /** Two batches in Review in one vault; the first apply is held until `release()`. */
  async function twoBatches(o: { inspect?: (bundle: string) => ProcessOutput } = {}) {
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    let applies = 0;
    const runner = sandboxed();
    h = setup([], {
      runner,
      ...(o.inspect ? { inspect: o.inspect } : {}),
      apply: async () => {
        applies += 1;
        if (applies === 1) await held;
        return ok(`op-${applies}`);
      },
    });
    const a = await firstJob();
    runner.steps.push(needsApproval(h.bundle(a)));
    await h.engine.whenIdle();
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    const b = await h.engine.processQueue({ force: true });
    assert.ok(b && b.id !== a.id, 'a second batch');
    runner.steps.push(needsApproval(h.bundle(b)));
    await h.engine.whenIdle();
    return { a, b: b!, runner, release, applies: () => applies };
  }

  test('a second approval waits for the first apply, then applies under its own approval', async () => {
    const t = await twoBatches();
    const first = h.engine.approve(t.a.id);
    await new Promise((r) => setImmediate(r));
    await h.engine.approve(t.b.id);
    let b = h.engine.getJob(t.b.id)!;
    assert.equal(b.state, 'awaitingApproval');
    assert.equal(b.queuedApply?.planSha256, PLAN.approval_sha256, 'queued');
    assert.match(b.turns.at(-1)!.text, /Queued: it applies after/);
    assert.equal(t.applies(), 1, 'never two applies at once');
    assert.equal((await h.engine.status()).pendingApprovals, 0, 'queued is not Needs you');
    t.release();
    await first;
    await h.engine.whenIdle();
    await new Promise((r) => setTimeout(r, 20));
    await h.engine.whenIdle();
    b = h.engine.getJob(t.b.id)!;
    assert.equal(h.engine.getJob(t.a.id)!.state, 'completed');
    assert.equal(b.state, 'completed', 'applied once the vault was free');
    assert.equal(b.queuedApply, undefined);
    assert.equal(t.applies(), 2);
  });

  test("Don't apply yet takes it out of the queue; nothing applies it", async () => {
    const t = await twoBatches();
    const first = h.engine.approve(t.a.id);
    await new Promise((r) => setImmediate(r));
    await h.engine.approve(t.b.id);
    h.engine.unqueue(t.b.id);
    t.release();
    await first;
    await h.engine.whenIdle();
    await new Promise((r) => setTimeout(r, 20));
    const b = h.engine.getJob(t.b.id)!;
    assert.equal(b.state, 'awaitingApproval');
    assert.equal(b.queuedApply, undefined);
    assert.equal(t.applies(), 1);
    assert.throws(() => h.engine.unqueue(t.b.id), /not waiting to apply/);
  });

  test('a queued plan the first apply made stale is rebuilt and asks once more, keeping its place', async () => {
    let stale = false;
    const t = await twoBatches({
      inspect: () => ({ status: 0, stdout: Buffer.from(JSON.stringify(stale ? { ...PLAN, approval_sha256: 'e'.repeat(64) } : PLAN)), stderr: Buffer.alloc(0) }),
    });
    const first = h.engine.approve(t.a.id);
    await new Promise((r) => setImmediate(r));
    await h.engine.approve(t.b.id);
    const order = h.engine.getJob(t.b.id)!.queuedApply!.order;
    stale = true;
    t.runner.steps.push(needsApproval(h.bundle(t.b)));
    t.release();
    await first;
    await h.engine.whenIdle();
    await new Promise((r) => setTimeout(r, 20));
    await h.engine.whenIdle();
    const b = h.engine.getJob(t.b.id)!;
    assert.match(t.runner.requests.at(-1)!.prompt, /The vault changed after this plan was built/, 'rebuilt in its own session');
    assert.equal(b.state, 'awaitingApproval');
    assert.equal(b.queuedApply?.order, order, 'keeps its place');
    assert.equal(b.queuedApply?.planSha256, undefined, 'needs the owner once more');
    assert.equal(t.applies(), 1, 'the stale plan never applied');
    assert.equal((await h.engine.status()).pendingApprovals, 1);
  });

  test('approving a plan the vault already overtook rebuilds it at once, without an apply turn', async () => {
    let applies = 0;
    const runner = sandboxed();
    h = setup([], { runner, apply: async () => ok(`op-${++applies}`) });
    const a = await firstJob();
    runner.steps.push(needsApproval(h.bundle(a)));
    await h.engine.whenIdle();
    // The plan expected wiki/a.md not to exist; the vault has it now (a hand edit, nothing Distill applied).
    fs.mkdirSync(path.dirname(h.bundle(a)), { recursive: true });
    fs.writeFileSync(h.bundle(a), JSON.stringify({ expected_hashes: { 'wiki/a.md': null }, writes: [] }));
    fs.mkdirSync(path.join(h.vault, 'wiki'), { recursive: true });
    fs.writeFileSync(path.join(h.vault, 'wiki', 'a.md'), '# A\n');
    const before = runner.requests.length;
    runner.steps.push(needsApproval(h.bundle(a)));
    await h.engine.approve(a.id);
    await h.engine.whenIdle();
    const job = h.engine.getJob(a.id)!;
    assert.equal(applies, 0, 'no apply ran');
    assert.equal(runner.requests.length, before + 1, 'one rebuild turn');
    assert.match(runner.requests.at(-1)!.prompt, /The vault changed after this plan was built/);
    assert.ok(!runner.requests.at(-1)!.allowedTools.some((t) => t.includes('transaction apply')), 'the rebuild turn has no apply rule');
    assert.ok(job.turns.some((t) => t.author === 'user' && /rebuilt first/.test(t.text)));
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.queuedApply?.planSha256, undefined, 'the rebuilt plan asks the owner once more');
    assert.equal(job.refresh, undefined, 'the rebuild finished');
  });

  test('a queued head stale again (already rebuilt against this vault) leaves the queue for recovery, keeping the approved hash', async () => {
    let stale = false;
    let bBundle = '';
    h = setup([], {
      inspect: (b) => ({ status: 0, stdout: Buffer.from(JSON.stringify(stale && b === bBundle ? { ...PLAN, approval_sha256: 'e'.repeat(64) } : PLAN)), stderr: Buffer.alloc(0) }),
    });
    const a = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(a)));
    await h.engine.whenIdle();
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    const b = (await h.engine.processQueue({ force: true }))!;
    bBundle = h.bundle(b);
    h.runner.steps.push(needsApproval(bBundle));
    await h.engine.whenIdle();
    // B's plan is already overtaken: Approve rebuilds it once against this vault (no apply has landed).
    fs.mkdirSync(path.dirname(bBundle), { recursive: true });
    fs.writeFileSync(bBundle, JSON.stringify({ expected_hashes: { 'wiki/b.md': null }, writes: [] }));
    fs.mkdirSync(path.join(h.vault, 'wiki'), { recursive: true });
    fs.writeFileSync(path.join(h.vault, 'wiki', 'b.md'), '# B\n');
    h.runner.steps.push(needsApproval(bBundle));
    await h.engine.approve(b.id);
    await h.engine.whenIdle();
    assert.match(h.runner.requests.at(-1)!.prompt, /The vault changed after this plan was built/, 'rebuilt once');
    fs.writeFileSync(bBundle, JSON.stringify({ expected_hashes: {}, writes: [] }));
    h.engine.unqueue(b.id);
    // A's apply turn runs (held); B is approved and queues behind it under its approval.
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    const run = h.runner.run.bind(h.runner);
    h.runner.run = async (req) => {
      if (req.allowedTools.some((x) => x.includes('transaction apply'))) {
        h.runner.requests.push(req);
        await held;
        return { sessionID: 's', resultText: '', isError: false, costUSD: 0, denials: [], raw: '{}', structured: { status: 'failed', summary: 'The apply did not run.' } };
      }
      return run(req);
    };
    await h.engine.approve(a.id);
    await h.engine.approve(b.id);
    assert.equal(h.engine.getJob(b.id)!.queuedApply?.planSha256, PLAN.approval_sha256, 'queued under its approval');
    // A's apply doesn't land, and the vault changed by hand: the head's inspect gives another hash.
    stale = true;
    h.runner.steps.push({ structured: { diagnosis: 'Something else keeps changing these pages.', fix: 'give_up', reason: 'r' } });
    const calls = h.runner.requests.length;
    release();
    for (let i = 0; i < 10; i++) {
      await new Promise((r) => setTimeout(r, 5));
      await h.engine.whenIdle();
    }
    const job = h.engine.getJob(b.id)!;
    assert.equal(h.engine.getJob(a.id)!.state, 'failed');
    assert.equal(h.runner.requests.length, calls + 1, 'one recovery call, no second rebuild');
    assert.match(h.runner.requests.at(-1)!.prompt, /recovery step/);
    assert.equal(job.recovery?.signature, 'stale-again');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(job.recovery?.approvedSha256, PLAN.approval_sha256, 'the approved hash is kept on the recovery');
    assert.equal(job.queuedApply?.planSha256, undefined, 'out of the queue: never applied under the old approval');
    assert.ok(!h.runner.requests.slice(calls).some((r) => r.allowedTools.some((x) => x.includes('transaction apply'))), 'no apply turn for B');
    assert.equal((await h.engine.status()).pendingApprovals, 1, 'B needs the owner (A failed on its own)');
    const inspects = h.inspectCalls.length;
    for (let i = 0; i < 3; i++) {
      await new Promise((r) => setTimeout(r, 5));
      await h.engine.whenIdle();
    }
    assert.equal(h.inspectCalls.length, inspects, 'the pump does not inspect it again');
  });

  test('reject takes a batch out of the queue', async () => {
    const t = await twoBatches();
    const first = h.engine.approve(t.a.id);
    await new Promise((r) => setImmediate(r));
    await h.engine.approve(t.b.id);
    await h.engine.reject(t.b.id);
    t.release();
    await first;
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(t.b.id)!.queuedApply, undefined);
    assert.equal(t.applies(), 1);
  });
});

describe('recovery fixes (review-queue.md, 2026-10-06)', () => {
  const sandboxed = (steps: Step[] = []) => new FakeRunner(steps, new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']));
  const ok = (op: string): ProcessOutput => ({ status: 0, stdout: Buffer.from(JSON.stringify({ operation_id: op, changed_paths: ['wiki/a.md'] })), stderr: Buffer.alloc(0) });

  /**
   * A batch in Review left with a recovery the rule already tried (as a restart finds it): start() hands it to the
   * recovery agent, whose answer is `answer`.
   */
  async function stuck(signature: string, answer: Record<string, unknown>, edit: (j: Record<string, unknown>, all: Array<Record<string, unknown>>) => void = () => {}, o: { apply?: () => ProcessOutput } = {}) {
    let applies = 0;
    await h?.engine.stop(); // a test that calls this twice
    tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-engine-')));
    h = setup([], { runner: sandboxed() });
    h.runner.steps.push(needsApproval(h.bundle(await firstJob())));
    await h.engine.whenIdle();
    const id = h.engine.listJobs()[0]!.id;
    await h.engine.stop();
    const jobsFile = path.join(tmp, 'state', 'jobs.json');
    const saved = JSON.parse(fs.readFileSync(jobsFile, 'utf8')) as Array<Record<string, unknown>>;
    const j = saved.find((x) => x.id === id)!;
    j.recovery = { state: 'running', signature, attempts: [{ at: '2026-10-06T09:00:00Z', by: 'rule', fix: 'rebuild_in_session', result: 'running', costUSD: 0 }] };
    edit(j, saved);
    h = setup([], {
      runner: sandboxed([{ structured: answer }]),
      jobs: saved,
      apply: () => {
        applies += 1;
        return o.apply?.() ?? ok('op-1');
      },
    });
    await h.engine.start();
    await h.engine.whenIdle();
    await new Promise((r) => setTimeout(r, 20));
    await h.engine.whenIdle();
    return { id, applies: () => applies };
  }
  const queued = (j: Record<string, unknown>) => {
    j.queuedApply = { at: '2026-10-06T08:59:00Z', order: 1, bundlePath: (j.approval as { bundlePath: string }).bundlePath, labels: 'confirm', carries: 'confirm' };
    (j.recovery as Record<string, unknown>).approvedSha256 = PLAN.approval_sha256;
  };

  test('reinspect_same_bundle: back to the queue under the approved hash; inspect proves it, then it applies', async () => {
    const t = await stuck('lock', { diagnosis: 'The lock is gone now.', fix: 'reinspect_same_bundle', reason: 'r' }, queued);
    const job = h.engine.getJob(t.id)!;
    assert.equal(t.applies(), 1, 'applied once, after inspect');
    assert.equal(job.state, 'completed');
    assert.ok(h.inspectCalls.some((c) => c.includes('inspect')), 'inspected again first');
    assert.equal(job.recovery?.state, 'fixed', 'the apply ended the recovery');
  });

  test('reinspect_same_bundle never retries a plan the owner did not approve', async () => {
    const t = await stuck('lock', { diagnosis: 'Try again.', fix: 'reinspect_same_bundle', reason: 'r' }, (j) => {
      queued(j);
      (j.recovery as Record<string, unknown>).approvedSha256 = 'e'.repeat(64); // a hash the current plan doesn't have
    });
    const job = h.engine.getJob(t.id)!;
    assert.equal(t.applies(), 0);
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.match(job.recovery?.summary ?? '', /plan changed after you approved it/);
    assert.equal(job.queuedApply?.planSha256, undefined, 'never queued under another hash');
  });

  test('a fix that needs an approval is refused without one; wait_then_retry needs a batch touching the same pages', async () => {
    let t = await stuck('lock', { diagnosis: 'x', fix: 'reinspect_same_bundle', reason: 'r' });
    assert.equal(h.engine.getJob(t.id)!.recovery?.state, 'gaveUp');
    assert.match(h.engine.getJob(t.id)!.recovery!.attempts.at(-1)!.error ?? '', /needs a plan you approved/);
    t = await stuck('lock', { diagnosis: 'x', fix: 'wait_then_retry', reason: 'r', waitFor: 'job-nope' }, queued);
    assert.equal(h.engine.getJob(t.id)!.recovery?.state, 'gaveUp');
    assert.equal(t.applies(), 0);
  });

  test('wait_then_retry: a minute later the approved apply goes again through the queue, without another agent call', async () => {
    const t = await stuck('lock', { diagnosis: 'Another batch is writing the same page.', fix: 'wait_then_retry', reason: 'r', waitFor: 'job-other' }, (j, all) => {
      queued(j);
      all.push({ ...structuredClone(j), id: 'job-other', recovery: undefined, queuedApply: undefined });
    });
    const job = h.engine.getJob(t.id)!;
    assert.equal(job.recovery?.state, 'waiting');
    assert.equal(job.recovery?.wake, 'retry', 'the wake retries the apply, not the agent');
    assert.equal(job.recovery?.approvedSha256, PLAN.approval_sha256);
    assert.ok(Date.parse(job.recovery!.waitUntil!) - Date.now() > 55_000, 'one backoff');
    assert.equal(job.queuedApply?.planSha256, undefined, 'not queued until its time');
    assert.equal(t.applies(), 0);
    assert.equal((await h.engine.status()).pendingApprovals, 1, 'only the other batch needs the owner; recovery is on this one');
  });

  test('Let recovery try again on a lock keeps the approved hash and goes to the agent (within its minute); session-gone refuses', async () => {
    const t = await stuck('lock', { diagnosis: 'Still locked.', fix: 'give_up', reason: 'r' }, queued);
    assert.equal(h.engine.getJob(t.id)!.recovery?.state, 'gaveUp');
    const calls = h.runner.requests.length;
    h.runner.steps.push({ structured: { diagnosis: 'Still locked.', fix: 'give_up', reason: 'r' } });
    h.engine.tryRecoveryAgain(t.id);
    await h.engine.whenIdle();
    const again = h.engine.getJob(t.id)!;
    assert.equal(h.runner.requests.length, calls + 1, 'one agent call (the owner reset the attempts)');
    assert.equal(again.recovery?.signature, 'lock');
    assert.equal(again.recovery?.approvedSha256, PLAN.approval_sha256, 'the hash the owner approved survives');
    assert.deepEqual(again.recovery?.attempts.map((a) => a.by), ['agent']);
    assert.equal(t.applies(), 0, 'nothing retried by itself');
    await h.engine.stop();

    const s = await stuck('lock', { diagnosis: 'x', fix: 'give_up', reason: 'r' }, (j) => {
      queued(j);
      (j.recovery as Record<string, unknown>).signature = 'session-gone';
    });
    assert.equal(h.engine.getJob(s.id)!.recovery?.state, 'gaveUp');
    assert.throws(() => h.engine.tryRecoveryAgain(s.id), /continue it in a new session/);
    assert.equal(h.engine.getJob(s.id)!.recovery?.signature, 'session-gone', 'nothing wiped');
  });

  test('split_batch and discard_stale_part are proposals: nothing in the batch changes until the owner confirms', async () => {
    const sources = (j: Record<string, unknown>) => {
      (j.approval as Record<string, unknown>).sources = [
        { page: 'wiki/sources/a.md', title: 'A', labels: [], by: 'none' },
        { page: 'wiki/sources/b.md', title: 'B', labels: [], by: 'none' },
      ];
    };
    let t = await stuck('stale-again', { diagnosis: 'Two sources keep colliding.', fix: 'split_batch', reason: 'r', groups: [['wiki/sources/a.md'], ['wiki/sources/b.md']] }, sources);
    let job = h.engine.getJob(t.id)!;
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(job.recovery?.proposal, 'split_batch');
    assert.deepEqual(job.recovery?.groups, [['wiki/sources/a.md'], ['wiki/sources/b.md']]);
    assert.equal(job.pendingPart, undefined, 'no part was started');
    assert.equal(h.runner.requests.length, 1, 'only the recovery call');

    t = await stuck('stale-again', { diagnosis: 'x', fix: 'split_batch', reason: 'r', groups: [['wiki/sources/a.md']] }, sources);
    job = h.engine.getJob(t.id)!;
    assert.equal(job.recovery?.proposal, undefined, 'one group is not a split');
    assert.match(job.recovery!.attempts.at(-1)!.error ?? '', /two groups/);

    t = await stuck('stale-again', { diagnosis: 'x', fix: 'discard_stale_part', reason: 'r' });
    job = h.engine.getJob(t.id)!;
    assert.equal(job.recovery?.proposal, undefined, 'no rebuilt part to discard');
    assert.equal(job.state, 'awaitingApproval', 'the batch is untouched');
  });
});

describe('recovery after a spent rule (review-queue.md, 2026-10-06)', () => {
  const sandboxed = (steps: Step[] = []) => new FakeRunner(steps, new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']));
  const lock: ProcessOutput = { status: 75, stdout: Buffer.alloc(0), stderr: Buffer.from('ERR LOCK_TIMEOUT: held\n') };

  async function settle(): Promise<void> {
    for (let i = 0; i < 6; i++) {
      await h.engine.whenIdle();
      await new Promise((r) => setImmediate(r));
    }
  }

  test('lock: after 30 s and 2 min the agent may retry under the approved hash; the bounds hold across retries', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: Date.parse('2026-10-06T10:00:00Z') });
    const runner = sandboxed();
    let applies = 0;
    h = setup([], { runner, apply: () => (applies++, lock), now: () => new Date(Date.now()) });
    const created = await firstJob();
    runner.steps.push(needsApproval(h.bundle(created)));
    await settle();
    const reinspect = { structured: { diagnosis: 'The lock may be gone.', fix: 'reinspect_same_bundle', reason: 'r' } };
    runner.steps.push(reinspect, reinspect);
    await h.engine.approve(created.id);
    await settle();
    const cycle = async () => {
      t.mock.timers.tick(30_000);
      await settle();
      t.mock.timers.tick(120_000);
      await settle();
      t.mock.timers.tick(0); // the retry's wake
      await settle();
    };
    await cycle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(runner.requests.length, 2, 'the batch, then one recovery call');
    assert.equal(job.recovery?.signature, 'lock');
    assert.equal(job.recovery?.approvedSha256, PLAN.approval_sha256);
    assert.ok(job.turns.some((x) => /stayed locked for several minutes\. Distill’s recovery is looking at it/.test(x.text)), 'recovery is on it');
    assert.ok(!job.turns.some((x) => /Approve again when it is closed/.test(x.text)), 'the owner isn’t told to act while recovery works');
    await cycle();
    await cycle();
    job = h.engine.getJob(created.id)!;
    assert.equal(runner.requests.length, 3, 'two agent attempts in all, never more');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.match(job.recovery?.summary ?? '', /kept your vault locked/);
    assert.equal(job.queuedApply?.planSha256, undefined, 'back to the owner');
    assert.ok(applies >= 3);
    assert.equal((await h.engine.status()).pendingApprovals, 1);
  });

  test('lock: the core gone by the time the waits are spent: it waits under the approved hash at $0 (2026-10-08)', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: Date.parse('2026-10-06T10:00:00Z') });
    const runner = sandboxed();
    h = setup([], { runner, apply: () => lock, now: () => new Date(Date.now()) });
    const created = await firstJob();
    runner.steps.push(needsApproval(h.bundle(created)));
    await settle();
    await h.engine.approve(created.id);
    await settle();
    fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
    t.mock.timers.tick(30_000);
    await settle();
    t.mock.timers.tick(120_000);
    await settle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(runner.requests.length, 1, 'only the batch: no recovery call');
    // The pump holds it before any inspect, rule or agent: still approved under its hash, the reason said once.
    assert.equal(job.queuedApply?.planSha256, PLAN.approval_sha256);
    assert.match(job.turns.at(-1)!.text, /^Not applied yet: Distill can't find its vault core at /);
    assert.equal(job.recovery, undefined, 'no rule, agent or wake is working on it');
    assert.equal(job.state, 'awaitingApproval');
  });

  for (const automatic of [true, false]) test(`lock: the core goes during the last locked apply: recovery stops at $0 under the approved hash (recoverAfterRule, automatic ${automatic})`, async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: Date.parse('2026-10-06T10:00:00Z') });
    const runner = sandboxed();
    let applies = 0;
    const apply = () => {
      // The third locked apply is the one that spends the rule; the checkout is deleted while it runs.
      if (++applies === 3) fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
      return lock;
    };
    // Automatic off: without its own guard, recoverAfterRule would give up with the lock's words, not the real cause.
    h = setup([], { runner, apply, now: () => new Date(Date.now()), settings: { recovery: { automatic } } });
    const created = await firstJob();
    runner.steps.push(needsApproval(h.bundle(created)));
    await settle();
    await h.engine.approve(created.id);
    await settle();
    t.mock.timers.tick(30_000);
    await settle();
    t.mock.timers.tick(120_000);
    await settle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(applies, 3);
    assert.equal(runner.requests.length, 1, 'only the batch: no recovery call');
    assert.equal(job.recovery?.signature, 'lock');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.match(job.recovery?.summary ?? '', /^Distill can't find its vault core at /);
    assert.equal(job.recovery?.approvedSha256, PLAN.approval_sha256);
  });

  test('the lock waits count per batch: another batch meeting a lock starts at 30 s', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: Date.parse('2026-10-06T10:00:00Z') });
    const runner = sandboxed();
    let calls = 0;
    const ok: ProcessOutput = { status: 0, stdout: Buffer.from(JSON.stringify({ operation_id: 'op-1', changed_paths: ['wiki/a.md'] })), stderr: Buffer.alloc(0) };
    h = setup([], { runner, apply: () => (++calls <= 2 ? lock : ok), now: () => new Date(Date.now()) });
    const a = await firstJob();
    runner.steps.push(needsApproval(h.bundle(a)));
    await settle();
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    const b = (await h.engine.processQueue({ force: true }))!;
    runner.steps.push(needsApproval(h.bundle(b)));
    await settle();
    await h.engine.approve(a.id); // the lock: a waits 30 s
    await settle();
    h.engine.unqueue(a.id); // the owner takes a out while it waits
    t.mock.timers.tick(30_000);
    await settle();
    await h.engine.approve(b.id); // the lock again, for another batch
    await settle();
    assert.equal(h.engine.getJob(b.id)!.state, 'awaitingApproval');
    t.mock.timers.tick(30_000);
    await settle();
    assert.equal(h.engine.getJob(b.id)!.state, 'completed', 'b waited 30 s, not the 2 min of a’s second wait');
  });

  test('a spent lock with Recover automatically off tells the owner to approve again', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: Date.parse('2026-10-06T10:00:00Z') });
    const runner = sandboxed();
    h = setup([], { runner, apply: () => lock, now: () => new Date(Date.now()), settings: { recovery: { automatic: false } } });
    const created = await firstJob();
    runner.steps.push(needsApproval(h.bundle(created)));
    await settle();
    await h.engine.approve(created.id);
    await settle();
    t.mock.timers.tick(30_000);
    await settle();
    t.mock.timers.tick(120_000);
    await settle();
    const job = h.engine.getJob(created.id)!;
    assert.match(job.turns.at(-1)!.text, /Approve again when it is closed/);
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(runner.requests.length, 1, 'no agent call');
  });

  test('session-gone while queued: recovery proposes a new session ($0, no agent); nothing starts by itself', async () => {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    await h.engine.stop();
    const jobsFile = path.join(tmp, 'state', 'jobs.json');
    const saved = JSON.parse(fs.readFileSync(jobsFile, 'utf8')) as Array<Record<string, unknown>>;
    const j = saved.find((x) => x.id === created.id)!;
    j.queuedApply = { at: '2026-10-06T08:59:00Z', order: 1, planSha256: PLAN.approval_sha256, bundlePath: h.bundle(created), labels: 'confirm', carries: 'confirm' };
    const runner = new FakeRunner([]);
    runner.status = 'missing';
    h = setup([], { runner, jobs: saved });
    await h.engine.start();
    await h.engine.whenIdle();
    await new Promise((r) => setTimeout(r, 20));
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.recovery?.signature, 'session-gone');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(job.recovery?.proposal, 'new_session');
    assert.match(job.recovery?.summary ?? '', /session isn’t available anymore/);
    assert.equal(runner.requests.length, 0, 'no agent call, no new session');
    assert.equal((await h.engine.status()).pendingApprovals, 1);
  });

  test('not-recorded: an apply turn that didn’t report the operation is recorded when the vault’s journal has it', async () => {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    const dir = path.join(h.vault, '.vault-meta', 'transactions', PLAN.operation_id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'journal.json'), JSON.stringify({ state: 'complete', approval_sha256: PLAN.approval_sha256 }));
    h.runner.steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: 'op-other' } });
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.state, 'completed');
    assert.equal(job.operationID, PLAN.operation_id, 'recorded from the journal');
    assert.match(job.turns.at(-1)!.text, /found in the vault’s journal/);
  });

  test('not-recorded without a journal entry stays not recorded (nothing is guessed)', async () => {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    h.runner.steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: 'op-other' } });
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(job.operationID, undefined);
    assert.match(job.turns.at(-1)!.text, /Nothing recorded as applied/);
  });
});

describe('a missing vault core (review-queue.md, 2026-10-08)', () => {
  /** The product checkout disappears while the batch runs (a deleted worktree); every inspect then fails. */
  function deleteCoreOnInspect(): (bundle: string) => ProcessOutput {
    return () => {
      fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
      return { status: 2, stdout: Buffer.alloc(0), stderr: Buffer.from(`python3: can't open file '${tmp}/product/scripts/claude-obsidian.py': [Errno 2] No such file or directory`) };
    };
  }

  test('a plan the core could not check because the core is gone: no rule turn, no agent, $0, the path named', async () => {
    h = setup([], { inspect: deleteCoreOnInspect() });
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 1, 'only the batch itself ran');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(job.recovery?.signature, 'plan-error');
    assert.deepEqual(job.recovery?.attempts, []);
    assert.equal(job.recovery?.attempts.reduce((n, a) => n + a.costUSD, 0), 0);
    const core = path.join(tmp, 'product', 'scripts', 'claude-obsidian.py');
    assert.equal(job.recovery?.summary, `Distill can't find its vault core at ${core}. Rebuild or reinstall Distill from a claude-obsidian checkout that still exists.`);
    assert.equal(job.recovery?.proposal, undefined);
    // Let recovery try again says the same thing and sends nothing.
    assert.throws(() => h.engine.tryRecoveryAgain(created.id), /can't find its vault core/);
    assert.equal(h.runner.requests.length, 1);
    assert.ok((await h.engine.status()).problems.some((p) => p.code === 'missingCore'));
  });

  test('blocked commands with the core gone: Distill doesn’t answer the session; $0 and the path named', async () => {
    h = setup([]);
    const created = await firstJob();
    fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
    h.runner.steps.push({
      structured: { status: 'needs_input', summary: 'I need to run the core.' },
      denials: [{ toolName: 'Bash', input: { command: 'python3 scripts/claude-obsidian.py status' } }],
    });
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 1, 'no answer was sent');
    assert.equal(job.recovery?.signature, 'denial');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.deepEqual(job.recovery?.attempts, []);
    assert.match(job.recovery?.summary ?? '', /^Distill can't find its vault core at /);
  });

  test('approve with the core gone: no apply turn; it stays approved under its hash and applies once the core is back', async () => {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    const product = path.join(tmp, 'product');
    fs.renameSync(product, `${product}-away`);
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    let job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 1, 'no apply turn was sent');
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.queuedApply?.planSha256, PLAN.approval_sha256, 'approved and queued under its hash');
    assert.match(job.turns.at(-1)!.text, /^Not applied yet: Distill can't find its vault core at /);
    // Approving again says it once more only if something else was said since, and still sends nothing.
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, 1);
    assert.equal(h.engine.getJob(created.id)!.turns.filter((x) => /vault core at/.test(x.text)).length, 1);
    // The checkout is back: the queue applies it under the same approval.
    fs.renameSync(`${product}-away`, product);
    h.runner.steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: PLAN.operation_id, changed_paths: PLAN.changed_paths } });
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 2, 'the apply turn, once the core is back');
  });

  test('a batch held for a missing core applies on its own at the next tick once the core is back', async () => {
    h = setup([], { tickMs: 5 });
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    const product = path.join(tmp, 'product');
    fs.renameSync(product, `${product}-away`);
    await h.engine.approve(created.id);
    await h.engine.start();
    await new Promise((r) => setTimeout(r, 30));
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, 1, 'ticks while the core is away send nothing');
    assert.equal(h.engine.getJob(created.id)!.turns.filter((x) => /vault core at/.test(x.text)).length, 1, 'said once, not every tick');
    fs.renameSync(`${product}-away`, product);
    h.runner.steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: PLAN.operation_id, changed_paths: PLAN.changed_paths } });
    await new Promise((r) => setTimeout(r, 50));
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 2, 'the apply turn, with no click');
    assert.match(h.runner.requests[1]!.prompt, new RegExp(`APPROVED operation ${PLAN.operation_id} with approval_sha256 ${PLAN.approval_sha256}`));
    assert.equal(job.operationID, PLAN.operation_id);
    await h.engine.stop();
  });

  test('a recovery waiting out its minute stops at $0 when the core is gone by then', async (t) => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    let clock = Date.parse('2026-10-05T10:00:00Z');
    h = setup([], { now: () => new Date(clock) });
    const bad = needsApproval('/tmp/elsewhere/bundle.json');
    h.runner.steps.push(bad, bad,
      { structured: { diagnosis: 'Wrong folder.', fix: 'rebuild_in_session', reason: 'r', guidance: 'Write the bundle inside the job directory.' } },
      bad);
    const created = await firstJob();
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(created.id)!.recovery?.state, 'waiting');
    const calls = h.runner.requests.length;
    fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
    clock += 61_000;
    t.mock.timers.tick(61_000);
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, calls, 'the wake never called the agent');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.match(job.recovery?.summary ?? '', /^Distill can't find its vault core at /);
    assert.equal(job.recovery?.waitUntil, undefined, 'no wait left to show');
    assert.equal(job.recovery?.proposal, undefined);
  });

  test('a saved root that lost its core heals to the checkout the core runs from: saved and announced', async () => {
    const other = path.join(tmp, 'other-checkout');
    fs.mkdirSync(path.join(other, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(other, 'scripts', 'claude-obsidian.py'), '# fake core\n');
    h = setup([], { detectProductRoot: () => other });
    await h.engine.updateSettings({ productRoot: path.join(tmp, 'deleted-worktree') });
    const s = await h.engine.status();
    assert.ok(!s.problems.some((p) => p.code === 'missingCore'));
    assert.equal(h.engine.getSettings().productRoot, other);
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'settings.json'), 'utf8')) as { productRoot: string };
    assert.equal(saved.productRoot, other);
    assert.ok(h.events.some((e) => e.type === 'settings.repaired' && e.key === 'productRoot' && e.from === path.join(tmp, 'deleted-worktree') && e.to === other));
    // Clients showing Settings get the healed root, not the stale one.
    const lastSettings = h.events.filter((e): e is Extract<CoreEvent, { type: 'settings' }> => e.type === 'settings').at(-1);
    assert.equal(lastSettings?.settings.productRoot, other);
  });

  test('a checkout gone mid-batch heals before recovery decides: recovery goes on as usual, not the $0 stop', async () => {
    const other = path.join(tmp, 'other-checkout');
    fs.mkdirSync(path.join(other, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(other, 'scripts', 'claude-obsidian.py'), '# fake core\n');
    h = setup([], { inspect: deleteCoreOnInspect(), detectProductRoot: () => other });
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.engine.getSettings().productRoot, other);
    assert.equal(job.recovery?.signature, 'plan-error');
    assert.doesNotMatch(job.recovery?.summary ?? '', /can't find its vault core/);
    assert.ok(h.runner.requests.length > 1, 'the rule turn or the agent ran');
  });

  test('a queued apply with the core gone is held before the session check: no new-session proposal, the hash kept ($0)', async () => {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    await h.engine.stop();
    const jobsFile = path.join(tmp, 'state', 'jobs.json');
    const saved = JSON.parse(fs.readFileSync(jobsFile, 'utf8')) as Array<Record<string, unknown>>;
    const j = saved.find((x) => x.id === created.id)!;
    j.queuedApply = { at: '2026-10-06T08:59:00Z', order: 1, planSha256: PLAN.approval_sha256, bundlePath: h.bundle(created), labels: 'confirm', carries: 'confirm' };
    const runner = new FakeRunner([]);
    runner.status = 'missing';
    h = setup([], { runner, jobs: saved });
    fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
    await h.engine.start();
    await h.engine.whenIdle();
    await new Promise((r) => setTimeout(r, 20));
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    // The pump holds it before the session check (2026-10-08, round 2): no new-session proposal, no turn.
    assert.equal(job.recovery?.proposal, undefined, 'a new session can’t help without the core');
    assert.equal(job.queuedApply?.planSha256, PLAN.approval_sha256, 'still approved under its hash');
    assert.match(job.turns.at(-1)!.text, /^Not applied yet: Distill can't find its vault core at /);
    assert.equal(runner.requests.length, 0);
  });

  /** A batch approved and queued before a restart (jobs.json), so the pump inspects it on start. */
  async function queuedBeforeRestart(o: { runner?: FakeRunner; inspect?: (bundle: string) => ProcessOutput; removeCore?: boolean; beforeStart?: (bundle: string) => void; detectProductRoot?: () => string } = {}): Promise<Job> {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    await h.engine.stop();
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, unknown>>;
    saved.find((x) => x.id === created.id)!.queuedApply = { at: '2026-10-06T08:59:00Z', order: 1, planSha256: PLAN.approval_sha256, bundlePath: h.bundle(created), labels: 'confirm', carries: 'confirm' };
    h = setup([], { jobs: saved, ...(o.runner ? { runner: o.runner } : {}), ...(o.inspect ? { inspect: o.inspect } : {}), ...(o.detectProductRoot ? { detectProductRoot: o.detectProductRoot } : {}) });
    if (o.removeCore) fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
    o.beforeStart?.(h.bundle(created));
    await h.engine.start();
    await h.engine.whenIdle();
    await new Promise((r) => setTimeout(r, 20));
    await h.engine.whenIdle();
    return h.engine.getJob(created.id)!;
  }

  test('a queued apply whose inspect fails with the core present and nothing changed goes back to the owner at $0', async () => {
    const job = await queuedBeforeRestart({ inspect: () => ({ status: 2, stdout: Buffer.alloc(0), stderr: Buffer.from('ERR INVALID_BUNDLE: bad\n') }) });
    assert.equal(h.runner.requests.length, 0, 'no rebuild turn');
    assert.equal(job.queuedApply?.planSha256, undefined, 'out of the queue: the owner approves again');
    assert.match(job.turns.at(-1)!.text, /couldn’t check this plan, and your vault hasn’t changed under it/);
    assert.ok(!job.turns.some((x) => /vault changed after this plan was built/.test(x.text)), 'no stale rebuild prompt');
    assert.equal(h.inspectCalls.filter((c) => c.includes('inspect')).length, 1, 'no root healed, so no second inspect');
  });

  test('a queued apply whose core goes during its inspect waits under its hash: not back to the owner, no rebuild', async () => {
    const job = await queuedBeforeRestart({ inspect: deleteCoreOnInspect() });
    assert.equal(h.runner.requests.length, 0);
    assert.equal(job.queuedApply?.planSha256, PLAN.approval_sha256, 'still approved under its hash');
    assert.match(job.turns.at(-1)!.text, /^Not applied yet: Distill can't find its vault core at /);
  });

  test('a queued apply whose inspect reports the core’s conflict (exit 75) is still rebuilt', async () => {
    const job = await queuedBeforeRestart({ inspect: () => ({ status: 75, stdout: Buffer.alloc(0), stderr: Buffer.from('ERR EXPECTED_HASH_MISMATCH: wiki/a.md changed\n') }) });
    assert.match(h.runner.requests.at(-1)?.prompt ?? '', /The vault changed after this plan was built/);
    assert.equal(job.queuedApply?.planSha256, undefined);
  });

  test('a queued apply whose inspect fails while its pages changed is still rebuilt', async () => {
    const job = await queuedBeforeRestart({
      inspect: () => ({ status: 2, stdout: Buffer.alloc(0), stderr: Buffer.from('ERR INVALID_BUNDLE: bad\n') }),
      beforeStart: (bundle) => {
        fs.writeFileSync(bundle, JSON.stringify({ expected_hashes: { 'wiki/a.md': null }, writes: [] }));
        fs.mkdirSync(path.join(tmp, 'vault', 'wiki'), { recursive: true });
        fs.writeFileSync(path.join(tmp, 'vault', 'wiki', 'a.md'), 'another batch wrote this\n');
      },
    });
    assert.match(h.runner.requests.at(-1)?.prompt ?? '', /The vault changed after this plan was built/);
    assert.equal(job.queuedApply?.planSha256, undefined);
  });

  test('a queued apply with the core gone: no rebuild, and the live log never says the vault changed', async () => {
    const job = await queuedBeforeRestart({ removeCore: true });
    assert.equal(h.runner.requests.length, 0);
    assert.equal(job.queuedApply?.planSha256, PLAN.approval_sha256);
    assert.ok(!job.turns.some((x) => /vault changed after/.test(x.text)), 'no STALE_REBUILD_PROMPT, so no “Not added: the vault changed …”');
    assert.match(job.turns.at(-1)!.text, /^Not applied yet: Distill can't find its vault core at /);
  });

  test('session-gone at the queue head keeps the approved hash on the recovery (q aliased the job’s queuedApply)', async () => {
    const runner = new FakeRunner([]);
    runner.status = 'missing';
    const job = await queuedBeforeRestart({ runner });
    assert.equal(job.recovery?.signature, 'session-gone');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.equal(job.recovery?.approvedSha256, PLAN.approval_sha256);
    assert.equal(job.queuedApply?.planSha256, undefined);
    assert.equal(runner.requests.length, 0);
  });

  test('an inspect that failed because the root was gone runs again, once, with the healed root', async () => {
    const other = path.join(tmp, 'other-checkout');
    fs.mkdirSync(path.join(other, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(other, 'scripts', 'claude-obsidian.py'), '# fake core\n');
    let inspects = 0;
    const runner = new FakeRunner([{ structured: { status: 'done', summary: 'Applied.', operation_id: PLAN.operation_id, changed_paths: PLAN.changed_paths } }]);
    const job = await queuedBeforeRestart({
      runner,
      detectProductRoot: () => other,
      inspect: () => {
        if (++inspects === 1) {
          fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
          return { status: 2, stdout: Buffer.alloc(0), stderr: Buffer.from('[Errno 2] No such file or directory') };
        }
        return { status: 0, stdout: Buffer.from(JSON.stringify(PLAN)), stderr: Buffer.alloc(0) };
      },
    });
    const inspected = h.inspectCalls.filter((c) => c.includes('inspect'));
    assert.equal(inspected.length, 2, 'inspected again after the heal');
    assert.equal(inspected[1]![1], path.join(other, 'scripts', 'claude-obsidian.py'));
    assert.ok(!job.turns.some((x) => /couldn’t check this plan/.test(x.text)), 'the old error never reached the owner');
    assert.equal(runner.requests.length, 1, 'the approved apply turn');
  });

  test('a healed root whose inspect also fails is inspected once more per pass, never again and again', async () => {
    // Each heal finds another checkout, which is gone by the time it is inspected: the worst case for a loop.
    let n = 0;
    const fresh = () => {
      const dir = path.join(tmp, `checkout-${++n}`);
      fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true });
      fs.writeFileSync(path.join(dir, 'scripts', 'claude-obsidian.py'), '# fake core\n');
      return dir;
    };
    const job = await queuedBeforeRestart({
      detectProductRoot: fresh,
      inspect: () => {
        fs.rmSync(path.join(h.engine.getSettings().productRoot, 'scripts'), { recursive: true, force: true });
        return { status: 2, stdout: Buffer.alloc(0), stderr: Buffer.from('[Errno 2] No such file or directory') };
      },
    });
    assert.equal(h.inspectCalls.filter((c) => c.includes('inspect')).length, 2, 'the first inspect and one more after the heal');
    assert.equal(h.runner.requests.length, 0);
    // The second error isn't retried again: it goes to the owner at $0, never to a rebuild.
    assert.match(job.turns.at(-1)!.text, /couldn’t check this plan, and your vault hasn’t changed under it/);
    assert.ok(!job.turns.some((x) => /vault changed after this plan was built/.test(x.text)));
  });

  /** A batch whose recovery waits out its minute when the engine starts; the core is gone by then. */
  async function waitingAtRestart(recovery: Record<string, unknown>): Promise<Job> {
    h = setup([]);
    const created = await firstJob();
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    await h.engine.stop();
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, unknown>>;
    saved.find((x) => x.id === created.id)!.recovery = recovery;
    h = setup([], { jobs: saved });
    fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
    await h.engine.start();
    await new Promise((r) => setTimeout(r, 20));
    await h.engine.whenIdle();
    return h.engine.getJob(created.id)!;
  }

  test('a stop for the missing core drops a proposal and a wake time, and keeps the approved hash', async () => {
    const job = await waitingAtRestart({
      state: 'waiting', signature: 'plan-error', attempts: [{ at: '2026-10-06T09:00:00Z', by: 'agent', fix: 'split_batch', result: 'failed', costUSD: 0.02 }],
      denialAnswers: 0, proposal: 'split_batch', groups: [['inbox/a.md']], waitUntil: '2000-01-01T00:00:00Z', approvedSha256: PLAN.approval_sha256,
    });
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.match(job.recovery?.summary ?? '', /^Distill can't find its vault core at /);
    assert.equal(job.recovery?.proposal, undefined, 'nothing the owner could confirm helps without the core');
    assert.equal(job.recovery?.waitUntil, undefined);
    assert.equal(job.recovery?.approvedSha256, PLAN.approval_sha256);
    assert.equal(job.recovery?.attempts.length, 1, 'no new attempt');
  });

  test('a rule turn still running when the core goes is settled as failed, not left running', async () => {
    const bad = needsApproval('/tmp/elsewhere/bundle.json');
    h = setup([bad, bad]);
    const run = h.runner.run.bind(h.runner);
    // The rule's rebuild turn starts with the core there; the checkout is deleted while it runs.
    h.runner.run = async (r) => {
      if (h.runner.requests.length === 1) fs.rmSync(path.join(tmp, 'product'), { recursive: true, force: true });
      return run(r);
    };
    const created = await firstJob();
    await h.engine.whenIdle();
    const job = h.engine.getJob(created.id)!;
    assert.equal(h.runner.requests.length, 2, 'the batch and the rule turn; no agent');
    assert.equal(job.recovery?.state, 'gaveUp');
    assert.deepEqual(job.recovery?.attempts.map((a) => [a.by, a.result]), [['rule', 'failed']]);
    assert.match(job.recovery?.summary ?? '', /^Distill can't find its vault core at /);
  });

  test('a root healed at load is announced when the engine starts', async () => {
    const other = path.join(tmp, 'other-checkout');
    fs.mkdirSync(path.join(other, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(other, 'scripts', 'claude-obsidian.py'), '# fake core\n');
    h = setup([], { detectProductRoot: () => other, settings: { productRoot: path.join(tmp, 'deleted-worktree') } });
    assert.equal(h.engine.getSettings().productRoot, other, 'healed before anything reads it');
    assert.equal((JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'settings.json'), 'utf8')) as { productRoot: string }).productRoot, other);
    assert.equal(h.events.length, 0);
    await h.engine.start();
    assert.ok(h.events.some((e) => e.type === 'settings.repaired' && e.key === 'productRoot' && e.to === other));
    await h.engine.stop();
  });
});

describe('Done on a batch that added nothing (review-queue.md, 2026-10-09)', () => {
  const APPLIED: Step = { structured: { status: 'done', summary: 'Applied.', operation_id: PLAN.operation_id, changed_paths: PLAN.changed_paths } };
  const FAILED: Step = { structured: { status: 'failed', summary: 'The vault core was not found.' } };

  /** A batch of `names` from the queue, approved; its apply turn answers `apply`. */
  async function approvedBatch(names: string[], apply: Step, o: { tickMs?: number; autoProcessEnabled?: boolean } = {}): Promise<Job> {
    h = setup([], { ...(o.tickMs ? { tickMs: o.tickMs } : {}), settings: { autoProcessEnabled: o.autoProcessEnabled === true } });
    for (const n of names) fs.writeFileSync(path.join(h.queue, n), `# ${n}\n`);
    const created = (await h.engine.processQueue({ force: true }))!;
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    h.runner.steps.push(apply);
    await h.engine.approve(created.id);
    await h.engine.whenIdle();
    return h.engine.getJob(created.id)!;
  }

  /** The vault already has a source page for this inbox file (as the re-read finds it). */
  function pageFor(file: string, name: string): void {
    fs.mkdirSync(path.join(h.vault, 'wiki', 'sources'), { recursive: true });
    fs.writeFileSync(path.join(h.vault, 'wiki', 'sources', `${name}.md`), `---\nsource_path: ${file}\n---\n# ${name}\n`);
  }

  /** reread.json keeps only plans with a group not started yet (it is removed when none is left). */
  const reread = () => {
    const file = path.join(tmp, 'state', 'reread.json');
    return (fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { plans: [] }) as { plans: { id: string; reason?: string; fromJob?: string; groups: { files: string[]; jobId?: string }[] }[] };
  };
  const released = () => reread().plans.filter((p) => p.reason === 'released');

  test('a failed batch: its sources go to a gated re-read; Done itself sends nothing; the next batch takes them', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    assert.equal(job.state, 'failed');
    assert.ok(job.approvedChange, 'approved, so Done is offered');
    const calls = h.runner.requests.length;
    const done = await h.engine.finishReview!(job.id);
    await h.engine.whenIdle();
    assert.ok(done.reviewDoneAt);
    assert.deepEqual([...done.released!.files].sort(), [...job.files].sort());
    assert.deepEqual(done.released!.inVault, []);
    assert.match(done.turns.at(-1)!.text, /^Not added\. Its 2 sources not in your vault are read again with the next batch\.$/);
    assert.equal(released().length, 1);
    assert.equal(released()[0]!.fromJob, job.id);
    assert.equal(h.runner.requests.length, calls, 'nothing runs from Done (nor from the job change it makes)');
    assert.equal(h.engine.listJobs().length, 1);
    // The next batch the rules allow takes them first.
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    const next = (await h.engine.processQueue({ force: true }))!;
    assert.equal(next.reread?.fromJob, job.id);
    assert.equal(next.reread?.reason, 'released');
    assert.deepEqual([...next.files].sort(), [...job.files].sort());
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, calls + 1);
    assert.equal(released().length, 0, 'every group started, so the plan is done');
    assert.equal(await h.engine.processQueue({ force: true }), null, 'started once');
  });

  test('the timer never starts released sources early: not on ticks, not after a restart, only with a batch', async () => {
    const job = await approvedBatch(['a.md'], FAILED, { tickMs: 5 });
    await h.engine.finishReview!(job.id);
    await h.engine.start();
    await new Promise((r) => setTimeout(r, 40));
    await h.engine.whenIdle();
    assert.equal(h.engine.listJobs().length, 1, 'auto processing off: nothing on the ticks');
    await h.engine.stop();
    // A restart keeps the plan gated (its reason is saved).
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as unknown[];
    h = setup([], { tickMs: 5, jobs: saved });
    await h.engine.start();
    await new Promise((r) => setTimeout(r, 40));
    await h.engine.whenIdle();
    assert.equal(h.engine.listJobs().length, 1);
    assert.equal(released().length, 1);
    await h.engine.stop();
  });

  test('Done on an applied batch is unchanged: no release, no turn, no re-read', async () => {
    const job = await approvedBatch(['a.md'], APPLIED);
    assert.equal(job.state, 'completed');
    const turns = job.turns.length;
    const done = await h.engine.finishReview!(job.id);
    assert.ok(done.reviewDoneAt);
    assert.equal(done.released, undefined);
    assert.equal(done.turns.length, turns);
    assert.equal(released().length, 0);
  });

  test('sources already in the vault, removed in Review, held for a full read, or gone are not read again', async () => {
    const job = await approvedBatch(['a.md', 'b.md', 'c.md', 'd.md', 'e.md'], FAILED);
    const [a, b, c, d, e] = [...job.files].sort();
    pageFor(a!, 'A');
    fs.rmSync(path.join(h.vault, e!));
    await h.engine.stop();
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, any>>;
    const j = saved.find((x) => x.id === job.id)!;
    j.approval.sources = [
      { page: 'wiki/sources/B.md', title: 'B', source: b, labels: [], by: 'none', removed: true },
      { page: 'wiki/sources/D.md', title: 'D', source: d, labels: [], by: 'none' },
    ];
    j.stopped = [{ file: c, reason: 'it isn’t valid UTF-8 text', at: '2026-10-09T10:00:00Z' }];
    h = setup([], { jobs: saved });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released!.files, [d]);
    assert.deepEqual(done.released!.inVault, [a]);
    assert.deepEqual(done.released!.missing, [e]);
    assert.equal(done.turns.at(-1)!.text, 'Not added. Its 1 source not in your vault is read again with the next batch. 1 source already in your vault stays as it is. 1 source can\'t be read again: the inbox file is gone.');
    assert.deepEqual(released()[0]!.groups.flatMap((g) => g.files), [d]);
    // The held source is still listed for its own Try again.
    assert.deepEqual((await h.engine.listHeld()).map((x) => x.file), [c]);
  });

  test('a batch where one part applied releases only the sources of the part that didn’t', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await h.engine.stop();
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, any>>;
    const j = saved.find((x) => x.id === job.id)!;
    // As the engine leaves it: part A applied (its page may not be found by a scan), part B failed after.
    j.operationID = 'op-part-a';
    j.parts = [{ operationID: 'op-part-a', pages: ['wiki/sources/A.md'], labels: 'confirm', at: '2026-10-09T10:00:00Z' }];
    j.approval.sources = [
      { page: 'wiki/sources/A.md', title: 'A', source: a, labels: [], by: 'none' },
      { page: 'wiki/sources/B.md', title: 'B', source: b, labels: [], by: 'none' },
    ];
    h = setup([], { jobs: saved });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released!.files, [b]);
  });

  test('a batch that completed without an operation added nothing: its sources are released', async () => {
    const job = await approvedBatch(['a.md'], APPLIED);
    await h.engine.stop();
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, any>>;
    delete saved.find((x) => x.id === job.id)!.operationID;
    h = setup([], { jobs: saved });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released!.files, job.files);
  });

  test('Done twice releases once; a batch already being read again releases nothing', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await h.engine.finishReview!(job.id);
    const turns = h.engine.getJob(job.id)!.turns.length;
    await h.engine.finishReview!(job.id);
    assert.equal(released().length, 1);
    assert.equal(h.engine.getJob(job.id)!.turns.length, turns);

    const other = await approvedBatch(['b.md'], FAILED);
    // The owner already ran `distill batch reread --job` (it waits for the vault).
    await h.engine.rereadSources({ jobId: other.id });
    const before = reread().plans.length;
    const done = await h.engine.finishReview!(other.id);
    assert.equal(done.released?.alreadyRereading, true);
    assert.deepEqual(done.released?.files, []);
    assert.equal(reread().plans.length, before, 'no second re-read');
    assert.equal(done.turns.at(-1)!.text, 'Not added. Its sources are already being read again.');
  });

  /** The batch as jobs.json holds it, changed by `edit`, then loaded by a fresh engine. */
  async function reloaded(job: Job, edit: (j: Record<string, any>) => void): Promise<void> {
    await h.engine.stop();
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, any>>;
    edit(saved.find((x) => x.id === job.id)!);
    h = setup([], { jobs: saved });
  }

  for (const leftOver of ['pendingPart', 'needsRebuild'] as const) {
    test(`completed after one part, with the rest left over (${leftOver}): only the rest is released`, async () => {
      const job = await approvedBatch(['a.md', 'b.md'], APPLIED);
      const [a, b] = [...job.files].sort();
      await reloaded(job, (j) => {
        j.parts = [{ operationID: PLAN.operation_id, pages: ['wiki/sources/A.md'], labels: 'confirm', at: '2026-10-09T10:00:00Z' }];
        j.approval = {
          summary: 's', questions: [], denials: [], skipped: [],
          sources: [{ page: 'wiki/sources/A.md', title: 'A', source: a, labels: [], by: 'none' }, { page: 'wiki/sources/B.md', title: 'B', source: b, labels: [], by: 'none' }],
          ...(leftOver === 'needsRebuild' ? { needsRebuild: true } : {}),
        };
        if (leftOver === 'pendingPart') j.pendingPart = { reason: 'remaining', expected: { 'wiki/sources/B.md': 'f'.repeat(64) }, excluded: ['wiki/sources/A.md'], labels: 'confirm' };
      });
      assert.equal(h.engine.getJob(job.id)!.state, 'completed');
      const done = await h.engine.finishReview!(job.id);
      assert.deepEqual(done.released?.files, [b]);
    });
  }

  for (const stopped of ['rejected', 'cancelled'] as const) {
    test(`a batch the owner ${stopped} is never released: they stopped it`, async () => {
      const job = await approvedBatch(['a.md'], FAILED);
      await reloaded(job, (j) => { j.state = stopped; });
      const done = await h.engine.finishReview!(job.id);
      assert.ok(done.reviewDoneAt);
      assert.equal(done.released, undefined);
      assert.equal(released().length, 0);
    });
  }

  test('a batch that isn’t one of sources (labels) is never released', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await reloaded(job, (j) => { j.kind = 'labels'; });
    const done = await h.engine.finishReview!(job.id);
    assert.equal(done.released, undefined);
    assert.equal(released().length, 0);
  });

  test('a re-read of this batch still waiting for the vault counts as already reading; a finished one doesn’t', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    // Another batch holds the vault, so the owner's re-read waits.
    fs.writeFileSync(path.join(h.queue, 'busy.md'), '# busy\n');
    h.runner.steps.push({ hang: true, structured: { status: 'done', summary: 'x' } });
    const busy = (await h.engine.processQueue({ force: true }))!;
    const asked = await h.engine.rereadSources({ jobId: job.id });
    assert.equal(asked.waiting, 1);
    const done = await h.engine.finishReview!(job.id);
    assert.equal(done.released?.alreadyRereading, true);
    await h.engine.cancel(busy.id);
    await h.engine.whenIdle();

    // A re-read of the batch that already ended (it failed) doesn't stop the release.
    const other = await approvedBatch(['b.md'], FAILED);
    h.runner.steps.push(FAILED);
    await h.engine.rereadSources({ jobId: other.id });
    await h.engine.whenIdle();
    assert.ok(h.engine.listJobs().some((j) => j.reread?.fromJob === other.id && j.state === 'failed'));
    const released2 = await h.engine.finishReview!(other.id);
    assert.deepEqual(released2.released?.files, other.files);
  });

  /** The batch's apply turn fails: Done is offered on it. */
  async function approveAndFail(id: string): Promise<void> {
    h.runner.steps.push(FAILED);
    await h.engine.approve(id);
    await h.engine.whenIdle();
  }

  /** The owner's `distill batch reread --job <id>`, its batch waiting in Review. */
  async function ownerRereadInReview(jobId: string): Promise<Job> {
    await h.engine.rereadSources({ jobId });
    const rr = h.engine.listJobs().find((j) => j.reread?.fromJob === jobId)!;
    h.runner.steps.push(needsApproval(h.bundle(rr)));
    await h.engine.whenIdle();
    return h.engine.getJob(rr.id)!;
  }

  test('real data (job-20261008-101155-3caf): the owner re-read it by hand, then pressed Done: no second plan', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const rr = await ownerRereadInReview(job.id);
    assert.equal(rr.state, 'awaitingApproval', 'the owner’s re-read waits in Review');
    const calls = h.runner.requests.length;
    const done = await h.engine.finishReview!(job.id);
    assert.equal(done.released?.alreadyRereading, true);
    assert.deepEqual(done.released?.files, []);
    assert.equal(released().length, 0, 'no second plan');
    assert.equal(h.runner.requests.length, calls);
    assert.equal(await h.engine.processQueue({ force: true }), null, 'nothing extra to start');
  });

  test('released names the plan it made', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    const done = await h.engine.finishReview!(job.id);
    assert.equal(done.released?.rereadId, released()[0]!.id);
  });

  test('a folder item is released as one folder, and its re-read batch keeps it', async () => {
    h = setup([]);
    fs.mkdirSync(path.join(h.queue, 'Trip'));
    fs.writeFileSync(path.join(h.queue, 'Trip', 'x.md'), '# x\n');
    fs.writeFileSync(path.join(h.queue, 'Trip', 'y.md'), '# y\n');
    const created = (await h.engine.processQueue({ force: true }))!;
    assert.equal(created.folders?.length, 1, 'the queue folder is one item');
    h.runner.steps.push(needsApproval(h.bundle(created)));
    await h.engine.whenIdle();
    await approveAndFail(created.id);
    await h.engine.finishReview!(created.id);
    assert.deepEqual(released()[0]!.groups[0]!.files.length, 2);
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    const next = (await h.engine.processQueue({ force: true }))!;
    assert.deepEqual(next.folders, created.folders);
  });

  // Found by the round-4 verifier (2026-10-09); fixed in round 4c.
  test('double spend: Done, then the owner re-reads the same batch by hand: one read of the source, not two', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await h.engine.finishReview!(job.id);
    await ownerRereadInReview(job.id);
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.processQueue({ force: true });
    await h.engine.whenIdle();
    const readers = h.engine.listJobs().filter((j) => j.id !== job.id && j.files.includes(job.files[0]!));
    assert.equal(readers.length, 1, `read by ${readers.map((j) => j.reread?.reason ?? 'manual').join(' and ')}`);
  });

  test('double spend: Done on a batch and on the owner’s failed re-read of it: one plan, not two with the same source', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    const rr = await ownerRereadInReview(job.id);
    await approveAndFail(rr.id);
    await h.engine.finishReview!(job.id);
    await h.engine.finishReview!(rr.id);
    const withA = released().filter((p) => p.groups.some((g) => g.files.includes(job.files[0]!)));
    assert.equal(withA.length, 1);
  });

  test('the cap holds through a hand-made re-read of a released re-read', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await h.engine.finishReview!(job.id);
    const r1 = (await h.engine.processQueue({ force: true }))!;
    h.runner.steps.push(needsApproval(h.bundle(r1)));
    await h.engine.whenIdle();
    await approveAndFail(r1.id);
    assert.ok((await h.engine.finishReview!(r1.id)).released?.notAgain, 'capped');
    const r2 = await ownerRereadInReview(r1.id);
    await approveAndFail(r2.id);
    const again = await h.engine.finishReview!(r2.id);
    assert.deepEqual(again.released?.files ?? [], [], 'a third automatic read of the same source');
  });

  /** reread.json and jobs.json as a test shapes them, read by a fresh engine. */
  async function restartWith(o: { plans?: (p: Record<string, any>[]) => void; jobs?: (j: Array<Record<string, any>>) => void }): Promise<void> {
    await h.engine.stop();
    const planFile = path.join(tmp, 'state', 'reread.json');
    const plans = (fs.existsSync(planFile) ? JSON.parse(fs.readFileSync(planFile, 'utf8')) : { plans: [] }) as { plans: Record<string, any>[] };
    o.plans?.(plans.plans);
    fs.writeFileSync(planFile, JSON.stringify(plans));
    const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, any>>;
    o.jobs?.(saved);
    h = setup([], { jobs: saved });
  }

  const plan = (id: string, groups: Record<string, unknown>[], extra: Record<string, unknown> = {}) =>
    ({ id, vaultPath: path.join(tmp, 'vault'), createdAt: '2026-10-09T10:00:00Z', perBatch: 0, tokenBudget: 100000, groups, ...extra });

  test('a started group stays in its plan when the owner re-reads its file; only waiting groups give files up', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await restartWith({ plans: (p) => p.push(plan('reread-rel', [{ files: [a], jobId: 'job-started' }, { files: [b] }], { reason: 'released', fromJob: 'job-x' })) });
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.rereadSources({ files: [a!] });
    await h.engine.whenIdle();
    assert.deepEqual(reread().plans.find((p) => p.id === 'reread-rel')!.groups, [{ files: [a], jobId: 'job-started' }, { files: [b] }]);
  });

  test('another vault’s waiting re-reads and batches never hold this vault’s files; a finished group doesn’t either', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    const [a] = job.files;
    await restartWith({
      plans: (p) => {
        p.push(plan('reread-other', [{ files: [a] }], { vaultPath: path.join(tmp, 'elsewhere'), reason: 'manual' }));
        p.push(plan('reread-done', [{ files: [a], jobId: 'job-finished' }, { files: ['inbox/z.md'] }], { reason: 'manual' }));
      },
      jobs: (js) => js.push({ ...js[0], id: 'job-other-vault', vaultPath: path.join(tmp, 'elsewhere'), state: 'awaitingApproval', reread: { id: 'r', group: 1, groups: 1 } }),
    });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, [a]);
  });

  test('a re-read batch in Review holds its files: Done leaves them for it', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await h.engine.rereadSources({ files: [a!] });
    const rr = h.engine.listJobs().find((j) => j.reread && j.files.includes(a!))!;
    h.runner.steps.push(needsApproval(h.bundle(rr)));
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(rr.id)!.state, 'awaitingApproval');
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, [b]);
    assert.deepEqual(done.released?.alreadyQueued, [a]);
  });

  test('the chain is walked to its end: a source released two re-reads up stays in inbox/', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    const [a] = job.files;
    await restartWith({
      jobs: (js) => {
        const j = js.find((x) => x.id === job.id)!;
        js.push({ ...j, id: 'job-root', released: { at: 't', files: [a], inVault: [], missing: [] } });
        js.push({ ...j, id: 'job-r1', state: 'failed', reread: { id: 'r1', group: 1, groups: 1, fromJob: 'job-root', reason: 'manual' } });
        j.reread = { id: 'r2', group: 1, groups: 1, fromJob: 'job-r1', reason: 'manual' };
      },
    });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, []);
    assert.deepEqual(done.released?.notAgain, [a]);
  });

  test('a re-read of a released re-read whose own origin is gone from History is still capped', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await restartWith({
      jobs: (js) => {
        const j = js.find((x) => x.id === job.id)!;
        js.push({ ...j, id: 'job-r1', state: 'failed', reread: { id: 'r1', group: 1, groups: 1, fromJob: 'job-pruned', reason: 'released' } });
        j.reread = { id: 'r2', group: 1, groups: 1, fromJob: 'job-r1', reason: 'manual' };
      },
    });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, []);
    assert.deepEqual(done.released?.notAgain, job.files);
  });

  test('the owner’s re-read of one released file takes it out of the waiting group; the rest still waits', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await h.engine.finishReview!(job.id);
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.rereadSources({ files: [a!] });
    await h.engine.whenIdle();
    assert.deepEqual(released()[0]!.groups.map((g) => g.files), [[b]]);
    // A re-read of the last one empties the plan.
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.rereadSources({ files: [b!] });
    await h.engine.whenIdle();
    assert.equal(released().length, 0);
  });

  test('a released folder keeps only its files not yet in the vault, and its prompt says not to read the others', async () => {
    const job = await approvedBatch(['solo.md'], FAILED);
    await reloaded(job, (j) => {
      const dir = path.join(tmp, 'vault', 'inbox', 'notes');
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'one.md'), '# one\n');
      fs.writeFileSync(path.join(dir, 'two.md'), '# two\n');
      j.files = ['inbox/notes/one.md', 'inbox/notes/two.md'];
      j.folders = ['inbox/notes'];
    });
    pageFor('inbox/notes/one.md', 'One');
    await h.engine.finishReview!(job.id);
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    const next = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    assert.deepEqual(next.files, ['inbox/notes/two.md']);
    const prompt = h.runner.requests.at(-1)!.prompt;
    assert.match(prompt, /- notes\/one\.md \(\d+ B, not in this batch, not read\)/);
    assert.match(prompt, /- notes\/two\.md \(\d+ B\)\n/);
  });

  test('the owner’s re-read leaves out a file another read holds, says which, and reads the rest', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    fs.writeFileSync(path.join(h.queue, 'busy.md'), '# busy\n');
    h.runner.steps.push({ hang: true, structured: { status: 'done', summary: 'x' } });
    const busy = (await h.engine.processQueue({ force: true }))!;
    await h.engine.rereadSources({ files: [a!] }); // waits behind the busy batch
    const res = await h.engine.rereadSources({ files: [a!, b!] });
    assert.deepEqual(res.groups.flatMap((g) => g.files), [b]);
    assert.deepEqual(res.skipped, [{ path: a, reason: 'already being read again' }]);
    await h.engine.cancel(busy.id);
    await h.engine.whenIdle();
  });

  test('Try again on a held source that a running batch already reads is refused in the same words', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    const [a] = job.files;
    await reloaded(job, (j) => { j.stopped = [{ file: a, reason: 'it isn’t valid UTF-8 text', at: '2026-10-09T10:00:00Z' }]; });
    h.runner.steps.push({ hang: true, structured: { status: 'done', summary: 'x' } });
    const first = await h.engine.retryHeld(a!);
    assert.equal(first.started.length, 1);
    await assert.rejects(h.engine.retryHeld(a!), /^CoreError: This source is already being read again\.$|This source is already being read again\./);
    await h.engine.cancel(first.started[0]!.id);
    await h.engine.whenIdle();
  });

  test('a folder item with one held file waits whole', async () => {
    const job = await approvedBatch(['solo.md'], FAILED);
    await reloaded(job, (j) => {
      const dir = path.join(tmp, 'vault', 'inbox', 'notes');
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'one.md'), '# one\n');
      fs.writeFileSync(path.join(dir, 'two.md'), '# two\n');
      j.files = [...j.files, 'inbox/notes/one.md', 'inbox/notes/two.md'];
      j.folders = ['inbox/notes'];
    });
    fs.writeFileSync(path.join(h.queue, 'busy.md'), '# busy\n');
    h.runner.steps.push({ hang: true, structured: { status: 'done', summary: 'x' } });
    const busy = (await h.engine.processQueue({ force: true }))!;
    await h.engine.rereadSources({ files: ['inbox/notes/one.md'] });
    const res = await h.engine.rereadSources({ jobId: job.id });
    assert.deepEqual(res.groups.flatMap((g) => g.files), [job.files[0]]);
    assert.deepEqual(res.skipped, [
      { path: 'inbox/notes/one.md', reason: 'already being read again' },
      { path: 'inbox/notes/two.md', reason: 'its folder is already being read again' },
    ]);
    await h.engine.cancel(busy.id);
    await h.engine.whenIdle();
  });

  test('a released folder item leaves whole when the owner re-reads one of its files', async () => {
    const job = await approvedBatch(['solo.md'], FAILED);
    await reloaded(job, (j) => {
      const dir = path.join(tmp, 'vault', 'inbox', 'notes');
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'one.md'), '# one\n');
      fs.writeFileSync(path.join(dir, 'two.md'), '# two\n');
      j.files = [...j.files, 'inbox/notes/one.md', 'inbox/notes/two.md'];
      j.folders = ['inbox/notes'];
    });
    await h.engine.finishReview!(job.id);
    const files = () => released().flatMap((p) => p.groups.flatMap((g) => g.files)).sort();
    assert.deepEqual(files(), [job.files[0], 'inbox/notes/one.md', 'inbox/notes/two.md'].sort());
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.rereadSources({ files: ['inbox/notes/one.md'] });
    await h.engine.whenIdle();
    assert.deepEqual(files(), [job.files[0]]);
    assert.ok(released().every((p) => p.groups.every((g) => !g.folders?.length)));
  });

  test('a re-read in another vault, or a plan that isn’t a release, is left alone', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await h.engine.finishReview!(job.id);
    const plan = released()[0]!;
    // The same path in a waiting re-read of another kind stays.
    await h.engine.stop();
    const file = path.join(tmp, 'state', 'reread.json');
    const saved = JSON.parse(fs.readFileSync(file, 'utf8')) as { plans: Record<string, unknown>[] };
    saved.plans.push({ ...saved.plans[0], id: 'reread-other-vault', vaultPath: path.join(tmp, 'elsewhere') });
    saved.plans.push({ ...saved.plans[0], id: 'reread-repair', reason: 'repair' });
    fs.writeFileSync(file, JSON.stringify(saved));
    h = setup([]);
    // The repair plan waiting in this vault holds the file, so the owner's re-read is refused; the release gives it up.
    await assert.rejects(h.engine.rereadSources({ files: job.files }), /This source is already being read again\./);
    const ids = reread().plans.map((p) => p.id).sort();
    assert.deepEqual(ids, ['reread-other-vault', 'reread-repair'], `${plan.id} absorbed, the others kept`);
  });

  test('Done leaves out a file another waiting re-read already holds, and says so', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    fs.writeFileSync(path.join(h.queue, 'busy.md'), '# busy\n');
    h.runner.steps.push({ hang: true, structured: { status: 'done', summary: 'x' } });
    const busy = (await h.engine.processQueue({ force: true }))!;
    await h.engine.rereadSources({ files: [a!] }); // waits: the vault is busy
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, [b]);
    assert.deepEqual(done.released?.alreadyQueued, [a]);
    assert.equal(done.turns.at(-1)!.text, 'Not added. Its 1 source not in your vault is read again with the next batch. 1 source already waits for another re-read.');
    await h.engine.cancel(busy.id);
    await h.engine.whenIdle();
  });

  test('a file an earlier batch of the chain released stays in inbox/, the rest is released; the words say both', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await reloaded(job, (j) => { j.released = { at: '2026-10-09T10:00:00Z', files: [a], inVault: [], missing: [] }; });
    const rr = await approvedBatch(['c.md'], FAILED);
    await reloaded(rr, (j) => { j.files = [a, b]; j.reread = { id: 'rr-m', group: 1, groups: 1, fromJob: job.id, reason: 'manual' }; });
    const done = await h.engine.finishReview!(rr.id);
    assert.deepEqual(done.released?.files, [b]);
    assert.deepEqual(done.released?.notAgain, [a]);
    assert.equal(done.turns.at(-1)!.text, 'Not added. Its 1 source not in your vault is read again with the next batch. 1 source already read again once stays in inbox/ for you to re-read.');
  });

  for (const [what, link] of [['loops back to itself', 'self'], ['loops through two batches', 'pair'], ['names a batch no longer listed', 'gone']] as const) {
    test(`the cap’s chain walk ends when it ${what}`, async () => {
      const job = await approvedBatch(['a.md'], FAILED);
      await reloaded(job, (j) => {
        j.reread = { id: 'rr-1', group: 1, groups: 1, fromJob: link === 'self' ? j.id : link === 'pair' ? 'job-partner' : 'job-gone', reason: 'manual' };
      });
      if (link === 'pair') {
        await h.engine.stop();
        const saved = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as Array<Record<string, any>>;
        saved.push({ ...saved[0], id: 'job-partner', reread: { id: 'rr-2', group: 1, groups: 1, fromJob: job.id, reason: 'manual' } });
        h = setup([], { jobs: saved });
      }
      const done = await h.engine.finishReview!(job.id);
      assert.deepEqual(done.released?.files, job.files, 'no released re-read in the chain: released as usual');
    });
  }

  test('released sources wait for the vault they came from, and never ride on a split queue’s next batch', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await h.engine.finishReview!(job.id);
    // The overflow continuation of a split queue is not a new batch the rules allowed.
    assert.equal(await (h.engine.processQueue as (o: { overflow?: boolean }) => Promise<Job | null>)({ overflow: true }), null);
    // Another vault is active: its batch doesn't take them.
    const other = path.join(tmp, 'other-vault');
    fs.mkdirSync(path.join(other, 'inbox'), { recursive: true });
    fs.writeFileSync(path.join(other, '.claude-obsidian.json'), '{}');
    const otherQueue = path.join(tmp, 'other-queue');
    fs.mkdirSync(otherQueue, { recursive: true });
    await h.engine.updateSettings({ vaults: [...h.engine.getSettings().vaults, { path: other, queueDirectory: otherQueue }], activeVaultPath: other });
    assert.equal(await h.engine.processQueue({ force: true }), null);
    assert.equal(released().length, 1, 'still waiting');
    assert.equal(h.engine.listJobs().length, 1);
  });

  test('the cap: a released re-read that didn’t add its sources either is not released again, even after a restart', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    await h.engine.finishReview!(job.id);
    h.runner.steps.push(needsApproval('PLACEHOLDER'));
    const again = (await h.engine.processQueue({ force: true }))!;
    assert.equal(again.reread?.reason, 'released');
    h.runner.steps[0] = needsApproval(h.bundle(again));
    await h.engine.whenIdle();
    h.runner.steps.push(FAILED);
    await h.engine.approve(again.id);
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(again.id)!.state, 'failed');
    await reloaded(again, () => undefined); // the reason must come back from jobs.json
    assert.equal(h.engine.getJob(again.id)!.reread?.reason, 'released');
    const calls = h.runner.requests.length;
    const done = await h.engine.finishReview!(again.id);
    assert.deepEqual(done.released?.files, []);
    assert.deepEqual([...done.released!.notAgain!].sort(), [...job.files].sort());
    assert.equal(done.turns.at(-1)!.text, 'Not added. These 2 sources were already read again once; they stay in inbox/ for you to re-read.');
    assert.equal(released().length, 0, 'no second plan');
    assert.equal(await h.engine.processQueue({ force: true }), null);
    assert.equal(h.runner.requests.length, calls);
  });

  test('the cap with one source, and with nothing left to read', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await reloaded(job, (j) => { j.reread = { id: 'rr-x', group: 1, groups: 1, fromJob: 'job-0', reason: 'released' }; });
    let done = await h.engine.finishReview!(job.id);
    assert.equal(done.turns.at(-1)!.text, 'Not added. This source was already read again once; it stays in inbox/ for you to re-read.');
    const other = await approvedBatch(['b.md'], FAILED);
    pageFor(other.files[0]!, 'B');
    await reloaded(other, (j) => { j.reread = { id: 'rr-y', group: 1, groups: 1, reason: 'released' }; });
    done = await h.engine.finishReview!(other.id);
    assert.deepEqual(done.released?.notAgain, []);
    assert.equal(done.turns.at(-1)!.text, 'Not added, and nothing to read again.');
  });

  test('a re-read for another reason (the owner’s) is released as usual', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await reloaded(job, (j) => { j.reread = { id: 'rr-z', group: 1, groups: 1, reason: 'retry' }; });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, job.files);
  });

  test('stopped sources survive a restart: still Held in inbox/', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await reloaded(job, (j) => { j.stopped = [{ file: j.files[0], reason: 'it isn’t valid UTF-8 text', at: '2026-10-09T10:00:00Z' }]; });
    // Done writes jobs.json through this engine (encodeJob); the held source isn't released.
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, []);
    await reloaded(job, () => undefined); // read back by the next engine
    assert.deepEqual(h.engine.getJob(job.id)!.stopped?.map((s) => s.file), job.files);
    assert.deepEqual((await h.engine.listHeld()).map((x) => x.file), job.files);
  });

  test('a held source is read once: by its own Try again, never also by the release', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await reloaded(job, (j) => { j.stopped = [{ file: a, reason: 'it isn’t valid UTF-8 text', at: '2026-10-09T10:00:00Z' }]; });
    // The owner's Try again waits while another batch holds the vault.
    fs.writeFileSync(path.join(h.queue, 'busy.md'), '# busy\n');
    h.runner.steps.push({ hang: true, structured: { status: 'done', summary: 'x' } });
    const busy = (await h.engine.processQueue({ force: true }))!;
    const retry = await h.engine.retryHeld(a);
    assert.equal(retry.waiting, 1);
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, [b], 'the held source is not released');
    const waiting = reread().plans.flatMap((p) => p.groups.filter((g) => !g.jobId).flatMap((g) => g.files));
    assert.deepEqual(waiting.filter((f) => f === a).length, 1, 'one waiting read of the held source: its Try again');
    await h.engine.cancel(busy.id);
    await h.engine.whenIdle();
  });

  test('every source already in the vault: nothing to read again, and the turn says so', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    pageFor(job.files[0]!, 'A');
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released!.files, []);
    assert.equal(done.released!.rereadId, undefined);
    assert.equal(done.turns.at(-1)!.text, 'Not added, and nothing to read again. 1 source already in your vault stays as it is.');
    assert.equal(released().length, 0);
  });

  // Round 4c verifier (2026-10-09): branches an independent mutation pass found unchecked.
  test('the plan Done makes holds only what it released: never a file another re-read holds', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await restartWith({ plans: (ps) => ps.push(plan('reread-owner', [{ files: [a] }], { reason: 'manual' })) });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.alreadyQueued, [a]);
    assert.deepEqual(released().flatMap((p) => p.groups.flatMap((g) => g.files)), [b], 'a is read once, by the owner’s re-read');
  });

  test('a running batch holds its files too: Done leaves them for it', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    h.runner.steps.push({ hang: true, structured: { status: 'nothing_to_do', summary: 'x' } });
    await h.engine.rereadSources({ files: [a!] }); // starts at once and runs
    const running = h.engine.listJobs().find((j) => j.reread && j.files.includes(a!))!;
    assert.equal(running.state, 'running');
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, [b]);
    assert.deepEqual(done.released?.alreadyQueued, [a]);
    await h.engine.cancel(running.id);
    await h.engine.whenIdle();
  });

  test('a file both released up the chain and held by another re-read counts as released before (notAgain)', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await restartWith({
      plans: (ps) => ps.push(plan('reread-owner', [{ files: [a] }], { reason: 'manual' })),
      jobs: (js) => {
        const j = js.find((x) => x.id === job.id)!;
        js.push({ ...j, id: 'job-ancestor', state: 'failed', released: { at: '2026-10-09T10:00:00Z', files: [a], inVault: [], missing: [] } });
        j.reread = { id: 'r1', group: 1, groups: 1, fromJob: 'job-ancestor', reason: 'manual' };
      },
    });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.notAgain, [a]);
    assert.equal(done.released?.alreadyQueued, undefined);
    assert.deepEqual(done.released?.files, [b]);
  });

  test('the cap records what another re-read holds as well', async () => {
    const job = await approvedBatch(['a.md', 'b.md'], FAILED);
    const [a, b] = [...job.files].sort();
    await restartWith({
      plans: (ps) => ps.push(plan('reread-owner', [{ files: [a] }], { reason: 'manual' })),
      jobs: (js) => { js.find((x) => x.id === job.id)!.reread = { id: 'r1', group: 1, groups: 1, fromJob: 'job-gone', reason: 'released' }; },
    });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.notAgain, [b]);
    assert.deepEqual(done.released?.alreadyQueued, [a]);
  });

  test('a cycle among the ancestors (a damaged jobs.json) ends the chain walk', { timeout: 10_000 }, async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await restartWith({
      jobs: (js) => {
        const j = js.find((x) => x.id === job.id)!;
        js.push({ ...j, id: 'job-p', state: 'failed', reread: { id: 'rp', group: 1, groups: 1, fromJob: 'job-q', reason: 'manual' } });
        js.push({ ...j, id: 'job-q', state: 'failed', reread: { id: 'rq', group: 1, groups: 1, fromJob: 'job-p', reason: 'manual' } });
        j.reread = { id: 'r1', group: 1, groups: 1, fromJob: 'job-p', reason: 'manual' };
      },
    });
    const done = await h.engine.finishReview!(job.id);
    assert.deepEqual(done.released?.files, job.files);
  });

  test('a folder item whose every file another re-read holds is not packed as an empty folder group', async () => {
    const job = await approvedBatch(['solo.md'], FAILED);
    await reloaded(job, (j) => {
      const dir = path.join(tmp, 'vault', 'inbox', 'notes');
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'one.md'), '# one\n');
      j.files = [...j.files, 'inbox/notes/one.md'];
      j.folders = ['inbox/notes'];
    });
    await restartWith({ plans: (ps) => ps.push(plan('reread-owner', [{ files: ['inbox/notes/one.md'], folders: ['inbox/notes'] }], { reason: 'manual' })) });
    await h.engine.finishReview!(job.id);
    assert.deepEqual(released().flatMap((p) => p.groups), [{ files: [job.files[0]] }]);
  });

  test('when one folder item leaves a waiting released group, its other folder stays a folder', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await restartWith({
      plans: (ps) => ps.push(plan('reread-rel', [{ files: ['inbox/x/1.md', 'inbox/y/1.md'], folders: ['inbox/x', 'inbox/y'] }], { reason: 'released', fromJob: job.id })),
    });
    for (const f of ['inbox/x/1.md', 'inbox/y/1.md']) {
      fs.mkdirSync(path.join(tmp, 'vault', path.dirname(f)), { recursive: true });
      fs.writeFileSync(path.join(tmp, 'vault', f), '# x\n');
    }
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.rereadSources({ files: ['inbox/x/1.md'] });
    await h.engine.whenIdle();
    assert.deepEqual(reread().plans.find((p) => p.id === 'reread-rel')!.groups, [{ files: ['inbox/y/1.md'], folders: ['inbox/y'] }]);
  });

  test('Process now started the released re-read; the owner then re-reads the same batch: one read, not two', async () => {
    const job = await approvedBatch(['a.md'], FAILED);
    await h.engine.finishReview!(job.id);
    h.runner.steps.push({ hang: true, structured: { status: 'nothing_to_do', summary: 'x' } });
    const rel = (await h.engine.processQueue({ force: true }))!;
    assert.equal(h.engine.getJob(rel.id)!.state, 'running');
    await h.engine.rereadSources({ jobId: job.id }).catch(() => undefined); // refusing is one acceptable answer
    const waiting = reread().plans.flatMap((p) => p.groups.filter((g) => !g.jobId).flatMap((g) => g.files));
    assert.ok(!waiting.includes(job.files[0]!), 'a second read of the source waits behind the one running');
    await h.engine.cancel(rel.id);
    await h.engine.whenIdle();
  });
});
