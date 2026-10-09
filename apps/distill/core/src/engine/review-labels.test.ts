import assert from 'node:assert/strict';
import { execFileSync, execSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, afterEach, before, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreError, Job, RunRequest, RunResult, RunnerCapability, SessionStoreStatus } from '../contracts.js';
import { isSessionUnavailableError, sessionNotFoundError } from '../runners/session.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { statePaths } from '../store/paths.js';
import { createEngine, type Engine } from './index.js';
import { mapPool } from './queue-labels.js';
import { readBundle, sourcePages, verifyRebuilt, writeRevision, pageShas } from './review-labels.js';

const PRODUCT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
const PYTHON = execFileSync('python3', ['-c', 'import sys; print(sys.executable)']).toString().trim();
const CORE = path.join(PRODUCT_ROOT, 'scripts', 'claude-obsidian.py');
const sha = (data: string | Buffer) => createHash('sha256').update(data).digest('hex');

// ───────────── fakes ─────────────

type Answer = (req: RunRequest) => Partial<RunResult> | Promise<Partial<RunResult>>;

class FakeRunner implements AgentRunner {
  readonly displayName = 'Fake';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly requests: RunRequest[] = [];
  constructor(
    readonly id: string,
    public answer: Answer,
    readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']),
  ) {}
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    await new Promise((r) => setImmediate(r));
    const a = await this.answer(request);
    return { sessionID: 'start' in request.session ? request.session.start : request.session.resume, resultText: '', isError: false, costUSD: 0.001, denials: [], raw: '{}', ...a };
  }
}

const isLabelRun = (req: RunRequest) => /"labels"/.test(req.outputSchema ?? '');

let tmp: string;
let template: string;
let engine: Engine | undefined;

before(() => {
  template = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-review-vault-')));
  const vault = path.join(template, 'vault');
  const dry = JSON.parse(execFileSync(PYTHON, [CORE, 'init', vault, '--operation-id', 't', '--generated-at', '2026-10-01T00:00:00Z']).toString());
  execFileSync(PYTHON, [CORE, 'init', vault, '--operation-id', 't', '--generated-at', '2026-10-01T00:00:00Z', '--apply', '--approved-plan-sha256', dry.approved_plan_sha256]);
});
after(() => fs.rmSync(template, { recursive: true, force: true }));
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-review-')));
});
afterEach(async () => {
  await engine?.whenIdle();
  await engine?.stop();
  engine = undefined;
  fs.rmSync(tmp, { recursive: true, force: true });
});

// ───────────── unit ─────────────

describe('worker pool', () => {
  test('mapPool runs at most 3 at a time and keeps the order', async () => {
    let running = 0;
    let most = 0;
    const out = await mapPool([1, 2, 3, 4, 5, 6, 7], 3, async (n) => {
      running += 1;
      most = Math.max(most, running);
      await new Promise((r) => setTimeout(r, 5 + (n % 3)));
      running -= 1;
      return n * 2;
    });
    assert.deepEqual(out, [2, 4, 6, 8, 10, 12, 14]);
    assert.equal(most, 3);
  });
});

// ───────────── a pending batch, as the batch leaves it ─────────────

const SOURCES = ['a', 'b', 'c'];

function draft(name: string, labels: string[]): string {
  return [
    '---',
    'type: source',
    `title: "Source ${name.toUpperCase()}"`,
    `source_path: "inbox/${name}.md"`,
    'tags:',
    ...labels.map((l) => `  - ${l}`),
    'labels_by: ai',
    'labels_reviewed: false',
    'labels_origin: queue-folder',
    '---',
    '',
    `# Source ${name.toUpperCase()}`,
    '',
    `About ${name}.`,
    '',
  ].join('\n');
}

interface Seed {
  vault: string;
  state: string;
  queue: string;
  jobID: string;
  bundle: string;
  dir: string;
}

/** A vault, and a batch awaiting approval whose bundle (3 source pages + the index) the real core inspected. */
function seed(o: { labels?: (name: string) => string[]; runnerID?: string } = {}): Seed {
  const vault = path.join(tmp, 'vault');
  fs.cpSync(path.join(template, 'vault'), vault, { recursive: true });
  const state = path.join(tmp, 'state');
  const queue = path.join(tmp, 'queue');
  fs.mkdirSync(state, { recursive: true });
  fs.mkdirSync(queue, { recursive: true });
  fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
  const jobID = 'job-20261004-233313-0018';
  const dir = path.join(vault, '.vault-meta/worker', jobID);
  fs.mkdirSync(path.join(dir, 'drafts'), { recursive: true });
  const expected: Record<string, string | null> = {};
  const writes: unknown[] = [];
  SOURCES.forEach((n, i) => {
    fs.writeFileSync(path.join(vault, 'inbox', `${n}.md`), `# ${n}\n\nNotes about ${n}.\n`);
    const text = draft(n, (o.labels ?? ((x) => ['tea', `topic-${x}`]))(n));
    const rel = `drafts/s0${i + 1}.md`;
    fs.writeFileSync(path.join(dir, rel), text);
    const page = `wiki/sources/Source ${n.toUpperCase()}.md`;
    expected[page] = null;
    writes.push({ path: page, mode: 'create', content_file: rel, sha256: sha(text) });
  });
  const index = fs.readFileSync(path.join(vault, 'wiki/index.md'));
  expected['wiki/index.md'] = sha(index);
  const nextIndex = index.toString('utf8') + '\n- [[Source A]]\n- [[Source B]]\n- [[Source C]]\n';
  fs.writeFileSync(path.join(dir, 'drafts/index.md'), nextIndex);
  writes.push({ path: 'wiki/index.md', mode: 'replace', content_file: 'drafts/index.md', sha256: sha(nextIndex) });
  const bundle = path.join(dir, 'bundle.json');
  fs.writeFileSync(bundle, JSON.stringify({ schema: 'claude-obsidian.transaction.v1', operation_id: `${jobID}-ingest`, operation_type: 'markdown', expected_hashes: expected, writes }, null, 2));
  const plan = JSON.parse(execFileSync(PYTHON, [CORE, 'transaction', 'inspect', bundle, '--vault', vault]).toString());
  const job: Job = {
    id: jobID,
    kind: 'ingest',
    vaultPath: vault,
    files: SOURCES.map((n) => `inbox/${n}.md`),
    sessionID: randomUUID(),
    runnerID: o.runnerID ?? 'sandboxed',
    model: 'x',
    state: 'awaitingApproval',
    createdAt: '2026-10-05T03:33:13Z',
    updatedAt: '2026-10-05T03:48:35Z',
    turns: [{ id: randomUUID(), date: '2026-10-05T03:33:13Z', author: 'app', text: 'Batched 3 file(s)', costUSD: 0 }],
    grantedTools: [],
    changedPaths: [],
    approval: {
      summary: 'Ingest of 3 notes.',
      questions: [],
      denials: [],
      skipped: [],
      bundlePath: bundle,
      plan: { operation_id: plan.operation_id, operation_type: plan.operation_type, valid: plan.valid, changed_paths: plan.changed_paths, approval_sha256: plan.approval_sha256 },
    },
  };
  fs.writeFileSync(path.join(state, 'jobs.json'), JSON.stringify([job]));
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({
      vaults: [{ path: vault, queueDirectory: queue }],
      activeVaultPath: vault,
      productRoot: PRODUCT_ROOT,
      pythonPath: PYTHON,
      settleSeconds: 0,
      autoProcessEnabled: false,
      enabledRunners: ['sandboxed'],
      taskDefaults: Object.fromEntries(['ingest', 'ask', 'labelSuggest', 'imageText'].map((t) => [t, { runnerID: 'sandboxed', model: 'x' }])),
    }),
  );
  return { vault, state, queue, jobID, bundle, dir };
}

/** Answers label runs, and part rebuilds by building exactly the bundle the prompt asks for (optionally tampering). */
function sessionRunner(s: Seed, o: { tamper?: boolean; labels?: string[] } = {}): FakeRunner {
  let n = 0;
  return new FakeRunner('sandboxed', (req) => {
    if (isLabelRun(req)) return { structured: { labels: o.labels ?? ['Kettle', 'tea'] } };
    const at = /Build a NEW transaction bundle at `([^`]+)`/.exec(req.prompt);
    if (!at) return { structured: { status: 'nothing_to_do', summary: 'ok' } };
    n += 1;
    const keep = [...req.prompt.matchAll(/^- (wiki\/sources\/[^(]+\.md) \(from [^)]+\): (\S+) \(sha256 ([0-9a-f]{64})\)$/gm)];
    const index = fs.readFileSync(path.join(s.vault, 'wiki/index.md'));
    const expected: Record<string, string | null> = { 'wiki/index.md': sha(index) };
    const writes: unknown[] = [];
    for (const [, page, file, digest] of keep) {
      let content = fs.readFileSync(file!, 'utf8');
      if (o.tamper) content = content.replace('About', 'Rewritten');
      const cf = path.join(path.dirname(at[1]!), `rebuilt-${n}-${path.basename(page!)}`);
      fs.writeFileSync(cf, content);
      expected[page!.trim()] = null;
      writes.push({ path: page!.trim(), mode: 'create', content_file: cf, sha256: o.tamper ? sha(content) : digest });
    }
    const nextIndex = index.toString('utf8') + `\n<!-- part ${n} -->\n`;
    const cf = path.join(path.dirname(at[1]!), `rebuilt-${n}-index.md`);
    fs.writeFileSync(cf, nextIndex);
    writes.push({ path: 'wiki/index.md', mode: 'replace', content_file: cf, sha256: sha(nextIndex) });
    fs.writeFileSync(at[1]!, JSON.stringify({ schema: 'claude-obsidian.transaction.v1', operation_id: `${s.jobID}-part-${n}-${randomUUID().slice(0, 6)}`, operation_type: 'markdown', expected_hashes: expected, writes }));
    return { structured: { status: 'needs_approval', summary: `Rebuilt for ${keep.length}.`, bundle_path: at[1]! } };
  });
}

/**
 * A batch runner that can be limited to the exact apply command (so approving resumes the batch's session), whose
 * sessions in `gone` have no transcript (session continuity's check), and which runs the approved apply for real.
 */
class AgentFake extends FakeRunner {
  readonly gone = new Set<string>();
  sessionStatus(sessionID: string): SessionStoreStatus {
    return this.gone.has(sessionID) ? 'missing' : 'unknown';
  }
}

function agentRunner(s: Seed): AgentFake {
  const parts = sessionRunner(s);
  return new AgentFake(
    'sandboxed',
    (req) => {
      const rule = req.allowedTools.find((t) => t.startsWith('Bash(') && t.includes(' transaction apply '));
      if (!rule) return parts.answer(req);
      const out = JSON.parse(execSync(rule.slice('Bash('.length, -1), { shell: '/bin/sh' }).toString());
      return { structured: { status: 'done', summary: 'Applied.', operation_id: out.operation_id, changed_paths: out.changed_paths } };
    },
    new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput', 'toolPermissions']),
  );
}

const strip = (j: Job | undefined) => {
  const { updatedAt: _u, ...rest } = structuredClone(j!);
  return rest;
};

const goneError = (e: unknown, expect: { labels?: string; pages?: string[] }) => {
  assert.ok(isSessionUnavailableError(e), String(e));
  const d = (e as CoreError).details as Record<string, unknown>;
  assert.equal(d.action, 'approve');
  assert.equal(d.labels, expect.labels);
  assert.deepEqual(d.pages, expect.pages);
  return true;
};

function start(s: Seed, runner: FakeRunner, o: { detectProductRoot?: () => string } = {}): Engine {
  engine = createEngine({ paths: statePaths(s.state), runners: createRunnerRegistry([runner]), tickMs: 60_000, ...o });
  return engine;
}

const pageText = (s: Seed, n: string) => fs.readFileSync(path.join(s.vault, `wiki/sources/Source ${n.toUpperCase()}.md`), 'utf8');

describe('labels in Review: the confirm revision (real core)', () => {
  test('an existing pending batch gets its labels confirmed in a revision; the original bundle is kept as the unconfirmed twin', async () => {
    const s = seed();
    const original = fs.readFileSync(s.bundle, 'utf8');
    const e = start(s, sessionRunner(s));
    await e.start();
    // Before the revision is checked, Approve is refused.
    assert.equal(e.getJob(s.jobID)!.approval!.labels!.state, 'confirming');
    await assert.rejects(e.approve(s.jobID), /still saving the labels/);
    await e.whenIdle();
    const job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.approval!.labels!.state, 'confirmed', job.approval!.labels!.message ?? '');
    assert.equal(job.approval!.bundlePath, path.join(s.dir, 'bundle-labels-1.json'));
    assert.notEqual(job.approval!.plan!.approval_sha256, job.approval!.unconfirmed!.plan.approval_sha256);
    assert.equal(job.approval!.unconfirmed!.bundlePath, s.bundle);
    assert.equal(fs.readFileSync(s.bundle, 'utf8'), original, 'the original bundle is never modified');
    assert.deepEqual(job.approval!.sources!.map((x) => [x.title, x.labels, x.by]), [
      ['Source A', ['tea', 'topic-a'], 'ai'],
      ['Source B', ['tea', 'topic-b'], 'ai'],
      ['Source C', ['tea', 'topic-c'], 'ai'],
    ]);
    const revised = readBundle(job.approval!.bundlePath!)!;
    for (const p of sourcePages(revised)) {
      assert.ok(p.text.includes('labels_by: user') && !p.text.includes('labels_reviewed') && !p.text.includes('labels_origin'));
    }
    // Approve: the pages land with the labels confirmed, exactly as shown.
    await e.approve(s.jobID);
    await e.whenIdle();
    const done = e.getJob(s.jobID)!;
    assert.equal(done.state, 'completed', done.error ?? '');
    assert.ok(pageText(s, 'a').includes('  - topic-a\nlabels_by: user\n'));
    assert.ok(!pageText(s, 'a').includes('labels_reviewed'));
  });

  test('Approve, review labels later: the unconfirmed twin is applied', async () => {
    const s = seed();
    const e = start(s, sessionRunner(s));
    await e.start();
    await e.whenIdle();
    const twin = e.getJob(s.jobID)!.approval!.unconfirmed!;
    assert.equal(twin.bundlePath, s.bundle, 'the bundle the batch was built with');
    assert.match(twin.plan.approval_sha256, /^[0-9a-f]{64}$/, 'inspected again at start');
    await e.approve(s.jobID, { labels: 'later' });
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.state, 'completed');
    assert.ok(pageText(s, 'b').includes('labels_reviewed: false'));
    assert.equal(e.getJob(s.jobID)!.parts![0]!.labels, 'later');
    const review = await e.labelReview(s.vault);
    assert.deepEqual(review.toReview.map((x) => x.title).sort(), ['Source A', 'Source B', 'Source C'], 'Labels → To review');
  });

  test('the vault changed since the bundle was built: labels stay unconfirmed and the original bundle and plan are kept', async () => {
    const s = seed();
    const before = JSON.parse(fs.readFileSync(path.join(s.state, 'jobs.json'), 'utf8'))[0].approval;
    fs.appendFileSync(path.join(s.vault, 'wiki/index.md'), '\nchanged by hand\n');
    const e = start(s, sessionRunner(s));
    await e.start();
    await e.whenIdle();
    const job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval', 'stays in Review');
    assert.equal(job.approval!.labels!.state, 'unconfirmed');
    assert.match(job.approval!.labels!.message!, /^Labels stay unconfirmed: the vault core refused/);
    assert.equal(job.approval!.bundlePath, s.bundle);
    assert.equal(job.approval!.plan!.approval_sha256, before.plan.approval_sha256);
    assert.deepEqual(job.approval!.sources!.map((x) => x.labels), [['tea', 'topic-a'], ['tea', 'topic-b'], ['tea', 'topic-c']]);
  });

  test('editing labels in Review writes a new revision and a new hash; a refused edit changes nothing', async () => {
    const s = seed();
    const e = start(s, sessionRunner(s));
    await e.start();
    await e.whenIdle();
    const first = e.getJob(s.jobID)!.approval!;
    const page = first.sources![1]!.page;
    const edited = await e.editReviewLabels(s.jobID, [{ page, labels: ['Sencha', 'tea'] }]);
    assert.equal(edited.approval!.bundlePath, path.join(s.dir, 'bundle-labels-2.json'));
    assert.notEqual(edited.approval!.plan!.approval_sha256, first.plan!.approval_sha256);
    assert.deepEqual(edited.approval!.sources![1]!.labels, ['sencha', 'tea']);
    assert.equal(edited.approval!.sources![1]!.by, 'user');
    assert.ok(edited.approval!.unconfirmed!.bundlePath.endsWith('bundle-labels-3.json'), 'the twin carries the edit too');
    const twin = readBundle(edited.approval!.unconfirmed!.bundlePath)!;
    const twinPages = sourcePages(twin);
    assert.ok(twinPages.find((p) => p.page === page)!.text.includes('labels_by: user'));
    assert.ok(twinPages.find((p) => p.page !== page)!.text.includes('labels_reviewed: false'));
    // A refused edit (the vault changed): conflict, the plan and labels are as before.
    fs.appendFileSync(path.join(s.vault, 'wiki/index.md'), '\nchanged by hand\n');
    await assert.rejects(e.editReviewLabels(s.jobID, [{ page, labels: ['kettle'] }]), { code: 'conflict', message: /Couldn't save your label edit/ });
    const after = e.getJob(s.jobID)!.approval!;
    assert.equal(after.plan!.approval_sha256, edited.approval!.plan!.approval_sha256);
    assert.deepEqual(after.sources![1]!.labels, ['sencha', 'tea']);
    assert.equal(after.labels!.state, 'confirmed');
  });

  test('a batch from before labels in Review, with no labels: they are suggested 3 at a time and attached', async () => {
    const s = seed({ labels: () => [] });
    // The drafts have no label properties at all (an older build).
    for (const f of fs.readdirSync(path.join(s.dir, 'drafts'))) {
      const p = path.join(s.dir, 'drafts', f);
      fs.writeFileSync(p, fs.readFileSync(p, 'utf8').replace(/tags:\nlabels_by: ai\nlabels_reviewed: false\nlabels_origin: queue-folder\n/, ''));
    }
    const b = JSON.parse(fs.readFileSync(s.bundle, 'utf8'));
    for (const w of b.writes) w.sha256 = sha(fs.readFileSync(path.join(s.dir, w.content_file)));
    fs.writeFileSync(s.bundle, JSON.stringify(b));
    const plan = JSON.parse(execFileSync(PYTHON, [CORE, 'transaction', 'inspect', s.bundle, '--vault', s.vault]).toString());
    const jobs = JSON.parse(fs.readFileSync(path.join(s.state, 'jobs.json'), 'utf8'));
    jobs[0].approval.plan.approval_sha256 = plan.approval_sha256;
    fs.writeFileSync(path.join(s.state, 'jobs.json'), JSON.stringify(jobs));
    const runner = sessionRunner(s, { labels: ['Kettle', 'tea'] });
    const e = start(s, runner);
    await e.start();
    assert.equal(e.getJob(s.jobID)!.approval!.labels!.state, 'suggesting');
    await assert.rejects(e.approve(s.jobID), /still being suggested/);
    await e.whenIdle();
    const job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.approval!.labels!.state, 'confirmed', job.approval!.labels!.message ?? '');
    assert.equal(runner.requests.filter(isLabelRun).length, 3);
    assert.deepEqual(job.approval!.sources!.map((x) => [x.labels, x.by]), [[['kettle', 'tea'], 'ai'], [['kettle', 'tea'], 'ai'], [['kettle', 'tea'], 'ai']]);
    // Approve, review labels later works here too: its version has the AI's labels left to review, freshly inspected.
    const twin = readBundle(job.approval!.unconfirmed!.bundlePath)!;
    assert.notEqual(job.approval!.unconfirmed!.bundlePath, s.bundle);
    for (const p of sourcePages(twin)) assert.ok(p.text.includes('labels_by: ai') && p.text.includes('labels_reviewed: false') && p.text.includes('  - kettle'));
    await e.approve(s.jobID, { labels: 'later' });
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.state, 'completed', e.getJob(s.jobID)!.error ?? '');
    assert.ok(pageText(s, 'a').includes('labels_reviewed: false'));
    assert.equal((await e.labelReview(s.vault)).toReview.length, 3);
  });
});

describe('parts of a batch (pick, remove, rebuild in the same session)', () => {
  test('approve 1 of 3: rebuilt and checked, approved once more, then the rest is rebuilt in the same session', async () => {
    const s = seed();
    const runner = sessionRunner(s);
    const e = start(s, runner);
    await e.start();
    await e.whenIdle();
    const sources = e.getJob(s.jobID)!.approval!.sources!;
    const session = e.getJob(s.jobID)!.sessionID;
    await e.removeReviewSource(s.jobID, sources[2]!.page, true);
    await e.approve(s.jobID, { pages: [sources[0]!.page] });
    await e.whenIdle();
    let job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval', job.approval?.planError ?? job.error ?? '');
    assert.deepEqual(job.approval!.rebuilt, { reason: 'partial', pages: [sources[0]!.page], labels: 'confirm' });
    assert.deepEqual(job.approval!.sources!.map((x) => x.page), [sources[0]!.page]);
    const rebuild = runner.requests.find((r) => r.prompt.includes('Build a NEW transaction bundle'))!;
    assert.deepEqual(rebuild.session, { resume: session }, "the batch's own session");
    assert.match(rebuild.prompt, /Leave these sources out entirely[\s\S]*Source B/);
    assert.match(rebuild.prompt, /removed these sources[\s\S]*Source C/);
    // Approve the rebuilt change: part 1 applies, the source left (B) is rebuilt; C (removed) never.
    await e.approve(s.jobID);
    await e.whenIdle();
    job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval', job.error ?? job.approval?.planError ?? '');
    assert.equal(job.parts!.length, 1);
    assert.deepEqual(job.parts![0]!.pages, [sources[0]!.page]);
    assert.deepEqual(job.approval!.rebuilt!.reason, 'remaining');
    assert.deepEqual(job.approval!.sources!.map((x) => x.page), [sources[1]!.page]);
    assert.ok(fs.existsSync(path.join(s.vault, 'wiki/sources/Source A.md')));
    assert.ok(!fs.existsSync(path.join(s.vault, 'wiki/sources/Source B.md')));
    await e.approve(s.jobID);
    await e.whenIdle();
    job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'completed', job.error ?? '');
    assert.equal(job.parts!.length, 2);
    assert.ok(fs.existsSync(path.join(s.vault, 'wiki/sources/Source B.md')));
    assert.ok(!fs.existsSync(path.join(s.vault, 'wiki/sources/Source C.md')), 'a removed source is never added');
    assert.ok(fs.existsSync(path.join(s.vault, 'inbox/c.md')), 'its inbox file stays');
    assert.equal(job.pendingPart, undefined);
    assert.ok(runner.requests.filter((r) => !isLabelRun(r)).every((r) => 'resume' in r.session && r.session.resume === session));
  });

  test('rejecting a rebuilt part discards only it: the sources go back to Review; Reject batch ends the batch', async () => {
    const s = seed();
    const runner = sessionRunner(s);
    const e = start(s, runner);
    await e.start();
    await e.whenIdle();
    const before = e.getJob(s.jobID)!.approval!;
    const sources = before.sources!;
    await e.approve(s.jobID, { pages: [sources[0]!.page] });
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.approval!.rebuilt!.reason, 'partial');
    // Reject the rebuilt part: nothing applied, every source back in this batch's Review, the plan as before.
    await e.reject(s.jobID);
    let job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.pendingPart, undefined);
    assert.equal(job.approval!.rebuilt, undefined);
    assert.deepEqual(job.approval!.sources!.map((x) => x.page), sources.map((x) => x.page));
    assert.equal(job.approval!.plan!.approval_sha256, before.plan!.approval_sha256);
    assert.match(job.turns.at(-1)!.text, /^Discarded the rebuilt change for 1 source; nothing was applied\. All 3 sources are back/);
    assert.ok(!fs.existsSync(path.join(s.vault, 'wiki/sources/Source A.md')), 'nothing applied');
    // Pick again, approve the part; then discard the rebuilt change for what is left: it stays, Approve rebuilds it.
    await e.approve(s.jobID, { pages: [sources[0]!.page] });
    await e.whenIdle();
    await e.approve(s.jobID);
    await e.whenIdle();
    job = e.getJob(s.jobID)!;
    assert.equal(job.approval!.rebuilt!.reason, 'remaining', job.error ?? job.approval?.planError ?? '');
    await e.reject(s.jobID, { scope: 'part' });
    job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.approval!.needsRebuild, true);
    assert.equal(job.approval!.plan, undefined);
    assert.deepEqual(job.approval!.sources!.map((x) => x.page), [sources[1]!.page, sources[2]!.page]);
    assert.ok(!fs.existsSync(path.join(s.vault, 'wiki/sources/Source B.md')));
    await assert.rejects(e.reject(s.jobID, { scope: 'part' }), /no rebuilt part/);
    const asked = runner.requests.length;
    await e.approve(s.jobID);
    await e.whenIdle();
    job = e.getJob(s.jobID)!;
    assert.equal(runner.requests.length, asked + 1, 'the same request, once more, in the same session');
    assert.equal(job.approval!.rebuilt!.reason, 'remaining', job.approval?.planError ?? '');
    // Only an explicit Reject batch rejects everything.
    await e.reject(s.jobID, { scope: 'batch' });
    job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'rejected');
    assert.equal(job.parts!.length, 1, 'the part already applied stays applied');
  });

  test('a rebuilt change that differs from what was approved is not offered', async () => {
    const s = seed();
    const e = start(s, sessionRunner(s, { tamper: true }));
    await e.start();
    await e.whenIdle();
    const sources = e.getJob(s.jobID)!.approval!.sources!;
    await e.approve(s.jobID, { pages: [sources[0]!.page, sources[1]!.page] });
    await e.whenIdle();
    const job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval');
    assert.equal(job.approval!.plan, undefined);
    assert.match(job.approval!.planError!, /doesn't match what you approved .*is not the page you approved/);
    await assert.rejects(e.approve(s.jobID), /no valid plan/);
  });

  test('remove and undo; picking every source is a normal approval', async () => {
    const s = seed();
    const e = start(s, sessionRunner(s));
    await e.start();
    await e.whenIdle();
    const page = e.getJob(s.jobID)!.approval!.sources![0]!.page;
    assert.equal((await e.removeReviewSource(s.jobID, page, true)).approval!.sources![0]!.removed, true);
    assert.equal((await e.removeReviewSource(s.jobID, page, false)).approval!.sources![0]!.removed, undefined);
    await assert.rejects(e.approve(s.jobID, { pages: ['wiki/sources/Nope.md'] }), { code: 'invalid_request' });
    await assert.rejects(e.approve(s.jobID, { pages: [] }), /Pick at least one source/);
    await e.approve(s.jobID, { pages: e.getJob(s.jobID)!.approval!.sources!.map((x) => x.page) });
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.state, 'completed');
  });

  test('the vault core is gone: a partial approve and a needs-rebuild approve refuse and change nothing (2026-10-08)', async () => {
    const s = seed();
    const runner = sessionRunner(s);
    // Never heal the missing root back to this checkout: the test is about the core being gone.
    const e = start(s, runner, { detectProductRoot: () => '' });
    await e.start();
    await e.whenIdle();
    const sources = e.getJob(s.jobID)!.approval!.sources!;
    const gone = async () => e.updateSettings({ productRoot: path.join(s.dir, 'deleted-worktree') });
    const back = async () => e.updateSettings({ productRoot: PRODUCT_ROOT });
    // A pick of 1 of 3.
    await gone();
    let before = strip(e.getJob(s.jobID));
    let calls = runner.requests.length;
    await assert.rejects(e.approve(s.jobID, { pages: [sources[0]!.page] }), { code: 'invalid_state', message: /can't find its vault core/ });
    assert.deepEqual(strip(e.getJob(s.jobID)), before, 'nothing changed');
    assert.equal(runner.requests.length, calls, 'no runner call');
    // A batch whose rebuilt part was rejected needs a rebuild: Approve would resume the session.
    await back();
    await e.approve(s.jobID, { pages: [sources[0]!.page] });
    await e.whenIdle();
    await e.approve(s.jobID);
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.approval!.rebuilt?.reason, 'remaining');
    await e.reject(s.jobID, { scope: 'part' });
    assert.equal(e.getJob(s.jobID)!.approval!.needsRebuild, true);
    await gone();
    before = strip(e.getJob(s.jobID));
    calls = runner.requests.length;
    await assert.rejects(e.approve(s.jobID), { code: 'invalid_state', message: /can't find its vault core/ });
    assert.deepEqual(strip(e.getJob(s.jobID)), before, 'nothing changed');
    assert.equal(runner.requests.length, calls, 'no runner call');
  });

  test('the session is gone on a partial approve: Cancel leaves the batch exactly as it was', async () => {
    const s = seed();
    const runner = agentRunner(s);
    const e = start(s, runner);
    await e.start();
    await e.whenIdle();
    const before = strip(e.getJob(s.jobID));
    const sources = before.approval!.sources!;
    runner.gone.add(before.sessionID);
    const calls = runner.requests.length;
    await assert.rejects(e.approve(s.jobID, { pages: [sources[0]!.page] }), (err) => goneError(err, { labels: 'confirm', pages: [sources[0]!.page] }));
    assert.deepEqual(strip(e.getJob(s.jobID)), before, 'Cancel: nothing changed, no part pending');
    assert.equal(runner.requests.length, calls, 'no runner call');
    // The runner refuses at the resume (no positive evidence before): the job is put back too, with the marker.
    runner.gone.clear();
    runner.answer = () => {
      throw sessionNotFoundError(`No conversation found with session ID: ${before.sessionID}`, before.sessionID);
    };
    await e.approve(s.jobID, { pages: [sources[0]!.page] });
    await e.whenIdle();
    const back = e.getJob(s.jobID)!;
    assert.equal(back.state, 'awaitingApproval');
    assert.equal(back.pendingPart, undefined);
    assert.deepEqual(back.approval, before.approval);
    assert.equal(back.sessionUnavailable!.reason, 'notFound');
    assert.deepEqual(back.sessionUnavailable!.pages, [sources[0]!.page], 'Continue must rebuild the same part, never the whole batch');
  });

  test('the session is gone on a partial approve: Continue rebuilds and applies only the part, in a new session', async () => {
    const s = seed();
    const runner = agentRunner(s);
    const e = start(s, runner);
    await e.start();
    await e.whenIdle();
    const job0 = e.getJob(s.jobID)!;
    const sources = job0.approval!.sources!;
    runner.gone.add(job0.sessionID);
    await assert.rejects(e.approve(s.jobID, { pages: [sources[0]!.page] }));
    // Continue: the same pick, in a new seeded session; the rebuilt change is checked as before.
    await e.approve(s.jobID, { pages: [sources[0]!.page], newSession: true });
    await e.whenIdle();
    let job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'awaitingApproval', job.approval?.planError ?? job.error ?? '');
    assert.notEqual(job.sessionID, job0.sessionID);
    assert.deepEqual(job.approval!.rebuilt!.pages, [sources[0]!.page]);
    const rebuild = runner.requests.find((r) => r.prompt.includes('Build a NEW transaction bundle'))!;
    assert.deepEqual(rebuild.session, { start: job.sessionID });
    assert.match(rebuild.prompt, /Leave these sources out entirely[\s\S]*Source B/, 'the same part request, seeded');
    // The new session is gone too when the part is approved: Continue applies exactly the rebuilt part's plan.
    const partPlan = job.approval!.plan!;
    const partBundle = job.approval!.bundlePath!;
    runner.gone.add(job.sessionID);
    await assert.rejects(e.approve(s.jobID), (err) => goneError(err, { labels: undefined, pages: undefined }));
    assert.equal(e.getJob(s.jobID)!.state, 'awaitingApproval');
    await e.approve(s.jobID, { newSession: true });
    await e.whenIdle();
    job = e.getJob(s.jobID)!;
    const apply = runner.requests.find((r) => r.allowedTools.some((t) => t.includes(' transaction apply ')))!;
    assert.ok(apply.allowedTools.some((t) => t.includes(partBundle) && t.includes(`--approved-plan-sha256 ${partPlan.approval_sha256}`)), 'the part, not the full plan');
    assert.equal(job.parts!.length, 1, job.error ?? '');
    assert.deepEqual(job.parts![0]!.pages, [sources[0]!.page]);
    assert.ok(fs.existsSync(path.join(s.vault, 'wiki/sources/Source A.md')));
    assert.ok(!fs.existsSync(path.join(s.vault, 'wiki/sources/Source B.md')), 'the rest is not applied');
  });

  test('the session is gone on approve-later: Continue applies the unconfirmed bundle', async () => {
    const s = seed();
    const runner = agentRunner(s);
    const e = start(s, runner);
    await e.start();
    await e.whenIdle();
    const job0 = e.getJob(s.jobID)!;
    const twin = job0.approval!.unconfirmed!;
    runner.gone.add(job0.sessionID);
    const before = strip(job0);
    await assert.rejects(e.approve(s.jobID, { labels: 'later' }), (err) => goneError(err, { labels: 'later', pages: undefined }));
    assert.deepEqual(strip(e.getJob(s.jobID)), before);
    await e.approve(s.jobID, { labels: 'later', newSession: true });
    await e.whenIdle();
    const job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'completed', job.error ?? '');
    const apply = runner.requests.find((r) => r.allowedTools.some((t) => t.includes(' transaction apply ')))!;
    assert.ok(apply.allowedTools.some((t) => t.includes(twin.bundlePath) && t.includes(`--approved-plan-sha256 ${twin.plan.approval_sha256}`)));
    assert.ok(pageText(s, 'a').includes('labels_reviewed: false'));
    assert.equal(job.parts![0]!.labels, 'later');
    // A marker left by a refused resume carries "later" too, so Continue without options keeps it.
    assert.equal((await e.labelReview(s.vault)).toReview.length, 3);
  });

  test('a refused resume of approve-later leaves the marker with labels later; Continue without options keeps it', async () => {
    const s = seed();
    const runner = agentRunner(s);
    const e = start(s, runner);
    await e.start();
    await e.whenIdle();
    const job0 = e.getJob(s.jobID)!;
    const answer = runner.answer;
    runner.answer = () => {
      throw sessionNotFoundError(`No conversation found with session ID: ${job0.sessionID}`, job0.sessionID);
    };
    await e.approve(s.jobID, { labels: 'later' });
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.sessionUnavailable!.labels, 'later');
    runner.answer = answer;
    await e.approve(s.jobID, { newSession: true });
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.state, 'completed');
    assert.ok(pageText(s, 'b').includes('labels_reviewed: false'));
  });
});

describe('review-labels helpers', () => {
  test('verifyRebuilt and the keep-mode revision', () => {
    const s = seed();
    const b = readBundle(s.bundle)!;
    const pages = sourcePages(b);
    const shas = pageShas(b);
    const first = pages[0]!.page;
    assert.deepEqual(verifyRebuilt(b, { [first]: shas.get(first)! }, []), []);
    assert.deepEqual(verifyRebuilt(b, { [first]: 'x'.repeat(64) }, [pages[1]!.page]), [`${first} is not the page you approved`, `${pages[1]!.page} should not be in it`]);
    const rev = writeRevision(b, pages, new Map([[first, ['own']]]), 'keep')!;
    assert.deepEqual(rev.changed, [first], 'keep mode touches only the edited page');
  });
});

describe('a plan applied outside Distill (Open in Terminal)', () => {
  test('the vault journal shows the approved plan complete: the batch is recorded as applied', async () => {
    const s = seed();
    const plan = JSON.parse(fs.readFileSync(path.join(s.state, 'jobs.json'), 'utf8'))[0].approval.plan;
    const tx = path.join(s.vault, '.vault-meta/transactions', plan.operation_id);
    fs.mkdirSync(tx, { recursive: true });
    fs.writeFileSync(path.join(tx, 'journal.json'), JSON.stringify({ state: 'complete', approval_sha256: plan.approval_sha256, operation_id: plan.operation_id }));
    fs.writeFileSync(path.join(tx, 'changed-paths.json'), JSON.stringify({ approval_sha256: plan.approval_sha256, changed_paths: plan.changed_paths }));
    const e = start(s, sessionRunner(s));
    await e.start();
    await e.whenIdle();
    const job = e.getJob(s.jobID)!;
    assert.equal(job.state, 'completed');
    assert.equal(job.operationID, plan.operation_id);
    assert.deepEqual([...job.changedPaths].sort(), [...plan.changed_paths].sort());
    assert.equal(job.approvedChange?.appliedOutside, true);
    assert.equal(job.approvedChange?.approvalSha256, plan.approval_sha256);
    assert.match(job.turns.at(-1)!.text, /outside Distill/);
  });

  test('a journal for a different plan, or not complete, changes nothing', async () => {
    const s = seed();
    const plan = JSON.parse(fs.readFileSync(path.join(s.state, 'jobs.json'), 'utf8'))[0].approval.plan;
    const tx = path.join(s.vault, '.vault-meta/transactions', plan.operation_id);
    fs.mkdirSync(tx, { recursive: true });
    fs.writeFileSync(path.join(tx, 'journal.json'), JSON.stringify({ state: 'complete', approval_sha256: 'f'.repeat(64) }));
    const e = start(s, sessionRunner(s));
    await e.start();
    await e.whenIdle();
    assert.equal(e.getJob(s.jobID)!.state, 'awaitingApproval');
  });
});
