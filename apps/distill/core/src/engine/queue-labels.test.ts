import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreEvent, RunRequest, RunResult, RunnerCapability } from '../contracts.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { statePaths } from '../store/paths.js';
import { createEngine, MAX_SETTLE_SECONDS, type Engine } from './index.js';

/** Label runs answer after `delay` ms (or throw); ingest turns finish with nothing_to_do. Tracks concurrency. */
class Runner implements AgentRunner {
  readonly id = 'claude-code';
  readonly displayName = 'Fake';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput']);
  labelRuns: RunRequest[] = [];
  turns: RunRequest[] = [];
  running = 0;
  most = 0;
  fail: (req: RunRequest) => boolean = () => false;
  constructor(readonly delay = 5) {}
  problems() {
    return [];
  }
  async run(req: RunRequest): Promise<RunResult> {
    const base = { sessionID: 's', resultText: '', isError: false, costUSD: 0.001, denials: [], raw: '{}' };
    if (!/"labels"/.test(req.outputSchema ?? '')) {
      this.turns.push(req);
      await new Promise((r) => setImmediate(r));
      return { ...base, structured: { status: 'nothing_to_do', summary: 'ok' } };
    }
    this.labelRuns.push(req);
    this.running += 1;
    this.most = Math.max(this.most, this.running);
    try {
      await new Promise((r) => setTimeout(r, this.delay));
      if (this.fail(req)) throw new Error('Haiku timed out');
      return { ...base, structured: { labels: ['Tea', 'Notes'] } };
    } finally {
      this.running -= 1;
    }
  }
}

let tmp: string;
let engine: Engine | undefined;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-qlabels-')));
});
afterEach(async () => {
  await engine?.whenIdle();
  await engine?.stop();
  engine = undefined;
  fs.rmSync(tmp, { recursive: true, force: true });
});

function setup(runner: Runner, settings: Record<string, unknown> = {}): { queue: string; vault: string; events: CoreEvent[] } {
  const vault = path.join(tmp, 'vault');
  const queue = path.join(tmp, 'queue');
  const state = path.join(tmp, 'state');
  const product = path.join(tmp, 'product');
  for (const d of [path.join(vault, 'inbox'), queue, state, path.join(product, 'scripts')]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '# fake\n');
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({ vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, productRoot: product, settleSeconds: 0, pythonPath: '/usr/bin/python3', autoProcessEnabled: false, ...settings }),
  );
  engine = createEngine({ paths: statePaths(state), runners: createRunnerRegistry([runner]), tickMs: 60_000 });
  const events: CoreEvent[] = [];
  engine.subscribe((e) => events.push(e));
  return { queue, vault, events };
}

describe('queue labels before the batch', () => {
  test('every text file gets labels, at most 3 at a time; PDFs and own tags need no call; per-file progress', async () => {
    const runner = new Runner(15);
    const { queue, events } = setup(runner);
    for (let i = 1; i <= 7; i += 1) fs.writeFileSync(path.join(queue, `note-${i}.md`), `Note ${i} about tea.\n`);
    fs.writeFileSync(path.join(queue, 'scan.pdf'), '%PDF-1.4');
    fs.writeFileSync(path.join(queue, 'tagged.md'), '---\ntags: [mine]\n---\nOwn\n');
    const first = engine!.listQueue();
    assert.equal(first.filter((e) => e.labels?.state === 'waiting').length, 7);
    assert.equal(first.find((e) => e.name === 'tagged.md')!.labels!.state, 'own');
    assert.equal(first.find((e) => e.name === 'scan.pdf')!.labels, undefined);
    await engine!.whenIdle();
    assert.equal(runner.labelRuns.length, 7);
    assert.equal(runner.most, 3, 'at most 3 in parallel, and the pool is used');
    const after = engine!.listQueue();
    assert.equal(after.filter((e) => e.labels?.state === 'suggested').length, 7);
    assert.deepEqual(after.find((e) => e.name === 'note-1.md')!.labels!.labels.map((l) => l.name), ['tea', 'notes']);
    assert.ok(after.every((e) => !e.heldForLabels));
    const perFile = events.filter((e) => e.type === 'progress' && e.progress.kind === 'labelSuggest' && e.progress.item);
    assert.equal(perFile.filter((e) => e.type === 'progress' && e.progress.finished).length, 7);
    // The batch reuses them: no label run, no pre-step.
    runner.labelRuns = [];
    const job = await engine!.processQueue({ force: true });
    await engine!.whenIdle();
    assert.ok(job);
    assert.equal(runner.labelRuns.length, 0);
    assert.match(runner.turns[0]!.prompt, /inbox\/note-1\.md: AI labels[\s\S]*- tea/);
  });

  test('the label gate: a batch leaves files whose labels are not in; Process now says so', async () => {
    const runner = new Runner(40);
    const { queue, events } = setup(runner);
    fs.writeFileSync(path.join(queue, 'a.md'), 'A\n');
    fs.writeFileSync(path.join(queue, 'scan.pdf'), '%PDF-1.4');
    const job = await engine!.processQueue({ force: true });
    assert.ok(job, 'the PDF goes');
    assert.deepEqual(job.files, ['inbox/scan.pdf']);
    assert.ok(fs.existsSync(path.join(queue, 'a.md')), 'a.md waits for its labels');
    assert.ok(events.some((e) => e.type === 'log' && /1 file still waits for labels; it goes in the next batch/.test(e.message)));
    await engine!.whenIdle();
    const next = await engine!.processQueue({ force: true });
    assert.ok(next);
    assert.deepEqual(next.files, ['inbox/a.md']);
  });

  test('labeling off: nothing is held and nothing is suggested', async () => {
    const runner = new Runner();
    const { queue } = setup(runner, { labeling: { autoLabelQueueFolder: false } });
    fs.writeFileSync(path.join(queue, 'a.md'), 'A\n');
    assert.equal(engine!.listQueue()[0]!.labels, undefined);
    const job = await engine!.processQueue({ force: true });
    assert.ok(job);
    await engine!.whenIdle();
    assert.equal(runner.labelRuns.length, 0);
  });

  test('failures retry by themselves up to 3 times, then wait for the user; Send without labels lets it go', async () => {
    const runner = new Runner(1);
    runner.fail = () => true;
    const { queue } = setup(runner);
    fs.writeFileSync(path.join(queue, 'a.md'), 'A\n');
    engine!.listQueue();
    await engine!.whenIdle();
    for (let i = 0; i < 4; i += 1) {
      assert.equal(await engine!.processQueue({ force: true }), null);
      engine!.listQueue();
      await engine!.whenIdle();
    }
    assert.equal(runner.labelRuns.length, 3, 'three tries, then it waits');
    const entry = engine!.listQueue()[0]!;
    assert.equal(entry.labels!.state, 'failed');
    assert.equal(entry.labels!.attempts, 3);
    assert.equal(entry.heldForLabels, true);
    await engine!.skipQueueLabels(entry.path);
    assert.equal(engine!.listQueue()[0]!.labels!.state, 'skipped');
    const job = await engine!.processQueue({ force: true });
    assert.ok(job);
    await engine!.whenIdle();
    assert.match(runner.turns[0]!.prompt, /inbox\/a\.md: no labels\./);
  });

  test('Retry asks again; confirming in the queue makes them the user’s', async () => {
    const runner = new Runner(1);
    let fails = true;
    runner.fail = () => fails;
    const { queue } = setup(runner);
    fs.writeFileSync(path.join(queue, 'a.md'), 'A\n');
    engine!.listQueue();
    await engine!.whenIdle();
    const file = engine!.listQueue()[0]!.path;
    fails = false;
    await engine!.retryQueueLabels(file);
    await engine!.whenIdle();
    assert.equal(engine!.listQueue()[0]!.labels!.state, 'suggested');
    const entries = await engine!.labelQueueItem(file, ['tea', 'sencha']);
    assert.deepEqual(entries[0]!.labels, { state: 'confirmed', labels: [{ name: 'tea', existing: true }, { name: 'sencha', existing: true }] });
    await assert.rejects(engine!.labelQueueItem(path.join(queue, 'nope.md'), ['x']), { code: 'not_found' });
    const job = await engine!.processQueue({ force: true });
    assert.ok(job);
    await engine!.whenIdle();
    assert.match(runner.turns[0]!.prompt, /inbox\/a\.md: labels the user confirmed:\n {4}tags:\n {6}- tea\n {6}- sencha\n {4}labels_by: user/);
  });

  test('the wait setting is clamped to 0..24 hours', async () => {
    setup(new Runner());
    assert.equal((await engine!.updateSettings({ settleSeconds: 999_999 })).settleSeconds, MAX_SETTLE_SECONDS);
    assert.equal((await engine!.updateSettings({ settleSeconds: 0 })).settleSeconds, 0);
  });
});
