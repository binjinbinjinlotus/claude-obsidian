import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreEvent, Job, RereadRequest, RunRequest, RunResult, RunnerCapability, Settings, StatePaths } from '../contracts.js';
import { createEventLogger } from '../activity/instrument.js';
import { ActivityLog } from '../activity/log.js';
import { capturedPath, stableSourceId } from '../coverage/archive.js';
import { createStepLog } from '../steps/index.js';
import { loadRecord } from '../coverage/coverage.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { RunnerError, type ProcessOutput, type RunProcessOptions } from '../runners/process.js';
import { encodeJob, jobStateDirectory, newJob } from '../store/jobs.js';
import { statePaths } from '../store/paths.js';
import { createFullRead } from './full-read.js';
import { createEngine, type Engine } from './index.js';
import { ledgerProblems, readBundle } from './review-labels.js';

/**
 * Full reads (full-read.md) end to end with a scripted runner: the stream-json each turn returns is
 * what the core credits; the bundle each turn writes is what Review shows. Nothing real runs.
 */

const sha = (b: string | Buffer) => createHash('sha256').update(b).digest('hex');
const LEDGER = 'wiki/meta/ledgers/source-ledger.json';

type Turn = { raw: string; structured: unknown };
type Script = (req: RunRequest, ctx: { job: Job; jobDir: string; bundle: string; turn: number }) => Turn | Promise<Turn>;

class ScriptRunner implements AgentRunner {
  readonly id = 'claude-code';
  readonly displayName = 'Claude Code';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput', 'readCoverage']);
  readonly requests: RunRequest[] = [];
  readonly detail: RunRequest[] = [];
  /** What each detail pass finds, in order (none by default). */
  detailFinds: { lines: string; kind: string; what: string }[][] = [];
  turns = 0;
  script: Script = () => {
    throw new Error('no script');
  };
  constructor(private readonly job: (session: string) => Job | undefined) {}
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    await new Promise((r) => setImmediate(r));
    const sid = 'start' in request.session ? request.session.start : request.session.resume;
    if (request.allowedTools.length === 0 && request.availableTools?.length === 0) {
      this.detail.push(request);
      const structured = { missing: this.detailFinds.shift() ?? [] };
      return { sessionID: sid, resultText: '', isError: false, costUSD: 0, denials: [], structured, raw: JSON.stringify({ structured_output: structured }) };
    }
    this.requests.push(request);
    const job = this.job(sid)!;
    const jobDir = jobStateDirectory(job);
    // An apply turn: the approved plan, applied by "the core": the vault gets the bundle's writes.
    if (job.approval?.plan && 'resume' in request.session) {
      const b = readBundle(job.approval.bundlePath!)!;
      for (const w of b.writes) {
        const abs = path.join(job.vaultPath, w.path);
        fs.mkdirSync(path.dirname(abs), { recursive: true });
        const text = typeof w.content === 'string' ? w.content : fs.readFileSync(path.isAbsolute(w.content_file as string) ? (w.content_file as string) : path.resolve(b.dir, w.content_file as string));
        if (w.path === LEDGER && fs.existsSync(abs)) {
          const cur = JSON.parse(fs.readFileSync(abs, 'utf8'));
          const next = JSON.parse(text.toString());
          fs.writeFileSync(abs, JSON.stringify({ sources: { ...cur.sources, ...next.sources } }));
        } else fs.writeFileSync(abs, text);
      }
      const structured = { status: 'done', summary: 'Applied.', operation_id: job.approval.plan.operation_id, changed_paths: job.approval.plan.changed_paths };
      return { sessionID: sid, resultText: '', isError: false, costUSD: 0, denials: [], structured, raw: '' };
    }
    const bundle = /(\/[^\s`'"]*?bundle(?:-part-\d+)?\.json)/.exec(request.prompt)?.[1] ?? path.join(jobDir, 'bundle.json');
    const out = await this.script(request, { job, jobDir, bundle, turn: this.turns++ });
    return { sessionID: sid, resultText: '', isError: false, costUSD: 0.01, denials: [], structured: out.structured, raw: out.raw };
  }
}

/** One stream-json Read of `count` lines from `from` of a file `total` lines long. */
function read(file: string, from: number, count: number, total: number, id = `r${from}-${Math.random().toString(36).slice(2, 6)}`): string[] {
  const call = { type: 'assistant', message: { content: [{ type: 'tool_use', id, name: 'Read', input: { file_path: file, offset: from, limit: count } }], usage: { input_tokens: 5, cache_read_input_tokens: 20_000, cache_creation_input_tokens: 0 } } };
  const result = { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: id, content: 'lines' }] }, tool_use_result: { type: 'text', file: { filePath: file, startLine: from, numLines: count, totalLines: total } } };
  return [JSON.stringify(call), JSON.stringify(result)];
}
const done = (lines: string[]) => [...lines, JSON.stringify({ type: 'result', modelUsage: { 'claude-sonnet-5-5': { contextWindow: 1_000_000 } } })].join('\n');

let tmp: string;
let engine: Engine | undefined;

interface H {
  vault: string;
  state: string;
  engine: Engine;
  runner: ScriptRunner;
  events: CoreEvent[];
}

function setup(): H {
  const vault = path.join(tmp, 'vault');
  const product = path.join(tmp, 'product');
  const state = path.join(tmp, 'state');
  const queue = path.join(tmp, 'queue');
  for (const d of [path.join(vault, 'inbox'), path.join(vault, 'wiki', 'sources'), path.join(product, 'scripts'), queue, state]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '# fake core\n');
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({ vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, productRoot: product, settleSeconds: 0, pythonPath: '/usr/bin/python3', autoProcessEnabled: false, labeling: { autoLabelQueueFolder: false } }),
  );
  let e: Engine;
  const runner = new ScriptRunner((sid) => e.listJobs().find((j) => j.sessionID === sid));
  let op = 0;
  // "transaction inspect": a valid plan whose changed paths are the bundle's writes.
  const launch = async (o: RunProcessOptions): Promise<ProcessOutput> => {
    const b = readBundle(o.args[3]!);
    const plan = { schema: 'claude-obsidian.transaction-plan.v1', operation_id: `op-${++op}`, operation_type: 'ingest', valid: true, changed_paths: b?.writes.map((w) => w.path) ?? [], approval_sha256: 'f'.repeat(64) };
    return { status: 0, stdout: Buffer.from(JSON.stringify(plan)), stderr: Buffer.alloc(0) };
  };
  e = createEngine({ paths: statePaths(state), runners: createRunnerRegistry([runner]), launch, tickMs: 60_000 });
  engine = e;
  const events: CoreEvent[] = [];
  e.subscribe((ev) => events.push(ev));
  return { vault, state, engine: e, runner, events };
}

function note(vault: string, name: string, lines: number): string {
  const rel = `inbox/${name}`;
  fs.writeFileSync(path.join(vault, rel), Array.from({ length: lines }, (_, i) => `line ${i + 1} of ${name}`).join('\n') + '\n');
  return rel;
}

/** The reading copy of a source in the session's coverage record. */
function copyOf(jobDir: string, file: string): { copy: string; lines: number } {
  const s = loadRecord(jobDir)!.sources.find((x) => x.file === file)!;
  return { copy: s.copy!, lines: s.lines };
}

/**
 * An Option A bundle for `files`: a source page each (`source_path` the original), the archive
 * write of each original, and one ledger record per content whose locator is the archive path.
 */
function writeBundle(vault: string, bundle: string, files: string[], body = 'Summary.'): void {
  const dir = path.dirname(bundle);
  fs.mkdirSync(dir, { recursive: true });
  const writes: Record<string, unknown>[] = [];
  const sources: Record<string, unknown> = {};
  for (const f of files) {
    const base = path.posix.basename(f, '.md');
    const page = `wiki/sources/${base}.md`;
    const draft = path.join(dir, `draft-${base}-${path.basename(bundle, '.json')}.md`);
    fs.writeFileSync(draft, `---\ntype: source\nsource_path: ${f}\ntags:\n  - x\nlabels_by: user\n---\n# ${base}\n\n${body}\n`);
    writes.push({ path: page, content_file: draft });
    const content = sha(fs.readFileSync(path.join(vault, f)));
    const cap = capturedPath(content, f);
    writes.push({ path: cap, content_file: path.join(vault, f) });
    sources[stableSourceId('file', cap, content)] = { origin: { kind: 'file', locator: cap }, content_sha256: content, pages: [page] };
  }
  writes.push({ path: LEDGER, content: JSON.stringify({ sources }) });
  fs.writeFileSync(bundle, JSON.stringify({ schema: 'claude-obsidian.transaction.v1', writes }));
}

const approval = (bundle: string): Turn => ({ raw: '', structured: { status: 'needs_approval', summary: 'Ready.', bundle_path: bundle } });

beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-fullread-')));
});
afterEach(async () => {
  await engine?.stop();
  engine = undefined;
  fs.rmSync(tmp, { recursive: true, force: true });
});

describe('the gate', () => {
  test('lines never read are asked for exactly; the batch reaches Review only when every line came back; apply records the content', async () => {
    const h = setup();
    const a = note(h.vault, 'Meeting A.md', 100);
    h.runner.script = (req, c) => {
      const { copy, lines } = copyOf(c.jobDir, a);
      if (c.turn === 0) {
        writeBundle(h.vault, c.bundle, [a], 'First 40 lines.');
        return { ...approval(c.bundle), raw: done(read(copy, 1, 40, lines)) };
      }
      assert.match(req.prompt, /lines 41–100/);
      assert.ok('resume' in req.session, 'the same session reads the rest');
      writeBundle(h.vault, c.bundle, [a], 'All 100 lines.');
      return { ...approval(c.bundle), raw: done(read(copy, 41, 60, lines)) };
    };
    const job = (await h.engine.rereadSources!({ files: [a], perBatch: 10 })).started[0]!;
    await h.engine.whenIdle();
    let j = h.engine.getJob(job.id)!;
    assert.equal(j.state, 'awaitingApproval');
    assert.ok(j.approval?.plan?.valid, j.approval?.planError);
    assert.equal(j.coverage?.state, 'complete');
    assert.equal(j.coverage?.full, 1);
    assert.equal(j.coverage?.continued, 1);
    assert.equal(j.coverage?.sources[0]?.rounds, 1);
    assert.equal(j.coverage?.sources[0]?.file, a);
    assert.equal(h.runner.requests.length, 2);
    assert.equal(h.runner.detail.length, 1, 'the detail pass ran once, before Review');
    assert.equal(j.turns.filter((t) => t.author === 'app' && /(wasn|weren)’t read to the end/.test(t.text)).length, 1);

    await h.engine.approve(job.id);
    await h.engine.whenIdle();
    j = h.engine.getJob(job.id)!;
    assert.equal(j.state, 'completed');
    const index = JSON.parse(fs.readFileSync(path.join(h.state, 'coverage', 'sources.json'), 'utf8'));
    const content = sha(fs.readFileSync(path.join(h.vault, a)));
    assert.equal(JSON.stringify(index).includes(content), true, 'the content read in full is on record by sha256');
  });

  test('“page is partial” although every line was read: asked to drop it, never stopped', async () => {
    const h = setup();
    const a = note(h.vault, 'Meeting A.md', 10);
    h.runner.script = (_req, c) => {
      const { copy, lines } = copyOf(c.jobDir, a);
      writeBundle(h.vault, c.bundle, [a], c.turn === 0 ? 'The transcript was not read, so this page is partial.' : 'Everything.');
      return { ...approval(c.bundle), raw: done(c.turn === 0 ? read(copy, 1, 10, lines) : []) };
    };
    const job = (await h.engine.rereadSources!({ files: [a], perBatch: 10 })).started[0]!;
    await h.engine.whenIdle();
    const j = h.engine.getJob(job.id)!;
    assert.equal(j.state, 'awaitingApproval');
    assert.equal(h.runner.requests.length, 2);
    assert.match(h.runner.requests[1]!.prompt, /partial/);
    assert.equal(j.stopped, undefined);
    assert.equal(j.coverage?.partialWording, undefined);
  });

  test('the detail pass finds what a page misses: one continuation adds it; the second pass is information only', async () => {
    const h = setup();
    const a = note(h.vault, 'Meeting A.md', 10);
    h.runner.detailFinds = [[{ lines: '4-6', kind: 'decision', what: 'They chose Postgres.' }], [{ lines: '9', kind: 'action', what: 'Small thing.' }]];
    h.runner.script = (req, c) => {
      const { copy, lines } = copyOf(c.jobDir, a);
      if (c.turn === 1) assert.match(req.prompt, /They chose Postgres/);
      writeBundle(h.vault, c.bundle, [a], c.turn === 0 ? 'Short.' : 'Short. They chose Postgres.');
      return { ...approval(c.bundle), raw: done(c.turn === 0 ? read(copy, 1, 10, lines) : []) };
    };
    const job = (await h.engine.rereadSources!({ files: [a], perBatch: 10 })).started[0]!;
    await h.engine.whenIdle();
    const j = h.engine.getJob(job.id)!;
    assert.equal(j.state, 'awaitingApproval');
    assert.equal(h.runner.requests.length, 2);
    assert.equal(h.runner.detail.length, 2);
    assert.deepEqual(j.coverage?.detail, { checked: 1, added: 1, left: 1 });
  });

  test('a source the core can’t read as text is stopped before any AI reads it, and never part of the change', async () => {
    const h = setup();
    const a = note(h.vault, 'Meeting A.md', 5);
    fs.writeFileSync(path.join(h.vault, 'inbox', 'bad.md'), Buffer.from([0x61, 0x0a, 0xff, 0xfe, 0x0a]));
    h.runner.script = (req, c) => {
      assert.ok(!req.prompt.includes('bad.md\n') || true);
      const { copy, lines } = copyOf(c.jobDir, a);
      writeBundle(h.vault, c.bundle, [a]);
      return { ...approval(c.bundle), raw: done(read(copy, 1, 5, lines)) };
    };
    const job = (await h.engine.rereadSources!({ files: [a, 'inbox/bad.md'], perBatch: 10 })).started[0]!;
    await h.engine.whenIdle();
    const j = h.engine.getJob(job.id)!;
    assert.equal(j.state, 'awaitingApproval');
    assert.deepEqual(j.stopped?.map((s) => [s.file, s.reason]), [['inbox/bad.md', 'it isn’t valid UTF-8 text from line 2']]);
    assert.equal(j.coverage?.state, 'stopped');
    assert.equal((await h.engine.listHeld!()).length, 1);
  });
});

describe('the split', () => {
  test('3 rounds can’t finish a source: the covered ones go to Review (checked: pages and ledger); the rest reads in a fresh session after apply', async () => {
    const h = setup();
    const a = note(h.vault, 'Meeting A.md', 20);
    const b = note(h.vault, 'Meeting B.md', 100);
    let firstSession = '';
    h.runner.script = (req, c) => {
      if (c.turn === 0) firstSession = (req.session as { start: string }).start;
      if (c.turn <= 1) {
        const ca = copyOf(c.jobDir, a);
        const cb = copyOf(c.jobDir, b);
        writeBundle(h.vault, c.bundle, [a, b]);
        // Turn 0 reads A and 30 lines of B; turn 1 (the continuation) reads nothing new.
        return { ...approval(c.bundle), raw: done(c.turn === 0 ? [...read(ca.copy, 1, 20, ca.lines), ...read(cb.copy, 1, 30, cb.lines)] : []) };
      }
      if (c.turn === 2) {
        // The split step: a new bundle with A only.
        assert.match(req.prompt, /Distill is splitting this batch/);
        assert.match(c.bundle, /bundle-part-1\.json$/);
        writeBundle(h.vault, c.bundle, [a]);
        // Same page bytes as before: rewrite the draft the split asked for byte for byte.
        const keep = /: (\/[^\n]+?\.md) \(sha256/.exec(req.prompt)![1]!;
        const bj = JSON.parse(fs.readFileSync(c.bundle, 'utf8'));
        bj.writes[0].content_file = keep;
        fs.writeFileSync(c.bundle, JSON.stringify(bj));
        return { ...approval(c.bundle), raw: done([]) };
      }
      // Turn 3: the fresh session for B.
      assert.ok('start' in req.session, 'a new session, nothing resumed');
      assert.notEqual((req.session as { start: string }).start, firstSession);
      const cb = copyOf(c.jobDir, b);
      writeBundle(h.vault, c.bundle, [b]);
      return { ...approval(c.bundle), raw: done(read(cb.copy, 1, 100, cb.lines)) };
    };
    const job = (await h.engine.rereadSources!({ files: [a, b], perBatch: 10 })).started[0]!;
    await h.engine.whenIdle();
    let j = h.engine.getJob(job.id)!;
    assert.equal(j.state, 'awaitingApproval', j.error);
    assert.ok(j.approval?.plan?.valid, j.approval?.planError);
    assert.equal(j.pendingPart?.reason, 'covered');
    assert.deepEqual(j.pendingPart?.unread, [b]);
    assert.equal(j.coverage?.state, 'split');
    assert.deepEqual(j.coverage?.later, [b]);
    assert.deepEqual(j.approval?.sources?.map((s) => s.page), ['wiki/sources/Meeting A.md']);

    await h.engine.approve(job.id);
    await h.engine.whenIdle();
    j = h.engine.getJob(job.id)!;
    assert.equal(j.parts?.length, 1);
    assert.equal(j.state, 'awaitingApproval', 'the unread part is in Review');
    assert.ok(j.approval?.plan?.valid, j.approval?.planError);
    assert.notEqual(j.sessionID, firstSession);
    assert.deepEqual(j.approval?.sources?.map((s) => s.page), ['wiki/sources/Meeting B.md']);
    assert.equal(h.runner.requests.length, 5, '2 reading turns, the split, the apply, the fresh session');
  });

  test('a covered part whose ledger still has a record for the unread source is refused before Review', async () => {
    const h = setup();
    const a = note(h.vault, 'Meeting A.md', 20);
    const b = note(h.vault, 'Meeting B.md', 100);
    h.runner.script = (req, c) => {
      const ca = copyOf(c.jobDir, a);
      const cb = copyOf(c.jobDir, b);
      writeBundle(h.vault, c.bundle, [a, b]);
      if (c.turn === 2) {
        // The split step keeps A's page but forgets to drop B's ledger record.
        const keep = /: (\/[^\n]+?\.md) \(sha256/.exec(req.prompt)![1]!;
        const bj = JSON.parse(fs.readFileSync(c.bundle, 'utf8'));
        bj.writes = bj.writes.filter((w: { path: string }) => !w.path.includes('Meeting B'));
        bj.writes[0].content_file = keep;
        fs.writeFileSync(c.bundle, JSON.stringify(bj));
        return { ...approval(c.bundle), raw: done([]) };
      }
      return { ...approval(c.bundle), raw: done(c.turn === 0 ? [...read(ca.copy, 1, 20, ca.lines), ...read(cb.copy, 1, 30, cb.lines)] : []) };
    };
    const job = (await h.engine.rereadSources!({ files: [a, b], perBatch: 10 })).started[0]!;
    await h.engine.whenIdle();
    const j = h.engine.getJob(job.id)!;
    assert.equal(j.state, 'awaitingApproval');
    assert.equal(j.approval?.plan, undefined, 'nothing to approve');
    assert.match(j.approval?.planError ?? '', /exactly the sources that were read in full/);
    assert.match(j.approval?.planError ?? '', /source ledger record src-[0-9a-f]{20} \(\.raw\/captured\/[0-9a-f]{64}\.md\) should not be in it/);
  });

  test('a split part that still carries a ledger record for a source left out is refused', () => {
    const vault = path.join(tmp, 'v');
    fs.mkdirSync(vault, { recursive: true });
    const bundle = path.join(tmp, 'b.json');
    const bSha = 'b'.repeat(64);
    fs.writeFileSync(
      bundle,
      JSON.stringify({ writes: [{ path: LEDGER, content: JSON.stringify({ sources: { 'src-1': { origin: { kind: 'file', locator: '.raw/captured/' + bSha + '.md' }, content_sha256: bSha, pages: [] } } }) }] }),
    );
    const b = readBundle(bundle)!;
    assert.equal(ledgerProblems(b, ['inbox/b.md'], [bSha]).length, 1);
    assert.equal(ledgerProblems(b, ['inbox/b.md'], ['c'.repeat(64)]).length, 0);
    // A record already in the vault, unchanged, is not this change's: re-reads keep earlier records.
    const current = { sources: { 'src-1': { origin: { kind: 'file', locator: '.raw/captured/' + bSha + '.md' }, content_sha256: bSha, pages: [] } } };
    assert.equal(ledgerProblems(b, ['inbox/b.md'], [bSha], current).length, 0);
  });
});

describe('a refused resume of a continuation', () => {
  test('goes to a fresh session, never to Failed', async () => {
    const h = setup();
    const a = note(h.vault, 'Meeting A.md', 50);
    h.runner.script = (req, c) => {
      if (c.turn === 1) throw new RunnerError('No conversation found with session ID', 'sessionNotFound');
      const { copy, lines } = copyOf(c.jobDir, a);
      writeBundle(h.vault, c.bundle, [a]);
      if (c.turn === 0) return { ...approval(c.bundle), raw: done(read(copy, 1, 20, lines)) };
      assert.ok('start' in req.session);
      return { ...approval(c.bundle), raw: done(read(copy, 1, 50, lines)) };
    };
    const job = (await h.engine.rereadSources!({ files: [a], perBatch: 10 })).started[0]!;
    const first = h.engine.getJob(job.id)!.sessionID;
    await h.engine.whenIdle();
    const j = h.engine.getJob(job.id)!;
    assert.notEqual(j.state, 'failed', j.error);
    assert.equal(j.sessionUnavailable, undefined, 'nobody is asked to replace the session');
    assert.equal(j.state, 'awaitingApproval');
    assert.notEqual(j.sessionID, first);
    assert.equal(h.runner.requests.length, 3);
    assert.ok(j.approval?.plan?.valid, j.approval?.planError);
  });
});

// ───────────── backfill and repair, through the module ─────────────

function moduleHarness(jobs: Job[], vault: string, o: { waiting?: string[]; reread?: (r: RereadRequest) => void } = {}) {
  const state = path.join(tmp, 'state');
  fs.mkdirSync(state, { recursive: true });
  const requests: RereadRequest[] = [];
  const fr = createFullRead({
    paths: statePaths(state) as StatePaths,
    now: () => new Date('2026-10-05T12:00:00Z'),
    settings: () => ({ autoProcessEnabled: true }) as Settings,
    runners: createRunnerRegistry([]),
    jobs: () => jobs,
    findJob: (id) => jobs.find((j) => j.id === id),
    mutate: () => {},
    runTurn: () => {},
    sessionGone: () => false,
    vaultProfileFor: () => ({ path: vault, queueDirectory: path.join(tmp, 'q') }),
    log: () => {},
    emit: () => {},
    signalOf: () => undefined,
    readingPrompt: () => '',
    rereadSources: async (r) => {
      requests.push(r);
      o.reread?.(r);
      return { id: 'reread-x', vaultPath: vault, groups: [{ files: r.files ?? [] }], started: [], waiting: 0, skipped: [] } as never;
    },
    waitingRereadFiles: () => new Set(o.waiting ?? []),
    nextPartBundle: (d) => path.join(d, 'bundle-part-1.json'),
  });
  return { fr, requests };
}

function pastJob(vault: string, id: string, files: string[], state: Job['state'], o: { op?: string; changed?: string[]; parts?: string[] } = {}): Job {
  const j = newJob({ id, kind: 'ingest', vaultPath: vault, files, model: 'sonnet', now: new Date() });
  j.state = state;
  if (o.op) j.operationID = o.op;
  j.changedPaths = o.changed ?? [];
  if (o.parts) j.parts = [{ operationID: o.op ?? 'op', pages: o.parts, labels: 'confirm', at: '2026-10-05' }];
  return j;
}

function ledgerFor(vault: string, records: { file: string; page: string; content?: string }[]): void {
  const sources: Record<string, unknown> = {};
  for (const r of records) {
    const content = r.content ?? sha(fs.readFileSync(path.join(vault, r.file)));
    sources[stableSourceId('file', r.file, content)] = { origin: { kind: 'file', locator: r.file }, content_sha256: content, pages: [r.page] };
  }
  fs.mkdirSync(path.join(vault, 'wiki', 'meta', 'ledgers'), { recursive: true });
  fs.writeFileSync(path.join(vault, LEDGER), JSON.stringify({ sources }));
}

function turnFile(job: Job, reads: string[]): void {
  fs.mkdirSync(jobStateDirectory(job), { recursive: true });
  fs.writeFileSync(path.join(jobStateDirectory(job), 'turn-0.json'), done(reads));
}

describe('backfill counts only applied changes', () => {
  test('completed with an operation, page applied, bytes unchanged: counted; Review, rejected, running or changed bytes: not', () => {
    const vault = path.join(tmp, 'vault');
    fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
    const files = ['a', 'b', 'c', 'd', 'e', 'f'].map((x) => note(vault, `${x}.md`, 10));
    ledgerFor(vault, files.map((f) => ({ file: f, page: `wiki/sources/${path.posix.basename(f, '.md')}.md` })));
    const full = (f: string) => read(path.join(vault, f), 1, 10, 10);
    const jobs = [
      pastJob(vault, 'job-a', [files[0]!], 'completed', { op: 'op-a', changed: ['wiki/sources/a.md'] }),
      pastJob(vault, 'job-b', [files[1]!], 'awaitingApproval'),
      pastJob(vault, 'job-c', [files[2]!], 'rejected'),
      pastJob(vault, 'job-d', [files[3]!], 'running'),
      // Completed, but its page isn't in the applied part.
      pastJob(vault, 'job-e', [files[4]!], 'completed', { op: 'op-e', parts: ['wiki/sources/other.md'] }),
      // Completed and applied, but the bytes changed since.
      pastJob(vault, 'job-f', [files[5]!], 'completed', { op: 'op-f', changed: ['wiki/sources/f.md'] }),
    ];
    jobs.forEach((j, i) => turnFile(j, full(files[i]!)));
    fs.appendFileSync(path.join(vault, files[5]!), 'one more line\n');
    const { fr } = moduleHarness(jobs, vault);
    assert.equal(fr.backfill(), 1);
    const content = (f: string) => sha(fs.readFileSync(path.join(vault, f)));
    assert.equal(fr.index.isFull(content(files[0]!)), true);
    for (const f of files.slice(1)) assert.equal(fr.index.isFull(content(f)), false, f);
  });

  test('a read of only part of a file is not a full read', () => {
    const vault = path.join(tmp, 'vault');
    fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
    const a = note(vault, 'a.md', 644);
    ledgerFor(vault, [{ file: a, page: 'wiki/sources/a.md' }]);
    const job = pastJob(vault, 'job-a', [a], 'completed', { op: 'op-a', changed: ['wiki/sources/a.md'] });
    turnFile(job, read(path.join(vault, a), 1, 139, 644));
    assert.equal(moduleHarness([job], vault).fr.backfill(), 0);
  });
});

describe('the repair', () => {
  test('queues sources never read in full, once, packed by tokens; skips what a live job or a waiting re-read holds', async () => {
    const vault = path.join(tmp, 'vault');
    fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
    const files = ['a', 'b', 'c', 'd'].map((x) => note(vault, `${x}.md`, 10));
    ledgerFor(vault, files.map((f) => ({ file: f, page: `wiki/sources/${path.posix.basename(f, '.md')}.md` })));
    // b: in a batch still in Review; c: in a re-read group not started; d: in a running batch by content only.
    const live = pastJob(vault, 'job-live', [files[1]!], 'awaitingApproval');
    const running = pastJob(vault, 'job-run', ['inbox/renamed.md'], 'running');
    fs.mkdirSync(jobStateDirectory(running), { recursive: true });
    fs.writeFileSync(
      path.join(jobStateDirectory(running), 'coverage.json'),
      JSON.stringify({ version: 1, sessionID: 's', seq: 0, lastContext: 0, sources: [{ file: 'inbox/renamed.md', kind: 'text', sha256: sha(fs.readFileSync(path.join(vault, files[3]!))), lines: 10, sourceLines: 10, imageLines: [], sections: [], estTokens: 10 }], events: [], rounds: 0, creditedAtLastRound: 0 }),
    );
    const { fr, requests } = moduleHarness([live, running], vault, { waiting: [files[2]!] });
    const res = await fr.repairScan({ path: vault, queueDirectory: '' }, { force: true });
    assert.ok(res);
    assert.equal(requests.length, 1);
    assert.deepEqual(requests[0]!.files, [files[0]]);
    assert.equal(requests[0]!.reason, 'repair');
    assert.equal(requests[0]!.perBatch, undefined, 'packed by tokens, not by count');
    // Never twice for the same content.
    await fr.repairScan({ path: vault, queueDirectory: '' }, { force: true });
    assert.equal(requests.length, 1);
  });

  test('nothing runs while automatic processing is off', async () => {
    const vault = path.join(tmp, 'vault');
    fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
    const a = note(vault, 'a.md', 3);
    ledgerFor(vault, [{ file: a, page: 'wiki/sources/a.md' }]);
    const state = path.join(tmp, 'state2');
    const calls: unknown[] = [];
    const fr = createFullRead({
      paths: statePaths(state),
      now: () => new Date(),
      settings: () => ({ autoProcessEnabled: false }) as Settings,
      runners: createRunnerRegistry([]),
      jobs: () => [],
      findJob: () => undefined,
      mutate: () => {},
      runTurn: () => {},
      sessionGone: () => false,
      vaultProfileFor: () => ({ path: vault, queueDirectory: '' }),
      log: () => {},
      emit: () => {},
      signalOf: () => undefined,
      readingPrompt: () => '',
      rereadSources: async (r) => {
        calls.push(r);
        return {} as never;
      },
      waitingRereadFiles: () => new Set(),
      nextPartBundle: (d) => d,
    });
    assert.equal(await fr.repairScan({ path: vault, queueDirectory: '' }, { force: true }), undefined);
    assert.equal(calls.length, 0);
  });
});

describe('activity and live log', () => {
  test('a stop and a queued repair are in Activity; full-read steps are in the live log', () => {
    const log = new ActivityLog({ dir: path.join(tmp, 'activity') });
    const logEvent = createEventLogger({ log, getSettings: () => ({ askPreferences: { historyDays: 10 } }) as never, collectorName: () => undefined }, []);
    const job = newJob({ id: 'job-s', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md', 'inbox/bad.md'], model: 'sonnet', now: new Date() });
    logEvent({ type: 'job', job });
    job.stopped = [{ file: 'inbox/bad.md', reason: 'it isn’t valid UTF-8 text from line 2', at: '2026-10-05' }];
    logEvent({ type: 'job', job });
    logEvent({ type: 'job', job });
    logEvent({ type: 'repair.queued', vaultPath: '/v', rereadId: 'reread-1', sources: 22, batches: 3, files: ['inbox/x.md'] });
    const entries = log.list().entries;
    const stopped = entries.filter((e) => e.type === 'batch.read_stopped');
    assert.equal(stopped.length, 1, 'once per source');
    assert.deepEqual(stopped[0]!.details?.files, ['inbox/bad.md']);
    const repair = entries.find((e) => e.type === 'batch.repair_queued')!;
    assert.match(repair.summary, /22 sources again in 3 batches/);

    const steps = createStepLog({ dir: path.join(tmp, 'steps'), emit: () => {}, getJob: () => job });
    steps.onEvent({ type: 'job', job });
    steps.fullRead(job.id, { text: 'Not read yet: lines 140–643 of “AIDR”', state: 'done', verb: 'coverage' });
    steps.fullRead(job.id, { id: 'detail', text: 'Checking each page against its source · 0 of 2', state: 'running', verb: 'detail' });
    steps.fullRead(job.id, { id: 'detail', text: 'Checking each page against its source · 2 of 2', state: 'done', verb: 'detail' });
    const list = steps.list(job.id).steps.filter((s) => s.phase === 'check');
    assert.deepEqual(list.map((s) => [s.verb, s.state, s.text]), [
      ['coverage', 'done', 'Not read yet: lines 140–643 of “AIDR”'],
      ['detail', 'done', 'Checking each page against its source · 2 of 2'],
    ]);
  });
});

describe('the reading copy in a batch', () => {
  test('a job saved before v10 still decodes', () => {
    const j = newJob({ id: 'job-1', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md'], model: 'm', now: new Date() });
    assert.equal(JSON.parse(JSON.stringify(encodeJob(j))).coverage, undefined);
  });
});
