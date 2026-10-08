import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreEvent, Job, RunRequest, RunResult, RunnerCapability } from '../contracts.js';
import { createEventLogger } from '../activity/instrument.js';
import { ActivityLog } from '../activity/log.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { cancelledError, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { createStepLog } from '../steps/index.js';
import { decodeJob, encodeJob, newJob } from '../store/jobs.js';
import { statePaths } from '../store/paths.js';
import { createEngine, type Engine } from './index.js';
import { FULL_READ_PROMPT, IngestJobKind, JobContext } from './job-kinds.js';
import { existingSourcePages, groupItems, inboxFileProblem, jobSourceItems, packItems, sourceFileProblem, sourceSize } from './reread.js';

/** Fake runner only: answers every first turn with a plan for its own bundle, records order and overlap. */
class FakeRunner implements AgentRunner {
  readonly id = 'claude-code';
  readonly displayName = 'Fake';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput']);
  readonly requests: RunRequest[] = [];
  running = 0;
  maxRunning = 0;
  constructor(private readonly vault: () => string, private readonly jobFor: (session: string) => Job | undefined) {}
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    this.running += 1;
    this.maxRunning = Math.max(this.maxRunning, this.running);
    try {
      await new Promise((r) => setImmediate(r));
      if (request.signal?.aborted) throw cancelledError();
      const sid = 'start' in request.session ? request.session.start : request.session.resume;
      const job = this.jobFor(sid);
      const structured =
        'start' in request.session
          ? { status: 'needs_approval', summary: 'Updates pages.', bundle_path: path.join(this.vault(), '.vault-meta/worker', job!.id, 'bundle.json') }
          : { status: 'done', summary: 'Applied.', operation_id: 'op-1', changed_paths: ['wiki/sources/a.md'] };
      return { sessionID: sid, resultText: '', isError: false, costUSD: 0, denials: [], structured, raw: JSON.stringify({ structured_output: structured }) };
    } finally {
      this.running -= 1;
    }
  }
}

const PLAN = {
  schema: 'claude-obsidian.transaction-plan.v1',
  operation_id: 'op-1',
  operation_type: 'ingest',
  valid: true,
  changed_paths: ['wiki/sources/a.md'],
  approval_sha256: 'f'.repeat(64),
};

let tmp: string;
let engine: Engine | undefined;

interface H {
  vault: string;
  queue: string;
  state: string;
  engine: Engine;
  runner: FakeRunner;
  events: CoreEvent[];
}

function setup(o: { queueIsInbox?: boolean } = {}): H {
  const vault = path.join(tmp, 'vault');
  const product = path.join(tmp, 'product');
  const state = path.join(tmp, 'state');
  fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
  fs.mkdirSync(path.join(vault, 'wiki', 'sources'), { recursive: true });
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
      labeling: { autoLabelQueueFolder: false },
    }),
  );
  let e: Engine;
  const runner = new FakeRunner(() => vault, (sid) => e.listJobs().find((j) => j.sessionID === sid));
  const launch = async (_opts: RunProcessOptions): Promise<ProcessOutput> => ({ status: 0, stdout: Buffer.from(JSON.stringify(PLAN)), stderr: Buffer.alloc(0) });
  e = createEngine({ paths: statePaths(state), runners: createRunnerRegistry([runner]), launch, tickMs: 60_000 });
  engine = e;
  const events: CoreEvent[] = [];
  e.subscribe((ev) => events.push(ev));
  return { vault, queue, state, engine: e, runner, events };
}

function writeInbox(vault: string, names: string[]): string[] {
  return names.map((n) => {
    const rel = `inbox/${n}`;
    fs.mkdirSync(path.dirname(path.join(vault, rel)), { recursive: true });
    fs.writeFileSync(path.join(vault, rel), `# ${n}\n\nGemini notes.\n\n## Transcript\n\nline 1\nline 2\n`);
    return rel;
  });
}

/** Every file under a folder with its hash and mtime, to prove nothing there changed. */
function snapshot(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (d: string) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const abs = path.join(d, e.name);
      if (e.isDirectory()) walk(abs);
      else out[path.relative(dir, abs)] = createHash('sha256').update(fs.readFileSync(abs)).digest('hex') + '@' + fs.statSync(abs).mtimeMs;
    }
  };
  walk(dir);
  return out;
}

function finishedJob(vault: string, files: string[], folders?: string[]): Job {
  const job = newJob({ id: 'job-20261004-233313-0018', kind: 'ingest', vaultPath: vault, files, model: 'sonnet', now: new Date() });
  job.state = 'completed';
  job.changedPaths = ['wiki/sources/a.md'];
  if (folders) job.folders = folders;
  return job;
}

beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-reread-')));
});
afterEach(async () => {
  await engine?.stop();
  engine = undefined;
  fs.rmSync(tmp, { recursive: true, force: true });
});

describe('re-read: grouping and expansion', () => {
  test('items go in groups of perBatch, in order; a folder stays one item', () => {
    const items = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].map((x) => ({ files: [`inbox/${x}.md`] }));
    const groups = groupItems(items, 3);
    assert.deepEqual(groups.map((g) => g.files.map((f) => path.posix.basename(f, '.md')).join('')), ['abc', 'def', 'g']);
    const withFolder = groupItems([{ files: ['inbox/a.md'] }, { files: ['inbox/T/x.md', 'inbox/T/y.md'], folder: 'inbox/T' }], 1);
    assert.deepEqual(withFolder, [{ files: ['inbox/a.md'] }, { files: ['inbox/T/x.md', 'inbox/T/y.md'], folders: ['inbox/T'] }]);
    assert.equal(groupItems(Array.from({ length: 22 }, (_, i) => ({ files: [`inbox/${i}.md`] })), 3).length, 8);
  });

  test('packed by tokens: in order, a group closes before it would pass the budget; one item over it gets a group alone', () => {
    const sizes: Record<string, number> = { a: 30_000, b: 50_000, c: 40_000, d: 150_000, e: 10_000 };
    const items = Object.keys(sizes).map((x) => ({ files: [`inbox/${x}.md`] }));
    const groups = packItems(items, 100_000, (f) => sizes[path.posix.basename(f, '.md')]!);
    assert.deepEqual(groups.map((g) => g.files.map((f) => path.posix.basename(f, '.md')).join('')), ['ab', 'c', 'd', 'e']);
    // A folder stays one item, whatever it weighs.
    const folder = packItems([{ files: ['inbox/T/x.md', 'inbox/T/y.md'], folder: 'inbox/T' }], 10, () => 100);
    assert.deepEqual(folder, [{ files: ['inbox/T/x.md', 'inbox/T/y.md'], folders: ['inbox/T'] }]);
  });

  test('an archived original can be re-read when its bytes still match its name; a missing one is refused by name', () => {
    const vault = path.join(tmp, 'v');
    fs.mkdirSync(path.join(vault, '.raw', 'captured'), { recursive: true });
    const body = 'archived\n';
    const sum = createHash('sha256').update(body).digest('hex');
    fs.writeFileSync(path.join(vault, '.raw', 'captured', `${sum}.md`), body);
    fs.writeFileSync(path.join(vault, '.raw', 'captured', `${'0'.repeat(64)}.md`), body);
    assert.equal(sourceFileProblem(vault, `.raw/captured/${sum}.md`), undefined);
    assert.match(sourceFileProblem(vault, `.raw/captured/${'0'.repeat(64)}.md`)!, /no longer match/);
    assert.match(sourceFileProblem(vault, `.raw/captured/${'1'.repeat(64)}.md`)!, /not in the archive/);
    assert.match(sourceFileProblem(vault, '.raw/captured/notes.md')!, /not an archived source/);
    assert.match(sourceFileProblem(vault, 'inbox/gone.md')!, /not in inbox/);
  });

  test('--job expansion: a batch\'s files minus note manifests, each folder one item', () => {
    const job = finishedJob('/v', ['inbox/a.md', 'inbox/a.distill.json', 'inbox/T/x.md', 'inbox/b.md', 'inbox/T/y.md'], ['inbox/T']);
    const { items, skipped } = jobSourceItems(job);
    assert.deepEqual(items, [{ files: ['inbox/a.md'] }, { files: ['inbox/T/x.md', 'inbox/T/y.md'], folder: 'inbox/T' }, { files: ['inbox/b.md'] }]);
    assert.deepEqual(skipped.map((s) => s.path), ['inbox/a.distill.json']);
  });

  test('a path must be a regular file inside inbox/', () => {
    const vault = path.join(tmp, 'v');
    fs.mkdirSync(path.join(vault, 'inbox', 'dir'), { recursive: true });
    fs.writeFileSync(path.join(vault, 'inbox', 'a.md'), 'x');
    fs.writeFileSync(path.join(vault, 'outside.md'), 'x');
    fs.symlinkSync(path.join(vault, 'outside.md'), path.join(vault, 'inbox', 'link.md'));
    assert.equal(inboxFileProblem(vault, 'inbox/a.md'), undefined);
    assert.match(inboxFileProblem(vault, 'inbox/gone.md')!, /not in inbox/);
    assert.match(inboxFileProblem(vault, 'inbox/../outside.md')!, /inside inbox/);
    assert.match(inboxFileProblem(vault, 'wiki/a.md')!, /inside inbox/);
    assert.match(inboxFileProblem(vault, 'inbox/dir')!, /not a file/);
    assert.match(inboxFileProblem(vault, 'inbox/link.md')!, /symbolic link/);
  });

  test('sizes leave embedded base64 images out; long lines are counted', () => {
    const f = path.join(tmp, 'n.md');
    fs.writeFileSync(f, `# Note\nhello\n${'x'.repeat(2100)}\n[image1]: <data:image/png;base64,${'A'.repeat(5000)}>\n`);
    const s = sourceSize(f)!;
    assert.equal(s.lines, 4);
    assert.equal(s.imageLines, 1);
    assert.equal(s.longLines, 1);
    assert.equal(s.textBytes, '# Note\n'.length + 'hello\n'.length + 2101);
  });

  test('existing source pages come from the ledger and from source_path; their labels are kept', () => {
    const vault = path.join(tmp, 'v');
    fs.mkdirSync(path.join(vault, 'wiki', 'meta', 'ledgers'), { recursive: true });
    fs.mkdirSync(path.join(vault, 'wiki', 'sources'), { recursive: true });
    fs.writeFileSync(
      path.join(vault, 'wiki', 'meta', 'ledgers', 'source-ledger.json'),
      JSON.stringify({ sources: { s1: { origin: { kind: 'file', locator: 'inbox/a.md' }, pages: ['wiki/sources/A.md', 'wiki/entities/X.md'] } } }),
    );
    fs.writeFileSync(path.join(vault, 'wiki', 'sources', 'A.md'), '---\ntype: source\ntags:\n  - Telus\n  - standup\nlabels_by: user\n---\n# A\n');
    fs.writeFileSync(path.join(vault, 'wiki', 'sources', 'B.md'), '---\ntype: source\nsource_path: inbox/b.md\ntags: [x]\nlabels_by: ai\nlabels_reviewed: false\nlabels_origin: queue-folder\n---\n# B\n');
    const found = existingSourcePages(vault, ['inbox/a.md', 'inbox/b.md', 'inbox/c.md']);
    assert.deepEqual(found.get('inbox/a.md'), { pages: ['wiki/sources/A.md'], labels: { file: 'inbox/a.md', labels: ['Telus', 'standup'], by: 'user' } });
    assert.deepEqual(found.get('inbox/b.md'), { pages: ['wiki/sources/B.md'], labels: { file: 'inbox/b.md', labels: ['x'], by: 'ai', origin: 'queue-folder' } });
    assert.equal(found.has('inbox/c.md'), false);
  });

  test('the reread marker survives jobs.json', () => {
    const job = finishedJob('/v', ['inbox/a.md']);
    job.reread = { id: 'reread-1', group: 2, groups: 8, fromJob: 'job-x', instruction: 'Mind the action items.' };
    assert.deepEqual(decodeJob(JSON.parse(JSON.stringify(encodeJob(job))), new Date())?.reread, job.reread);
  });
});

describe('re-read: the prompt', () => {
  test('every ingest prompt asks for a full read, one file at a time', () => {
    const job = newJob({ id: 'job-1', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md'], model: 'm', now: new Date() });
    const settings = { productRoot: '/p', pythonPath: '/usr/bin/python3', extraAllowedTools: [] } as never;
    const prompt = IngestJobKind.initialPrompt(new JobContext(job, { path: '/v', queueDirectory: '/q' }, settings));
    assert.ok(prompt.includes(FULL_READ_PROMPT));
    assert.ok(prompt.includes('the source budget is the full size of these files'));
    assert.ok(prompt.includes("the skill's default existing-page budget"));
    assert.ok(!prompt.includes('default existing-page budget from the skill'));
    assert.ok(!prompt.includes('RE-READ'));
    assert.match(prompt, /Process the files one at a time, in order/);
    assert.match(prompt, /never to\s+save effort/);
    assert.match(prompt, /read sources only with the\s+Read tool \(not `cat`/);
    assert.match(prompt, /image attachments, not\s+text: skip them/);
    assert.match(prompt, /a Discussion section per topic/);
  });

  test('a re-read adds: ingested before, read completely, update the existing page, no duplicates, keep labels', () => {
    const job = newJob({ id: 'job-1', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md', 'inbox/b.md'], model: 'm', now: new Date() });
    job.reread = { id: 'reread-1', group: 2, groups: 8, fromJob: 'job-20261004-233313-0018', instruction: 'Keep action items.' };
    const settings = { productRoot: '/p', pythonPath: '/usr/bin/python3', extraAllowedTools: [] } as never;
    const facts = {
      sources: [
        { file: 'inbox/a.md', bytes: 140_000, lines: 900, textBytes: 120_000, imageLines: 2, longLines: 0, pages: ['wiki/sources/2026-09-29 Telus Daily Stand-up.md'] },
        { file: 'inbox/b.md', bytes: 2_000, lines: 40, textBytes: 2_000, imageLines: 0, longLines: 0, pages: [] },
      ],
    };
    const labels = [{ file: 'inbox/a.md', labels: ['Telus'], by: 'user' as const }];
    const prompt = IngestJobKind.initialPrompt(new JobContext(job, { path: '/v', queueDirectory: '/q' }, settings, labels, facts));
    assert.ok(prompt.includes(FULL_READ_PROMPT));
    assert.match(prompt, /RE-READ \(group 2 of 8 of the sources of batch job-20261004-233313-0018\)/);
    assert.match(prompt, /ingested before, but only partly read/);
    assert.match(prompt, /119 KB of\s+text in all/);
    assert.match(prompt, /Update the EXISTING source page for each input; do not create a second source page/);
    assert.match(prompt, /source-ledger\.json, by `origin\.locator`/);
    assert.match(prompt, /`source_path`/);
    assert.match(prompt, /entity and concept pages, and the source and claim ledgers/);
    assert.match(prompt, /- inbox\/a\.md \(900 lines, 117 KB of text; 2 embedded base64 image line\(s\)[^)]*\): update wiki\/sources\/2026-09-29 Telus Daily Stand-up\.md/);
    assert.match(prompt, /- inbox\/b\.md \(40 lines, 2 KB of text\): no source page found by the core/);
    assert.match(prompt, /Keep the labels already on those source pages/);
    assert.match(prompt, /- inbox\/a\.md: labels the user confirmed:\n {4}tags:\n {6}- Telus\n {4}labels_by: user/);
    assert.match(prompt, /The user added this for the re-read \(from the user, not from a source\):\nKeep action items\./);
    assert.match(prompt, /existing-page budget raised as far as updating these sources' pages needs/);
    assert.match(prompt, /Mark a page partial only if a file truly cannot be read/);
  });
});

describe('re-read: long lines', () => {
  test('a long line is split in the reading copy, never named as skipped', () => {
    const job = newJob({ id: 'job-1', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md'], model: 'm', now: new Date() });
    job.reread = { id: 'reread-1', group: 1, groups: 1 };
    const settings = { productRoot: '/p', pythonPath: '/usr/bin/python3', extraAllowedTools: [] } as never;
    const facts = { sources: [{ file: 'inbox/a.md', bytes: 9000, lines: 10, textBytes: 9000, imageLines: 0, longLines: 2, pages: [] }] };
    const prompt = IngestJobKind.initialPrompt(new JobContext(job, { path: '/v', queueDirectory: '/q' }, settings, [], facts));
    assert.match(prompt, /2 text line\(s\) over 1,900 characters, split in its reading copy/);
    assert.doesNotMatch(prompt, /name them in .?skipped/);
  });
});

describe('re-read: batches in sequence', () => {
  test('7 files in groups of 3: one batch at a time, each its own job and fresh session, files read in place', async () => {
    const h = setup();
    const files = writeInbox(h.vault, ['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md', 'g.md']);
    const source = finishedJob(h.vault, [...files, 'inbox/a.distill.json']);
    fs.writeFileSync(path.join(h.vault, 'inbox', 'a.distill.json'), '{}');
    fs.writeFileSync(path.join(h.state, 'jobs.json'), JSON.stringify([encodeJob(source)]));
    // Re-create the engine so it loads the finished batch.
    await h.engine.stop();
    const h2 = setup();
    const inboxBefore = snapshot(path.join(h2.vault, 'inbox'));
    const queueBefore = snapshot(h2.queue);

    const res = await h2.engine.rereadSources!({ jobId: source.id, perBatch: 3 });
    assert.equal(res.groups.length, 3);
    assert.deepEqual(res.groups.map((g) => g.files.length), [3, 3, 1]);
    assert.deepEqual(res.skipped?.map((s) => s.path), ['inbox/a.distill.json']);
    assert.equal(res.started.length, 1, 'one batch starts now');
    assert.equal(res.waiting, 2);
    assert.equal(res.fromJob, source.id);
    assert.equal(res.started[0]!.state, 'running');
    assert.deepEqual(res.started[0]!.reread, { id: res.id, group: 1, groups: 3, fromJob: source.id });
    assert.ok(fs.existsSync(path.join(h2.state, 'reread.json')), 'waiting groups survive a restart');

    // The vault is busy: a second re-read or a queue batch waits.
    const blocked = await h2.engine.processQueue({ force: true });
    assert.equal(blocked, null);

    await h2.engine.whenIdle();
    const rereads = h2.engine.listJobs().filter((j) => j.reread).reverse();
    assert.equal(rereads.length, 3, 'each group became its own batch');
    assert.equal(h2.runner.maxRunning, 1, 'never two at once on the vault');
    assert.deepEqual(rereads.map((j) => j.reread!.group), [1, 2, 3]);
    assert.deepEqual(rereads.map((j) => j.files), res.groups.map((g) => g.files));
    assert.ok(rereads.every((j) => j.state === 'awaitingApproval'), 'all wait in Review; the next started when the one before was ready');
    const sessions = h2.runner.requests.map((r) => ('start' in r.session ? r.session.start : 'resume'));
    assert.equal(new Set(sessions).size, 3, 'a fresh session for each batch');
    assert.deepEqual(sessions, rereads.map((j) => j.sessionID));
    // Order: batch N+1 was created only after batch N left running.
    for (let i = 1; i < rereads.length; i++) {
      const readyAt = h2.events.findIndex((e) => e.type === 'job' && e.job.id === rereads[i - 1]!.id && e.job.state === 'awaitingApproval');
      const createdAt = h2.events.findIndex((e) => e.type === 'job' && e.job.id === rereads[i]!.id);
      assert.ok(readyAt >= 0 && createdAt > readyAt, `group ${i + 1} started after group ${i} was ready`);
    }
    for (const r of h2.runner.requests) assert.match(r.prompt, /RE-READ \(group \d of 3/);
    assert.ok(h2.runner.requests.every((r) => typeof r.onStep === 'function'), 'ingest turns always stream, so the reads are on record');
    assert.equal(fs.existsSync(path.join(h2.state, 'reread.json')), false, 'nothing left waiting');

    // Approve them all (apply turns): still nothing in inbox/ or the queue changes.
    for (const j of rereads) {
      await h2.engine.approve(j.id);
      await h2.engine.whenIdle();
    }
    assert.ok(h2.engine.listJobs().filter((j) => j.reread).every((j) => j.state === 'completed'));
    assert.deepEqual(snapshot(path.join(h2.vault, 'inbox')), inboxBefore, 'nothing written, moved or touched in inbox/');
    assert.deepEqual(snapshot(h2.queue), queueBefore);
  });

  test('files given directly, perBatch 2; a missing file is refused with its name', async () => {
    const h = setup();
    const files = writeInbox(h.vault, ['a.md', 'b.md', 'c.md']);
    await assert.rejects(h.engine.rereadSources!({ files: [...files, 'inbox/gone.md'] }), (err: Error) => /inbox\/gone\.md: not in inbox/.test(err.message));
    await assert.rejects(h.engine.rereadSources!({ files: ['wiki/x.md'] }), /inside inbox/);
    await assert.rejects(h.engine.rereadSources!({ files, perBatch: 0 }), /perBatch/);
    await assert.rejects(h.engine.rereadSources!({}), /either files/);
    assert.equal(h.engine.listJobs().length, 0);
    const res = await h.engine.rereadSources!({ files, perBatch: 2, instruction: 'Note who owns each action.' });
    assert.deepEqual(res.groups.map((g) => g.files), [['inbox/a.md', 'inbox/b.md'], ['inbox/c.md']]);
    await h.engine.whenIdle();
    assert.equal(h.runner.requests.length, 2);
    assert.match(h.runner.requests[1]!.prompt, /Note who owns each action\./);
  });

  test('by default the groups are packed by tokens: the result says the budget', async () => {
    const h = setup();
    const files = writeInbox(h.vault, ['a.md', 'b.md', 'c.md', 'd.md']);
    const res = await h.engine.rereadSources!({ files });
    assert.equal(res.perBatch, 0);
    assert.ok((res.tokenBudget ?? 0) >= 10_000, 'a token budget');
    assert.deepEqual(res.groups.map((g) => g.files), [files], 'four small notes fit in one batch');
    await h.engine.whenIdle();
    await assert.rejects(h.engine.rereadSources!({ files, tokenBudget: 10 }), /at least 1000/);
    const sized = await h.engine.rereadSources!({ files, tokenBudget: 1000 });
    assert.equal(sized.tokenBudget, 1000);
    assert.equal(sized.groups.length, 1, 'small notes still fit');
    await h.engine.whenIdle();
  });

  test('a batch still in Review is not a source; a running re-read keeps the next group waiting', async () => {
    const h = setup();
    const files = writeInbox(h.vault, ['a.md', 'b.md']);
    const first = await h.engine.rereadSources!({ files, perBatch: 1 });
    // The first group's job is running: the second waits.
    assert.equal(first.started.length, 1);
    assert.equal(first.waiting, 1);
    await assert.rejects(h.engine.rereadSources!({ jobId: first.started[0]!.id }), /still running/);
    await h.engine.whenIdle();
  });

  test('cancelling a re-read batch drops its groups not started', async () => {
    const h = setup();
    const files = writeInbox(h.vault, ['a.md', 'b.md', 'c.md']);
    const res = await h.engine.rereadSources!({ files, perBatch: 1 });
    await h.engine.cancel(res.started[0]!.id);
    await h.engine.whenIdle();
    const rereads = h.engine.listJobs().filter((j) => j.reread);
    assert.equal(rereads.length, 1, 'no other group started');
    assert.equal(fs.existsSync(path.join(h.state, 'reread.json')), false);
  });

  test('a file cleaned up before its group starts fails that batch by name; the next group still runs', async () => {
    const h = setup();
    const files = writeInbox(h.vault, ['a.md', 'b.md', 'c.md']);
    const res = await h.engine.rereadSources!({ files, perBatch: 1 });
    fs.rmSync(path.join(h.vault, 'inbox', 'b.md'));
    await h.engine.whenIdle();
    const rereads = h.engine.listJobs().filter((j) => j.reread).reverse();
    assert.equal(rereads.length, 3);
    assert.equal(rereads[0]!.id, res.started[0]!.id);
    assert.equal(rereads[1]!.state, 'failed');
    assert.match(rereads[1]!.error ?? '', /inbox\/b\.md is not in inbox/);
    assert.equal(rereads[2]!.state, 'awaitingApproval');
  });
});

describe('re-read: activity and live log', () => {
  test('batch.started carries the reread marker; the live log says the files are read in place', () => {
    const dir = path.join(tmp, 'logs');
    const log = new ActivityLog({ dir: path.join(dir, 'activity') });
    const logEvent = createEventLogger({ log, getSettings: () => ({ askPreferences: { historyDays: 10 } }) as never, collectorName: () => undefined }, []);
    const job = newJob({ id: 'job-r', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md', 'inbox/b.md'], model: 'sonnet', now: new Date() });
    job.reread = { id: 'reread-1', group: 1, groups: 8, fromJob: 'job-x' };
    logEvent({ type: 'job', job });
    const entry = log.list().entries[0]!;
    assert.equal(entry.type, 'batch.started');
    assert.equal(entry.details?.reread, true);
    assert.equal(entry.details?.rereadID, 'reread-1');
    assert.equal(entry.details?.rereadGroup, 1);
    assert.equal(entry.details?.rereadGroups, 8);
    assert.equal(entry.details?.fromJob, 'job-x');
    assert.match(entry.summary, /re-read 1 of 8/);

    const steps = createStepLog({ dir: path.join(dir, 'steps'), emit: () => {}, getJob: () => job });
    steps.onEvent({ type: 'job', job });
    const first = steps.list(job.id).steps[0]!;
    assert.equal(first.verb, 'reread');
    assert.equal(first.text, 'Re-reading 2 files already in your inbox (group 1 of 8)');
  });
});
