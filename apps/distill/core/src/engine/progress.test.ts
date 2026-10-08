import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreEvent, Progress, RunRequest, RunResult, RunnerCapability } from '../contracts.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { cancelledError, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { statePaths } from '../store/paths.js';
import { createEngine, type Engine } from './index.js';

type Step = Partial<RunResult> & { hang?: boolean; throws?: string };

/** Scripted runner (same shape as engine.test.ts) plus a resume command. */
class FakeRunner implements AgentRunner {
  readonly displayName: string;
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly requests: RunRequest[] = [];
  constructor(
    readonly id: string,
    readonly steps: Step[] | ((req: RunRequest) => Step),
    readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>([
      'agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput',
    ]),
  ) {
    this.displayName = `Fake ${id}`;
  }
  problems() {
    return [];
  }
  resumeCommand(sessionID: string, model: string): string[] {
    return ['fake-cli', '--resume', sessionID, '--model', model];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    await new Promise((r) => setImmediate(r));
    const step =
      typeof this.steps === 'function'
        ? this.steps(request)
        : (this.steps.shift() ?? { structured: { status: 'failed', summary: 'no more steps' } });
    if (step.hang) {
      await new Promise<void>((_, reject) => {
        if (request.signal?.aborted) reject(cancelledError());
        request.signal?.addEventListener('abort', () => reject(cancelledError()), { once: true });
      });
    }
    if (step.throws) throw new Error(step.throws);
    const sid = 'start' in request.session ? request.session.start : request.session.resume;
    const { hang: _h, throws: _t, ...rest } = step;
    return { sessionID: sid, resultText: '', isError: false, costUSD: 0.01, denials: [], raw: '{}', ...rest };
  }
}

const PLAN = {
  operation_id: 'op-1',
  operation_type: 'ingest',
  valid: true,
  changed_paths: ['wiki/a.md', 'wiki/b.md'],
  approval_sha256: 'f'.repeat(64),
};

interface Harness {
  vault: string;
  queue: string;
  trash: string;
  engine: Engine;
  runner: FakeRunner;
  labeler: FakeRunner;
  events: CoreEvent[];
}

let tmp: string;
let h: Harness | undefined;

beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-progress-')));
});
afterEach(async () => {
  await h?.engine.whenIdle();
  await h?.engine.stop();
  h = undefined;
  fs.rmSync(tmp, { recursive: true, force: true });
});

function setup(
  steps: Step[] | ((req: RunRequest) => Step),
  o: { labels?: (req: RunRequest) => Step; autoLabel?: boolean; queueIsInbox?: boolean; applyStatus?: number; sandboxed?: boolean } = {},
): Harness {
  const vault = path.join(tmp, 'Research');
  const product = path.join(tmp, 'product');
  const state = path.join(tmp, 'state');
  const trash = path.join(tmp, 'Trash');
  fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
  fs.mkdirSync(path.join(vault, 'wiki'), { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.mkdirSync(path.join(product, 'scripts'), { recursive: true });
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '# fake core\n');
  const queue = o.queueIsInbox ? path.join(vault, 'inbox') : path.join(tmp, 'queue');
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
      enabledRunners: ['claude-code', 'fake-labels'],
      taskDefaults: { labelSuggest: { runnerID: 'fake-labels', model: 'tiny' } },
      labeling: { autoLabelQueueFolder: o.autoLabel === true },
    }),
  );
  const runner = new FakeRunner(
    'claude-code',
    steps,
    o.sandboxed ? new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']) : undefined,
  );
  const labeler = new FakeRunner('fake-labels', o.labels ?? (() => ({ structured: { labels: ['tea'] } })), new Set(['structuredOutput']));
  const launch = async (opts: RunProcessOptions): Promise<ProcessOutput> => {
    if (opts.args.includes('apply')) {
      return { status: o.applyStatus ?? 0, stdout: Buffer.from(JSON.stringify({ operation_id: 'op-1', changed_paths: PLAN.changed_paths })), stderr: Buffer.alloc(0) };
    }
    return { status: 0, stdout: Buffer.from(JSON.stringify(PLAN)), stderr: Buffer.alloc(0) };
  };
  const engine = createEngine({
    paths: statePaths(state),
    runners: createRunnerRegistry([runner, labeler]),
    launch,
    tickMs: 60_000,
    trashDir: trash,
  });
  const events: CoreEvent[] = [];
  engine.subscribe((e) => events.push(e));
  h = { vault, queue, trash, engine, runner, labeler, events };
  return h;
}

const progressOf = (events: CoreEvent[], key?: string): Progress[] =>
  events.flatMap((e) => (e.type === 'progress' && (key === undefined || e.progress.key === key) ? [e.progress] : []));

function needsApproval(vault: string, engine: Engine): Step {
  const jobID = engine.listJobs()[0]!.id;
  const bundle = path.join(vault, '.vault-meta/worker', jobID, 'bundle.json');
  return { structured: { status: 'needs_approval', summary: 'Adds pages.', bundle_path: bundle } };
}

function assertOneFinished(list: Progress[]): Progress {
  const finished = list.filter((p) => p.finished);
  assert.equal(finished.length, 1, `exactly one finished event: ${JSON.stringify(list)}`);
  assert.equal(list[list.length - 1], finished[0], 'finished is the last event for the key');
  assert.ok(list.every((p) => p.startedAt === list[0]!.startedAt), 'one timer per run');
  assert.ok(!Number.isNaN(Date.parse(list[0]!.startedAt)));
  return finished[0]!;
}

describe('batch progress', () => {
  test('steps advance from reading to review, then apply has its own progress', async () => {
    let engine!: Engine;
    let vault = '';
    const steps: Step[] = [];
    h = setup((req) => {
      if (steps.length === 0) {
        steps.push(needsApproval(vault, engine));
        steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: 'op-1', changed_paths: PLAN.changed_paths } });
      }
      void req;
      return steps.shift()!;
    });
    ({ engine, vault } = h);
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    fs.writeFileSync(path.join(h.queue, 'c.md'), '# C\n');
    const job = (await engine.processQueue({ force: true }))!;
    await engine.whenIdle();

    const batch = progressOf(h.events, job.id);
    const expectedSteps = ['Moved to inbox', 'Read sources', 'Drafting page changes', 'Ready for review'];
    assert.deepEqual(batch.map((p) => [p.kind, p.stepIndex, p.message, !!p.finished]), [
      ['batch', 1, 'Reading 3 sources into Research', false],
      ['batch', 2, 'Checking the page changes', false],
      ['batch', 3, 'Ready for review', true],
    ]);
    assert.ok(batch.every((p) => JSON.stringify(p.steps) === JSON.stringify(expectedSteps)));
    assert.equal(batch[0]!.runnerID, 'claude-code');
    assert.equal(batch[0]!.model, job.model);
    assertOneFinished(batch);
    assert.deepEqual(await Promise.resolve(progressOf(h.events).filter((p) => !p.finished && p.key !== job.id)), []);

    h.events.length = 0;
    await engine.approve(job.id);
    await engine.whenIdle();
    const apply = progressOf(h.events, job.id);
    assert.equal(apply[0]!.kind, 'apply');
    assert.equal(apply[0]!.message, 'Applying 2 changes');
    assert.equal(apply[0]!.runnerID, 'claude-code');
    const end = assertOneFinished(apply);
    assert.equal(end.kind, 'apply');
    assert.equal(end.error, undefined);
    assert.equal(engine.getJob(job.id)!.state, 'completed');
  });

  test('the label pre-step adds "Suggesting labels" with done/total and the labeler model', async () => {
    h = setup([{ structured: { status: 'nothing_to_do', summary: 'ok' } }], { autoLabel: true });
    // CLI notes nobody labeled get their AI labels in the batch (queue files get theirs before it).
    await h.engine.addNote({ title: 'A', text: 'about tea', origin: 'cli', suggest: 'none' });
    await h.engine.addNote({ title: 'B', text: 'about coffee', origin: 'cli', suggest: 'none' });
    const job = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    const list = progressOf(h.events, job.id);
    assert.deepEqual(list[0]!.steps, ['Moved to inbox', 'Suggesting labels', 'Read sources', 'Drafting page changes', 'Ready for review']);
    // Each file that starts also names itself as `current` (same counts), so repeats are folded here.
    const rows = list.map((p) => JSON.stringify([p.stepIndex, p.done ?? null, p.total ?? null, p.model ?? null, !!p.finished]));
    assert.ok(list.some((p) => p.stepIndex === 1 && typeof p.current === 'string' && p.current.startsWith('inbox/')));
    assert.deepEqual(
      rows.filter((r, i) => r !== rows[i - 1]).map((r) => JSON.parse(r) as unknown[]),
      [
        [1, 0, 2, 'tiny', false],
        [1, 1, 2, 'tiny', false],
        [1, 2, 2, 'tiny', false],
        [2, null, null, job.model, false],
        [4, null, null, job.model, true],
      ],
    );
    assert.equal(list[0]!.message, 'Suggesting labels for 2 sources');
    assert.match(list.find((p) => p.stepIndex === 2)!.message, /^Reading \d+ sources into Research$/); // the count includes the notes' manifests (pre-existing)
    assertOneFinished(list);
  });

  test('a failed turn finishes with the error; a cancelled turn finishes too', async () => {
    h = setup([{ throws: 'runner exploded' }]);
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    const end = assertOneFinished(progressOf(h.events, job.id));
    assert.equal(end.error, 'runner exploded');
    assert.equal(h.engine.getJob(job.id)!.state, 'failed');
    await h.engine.deleteJob(job.id);
    await h.engine.stop();

    h = setup([{ hang: true }]);
    fs.writeFileSync(path.join(h.queue, 'b.md'), '# B\n');
    const second = (await h.engine.processQueue({ force: true }))!;
    await new Promise((r) => setTimeout(r, 10));
    await h.engine.cancel(second.id);
    await h.engine.whenIdle();
    const cancelled = assertOneFinished(progressOf(h.events, second.id));
    assert.equal(cancelled.message, 'Cancelled');
    assert.equal(h.engine.getJob(second.id)!.state, 'cancelled');
  });

  test('reply runs a new batch progress at the drafting step', async () => {
    h = setup([
      { structured: { status: 'needs_input', summary: 'Which title?', questions: ['Which title?'] } },
      { structured: { status: 'nothing_to_do', summary: 'ok' } },
    ]);
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    h.events.length = 0;
    await h.engine.reply(job.id, 'Use Tea');
    await h.engine.whenIdle();
    const list = progressOf(h.events, job.id);
    assert.equal(list[0]!.message, 'Working on your reply');
    assert.equal(list[0]!.stepIndex, 2);
    assertOneFinished(list);
  });

  test('an apply in the core (sandboxed runner) has apply progress and finishes with the error on failure', async () => {
    let engine!: Engine;
    let vault = '';
    h = setup(() => needsApproval(vault, engine), { applyStatus: 3, sandboxed: true });
    ({ engine, vault } = h);
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await engine.processQueue({ force: true }))!;
    await engine.whenIdle();
    h.events.length = 0;
    await engine.approve(job.id);
    await engine.whenIdle();
    const list = progressOf(h.events, job.id);
    assert.equal(list[0]!.kind, 'apply');
    assert.equal(list[0]!.runnerID, undefined, 'the core applies, not a runner');
    const end = assertOneFinished(list);
    assert.match(end.error ?? '', /transaction apply exited 3/);
    assert.equal(engine.getJob(job.id)!.state, 'failed');
    assert.equal(h.runner.requests.length, 1, 'no agent turn for the apply');
  });
});

describe('labelSuggest progress around addNote', () => {
  test('wait: progress keyed by request ID, cost on the result', async () => {
    h = setup([]);
    const r = await h.engine.addNote({ title: 'Sencha', text: 'Green tea.', suggest: 'wait', origin: 'cli' });
    assert.equal(r.costUSD, 0.01);
    const list = progressOf(h.events, `note:${r.requestID}`);
    assert.deepEqual(list.map((p) => [p.kind, p.message, p.runnerID, p.model, !!p.finished]), [
      ['labelSuggest', 'Suggesting labels', 'fake-labels', 'tiny', false],
      ['labelSuggest', 'Suggesting labels', 'fake-labels', 'tiny', true],
    ]);
    assertOneFinished(list);
  });

  test('background failure: finished with the error, labelSuggestions carries it, no cost', async () => {
    h = setup([], { labels: () => ({ isError: true, resultText: 'quota exceeded' }) });
    const r = await h.engine.addNote({ title: 'Bg', text: 'x' });
    assert.equal(r.costUSD, undefined);
    await h.engine.whenIdle();
    const end = assertOneFinished(progressOf(h.events, `note:${r.requestID}`));
    assert.equal(end.error, 'quota exceeded');
    const ev = h.events.find((e) => e.type === 'labelSuggestions');
    assert.ok(ev && ev.type === 'labelSuggestions');
    assert.equal(ev.error, 'quota exceeded');
    assert.equal(ev.costUSD, undefined);
  });
});

describe('job and queue extras', () => {
  test('deleteJob: finished only; emits a deleted job event', async () => {
    h = setup([{ structured: { status: 'needs_input', summary: '?', questions: [] } }]);
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    await assert.rejects(h.engine.deleteJob(job.id), { code: 'invalid_state' });
    await assert.rejects(h.engine.deleteJob('job-nope'), { code: 'not_found' });
    await h.engine.reject(job.id);
    await h.engine.deleteJob(job.id);
    assert.equal(h.engine.getJob(job.id), undefined);
    assert.ok(h.events.some((e) => e.type === 'job' && e.job.id === job.id && (e as { deleted?: boolean }).deleted === true));
  });

  test('deleteJob refuses when the queue is the inbox and its files are still there', async () => {
    h = setup([{ structured: { status: 'nothing_to_do', summary: 'ok' } }], { queueIsInbox: true });
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(job.id)!.state, 'completed');
    await assert.rejects(h.engine.deleteJob(job.id), { code: 'invalid_state', message: /back into the queue/ });
    fs.rmSync(path.join(h.vault, 'inbox', 'a.md'));
    await h.engine.deleteJob(job.id);
  });

  test('jobResumeCommand: the runner argv; null for label jobs', async () => {
    h = setup([{ structured: { status: 'nothing_to_do', summary: 'ok' } }]);
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    const job = (await h.engine.processQueue({ force: true }))!;
    await h.engine.whenIdle();
    assert.deepEqual(await h.engine.jobResumeCommand(job.id), ['fake-cli', '--resume', job.sessionID, '--model', job.model]);
    await assert.rejects(h.engine.jobResumeCommand('job-nope'), { code: 'not_found' });
    fs.writeFileSync(path.join(h.vault, 'wiki', 'p.md'), '# P\n');
    const labels = await h.engine.confirmLabels([{ path: 'wiki/p.md', labels: ['tea'] }]);
    assert.equal(await h.engine.jobResumeCommand(labels.id), null);
  });

  test('removeQueueEntry moves the file (and a note manifest) to the Trash with collision names', async () => {
    h = setup([]);
    const a = path.join(h.queue, 'a.md');
    fs.writeFileSync(a, '# A\n');
    fs.writeFileSync(path.join(h.queue, 'a.distill.json'), '{}');
    fs.writeFileSync(path.join(h.queue, 'keep.txt'), 'k');
    fs.mkdirSync(h.trash, { recursive: true });
    fs.writeFileSync(path.join(h.trash, 'a.md'), 'older');
    const entries = await h.engine.removeQueueEntry(a);
    assert.deepEqual(entries.map((e) => e.name), ['keep.txt']);
    assert.equal(fs.readFileSync(path.join(h.trash, 'a 2.md'), 'utf8'), '# A\n');
    assert.ok(fs.existsSync(path.join(h.trash, 'a.distill.json')));
    assert.equal(fs.readFileSync(path.join(h.trash, 'a.md'), 'utf8'), 'older');

    const outside = path.join(tmp, 'elsewhere.txt');
    fs.writeFileSync(outside, 'x');
    await assert.rejects(h.engine.removeQueueEntry(outside), { code: 'invalid_request' });
    await assert.rejects(h.engine.removeQueueEntry(path.join(h.queue, '..', 'elsewhere.txt')), { code: 'invalid_request' });
    await assert.rejects(h.engine.removeQueueEntry(path.join(h.queue, 'missing.txt')), { code: 'not_found' });
    // v5: a folder item goes to the Trash whole (it used to be refused).
    fs.mkdirSync(path.join(h.queue, 'folder', 'sub'), { recursive: true });
    fs.writeFileSync(path.join(h.queue, 'folder', 'sub', 'x.md'), 'x');
    fs.mkdirSync(path.join(h.trash, 'folder'));
    await h.engine.removeQueueEntry(path.join(h.queue, 'folder'));
    assert.ok(!fs.existsSync(path.join(h.queue, 'folder')));
    assert.equal(fs.readFileSync(path.join(h.trash, 'folder 2', 'sub', 'x.md'), 'utf8'), 'x');
    assert.deepEqual(fs.readdirSync(path.join(h.trash, 'folder')), [], 'an existing Trash folder is never replaced');
    fs.symlinkSync(outside, path.join(h.queue, 'link.txt'));
    await assert.rejects(h.engine.removeQueueEntry(path.join(h.queue, 'link.txt')), { code: 'invalid_request' });
    assert.ok(fs.existsSync(outside));
  });

  test('removeQueueEntry on a note removes the whole set; a member alone is refused', async () => {
    h = setup([]);
    const img = path.join(tmp, 'card.png');
    fs.writeFileSync(img, 'PNGDATA');
    const { notePath } = await h.engine.addNote({ title: 'Gyokuro', text: 'x', images: [{ path: img, mode: 'keep' }], suggest: 'none' });
    const manifest = path.join(h.queue, 'Gyokuro.distill.json');
    const image = path.join(h.queue, 'Gyokuro image 1.png');
    fs.writeFileSync(path.join(h.queue, 'keep.txt'), 'k');

    await assert.rejects(h.engine.removeQueueEntry(manifest), { code: 'invalid_request', message: /belongs to the note Gyokuro\.md/ });
    await assert.rejects(h.engine.removeQueueEntry(image), { code: 'invalid_request', message: /remove the note instead/ });
    assert.ok(fs.existsSync(manifest) && fs.existsSync(image), 'the note set is untouched');
    assert.deepEqual(h.engine.listQueue().find((e) => e.path === notePath)?.members, [manifest, image]);

    const entries = await h.engine.removeQueueEntry(notePath);
    assert.deepEqual(entries.map((e) => e.name), ['keep.txt']);
    for (const name of ['Gyokuro.md', 'Gyokuro.distill.json', 'Gyokuro image 1.png']) {
      assert.ok(fs.existsSync(path.join(h.trash, name)), name);
      assert.ok(!fs.existsSync(path.join(h.queue, name)), name);
    }
  });

  test('removeQueueEntry: an orphan manifest (its .md gone) can be removed on its own', async () => {
    h = setup([]);
    const { notePath } = await h.engine.addNote({ title: 'Lone', text: 'x', suggest: 'none' });
    fs.rmSync(notePath);
    const entries = await h.engine.removeQueueEntry(path.join(h.queue, 'Lone.distill.json'));
    assert.deepEqual(entries, []);
  });

  test('removeQueueEntry refuses a file a batch already took (queue = inbox)', async () => {
    h = setup([{ structured: { status: 'needs_input', summary: '?', questions: [] } }], { queueIsInbox: true });
    fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
    await h.engine.processQueue({ force: true });
    await h.engine.whenIdle();
    await assert.rejects(h.engine.removeQueueEntry(path.join(h.queue, 'a.md')), { code: 'invalid_state' });
  });
});
