import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreEvent, JobStep, RunRequest, RunResult, RunnerCapability, RunnerStep } from '../contracts.js';
import { createCore } from '../index.js';
import { createRunnerRegistry } from '../runners/registry.js';
import type { ProcessOutput, RunProcessOptions } from '../runners/process.js';
import { MemorySecretStore } from '../runners/secrets.js';
import { startServer, type RunningServer } from '../server/http.js';
import { JobStore, newJob } from '../store/jobs.js';
import { statePaths } from '../store/paths.js';
import { createStepLog, MAX_STEPS } from './index.js';
import { noteWords, redact, toolWords, unwrapShell, type WordsContext } from './words.js';

type Turn = { steps?: RunnerStep[]; result: Partial<RunResult> };

class StepRunner implements AgentRunner {
  readonly displayName = 'Fake Claude';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly capabilities: ReadonlySet<RunnerCapability>;
  readonly requests: RunRequest[] = [];
  constructor(
    readonly id: string,
    readonly turns: (req: RunRequest) => Turn,
    caps: RunnerCapability[] = ['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput'],
  ) {
    this.capabilities = new Set(caps);
  }
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    await new Promise((r) => setImmediate(r));
    const t = this.turns(request);
    for (const s of t.steps ?? []) request.onStep?.(s);
    const sid = 'start' in request.session ? request.session.start : request.session.resume;
    return { sessionID: sid, resultText: '', isError: false, costUSD: 0, denials: [], raw: '{}', ...t.result };
  }
}

const PLAN = { operation_id: 'op-1', operation_type: 'ingest', valid: true, changed_paths: ['wiki/a.md', 'wiki/b.md'], approval_sha256: 'f'.repeat(64) };

let root: string;
beforeEach(() => {
  root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-steps-')));
});
afterEach(() => fs.rmSync(root, { recursive: true, force: true }));

function setup(turns: (req: RunRequest, vault: string, jobId: () => string) => Turn, o: { autoLabel?: boolean; jobs?: unknown[] } = {}) {
  const vault = path.join(root, 'Research');
  const queue = path.join(root, 'queue');
  const state = path.join(root, 'state');
  const product = path.join(root, 'product');
  for (const d of [path.join(vault, 'inbox'), path.join(vault, 'wiki'), queue, state, path.join(product, 'scripts')]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '# fake\n');
  fs.writeFileSync(path.join(state, 'settings.json'), JSON.stringify({
    vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, productRoot: product, settleSeconds: 0,
    pythonPath: '/usr/bin/python3', autoProcessEnabled: false, enabledRunners: ['claude-code', 'fake-labels'],
    taskDefaults: { labelSuggest: { runnerID: 'fake-labels', model: 'tiny' } }, labeling: { autoLabelQueueFolder: o.autoLabel === true },
  }));
  if (o.jobs) fs.writeFileSync(path.join(state, 'jobs.json'), JSON.stringify(o.jobs));
  let core!: ReturnType<typeof createCore>;
  const jobId = () => core.listJobs()[0]!.id;
  const runner = new StepRunner('claude-code', (req) => turns(req, vault, jobId));
  const labeler = new StepRunner('fake-labels', () => ({ result: { structured: { labels: ['tea', 'kettle'] } } }), ['structuredOutput']);
  const launch = async (opts: RunProcessOptions): Promise<ProcessOutput> => {
    if (opts.args.includes('apply')) return { status: 0, stdout: Buffer.from(JSON.stringify({ operation_id: 'op-1', changed_paths: PLAN.changed_paths })), stderr: Buffer.alloc(0) };
    return { status: 0, stdout: Buffer.from(JSON.stringify(PLAN)), stderr: Buffer.alloc(0) };
  };
  core = createCore({
    paths: statePaths(state), runners: createRunnerRegistry([runner, labeler]), launch, tickMs: 60_000,
    trashDir: path.join(root, 'trash'), secrets: new MemorySecretStore(),
    collectors: { homeDir: root, tmpDir: root },
  });
  const events: CoreEvent[] = [];
  core.subscribe((e) => events.push(e));
  return { core, vault, queue, state, events, runner };
}

const idle = (core: ReturnType<typeof createCore>) => (core as unknown as { whenIdle(): Promise<void> }).whenIdle();

describe('job steps (live log)', () => {
  test('a batch: moved, labels per file, Claude’s steps in plain words, checked, waiting for review; then approved and applied', async () => {
    const h = setup((req, vault, jobId) => {
      if ('resume' in req.session) {
        return {
          steps: [{ kind: 'tool', id: 'ap1', tool: 'Bash', input: { command: `python3 /p/scripts/claude-obsidian.py transaction apply /b.json --vault ${vault} --approved-plan-sha256 ${'f'.repeat(64)}` } }],
          result: { structured: { status: 'done', summary: 'Applied.', operation_id: 'op-1', changed_paths: PLAN.changed_paths } },
        };
      }
      const jobDir = path.join(vault, '.vault-meta/worker', jobId());
      return {
        steps: [
          { kind: 'tool', id: 't1', tool: 'Skill', input: { skill: 'claude-obsidian:wiki-ingest' } },
          { kind: 'toolDone', id: 't1' },
          { kind: 'tool', id: 't2', tool: 'Read', input: { file_path: path.join(vault, 'inbox/a.md'), limit: 110 } },
          { kind: 'tool', id: 't3', tool: 'Read', input: { file_path: path.join(vault, 'wiki/hot.md') } },
          { kind: 'toolDone', id: 't2' },
          { kind: 'toolDone', id: 't3' },
          { kind: 'message', text: 'Still reading sources: 1 of 2 are done. token=abc123secret' },
          { kind: 'tool', id: 't4', tool: 'Bash', input: { command: 'shasum -a 256 inbox/a.md' } },
          { kind: 'tool', id: 't5', tool: 'Write', input: { file_path: path.join(jobDir, 'drafts/s01.md'), content: 'SECRET NOTE TEXT' } },
          { kind: 'tool', id: 't6', tool: 'StructuredOutput', input: { status: 'needs_approval' } },
        ],
        result: { structured: { status: 'needs_approval', summary: 'Adds pages.', bundle_path: path.join(jobDir, 'bundle.json') } },
      };
    }, { autoLabel: true });
    // Notes nobody labeled get their labels in the batch's pre-step (queue-folder files get theirs in
    // the queue, before the batch, and the batch reuses them).
    await h.core.addNote({ title: 'a', text: 'about tea', origin: 'cli', suggest: 'none' });
    await h.core.addNote({ title: 'Kettle comparison', text: 'about kettles', origin: 'cli', suggest: 'none' });
    const job = (await h.core.processQueue({ force: true }))!;
    await idle(h.core);

    const page = await h.core.listJobSteps!(job.id);
    assert.equal(page.kept, true);
    const by = (verb: string) => page.steps.filter((s) => s.verb === verb);
    assert.equal(by('move')[0]!.text, 'Moved 4 files from the queue to your inbox'); // each note and its manifest
    const labels = page.steps.find((s) => s.id === 'labels')!;
    assert.equal(labels.state, 'done');
    assert.match(labels.text, /^Suggested labels for 2 files$/);
    const files = by('label');
    assert.equal(files.length, 2);
    assert.ok(files.every((f) => f.parent === 'labels' && f.state === 'done' && f.count === '2 labels'));
    assert.deepEqual(files.map((f) => f.text).sort(), ['Kettle comparison', 'a']);
    assert.equal(by('skill')[0]!.text, 'Started the wiki-ingest instructions');
    assert.equal(by('read')[0]!.text, 'Read “a”');
    assert.equal(by('read')[0]!.detail, 'Read · inbox/a.md · lines 1–110');
    assert.equal(by('readPage')[0]!.text, 'Read your page “hot”');
    assert.equal(by('note')[0]!.kind, 'note');
    assert.match(by('note')[0]!.text, /token=•••/);
    assert.equal(by('command')[0]!.text, 'Ran a command: shasum');
    assert.equal(by('write')[0]!.text, 'Wrote a draft (s01.md)');
    assert.ok(!page.steps.some((s) => /StructuredOutput/.test(s.text)), 'the structured answer is not a step');
    // Never the contents of a file or a draft.
    assert.ok(!JSON.stringify(page.steps).includes('SECRET NOTE TEXT'));
    assert.ok(!JSON.stringify(page.steps).includes('abc123secret'));
    // Tools that never reported back are closed when the turn ends.
    assert.ok(page.steps.filter((s) => s.phase === 'agent').every((s) => s.state === 'done'));
    const check = by('check')[0]!;
    assert.equal(check.state, 'done');
    assert.equal(check.count, '2 changes');
    const review = by('review').at(-1)!;
    assert.equal(review.state, 'review');
    assert.equal(review.text, 'Waiting for your review');
    // Live: every step went out as a job.step event.
    const live = h.events.filter((e): e is Extract<CoreEvent, { type: 'job.step' }> => e.type === 'job.step');
    assert.ok(live.length >= page.steps.length);
    // The label line was sent running, then done.
    const labelEvents = live.filter((e) => e.step.verb === 'label').map((e) => e.step.state);
    assert.deepEqual([...new Set(labelEvents)].sort(), ['done', 'running']);
    // The progress event names the file being labeled.
    assert.ok(h.events.some((e) => e.type === 'progress' && e.progress.current === 'inbox/a.md' || e.type === 'progress' && e.progress.current === 'inbox/Kettle comparison.md'));

    await h.core.approve(job.id);
    await idle(h.core);
    const after = (await h.core.listJobSteps!(job.id)).steps;
    assert.equal(after.find((s) => s.id === review.id)!.text, 'You approved');
    // v8: Review after Approve: the AI starting, applying through the vault core, Added with plan counts.
    const ap = after.filter((s) => s.phase === 'apply');
    const start = ap.find((s) => s.verb === 'start')!;
    assert.equal(start.state, 'done');
    assert.equal(start.text, 'Claude resumed this batch’s session');
    const apply = ap.find((s) => s.verb === 'apply')!;
    assert.equal(apply.state, 'done');
    assert.equal(apply.text, 'Applied through the vault core');
    assert.equal(apply.count, 'op-1');
    const added = ap.find((s) => s.verb === 'added')!;
    assert.equal(added.text, 'Added to Research: 2 pages added');
    assert.deepEqual(ap.map((s) => s.verb).slice(0, 3), ['start', 'apply', 'added']);
    const applyEvents = h.events.filter((e): e is Extract<CoreEvent, { type: 'job.step' }> => e.type === 'job.step' && e.step.id === apply.id).map((e) => e.step.state);
    assert.deepEqual(applyEvents, ['waiting', 'running', 'done']);

    // Kept on disk: a new core reads the same log.
    await h.core.stop();
    const again = createStepLog({ dir: path.join(h.state, 'steps'), emit: () => undefined, getJob: () => undefined });
    assert.deepEqual(again.list(job.id).steps.map((s) => s.id), after.map((s) => s.id));
  });

  test('v8: an apply turn that reports another operation: Nothing recorded as applied, with what to do; Done is refused until it is added', async () => {
    const h = setup((req, vault, jobId) => {
      if ('resume' in req.session) return { result: { structured: { status: 'done', summary: 'Applied.', operation_id: 'op-other', changed_paths: [] } } };
      const jobDir = path.join(vault, '.vault-meta/worker', jobId());
      return { result: { structured: { status: 'needs_approval', summary: 'Adds pages.', bundle_path: path.join(jobDir, 'bundle.json') } } };
    });
    fs.writeFileSync(path.join(h.vault, 'wiki', 'b.md'), '# B\n'); // exists: counted as updated
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await h.core.processQueue({ force: true }))!;
    await idle(h.core);
    await assert.rejects(h.core.finishReview!(job.id), /not approved/);
    await h.core.approve(job.id);
    const approved = h.core.getJob(job.id)!;
    assert.equal(approved.approvedChange?.operationID, 'op-1');
    assert.equal(approved.approvedChange?.changes, 2);
    assert.equal(approved.approvedChange?.otherPages, 1);
    assert.equal(approved.approvedChange?.updated, 1);
    await idle(h.core);
    const ap = (await h.core.listJobSteps!(job.id)).steps.filter((s) => s.phase === 'apply');
    const apply = ap.find((s) => s.verb === 'apply')!;
    assert.equal(apply.state, 'failed');
    assert.equal(apply.text, 'Nothing recorded as applied: Claude didn’t report the approved change');
    assert.match(apply.hint!, /Show steps/);
    assert.equal(ap.some((s) => s.verb === 'added'), false);
    // Completed (nothing recorded): Done takes it out of Review.
    const done = await h.core.finishReview!(job.id);
    assert.ok(done.reviewDoneAt);
    await h.core.stop();
    // Both survive a restart (jobs.json read again), and an older build's unknown keys are not the source.
    const reloaded = new JobStore(statePaths(h.state).jobs).load().find((j) => j.id === job.id)!;
    assert.equal(reloaded.approvedChange?.operationID, 'op-1');
    assert.equal(reloaded.approvedChange?.updated, 1);
    assert.equal(reloaded.reviewDoneAt, done.reviewDoneAt);
  });

  test('a job that ran before steps were kept says so; the HTTP route serves the log', async () => {
    const vault = path.join(root, 'Research');
    const old = { ...newJob({ id: 'job-20261001-120000-aaaa', kind: 'ingest', vaultPath: vault, files: ['inbox/x.md'], model: 'sonnet', now: new Date() }), state: 'completed', changedPaths: ['wiki/x.md'] };
    const h = setup(() => ({ result: { structured: { status: 'nothing_to_do', summary: 'ok' } } }), { jobs: [old] });
    let server: RunningServer | undefined;
    try {
      server = await startServer({ core: h.core, token: 'tttttttttttttttttttt' });
      const get = (p: string) => new Promise<{ status: number; body: Record<string, unknown> }>((resolve, reject) => {
        http.get({ host: '127.0.0.1', port: server!.port, path: p, headers: { authorization: 'Bearer tttttttttttttttttttt' } }, (res) => {
          let data = '';
          res.on('data', (c) => (data += c));
          res.on('end', () => resolve({ status: res.statusCode ?? 0, body: JSON.parse(data) }));
        }).on('error', reject);
      });
      const r = await get(`/v1/jobs/${old.id}/steps`);
      assert.equal(r.status, 200);
      assert.equal(r.body.kept, false);
      assert.deepEqual(r.body.steps, []);
      assert.equal((await get('/v1/jobs/job-nope/steps')).status, 404);
    } finally {
      await server?.close();
      await h.core.stop();
    }
  });

  test('a failed turn ends the log with the error; deleting the job removes its log', async () => {
    const h = setup(() => ({ steps: [{ kind: 'tool', id: 'x', tool: 'Read', input: { file_path: 'inbox/a.md' } }], result: { isError: true, resultText: 'runner exploded' } }));
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await h.core.processQueue({ force: true }))!;
    await idle(h.core);
    const steps = (await h.core.listJobSteps!(job.id)).steps;
    const last = steps.at(-1)!;
    assert.equal(last.state, 'failed');
    assert.equal(last.text, 'Failed: runner exploded');
    assert.equal(steps.find((s) => s.verb === 'read')!.state, 'done');
    const file = path.join(h.state, 'steps', `${job.id}.jsonl`);
    assert.ok(fs.existsSync(file));
    await h.core.deleteJob(job.id);
    assert.ok(!fs.existsSync(file));
    await h.core.stop();
  });
});

describe('step log review', () => {
  test('blocked tools and questions stop waiting once the review is answered or the job ends', () => {
    const dir = path.join(root, 'steps-review');
    let job = { ...newJob({ id: 'job-r', kind: 'ingest', vaultPath: root, files: ['inbox/a.md'], model: 'm', now: new Date() }) };
    const log = createStepLog({ dir, emit: () => undefined, getJob: () => job });
    log.onEvent({ type: 'job', job });
    job = { ...job, state: 'awaitingApproval', approval: { summary: 's', questions: ['Which?'], plan: PLAN, denials: [{ toolName: 'Bash', toolUseID: 'u', input: { command: 'rm x' } }], skipped: [] } } as typeof job;
    log.onEvent({ type: 'job', job });
    assert.equal(log.list('job-r').steps.filter((s) => s.state === 'review').length, 3);
    job = { ...job, state: 'rejected' } as typeof job;
    log.onEvent({ type: 'job', job });
    assert.deepEqual(log.list('job-r').steps.filter((s) => s.state === 'review'), []);
  });
});

describe('step log limits', () => {
  test('stops at MAX_STEPS with one “not kept” line', () => {
    const dir = path.join(root, 'steps');
    const job = { ...newJob({ id: 'job-1', kind: 'ingest', vaultPath: root, files: ['inbox/a.md'], model: 'm', now: new Date() }) };
    const sent: JobStep[] = [];
    const log = createStepLog({ dir, emit: (e) => e.type === 'job.step' && sent.push(e.step), getJob: () => job });
    log.onEvent({ type: 'job', job });
    log.runnerStep('job-1', { kind: 'tool', id: 'early', tool: 'Read', input: { file_path: 'inbox/a.md' } });
    for (let i = 0; i < MAX_STEPS + 50; i++) log.runnerStep('job-1', { kind: 'tool', tool: 'Glob', input: { pattern: `*${i}` } });
    const page = log.list('job-1');
    assert.equal(page.steps.length, MAX_STEPS);
    assert.equal(page.truncated, true);
    assert.equal(page.steps.at(-1)!.verb, 'truncated');
    // A kept step can still finish after the cap; a new one is not kept.
    log.runnerStep('job-1', { kind: 'toolDone', id: 'early' });
    log.runnerStep('job-1', { kind: 'tool', id: 'late', tool: 'Read', input: { file_path: 'inbox/b.md' } });
    const after = log.list('job-1');
    assert.equal(after.steps.length, MAX_STEPS);
    assert.ok(after.steps.every((s) => s.state !== 'running'), 'no spinner left behind the cap');
  });

  test('prune removes logs of jobs no longer listed', () => {
    const dir = path.join(root, 'steps');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'job-a.jsonl'), '');
    fs.writeFileSync(path.join(dir, 'job-b.jsonl'), '');
    createStepLog({ dir, emit: () => undefined, getJob: () => undefined }).prune([]);
    assert.equal(fs.readdirSync(dir).length, 2, 'an empty job list never wipes the logs');
    createStepLog({ dir, emit: () => undefined, getJob: () => undefined }).prune(['job-a']);
    assert.deepEqual(fs.readdirSync(dir), ['job-a.jsonl']);
  });
});

describe('plain words', () => {
  const ctx: WordsContext = { vaultPath: '/v', jobDir: '/v/.vault-meta/worker/job-1', sources: ['inbox/Tea.md'] };
  test('reads, searches, commands and drafts', () => {
    assert.equal(toolWords({ kind: 'tool', tool: 'Read', input: { file_path: '/v/inbox/Tea.md', offset: 10, limit: 5 } }, ctx)!.detail, 'Read · inbox/Tea.md · lines 10–14');
    assert.equal(toolWords({ kind: 'tool', tool: 'Read', input: { file_path: '/Users/me/product/skills/wiki/references/provenance.md' } }, ctx)!.text, 'Read provenance.md');
    assert.equal(toolWords({ kind: 'tool', tool: 'Read', input: { file_path: '/Users/me/product/skills/wiki/references/provenance.md' } }, ctx)!.detail, 'Read · …/references/provenance.md');
    assert.equal(toolWords({ kind: 'tool', tool: 'Grep', input: { pattern: 'address_requests', path: '/v/wiki' } }, ctx)!.text, 'Searched for “address_requests”');
    assert.equal(toolWords({ kind: 'tool', tool: 'Bash', input: { command: "bash -lc 'sed -n 1,200p inbox/Tea.md'" } }, ctx)!.text, 'Read “Tea”');
    assert.equal(toolWords({ kind: 'tool', tool: 'Bash', input: { command: 'python3 scripts/claude-obsidian.py transaction inspect b.json --vault /v' } }, ctx)!.text, 'Checked the plan with the vault core');
    assert.equal(toolWords({ kind: 'tool', tool: 'Bash', input: { command: 'cat inbox/Tea.md | wc -l' } }, ctx)!.text, 'Ran a command: cat');
    assert.equal(toolWords({ kind: 'tool', tool: 'Edit', input: { file_path: '/v/.vault-meta/worker/job-1/drafts/s02.md', old_string: 'x', new_string: 'y' } }, ctx)!.text, 'Edited a draft (s02.md)');
    assert.equal(toolWords({ kind: 'tool', tool: 'StructuredOutput', input: {} }, ctx), undefined);
    assert.equal(toolWords({ kind: 'tool', tool: 'mcp.thing', input: {} }, ctx)!.text, 'Used mcp.thing');
    assert.equal(unwrapShell('/bin/zsh -lc "ls -la"'), 'ls -la');
    assert.equal(toolWords({ kind: 'tool', tool: 'Glob', input: { pattern: '/Users/me/product/skills/**/SKILL.md' } }, ctx)!.text, 'Looked for files (…/**/SKILL.md)');
  });
  test('keys and long notes', () => {
    assert.equal(redact('curl -H "Authorization: Bearer abcdefghijklmnop" https://x'), 'curl -H "Authorization: Bearer •••" https://x');
    assert.equal(redact('export SLACK_TOKEN=xoxb-1234567890-abcdef'), 'export SLACK_TOKEN=•••');
    assert.equal(redact('key sk-ant-api03-abcdefghijklmnopqrstuv'), 'key •••');
    const long = noteWords('x'.repeat(400))!;
    assert.equal(long.text.length, 280);
    const cmd = toolWords({ kind: 'tool', tool: 'Bash', input: { command: `echo ${'y'.repeat(300)}` } }, ctx)!;
    assert.ok(cmd.detail!.length <= 127);
  });
});
